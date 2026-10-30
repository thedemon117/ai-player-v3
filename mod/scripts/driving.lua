-- Asynchronous driving (v3): boards the nearest free car, then steers it tick by
-- tick toward a point. Like walking, a skill only starts the job
-- (AIDriving.start) and step() (called from on_tick) runs it; the outcome lands
-- in storage.ai_player.drive_result and memory.last_action_results.
--
-- Steering is continuous orientation control with braking near the goal and a
-- couple of reverse attempts when stuck. Cars cannot path around lakes or
-- forests: a car that cannot make progress fails honestly (walking, which does
-- pathfind, is the fallback).
--
--   drive_result = {status = "parked"|"failed", tick, detail, pos}

AIDriving = {}

local LOG_FILE = "ai-player/errors.log"

local BOARD_SEARCH_RADIUS = 30
local BOARD_REACH         = 3     -- tiles from the car at which the character gets in
local ARRIVE_DEFAULT      = 3
local STUCK_CHECK_TICKS   = 90
local STUCK_EPSILON_SQ    = 0.25
local REVERSE_TICKS       = 45
local MAX_TICKS           = 60 * 60 * 5

local function log_line(msg)
  helpers.write_file(LOG_FILE, string.format("[tick=%d] drive: %s\n", game.tick, msg), true)
end

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Map orientation: 0 = north, clockwise, 0..1.
local function desired_orientation(from, to)
  return (math.atan2(to.x - from.x, -(to.y - from.y)) / (2 * math.pi)) % 1
end

local function finish(character, status, detail)
  storage.ai_player.drive = nil
  if character and character.valid then
    pcall(function() character.riding_state = {
      acceleration = defines.riding.acceleration.nothing, direction = defines.riding.direction.straight} end)
  end
  local pos = character and character.valid and character.position or nil
  storage.ai_player.drive_result = {status = status, tick = game.tick, detail = detail, pos = pos}
  log_line(status .. ": " .. detail)
  local mem = storage.ai_player.memory
  if mem then
    mem.last_action_results = mem.last_action_results or {}
    table.insert(mem.last_action_results, {action = "drive", ok = (status == "parked"), detail = detail})
  end
end

-- Put coal/wood/etc. from the character's inventory into the car if it has none.
local function fuel_car(character, car)
  local has = false
  pcall(function()
    has = car.burner.currently_burning ~= nil or car.burner.inventory.get_item_count() > 0
  end)
  if has then return true end
  local main = character.get_inventory(defines.inventory.character_main)
  -- get_contents is a list of {name, count} on 2.0 and may be a name -> count map elsewhere
  local items = {}
  for k, v in pairs(main.get_contents()) do
    if type(v) == "table" then items[#items + 1] = {name = v.name, count = v.count}
    else items[#items + 1] = {name = k, count = v} end
  end
  for _, item in ipairs(items) do
    local proto = prototypes.item[item.name]
    local inserted = 0
    local ok, err = pcall(function()
      -- can_insert respects the burner's fuel categories (fuel_category is gone on 2.1)
      local inv = car.burner.inventory
      if proto.fuel_value and proto.fuel_value > 0 and inv.can_insert{name = item.name, count = 1} then
        inserted = inv.insert{name = item.name, count = math.min(item.count, 10)}
      end
    end)
    if not ok then log_line("fuel_car: " .. tostring(err)) end
    if inserted > 0 then main.remove{name = item.name, count = inserted}; return true end
  end
  return false
end

-- Begin driving toward target ({x=,y=}). Returns (ok, detail) like a skill.
function AIDriving.start(character, target, arrive_within)
  local x, y = tonumber(target and target.x), tonumber(target and target.y)
  if not (x and y) then return false, "drive_to: position must be {x=N, y=N}" end
  local d = {target = {x = x, y = y}, arrive = math.max(tonumber(arrive_within) or ARRIVE_DEFAULT, 2),
             started = game.tick, phase = "drive"}
  if not character.vehicle then
    local best, best_d
    for _, e in ipairs(AIVision.filter_known(character.surface.find_entities_filtered{
        type = "car", position = character.position, radius = BOARD_SEARCH_RADIUS, force = character.force},
        character.surface, character.force)) do
      if e.valid and not e.get_driver() then
        local dd = dist_sq(e.position, character.position)
        if not best or dd < best_d then best, best_d = e, dd end
      end
    end
    if not best then
      return false, string.format("drive_to: no free car of yours within %d tiles — craft and place one first, or walk (goto)",
        BOARD_SEARCH_RADIUS)
    end
    d.phase, d.car = "board", best
    AIMovement.walk_to(character, {x = best.position.x, y = best.position.y + 2})
  end
  storage.ai_player.drive = d
  return true, string.format("%s, then driving to (%.0f, %.0f) — check position next turn",
    d.phase == "board" and "walking to the car" or "driving", x, y)
end

function AIDriving.status()
  local d = storage.ai_player and storage.ai_player.drive
  if not d then return nil end
  return {phase = d.phase, target = d.target}
end

-- Leave the vehicle (instant). Returns (ok, detail).
function AIDriving.exit(character)
  if not character.vehicle then return false, "exit_vehicle: not in a vehicle" end
  local name = character.vehicle.name
  storage.ai_player.drive = nil
  character.driving = false
  return true, string.format("left the %s at (%.0f, %.0f)", name, character.position.x, character.position.y)
end

-- Called every tick from on_tick, independent of the autonomy gate.
function AIDriving.step()
  local d = storage.ai_player and storage.ai_player.drive
  if not d then return end
  local character = AICharacter.get_character()
  if not (character and character.valid) then
    storage.ai_player.drive = nil
    return
  end
  if game.tick - d.started > MAX_TICKS then
    return finish(character, "failed", "timed out after 5 minutes")
  end
  local acc, rdir = defines.riding.acceleration, defines.riding.direction

  if d.phase == "board" then
    local car = d.car
    if not (car and car.valid) then return finish(character, "failed", "the car disappeared before I could get in") end
    if storage.ai_player.walk then return end   -- still walking over
    if dist_sq(character.position, car.position) > (BOARD_REACH + 2) ^ 2 then
      return finish(character, "failed", "could not reach the car (walk blocked) — move closer and try again")
    end
    if not fuel_car(character, car) then
      return finish(character, "failed", "the car has no fuel and I carry none — give me coal or wood")
    end
    car.set_driver(character)
    if character.vehicle ~= car then return finish(character, "failed", "couldn't get into the car — is someone driving it?") end
    d.phase = "drive"
    return
  end

  local car = character.vehicle
  if not car then return finish(character, "failed", "I'm not in a vehicle anymore") end
  local pos = car.position
  local dist = math.sqrt(dist_sq(pos, d.target))
  local speed_tps = math.abs(car.speed) * 60

  if dist <= d.arrive then
    if math.abs(car.speed) < 0.01 then
      return finish(character, "parked", string.format(
        "parked at (%.1f, %.1f) — still at the wheel; exit_vehicle to get out", pos.x, pos.y))
    end
    character.riding_state = {acceleration = acc.braking, direction = rdir.straight}
    return
  end

  local diff = (desired_orientation(pos, d.target) - car.orientation + 0.5) % 1 - 0.5
  local steer = rdir.straight
  if diff > 0.01 then steer = rdir.right elseif diff < -0.01 then steer = rdir.left end

  if d.reverse_until then
    if game.tick < d.reverse_until then
      character.riding_state = {acceleration = acc.reversing, direction = steer}
      return
    end
    d.reverse_until = nil
  end

  if not d.last_tick then
    d.last_tick, d.last_pos = game.tick, {x = pos.x, y = pos.y}
  elseif game.tick - d.last_tick >= STUCK_CHECK_TICKS then
    if dist_sq(pos, d.last_pos) < STUCK_EPSILON_SQ then
      local fuel_left = 1
      pcall(function()
        fuel_left = car.burner.inventory.get_item_count() + (car.burner.currently_burning and 1 or 0)
      end)
      if fuel_left == 0 then return finish(character, "failed", "the car ran out of fuel on the way") end
      d.reversals = (d.reversals or 0) + 1
      if d.reversals <= 2 then
        d.reverse_until = game.tick + REVERSE_TICKS
      else
        return finish(character, "failed", string.format(
          "the car is stuck at (%.1f, %.1f), %.0f tiles from the goal — something is in the way; goto (walking) pathfinds",
          pos.x, pos.y, dist))
      end
    elseif dist_sq(pos, d.last_pos) > 25 then
      d.reversals = 0
    end
    d.last_tick, d.last_pos = game.tick, {x = pos.x, y = pos.y}
  end

  local a = acc.accelerating
  -- brake ~1 s before the goal, but only while actually rolling: a stopped car that
  -- is still short of the goal must be allowed to creep forward
  if speed_tps > 1 and dist < math.max(d.arrive + 1, speed_tps) then a = acc.braking
  elseif math.abs(diff) > 0.15 and speed_tps > 8 then a = acc.braking end
  character.riding_state = {acceleration = a, direction = steer}
end

return AIDriving
