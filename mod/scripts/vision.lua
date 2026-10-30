-- Optional fog of war for the AI character (v3).
--
-- The engine never charts the map for a character that has no player, and
-- force.chart() does nothing while the force has no players. Without a filter,
-- find_entities_filtered sees every generated chunk, so a query could "find" ore
-- the character has never been near. This module keeps its own per-force set of
-- explored chunks and offers filters for perception queries:
--
--   KNOWN    chunk explored by the AI character, or charted by the force
--            (humans and radars chart for the whole force). Terrain, resources
--            and the force's own buildings are only reported in known chunks.
--   VISIBLE  within view radius of the AI character or a connected player, or
--            in a radar-visible chunk. Live details of other forces (enemies)
--            are only reported when visible.
--
-- Everything here is a no-op unless the runtime setting "ai-player-fog-of-war"
-- is on (default off), so existing behaviour is unchanged. Exploration is
-- recorded either way, so the setting can be switched on mid-game.

AIVision = {}

local CHART_RADIUS   = 2    -- chunks around the character marked explored
local VIEW_RADIUS    = 32   -- tiles: live visibility around a character
local EXPLORE_RADIUS = 64   -- tiles: how far into the unknown a walk goal may be
local START_AREA     = 200  -- tiles around spawn known from the start (freeplay charts this much)

function AIVision.enabled()
  local s = settings.global["ai-player-fog-of-war"]
  return s ~= nil and s.value == true
end

local function root()
  storage.vision = storage.vision or {explored = {}}
  return storage.vision
end

local function explored_set(force, surface)
  local by_force = root().explored
  local f = by_force[force.index]
  if not f then f = {}; by_force[force.index] = f end
  local s = f[surface.index]
  if not s then s = {}; f[surface.index] = s end
  return s
end

local function chunk_of(pos) return math.floor(pos.x / 32), math.floor(pos.y / 32) end
local function key(cx, cy) return cx .. "," .. cy end

local function charted(force, surface, cx, cy)
  local ok, c = pcall(function() return force.is_chunk_charted(surface, {cx, cy}) end)
  return ok and c or false
end

-- Mark the chunks around an entity explored and ask the generator for the ring
-- beyond, so paths toward the frontier don't run into ungenerated land.
function AIVision.mark(entity)
  if not (entity and entity.valid) then return end
  local set = explored_set(entity.force, entity.surface)
  local cx, cy = chunk_of(entity.position)
  for dx = -CHART_RADIUS, CHART_RADIUS do
    for dy = -CHART_RADIUS, CHART_RADIUS do set[key(cx + dx, cy + dy)] = true end
  end
  pcall(function() entity.surface.request_to_generate_chunks(entity.position, CHART_RADIUS + 1) end)
end

-- A player starts with the area around spawn on the map, so the AI does too —
-- once per force and surface.
function AIVision.grant_start_area(entity)
  local surface, force, center = entity.surface, entity.force, entity.position
  local v = root()
  v.start_granted = v.start_granted or {}
  local k = force.index .. ":" .. surface.index
  if v.start_granted[k] then return end
  v.start_granted[k] = true
  local set = explored_set(force, surface)
  local x1, y1 = chunk_of({x = center.x - START_AREA, y = center.y - START_AREA})
  local x2, y2 = chunk_of({x = center.x + START_AREA, y = center.y + START_AREA})
  for cx = x1, x2 do
    for cy = y1, y2 do set[key(cx, cy)] = true end
  end
  pcall(function() surface.request_to_generate_chunks(center, math.ceil(START_AREA / 32)) end)
end

-- Called from on_tick (every 30 ticks) with the AI character.
function AIVision.update(character)
  if not (character and character.valid) then return end
  AIVision.grant_start_area(character)
  AIVision.mark(character)
end

function AIVision.is_known(surface, force, pos)
  local cx, cy = chunk_of(pos)
  return explored_set(force, surface)[key(cx, cy)] == true or charted(force, surface, cx, cy)
end

-- Generated chunks inside the rectangle the force knows (all of them when fog of
-- war is off). Returns a list of {cx, cy}.
function AIVision.known_chunks(surface, force, x1, y1, x2, y2)
  local out, fog = {}, AIVision.enabled()
  for cy = math.floor(y1 / 32), math.floor(y2 / 32) do
    for cx = math.floor(x1 / 32), math.floor(x2 / 32) do
      if surface.is_chunk_generated({cx, cy})
          and (not fog or AIVision.is_known(surface, force, {x = cx * 32 + 16, y = cy * 32 + 16})) then
        out[#out + 1] = {cx, cy}
      end
    end
  end
  return out
end

local function viewers(surface, force)
  local out = {}
  local c = AICharacter.get_character()
  if c and c.valid and c.surface == surface and c.force == force then out[#out + 1] = c.position end
  for _, p in pairs(force.connected_players) do
    if p.surface == surface then out[#out + 1] = p.position end
  end
  return out
end

function AIVision.is_visible(surface, force, pos, cache)
  local r2 = VIEW_RADIUS * VIEW_RADIUS
  local vs = cache and cache.viewers or viewers(surface, force)
  if cache then cache.viewers = vs end
  for _, v in ipairs(vs) do
    local dx, dy = v.x - pos.x, v.y - pos.y
    if dx * dx + dy * dy <= r2 then return true end
  end
  local cx, cy = chunk_of(pos)
  local ok, vis = pcall(function() return force.is_chunk_visible(surface, {cx, cy}) end)
  return ok and vis or false
end

-- Filters keep input order. `force_on` applies the filter even when the setting
-- is off (an explicit charted_only request); otherwise they pass through.
function AIVision.filter_known(entities, surface, force, force_on)
  if not (force_on or AIVision.enabled()) then return entities end
  local memo, out = {}, {}
  for _, e in ipairs(entities) do
    if e.valid then
      local cx, cy = chunk_of(e.position)
      local k = key(cx, cy)
      local known = memo[k]
      if known == nil then
        known = explored_set(force, surface)[k] == true or charted(force, surface, cx, cy)
        memo[k] = known
      end
      if known then out[#out + 1] = e end
    end
  end
  return out
end

function AIVision.filter_visible(entities, surface, force)
  if not AIVision.enabled() then return entities end
  local cache, out = {}, {}
  for _, e in ipairs(entities) do
    if e.valid and AIVision.is_visible(surface, force, e.position, cache) then out[#out + 1] = e end
  end
  return out
end

-- Walk goals must be known terrain, or unexplored terrain close enough to be the
-- next exploration step. Returns nil when fine, else a reason the model can act on.
function AIVision.walk_goal_problem(entity, pos)
  if not AIVision.enabled() or AIVision.is_known(entity.surface, entity.force, pos) then return nil end
  local dx, dy = pos.x - entity.position.x, pos.y - entity.position.y
  if dx * dx + dy * dy > EXPLORE_RADIUS * EXPLORE_RADIUS then
    return string.format("(%.0f, %.0f) is unexplored and more than %d tiles away — explore toward it in steps of up to %d tiles",
      pos.x, pos.y, EXPLORE_RADIUS, EXPLORE_RADIUS)
  end
  return nil
end

return AIVision
