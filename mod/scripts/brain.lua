-- Request/response lifecycle between the mod and the bridge.
--
-- The bridge (Python) is responsible for:
--   - Assembling the LLM prompt (system prompt + perception + memory)
--   - Calling the LLM provider
--   - Parsing and validating the response
--   - Sending the action list back via /ai-response
--
-- This module is responsible for:
--   - Writing perception + memory to a request file
--   - Managing pending request state
--   - Parsing the action JSON from /ai-response
--   - Maintaining in-game memory (notes, todos, summary, directive)

AIBrain = {}

-- How long the mod waits for a bridge response before discarding a pending
-- request. MUST be longer than the bridge's own SDK timeout, or a slow model's
-- legitimate response arrives after the mod has already expired the request
-- ("Unknown request id"). The bridge pushes the derived value into
-- storage.ai_player.request_timeout_ticks via RCON at startup (single source =
-- AI_TIMEOUT); this constant is only the fallback when the bridge hasn't set it.
local DEFAULT_REQUEST_TIMEOUT_TICKS = 18000  -- 300s at 60 tps

-- -------------------------------------------------------------------------
-- Config helpers
-- -------------------------------------------------------------------------

local function setting(name)
  return settings.global[name] and settings.global[name].value
end

local function json_escape(s)
  s = tostring(s or "")
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"',  '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

-- -------------------------------------------------------------------------
-- Write bridge config (called on init and settings change)
-- -------------------------------------------------------------------------

function AIBrain.write_bridge_config()
  local content = string.format(
    '{"provider":"%s","model_name":"%s","lm_studio_url":"%s",' ..
    '"openai_api_key":"%s","openai_api_base":"%s","custom_url":"%s",' ..
    '"rcon_host":"%s","rcon_port":%d,"rcon_password":"%s"}',
    json_escape(setting("ai-player-provider") or "lmstudio"),
    json_escape(setting("ai-player-model-name") or "local-model"),
    json_escape(setting("ai-player-lm-studio-url") or ""),
    json_escape(setting("ai-player-openai-api-key") or ""),
    json_escape(setting("ai-player-openai-api-base") or ""),
    json_escape(setting("ai-player-custom-url") or ""),
    json_escape(setting("ai-player-rcon-host") or "localhost"),
    tonumber(setting("ai-player-rcon-port")) or 27015,
    json_escape(setting("ai-player-rcon-password") or "")
  )
  helpers.write_file("ai-player/config.json", content, false)
end

-- -------------------------------------------------------------------------
-- Request serialisation
-- -------------------------------------------------------------------------

-- Serialise a Lua value to a JSON string (no external library — hand-rolled
-- for the limited set of types perception actually produces).
local function to_json(val)
  local t = type(val)
  if val == nil  then return "null" end
  if t == "boolean" then return val and "true" or "false" end
  if t == "number" then
    if val ~= val then return "null" end  -- NaN
    return tostring(val)
  end
  if t == "string" then
    return '"' .. json_escape(val) .. '"'
  end
  if t == "table" then
    -- Detect array (all integer keys 1..n)
    local is_array = true
    local max_i = 0
    for k in pairs(val) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false
        break
      end
      if k > max_i then max_i = k end
    end
    if is_array and max_i == #val then
      local parts = {}
      for i = 1, #val do
        parts[i] = to_json(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, '"' .. json_escape(k) .. '":' .. to_json(v))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

-- -------------------------------------------------------------------------
-- Make a decision request
-- -------------------------------------------------------------------------

function AIBrain.request_decision(character, user_message)
  local mem = storage.ai_player.memory

  -- A directive sent while a request was in flight is queued; pick it up here so
  -- it still reaches the bridge as a user_message (and gets a chat reply).
  user_message = user_message or mem.pending_user_message

  -- Only one pending request at a time. Keep the queued message for next time.
  if next(storage.ai_player.pending_requests) ~= nil then
    if setting("ai-player-debug-chat") then
      game.print("[AI Brain] Skipping — pending request in flight")
    end
    return
  end

  -- We are committing to a request now — consume the queued message.
  mem.pending_user_message = nil

  local perception = AIPerception.gather(character)

  -- Build minimal memory snapshot for the bridge
  local memory_snapshot = {
    previous_summary    = mem.previous_summary,
    notes               = mem.notes,
    todo_lists          = mem.todo_lists,
    recent_actions      = mem.recent_actions,
    user_directive      = mem.user_directive,
    force_skill         = mem.force_skill,
    last_action_results = mem.last_action_results,
  }

  local req_id = tostring(game.tick) .. "_" .. tostring(math.random(10000, 99999))

  local body = to_json({
    req_id     = req_id,
    perception = perception,
    memory     = memory_snapshot,
    user_message = user_message or nil,
  })

  helpers.write_file("ai-player/request_" .. req_id .. ".json", body, false)

  storage.ai_player.pending_requests[req_id] = {
    timestamp    = game.tick,
    user_message = user_message,
  }

  if setting("ai-player-debug-chat") then
    game.print("[AI Brain] Request " .. req_id .. " written")
  end
end

-- -------------------------------------------------------------------------
-- Handle /ai-response from the bridge
-- -------------------------------------------------------------------------

function AIBrain.handle_response(req_id, actions_json)
  local pending = storage.ai_player.pending_requests[req_id]
  if not pending then
    game.print("[AI Brain] Unknown request id: " .. req_id, {r=1, g=0.5, b=0})
    return
  end

  storage.ai_player.pending_requests[req_id] = nil

  if setting("ai-player-debug-chat") then
    game.print("[AI Brain] Response for " .. req_id .. ": " .. actions_json:sub(1, 120))
  end

  -- Track last responded-to player message for dedup
  if pending.user_message then
    storage.ai_player.memory.last_responded_to_message = pending.user_message
  end

  local entries = AIBrain.parse_actions(actions_json)
  if not entries or #entries == 0 then
    game.print("[AI Brain] No valid skill/action entries parsed from response", {r=1, g=0.5, b=0})
    return
  end

  -- Entries may be skills {skill=...} or primitives {action=...}; the unified
  -- executor dispatches each and records E1 results.
  AISkills.execute(storage.ai_player.character, entries)
end

-- -------------------------------------------------------------------------
-- Expire stale requests
-- -------------------------------------------------------------------------

function AIBrain.process_pending(current_tick)
  local limit = storage.ai_player.request_timeout_ticks or DEFAULT_REQUEST_TIMEOUT_TICKS
  for req_id, req in pairs(storage.ai_player.pending_requests) do
    if current_tick - req.timestamp > limit then
      game.print(
        string.format("[AI Brain] Request %s timed out after %ds", req_id,
          math.floor(limit / 60)),
        {r=1, g=0.5, b=0}
      )
      storage.ai_player.pending_requests[req_id] = nil
    end
  end
end

-- -------------------------------------------------------------------------
-- JSON action parser
-- Custom regex-based parser — Lua has no JSON library at runtime.
-- Parses a flat array of action objects with string/number/position fields.
-- -------------------------------------------------------------------------

function AIBrain.parse_actions(json_str)
  if not json_str or json_str == "" then return {} end

  -- Strip reasoning tags from models that emit <think>…</think>
  json_str = json_str:gsub("<think>.-</think>", "")

  -- Find outermost [ ... ]
  local array_start = json_str:find("%[")
  if not array_start then return {} end
  local depth = 0
  local array_end = nil
  for i = array_start, #json_str do
    local ch = json_str:sub(i, i)
    if ch == "[" then depth = depth + 1
    elseif ch == "]" then
      depth = depth - 1
      if depth == 0 then array_end = i; break end
    end
  end
  if not array_end then return {} end

  local array_str = json_str:sub(array_start, array_end)

  -- Extract individual { ... } objects
  local actions = {}
  local i = 1
  while i <= #array_str do
    local obj_start = array_str:find("{", i)
    if not obj_start then break end

    depth = 0
    local obj_end = nil
    for j = obj_start, #array_str do
      local ch = array_str:sub(j, j)
      if ch == "{" then depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 then obj_end = j; break end
      end
    end
    if not obj_end then break end

    local obj_str = array_str:sub(obj_start, obj_end)
    local action = AIBrain.parse_action_object(obj_str)
    if action and (action.action or action.skill) then
      table.insert(actions, action)
    end

    i = obj_end + 1
  end

  return actions
end

function AIBrain.parse_action_object(obj_str)
  local action = {}

  -- String fields (primitive + skill params)
  for _, field in ipairs({"action","skill","direction","item","name","type","recipe",
                           "ore","output","message","text","title","inventory","slot"}) do
    local val = obj_str:match('"' .. field .. '":%s*"([^"]*)"')
    if val then action[field] = val end
  end

  -- Number fields
  for _, field in ipairs({"count","radius","distance","index"}) do
    local val = obj_str:match('"' .. field .. '":%s*([%-]?%d+%.?%d*)')
    if val then action[field] = tonumber(val) end
  end

  -- Position object {x:N, y:N}
  local pos_str = obj_str:match('"position"%s*:%s*({[^}]*})')
  if pos_str then
    local px = pos_str:match('"?x"?%s*:%s*([%-]?%d+%.?%d*)')
    local py = pos_str:match('"?y"?%s*:%s*([%-]?%d+%.?%d*)')
    if px and py then
      action.position = {x = tonumber(px), y = tonumber(py)}
    end
  end

  -- items array for create_todo
  local items_str = obj_str:match('"items"%s*:%s*(%[[^%]]*%])')
  if items_str then
    local items = {}
    for item in items_str:gmatch('"([^"]+)"') do
      table.insert(items, item)
    end
    action.items = items
  end

  return action
end

-- -------------------------------------------------------------------------
-- Memory management
-- -------------------------------------------------------------------------

function AIBrain.init_memory()
  return {
    previous_summary            = nil,
    notes                       = {},
    todo_lists                  = {},
    recent_actions              = {},
    last_player_message         = nil,
    last_responded_to_message   = nil,
    pending_user_message        = nil,  -- chat msg waiting to reach the bridge (carries
                                        -- across a tick when a request was already in flight)
    last_action_results         = {},   -- E1: outcome of each action from the last turn
    user_directive              = nil,
    directive_expire_tick       = nil,
    force_skill                 = nil,  -- if set, the router prompt is gated to this skill
  }
end

function AIBrain.update_recent_actions(summary_text)
  local recent = storage.ai_player.memory.recent_actions
  table.insert(recent, 1, {tick = game.tick, text = summary_text})
  while #recent > 6 do table.remove(recent) end
end

function AIBrain.set_directive(text, duration_ticks)
  local mem = storage.ai_player.memory
  mem.user_directive = text
  mem.directive_expire_tick = game.tick + (duration_ticks or 1800)
  -- If the directive's first word names a skill (e.g. "gather wood",
  -- "build_miner on iron"), gate the router to that skill until expiry.
  -- Otherwise leave it as a soft directive the model interprets freely.
  local first = text:match("^%s*(%S+)")
  if first and AISkills.REGISTRY[first] then
    mem.force_skill = first
  else
    mem.force_skill = nil
  end
end

function AIBrain.process_directive_expiry(current_tick)
  local mem = storage.ai_player.memory
  if mem.directive_expire_tick and current_tick > mem.directive_expire_tick then
    mem.user_directive = nil
    mem.directive_expire_tick = nil
    mem.force_skill = nil
  end
end

return AIBrain
