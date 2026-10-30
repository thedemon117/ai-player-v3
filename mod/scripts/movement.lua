-- Asynchronous walking (v3).
--
-- Skills run synchronously inside one tick, but walking takes many: the
-- character has to hold a walking_state every tick until it arrives. walk_to()
-- records the destination in storage.ai_player.walk and step() (called from
-- on_tick) steers toward it. The route comes from the engine pathfinder
-- (surface.request_path, answered asynchronously through
-- on_script_path_request_finished): the character follows the waypoints, so
-- trees, water and buildings are walked around. If no path is returned (or the
-- request cannot be made) it falls back to a straight line, which fails as
-- "blocked" when something is in the way and lets the caller decide.
--
-- Outcome of the last walk lives in storage.ai_player.walk_result:
--   {status = "arrived"|"timeout"|"blocked"|"cancelled"|"lost", tick, target, pos}

AIMovement = {}

local LOG_FILE = "ai-player/errors.log"

local REACH         = 1.5   -- tiles from the target counted as arrived
local STUCK_TICKS   = 45    -- ticks without real progress before giving up
local STUCK_EPSILON = 0.02  -- tiles per tick below which we count as not moving
local GRACE_TICKS   = 120   -- slack added on top of the estimated travel time
local MAX_TIMEOUT   = 60 * 60 * 5  -- hard cap: 5 minutes of game time
local WALK_SPEED    = 0.15  -- tiles per tick of an unboosted character (conservative)
local PATH_WAIT     = 600   -- ticks to wait for the pathfinder before going straight
local WAYPOINT_NEAR = 0.8   -- tiles from a waypoint counted as passed

local function debug_print(msg)
  if settings.global["ai-player-debug-chat"] and settings.global["ai-player-debug-chat"].value then
    game.print("[AI] " .. msg, {r=0.7, g=0.9, b=1})
  end
end

local function log_line(msg)
  helpers.write_file(LOG_FILE, string.format("[tick=%d] walk: %s\n", game.tick, msg), true)
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Eight-way direction closest to the vector (dx, dy). Factorio's y axis points
-- south, so north is -y.
local function direction_to(dx, dy)
  local angle = math.atan2(dx, -dy)  -- 0 = north, clockwise positive
  local octant = math.floor(angle / (math.pi / 4) + 0.5) % 8
  return octant * 2  -- defines.direction.north == 0, northeast == 2, ...
end

local function finish(character, status, extra)
  local w = storage.ai_player.walk
  storage.ai_player.walk = nil
  if character and character.valid then
    character.walking_state = {walking = false}
  end
  local pos = character and character.valid and character.position or nil
  storage.ai_player.walk_result = {
    status = status, tick = game.tick, target = w and w.target, pos = pos,
  }
  local line = string.format("%s target=(%.1f,%.1f) pos=%s", status,
    w and w.target.x or 0, w and w.target.y or 0,
    pos and string.format("(%.1f,%.1f)", pos.x, pos.y) or "none")
  log_line(line)
  debug_print("walk " .. line)
  -- Surface the outcome in the next decision's E1 feedback, since the skill that
  -- started the walk returned long ago.
  local mem = storage.ai_player.memory
  if mem then
    mem.last_action_results = mem.last_action_results or {}
    table.insert(mem.last_action_results, {
      action = "walk", ok = (status == "arrived"), detail = line,
    })
  end
end

local function request_path(character, w)
  local ok, id = pcall(function()
    return character.surface.request_path{
      bounding_box = character.prototype.collision_box,
      collision_mask = character.prototype.collision_mask,
      start = character.position, goal = w.target, force = character.force,
      entity_to_ignore = character,   -- else its own collision box blocks the start
      radius = REACH, can_open_gates = true,
      pathfind_flags = {cache = false, prefer_straight_paths = true},
    }
  end)
  if ok and id then
    w.path_id, w.path_wait_until = id, game.tick + PATH_WAIT
    log_line("path requested id=" .. tostring(id))
  else
    log_line("pathfinder request failed, walking straight: " .. tostring(id))
  end
end

-- on_script_path_request_finished: attach the route to the walk that asked.
function AIMovement.on_path(event)
  local w = storage.ai_player and storage.ai_player.walk
  if not (w and w.path_id and w.path_id == event.id) then return end
  w.path_id = nil
  if event.path and #event.path > 0 then
    w.waypoints, w.wp = event.path, 1
    local len, prev = 0, nil
    for _, wp in ipairs(event.path) do
      if prev then len = len + dist(prev, wp.position) end
      prev = wp.position
    end
    local c = AICharacter.get_character()
    local speed = (c and c.valid and c.character_running_speed or WALK_SPEED)
    if speed <= 0 then speed = WALK_SPEED end
    local want = game.tick + math.ceil(len / speed) + GRACE_TICKS
    w.deadline = math.min(math.max(w.deadline, want), w.started + MAX_TIMEOUT)
    log_line(string.format("path found: %d waypoints, %.1f tiles", #event.path, len))
  elseif event.try_again_later and not w.retried then
    w.retried = true
    local c = AICharacter.get_character()
    if c and c.valid then request_path(c, w) end
  else
    log_line(string.format("no path to target (try_again_later=%s, id=%s, tick %d), walking straight",
      tostring(event.try_again_later), tostring(event.id), game.tick))
  end
end

-- Start walking toward target ({x=,y=}). Replaces any walk in progress.
-- Returns (ok, detail) like a skill. ok=true only means the walk started (or
-- we are already there); the outcome arrives later via walk_result.
function AIMovement.walk_to(character, target, timeout)
  if not (character and character.valid) then return false, "walk: no valid character" end
  local x, y = tonumber(target and target.x), tonumber(target and target.y)
  if not (x and y) then return false, "walk: target must be {x=N, y=N}" end
  target = {x = x, y = y}

  local d = dist(character.position, target)
  if d <= REACH then
    storage.ai_player.walk = nil
    return true, string.format("already at (%.0f, %.0f)", x, y)
  end

  local speed = (character.character_running_speed or WALK_SPEED)
  if speed <= 0 then speed = WALK_SPEED end
  local budget = math.min(timeout or (math.ceil(d / speed) + GRACE_TICKS), MAX_TIMEOUT)
  storage.ai_player.walk = {
    target = target, started = game.tick, deadline = game.tick + budget,
    last_pos = {x = character.position.x, y = character.position.y}, stuck = 0,
  }
  log_line(string.format("start from (%.1f,%.1f) to (%.1f,%.1f) dist=%.1f budget=%d",
    character.position.x, character.position.y, x, y, d, budget))
  request_path(character, storage.ai_player.walk)
  return true, string.format("walking to (%.0f, %.0f), %.0f tiles, ~%d ticks — check position next turn",
    x, y, d, math.ceil(d / speed))
end

function AIMovement.cancel(character)
  if storage.ai_player and storage.ai_player.walk then finish(character, "cancelled") end
end

-- Compact view for status queries / prompts. nil when idle.
function AIMovement.status()
  local w = storage.ai_player and storage.ai_player.walk
  if not w then return nil end
  return {target = w.target, ticks_left = w.deadline - game.tick}
end

-- Called every tick from on_tick, independent of the autonomy gate.
function AIMovement.step()
  local w = storage.ai_player and storage.ai_player.walk
  if not w then return end

  local character = AICharacter.get_character()
  if not (character and character.valid) then
    finish(nil, "lost")
    return
  end

  local pos = character.position
  if dist(pos, w.target) <= REACH then
    finish(character, "arrived")
    return
  end
  if game.tick >= w.deadline then
    finish(character, "timeout")
    return
  end

  -- Progress check: only samples movement, so standing still against a wall
  -- (or a cliff/water edge) fails fast instead of burning the whole timeout.
  if dist(pos, w.last_pos) < STUCK_EPSILON then
    w.stuck = w.stuck + 1
    if w.stuck >= STUCK_TICKS then
      finish(character, "blocked")
      return
    end
  else
    w.stuck = 0
  end
  w.last_pos = {x = pos.x, y = pos.y}

  local aim = w.target
  if w.path_id then
    if game.tick < w.path_wait_until then
      character.walking_state = {walking = false}
      w.stuck = 0   -- standing still while the pathfinder works is not "blocked"
      return
    end
    w.path_id = nil
    log_line("pathfinder gave no answer in time, walking straight")
  elseif w.waypoints then
    local wps = w.waypoints
    while w.wp < #wps and dist(pos, wps[w.wp].position) < WAYPOINT_NEAR do w.wp = w.wp + 1 end
    aim = wps[w.wp].position
  end
  character.walking_state = {
    walking = true, direction = direction_to(aim.x - pos.x, aim.y - pos.y),
  }
end

return AIMovement
