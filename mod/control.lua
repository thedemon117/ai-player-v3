-- ai-player-v3 entry point (skill-based agent)
-- Registers event handlers and console commands.
-- Logic delegates to scripts/*: character, perception, primitives (Tier-0
-- actions), skills (Tier-1 loops + unified executor), brain (request lifecycle).

require("scripts.character")
require("scripts.registry")
require("scripts.perception")
require("scripts.primitives")
require("scripts.brain")
require("scripts.skills")

-- -------------------------------------------------------------------------
-- Remote interface — lets an external MCP/RCON client invoke a skill against
-- the AI character and get its {ok, detail} result back synchronously, reusing
-- the SAME dispatch path the bridge uses (AISkills.run -> REGISTRY). Registered
-- in the main chunk so it exists on every load (Factorio requires interfaces to
-- be added identically each load). Call over RCON:
--   /sc rcon.print(game.table_to_json(
--     remote.call("ai_player", "run_skill", "gather", {item="coal", count=50})))
-- -------------------------------------------------------------------------
remote.add_interface("ai_player", {
  -- skill: registry name; params: table of skill params (item/count/ore/...).
  run_skill = function(skill, params)
    local character = AICharacter.get_character()
    if not character then
      return { ok = false, detail = "no ai character — /spawn-ai-player first" }
    end
    local entry = params or {}
    entry.skill = skill
    local ok, detail = AISkills.run(character, entry)
    return { ok = ok, detail = detail or "" }
  end,
  -- Discovery: sorted list of valid skill names.
  list_skills = function()
    local names = {}
    for n in pairs(AISkills.REGISTRY) do names[#names + 1] = n end
    table.sort(names)
    return names
  end,
  -- Compact, registry-backed situation snapshot (perception.lua factory_state).
  get_state = function()
    local character = AICharacter.get_character()
    if not character then
      return { error = "no ai character — /spawn-ai-player first" }
    end
    return AIPerception.factory_state(character)
  end,
  -- Toggle the autonomous on_tick decision loop. enabled: boolean.
  -- Returns the new state so the caller can confirm.
  set_autonomy = function(enabled)
    storage.ai_player.autonomy_enabled = (enabled == true)
    return { autonomy = storage.ai_player.autonomy_enabled }
  end,
  -- Switch co-op (rides the player force) vs solo (own force). enabled: boolean.
  -- Returns { coop = bool, force = name } so the caller can confirm.
  set_coop = function(enabled)
    return AICharacter.set_coop(enabled == true)
  end,
})

-- -------------------------------------------------------------------------
-- Storage initialisation
-- -------------------------------------------------------------------------

local function init_storage()
  storage.ai_player = storage.ai_player or {}
  local s = storage.ai_player
  s.character        = s.character or nil
  -- "player" = co-op (AI rides the human's force: shared base view, power,
  -- research). Any other name = solo (own force). Doubles as the mode switch
  -- (AICharacter.set_coop / remote set_coop / /ai-coop). Default: co-op.
  s.force_name       = s.force_name or "player"
  s.tick_counter     = s.tick_counter or 0
  s.pending_requests = s.pending_requests or {}
  s.chat_log         = s.chat_log or {}
  s.respawn_tick     = s.respawn_tick or nil
  s.map_tag          = s.map_tag or nil
  s.memory           = s.memory or AIBrain.init_memory()
  s.machines         = s.machines or {}   -- registry.lua: unit_number -> LuaEntity
  s.last_reconcile_tick = s.last_reconcile_tick or 0
  -- Autonomous on_tick decision loop on by default; an external harness can
  -- disable it (set_autonomy) so it doesn't contend with skill calls. The
  -- `~= false` keeps an explicit false across re-init instead of resetting it.
  s.autonomy_enabled = (s.autonomy_enabled ~= false)
end

-- Ensure exactly one AI character exists on ai_player_force.
-- If the stored reference is stale (entity was removed externally), clears it.
-- If multiple characters exist on the force (duplicate spawns), destroys extras.
-- Returns the valid character entity, or nil if none exists.
local function reconcile_character()
  if not storage.ai_player then return nil end

  local surface = game.surfaces["nauvis"]
  local force   = AICharacter.get_force()
  if not surface or not force then return nil end

  -- AI characters have NO controlling/associated player (the human's character
  -- does). This distinguishes the AI even when it shares the player force in
  -- co-op mode, so we never select or destroy the human's character.
  local chars = {}
  for _, c in ipairs(surface.find_entities_filtered{type = "character", force = force}) do
    if c.valid and c.player == nil and c.associated_player == nil then
      chars[#chars + 1] = c
    end
  end

  if #chars == 0 then
    -- No character in world — clear any stale reference
    storage.ai_player.character = nil
    return nil
  end

  if #chars > 1 then
    -- Duplicates — keep the one matching storage, or the first found; destroy the rest
    local keep = nil
    local stored = storage.ai_player.character
    for _, c in ipairs(chars) do
      if stored and stored.valid and c == stored then
        keep = c
        break
      end
    end
    if not keep then keep = chars[1] end
    for _, c in ipairs(chars) do
      if c ~= keep and c.valid then
        game.print(string.format("[AI] Removing duplicate character at {%.0f,%.0f}", c.position.x, c.position.y), {r=1,g=0.5,b=0})
        c.destroy()
      end
    end
    storage.ai_player.character = keep
    return keep
  end

  -- Exactly one character — ensure storage points to it
  storage.ai_player.character = chars[1]
  return chars[1]
end

-- Update/create the chart tag that marks the AI on the player's map.
-- Reveals fog of war around the character and places a named map marker.
local function update_map_tag()
  if not storage.ai_player then return end
  local character = storage.ai_player.character
  if not character or not character.valid then
    local tag = storage.ai_player.map_tag
    if tag and tag.valid then tag.destroy() end
    storage.ai_player.map_tag = nil
    return
  end

  local player_force = game.forces["player"]
  if not player_force then return end
  local surface = character.surface
  local pos     = character.position

  -- Reveal fog of war around AI so the tag is always visible on the map
  player_force.chart(surface, {
    left_top     = {x = pos.x - 64, y = pos.y - 64},
    right_bottom = {x = pos.x + 64, y = pos.y + 64},
  })

  -- Recreate tag at current position (tags are not moveable)
  local tag = storage.ai_player.map_tag
  if tag and tag.valid then tag.destroy() end
  storage.ai_player.map_tag = player_force.add_chart_tag(surface, {
    position = pos,
    text     = "AI Player",
    icon     = {type = "virtual", name = "signal-A"},
  })
end

-- -------------------------------------------------------------------------
-- Events
-- -------------------------------------------------------------------------

script.on_init(function()
  init_storage()
  AICharacter.create_force()
  AIBrain.write_bridge_config()
  game.print("[AI Player v3] Initialised — use /spawn-ai-player to start", {r=0, g=1, b=1})
end)

script.on_configuration_changed(function()
  init_storage()
  AICharacter.create_force()
  storage.ai_player.pending_requests = {}
  reconcile_character()
  -- Give an already-spawned character a home anchor if it lacks one (e.g. after
  -- updating to a mod version that added home tracking mid-session).
  local c = storage.ai_player.character
  if c and c.valid and not storage.ai_player.home_position then
    storage.ai_player.home_position = {x = math.floor(c.position.x), y = math.floor(c.position.y)}
  end
  AIBrain.write_bridge_config()
  -- Rebuild the machine registry from the live world (covers mod-update load and
  -- any machines created while the registry was absent/stale).
  AIRegistry.reconcile(game.surfaces["nauvis"], game.forces[storage.ai_player.force_name])
  game.print("[AI Player v3] Configuration reloaded", {r=0.7, g=1, b=0.7})
end)

script.on_load(function()
  -- on_load must NOT modify storage — Factorio CRC-checks it before/after
  -- and will abort with a save/load stability error if anything changed.
  --
  -- pending_requests: the bridge calls clear_pending_requests() via RCON on
  -- startup, and process_pending() expires stale requests after 150s anyway.
  --
  -- reconcile_character: entity references in storage survive save/load in
  -- Factorio automatically. on_configuration_changed handles reconciliation
  -- after F5 / mod setting changes where game is available.
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  local bridge_settings = {
    "ai-player-provider", "ai-player-model-name", "ai-player-lm-studio-url",
    "ai-player-openai-api-key", "ai-player-openai-api-base", "ai-player-custom-url",
    "ai-player-rcon-host", "ai-player-rcon-port", "ai-player-rcon-password",
  }
  for _, name in ipairs(bridge_settings) do
    if event.setting == name then
      AIBrain.write_bridge_config()
      break
    end
  end
end)

-- -------------------------------------------------------------------------
-- Machine registry — event-driven add/remove (latency optimisation; the
-- periodic reconcile in on_tick is the authoritative backbone). Filtered to
-- tracked machine types so these handlers don't fire for trees, biters, etc.
-- -------------------------------------------------------------------------

local function on_machine_built(event)
  local e = event.entity or event.created_entity or event.destination
  if e then AIRegistry.add(e) end
end

local function on_machine_removed(event)
  local e = event.entity
  if e and e.unit_number then AIRegistry.remove(e.unit_number) end
end

for _, ev in ipairs({
  defines.events.on_built_entity, defines.events.on_robot_built_entity,
  defines.events.script_raised_built, defines.events.script_raised_revive,
}) do
  script.on_event(ev, on_machine_built, AIRegistry.event_filters())
end

for _, ev in ipairs({
  defines.events.on_entity_died, defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity, defines.events.script_raised_destroy,
}) do
  script.on_event(ev, on_machine_removed, AIRegistry.event_filters())
end

-- -------------------------------------------------------------------------
-- Main tick
-- -------------------------------------------------------------------------

script.on_event(defines.events.on_tick, function(event)
  -- Self-heal if storage was never initialised (e.g. save loaded without on_init firing)
  if not storage.ai_player then
    init_storage()
    AICharacter.create_force()
    return
  end

  local tick = event.tick

  -- Periodic registry reconciliation — the authoritative correction path for the
  -- machine registry (events keep it fresh between these; this catches anything
  -- missed and prunes invalids). Every 600 ticks (~10s); cheap relative to that.
  if tick % 600 == 0 then
    AIRegistry.reconcile(game.surfaces["nauvis"], game.forces[storage.ai_player.force_name])
  end

  -- Auto-respawn
  if storage.ai_player.respawn_tick and tick >= storage.ai_player.respawn_tick then
    storage.ai_player.respawn_tick = nil
    AICharacter.spawn_ai_player()
  end

  -- Expire stale pending requests
  AIBrain.process_pending(tick)

  -- Expire directive
  AIBrain.process_directive_expiry(tick)

  -- Autonomy gate: when disabled (an external MCP/harness is driving via skill
  -- tools), skip the periodic self-directed decision so the built-in router
  -- doesn't issue competing actions. Maintenance above (registry reconcile,
  -- respawn, pending expiry) still runs; chat directives still trigger decisions
  -- via on_console_chat, which is independent of this loop.
  if storage.ai_player.autonomy_enabled == false then return end

  -- Decision tick
  local interval = settings.global["ai-player-tick-interval"].value or 300
  storage.ai_player.tick_counter = (storage.ai_player.tick_counter or 0) + 1
  if storage.ai_player.tick_counter < interval then return end
  storage.ai_player.tick_counter = 0

  local character = AICharacter.get_character()
  if not character then return end

  update_map_tag()
  AIBrain.request_decision(character, nil)
end)

-- -------------------------------------------------------------------------
-- Character death
-- -------------------------------------------------------------------------

script.on_event(defines.events.on_entity_died, function(event)
  if not storage.ai_player then return end
  if event.entity == storage.ai_player.character then
    game.print("[AI] Character died — respawning in 5s", {r=1, g=0.5, b=0})
    storage.ai_player.character = nil
    if settings.global["ai-player-auto-respawn"].value then
      storage.ai_player.respawn_tick = event.tick + 300
    end
  end
end)

-- -------------------------------------------------------------------------
-- Player chat → directive
-- -------------------------------------------------------------------------

script.on_event(defines.events.on_console_chat, function(event)
  if not storage.ai_player then return end
  if not event.message then return end

  local msg = event.message
  local lower = msg:lower()
  local directive = nil

  -- Prefixes: "ai: ", "ai, ", "!ai ", "ai <text>"
  if lower:sub(1,4) == "ai: " or lower:sub(1,4) == "ai, " then
    directive = msg:sub(5)
  elseif lower:sub(1,4) == "!ai " then
    directive = msg:sub(5)
  elseif lower:sub(1,3) == "ai " then
    directive = msg:sub(4)
  end

  if not directive or directive == "" then return end

  local mem = storage.ai_player.memory
  -- Skip if already responded to this exact message
  if mem.last_responded_to_message == directive then return end
  mem.last_player_message = directive
  -- Queue it so it reaches the bridge even if a request is currently in flight.
  mem.pending_user_message = directive

  AIBrain.set_directive(directive, 1800)

  -- Immediate, model-independent acknowledgement so the player always gets
  -- feedback the instant they speak — does not wait on the (possibly slow) LLM.
  game.print("[AI] Got it — working on: " .. directive, {r=0.5, g=0.9, b=1})

  local character = AICharacter.get_character()
  if character then
    AIBrain.request_decision(character, directive)
  else
    game.print("[AI] (no character spawned — use /spawn-ai-player)", {r=1, g=0.6, b=0})
  end
end)

-- -------------------------------------------------------------------------
-- Console commands
-- -------------------------------------------------------------------------

commands.add_command("spawn-ai-player", "Spawn or reset the AI player character",
  function()
    if not storage.ai_player then
      game.print("[AI] Not initialised", {r=1,g=0,b=0}); return
    end
    local ok = AICharacter.spawn_ai_player()
    if ok then
      game.print("[AI] Character spawned", {r=0,g=1,b=0})
    end
  end
)

commands.add_command("remove-ai-player", "Destroy the AI player character",
  function()
    if not storage.ai_player then return end
    -- Destroy only AI characters (no controlling/associated player) — so this is
    -- safe even when the AI shares the player force in co-op mode.
    local surface = game.surfaces["nauvis"]
    local force   = AICharacter.get_force()
    local removed = 0
    if surface and force then
      local chars = surface.find_entities_filtered{type="character", force=force}
      for _, c in ipairs(chars) do
        if c.valid and c.player == nil and c.associated_player == nil then
          c.destroy(); removed = removed + 1
        end
      end
    end
    storage.ai_player.character = nil
    storage.ai_player.respawn_tick = nil
    game.print(string.format("[AI] Removed %d character(s)", removed), {r=1,g=0.5,b=0})
  end
)

-- A free spot BESIDE `target` (never on top of it). Characters don't collide
-- with each other, so find_non_colliding_position happily returns the target's
-- exact position — landing a teleport there stacks the two characters and can
-- trap the human under an AI that isn't moving. Search adjacent offsets and
-- reject anything closer than 1 tile.
local function position_beside(surface, target)
  local offsets = {{1.5,0},{-1.5,0},{0,1.5},{0,-1.5},{1.5,1.5},{-1.5,-1.5},{1.5,-1.5},{-1.5,1.5}}
  for _, off in ipairs(offsets) do
    local pos = surface.find_non_colliding_position("character",
      {target.x + off[1], target.y + off[2]}, 4, 0.25)
    if pos then
      local dx, dy = pos.x - target.x, pos.y - target.y
      if (dx*dx + dy*dy) >= 1 then return pos end
    end
  end
  return target  -- fully enclosed target; overlap beats a failed teleport
end

commands.add_command("goto-ai-player", "Teleport to the AI player",
  function(cmd)
    if not storage.ai_player then return end
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active", {r=1,g=0,b=0}); return
    end
    local player = game.get_player(cmd.player_index)
    if player then
      player.teleport(position_beside(character.surface, character.position), character.surface)
    end
  end
)

commands.add_command("ai-coop",
  "Switch the AI between co-op (shares your force) and solo (own force). Usage: /ai-coop on|off",
  function(cmd)
    if not storage.ai_player then return end
    local arg = (cmd.parameter or ""):lower():match("%S+")
    if arg ~= "on" and arg ~= "off" then
      local cur = storage.ai_player.force_name == "player" and "co-op" or "solo"
      game.print("[AI] Usage: /ai-coop on|off  (currently " .. cur .. ")", {r=1,g=1,b=0})
      return
    end
    local r = AICharacter.set_coop(arg == "on")
    game.print("[AI] Mode: " .. (r.coop and "CO-OP — shares your force, sees your base" or "SOLO — own force"), {r=0,g=1,b=1})
  end
)

commands.add_command("ai-come", "Bring the AI character to you",
  function(cmd)
    if not storage.ai_player then return end
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active", {r=1,g=0,b=0}); return
    end
    local player = game.get_player(cmd.player_index)
    if player and player.character then
      local ps = player.character.surface
      character.teleport(position_beside(ps, player.character.position), ps)
      game.print("[AI] Coming to you", {r=0,g=1,b=1})
    end
  end
)

commands.add_command("ai-collect",
  "AI mines back ALL buildings it placed (into its inventory), then returns to you",
  function(cmd)
    if not storage.ai_player then return end
    -- Force-sweep mine: only safe on the AI's OWN (solo) force. In co-op the AI
    -- shares the player force, so this would mine the human's entire base — refuse.
    if storage.ai_player.force_name == "player" then
      game.print("[AI] ai-collect is disabled in co-op mode (it would mine the shared base). Switch to solo with /ai-coop off first.", {r=1,g=0.5,b=0})
      return
    end
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active", {r=1,g=0,b=0}); return
    end
    local surface = character.surface
    local force   = AICharacter.get_force()
    local char_inv = character.get_inventory(defines.inventory.character_main)
    local mined, left = 0, 0
    for _, e in ipairs(surface.find_entities_filtered{force = force}) do
      if e.valid and e.type ~= "character" and e.minable then
        local ok = e.mine{inventory = char_inv, raise_destroyed = true}
        if ok then mined = mined + 1 else left = left + 1 end
      end
    end
    game.print(string.format("[AI] Collected %d building(s)%s", mined,
      left > 0 and (" — " .. left .. " left (inventory full or unminable)") or ""),
      {r=0, g=1, b=0.5})
    -- Return to the player
    local player = game.get_player(cmd.player_index)
    if player and player.character then
      local ps = player.character.surface
      character.teleport(position_beside(ps, player.character.position), ps)
      game.print("[AI] Returned to you", {r=0, g=1, b=1})
    end
  end
)

commands.add_command("ai-do",
  "Force-run a skill deterministically (bypasses the LLM): /ai-do <skill> [arg] [count|output]",
  function(cmd)
    if not storage.ai_player then return end
    local character = AICharacter.get_character()
    if not character then
      game.print("[AI] No character active — /spawn-ai-player first", {r=1,g=0,b=0}); return
    end
    local param = cmd.parameter or ""
    local skill, rest = param:match("^%s*(%S+)%s*(.*)$")
    if not skill then
      game.print("[AI] usage: /ai-do <skill> [arg] [count|output]  e.g. /ai-do build_miner iron-ore", {r=1,g=0.8,b=0.3})
      return
    end
    if not AISkills.REGISTRY[skill] then
      local names = {}
      for n in pairs(AISkills.REGISTRY) do names[#names+1] = n end
      table.sort(names)
      game.print("[AI] unknown skill '" .. skill .. "'. Known: " .. table.concat(names, ", "), {r=1,g=0.6,b=0.3})
      return
    end
    -- arg maps to item/resource/ore so one token works across gather/miner/smelter.
    -- Tokenise (robust to extra/trailing spaces); arg1 = thing, arg2 = count|output.
    local tokens = {}
    for tok in rest:gmatch("%S+") do tokens[#tokens + 1] = tok end
    local entry = {skill = skill}
    if tokens[1] then
      entry.item = tokens[1]; entry.resource = tokens[1]; entry.ore = tokens[1]; entry.tech = tokens[1]
    end
    if tokens[2] then
      local n = tonumber(tokens[2])
      if n then entry.count = n else entry.output = tokens[2] end
    end
    AISkills.execute(character, {entry})
    local r = storage.ai_player.memory.last_action_results
    r = r and r[1]
    if r then
      game.print("[AI /ai-do] " .. (r.ok and "OK: " or "FAILED: ") .. (r.detail or ""),
        r.ok and {r=0.6,g=1,b=0.6} or {r=1,g=0.6,b=0.4})
    end
  end
)

commands.add_command("ai-force",
  "Lock the LLM to one skill until cleared: /ai-force <skill> [args] | /ai-force off",
  function(cmd)
    if not storage.ai_player then return end
    local mem = storage.ai_player.memory
    local param = (cmd.parameter or ""):match("^%s*(.-)%s*$")  -- trim both ends

    -- No arg: report current lock state.
    if param == "" then
      if mem.force_skill then
        game.print("[AI] Locked to skill: " .. mem.force_skill .. "  (/ai-force off to clear)", {r=1,g=0.9,b=0.5})
      else
        game.print("[AI] Not locked. Usage: /ai-force <skill> [args] | /ai-force off", {r=1,g=0.8,b=0.3})
      end
      return
    end

    -- Clear the lock.
    local lower = param:lower()
    if lower == "off" or lower == "none" or lower == "clear" then
      mem.force_skill = nil
      mem.user_directive = nil
      mem.directive_expire_tick = nil
      game.print("[AI] Skill lock cleared", {r=0.6,g=1,b=0.6})
      return
    end

    local skill = param:match("^(%S+)")
    if not AISkills.REGISTRY[skill] then
      local names = {}
      for n in pairs(AISkills.REGISTRY) do names[#names + 1] = n end
      table.sort(names)
      game.print("[AI] unknown skill '" .. skill .. "'. Known: " .. table.concat(names, ", "), {r=1,g=0.6,b=0.3})
      return
    end

    -- Persistent lock: unlike a chat directive (30s TTL), this has no expiry —
    -- it holds until /ai-force off. user_directive carries the param context
    -- (e.g. "build_miner iron-ore") into the prompt so the model fills params.
    mem.force_skill = skill
    mem.user_directive = param
    mem.directive_expire_tick = nil
    game.print("[AI] Locked to skill: " .. param .. "  (until /ai-force off)", {r=0.5,g=0.9,b=1})

    -- Kick off a decision now (tick-based, no chat ack) so it takes effect immediately.
    local character = AICharacter.get_character()
    if character then AIBrain.request_decision(character, nil) end
  end
)

commands.add_command("ai-response",
  "Internal: deliver bridge response to the mod",
  function(cmd)
    if not cmd.parameter then return end
    local sep = cmd.parameter:find("|")
    if not sep then
      game.print("[AI] ai-response: malformed (missing |)", {r=1,g=0,b=0}); return
    end
    local req_id     = cmd.parameter:sub(1, sep - 1)
    local actions_json = cmd.parameter:sub(sep + 1)
    AIBrain.handle_response(req_id, actions_json)
  end
)

commands.add_command("ai-pending",
  "Show pending AI requests",
  function()
    if not storage.ai_player then return end
    local pending = storage.ai_player.pending_requests
    if not next(pending) then
      game.print("[AI] No pending requests"); return
    end
    for id, req in pairs(pending) do
      local age = math.floor((game.tick - req.timestamp) / 60)
      local trigger = req.user_message and ("triggered by: \"" .. req.user_message .. "\"") or "tick-based"
      game.print(string.format("[AI] Pending #%s — %ds ago (%s)", id, age, trigger),
        {r=1, g=0.8, b=0.3})
    end
  end
)

commands.add_command("ai-clear",
  "Abort all in-flight AI requests (manual recovery if the agent is stalled)",
  function()
    if not storage.ai_player then return end
    local n = 0
    for _ in pairs(storage.ai_player.pending_requests) do n = n + 1 end
    storage.ai_player.pending_requests = {}
    game.print(string.format("[AI] Cleared %d pending request(s)", n), {r=1, g=0.8, b=0.3})
  end
)

commands.add_command("ai-memory",
  "Show AI memory (notes, todos, summary)",
  function()
    if not storage.ai_player then return end
    local mem = storage.ai_player.memory
    game.print("[AI Memory] === Notes ===", {r=0.8,g=0.8,b=1})
    if #mem.notes == 0 then
      game.print("  (none)")
    else
      for i, note in ipairs(mem.notes) do
        game.print(string.format("  %d: %s", i, note.text), {r=0.9,g=0.9,b=1})
      end
    end
    game.print("[AI Memory] === Todos ===", {r=0.8,g=1,b=0.8})
    if not next(mem.todo_lists) then
      game.print("  (none)")
    else
      for title, items in pairs(mem.todo_lists) do
        game.print("  [" .. title .. "]", {r=0.7,g=1,b=0.7})
        for i, item in ipairs(items) do
          local status = item.completed and "[DONE]" or "[ ]"
          game.print(string.format("    %s %d: %s", status, i, item.text))
        end
      end
    end
    if mem.previous_summary then
      game.print("[AI Memory] === Last Summary ===", {r=1,g=1,b=0.8})
      game.print("  " .. mem.previous_summary, {r=0.9,g=0.9,b=0.7})
    end
    if mem.user_directive then
      game.print("[AI Memory] === Active Directive ===", {r=1,g=0.8,b=0.5})
      game.print("  " .. mem.user_directive, {r=1,g=0.9,b=0.6})
    end
  end
)
