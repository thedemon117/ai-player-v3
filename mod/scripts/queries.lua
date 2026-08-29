-- Read-only world/prototype queries for external callers (the MCP server via
-- the "ai_player" remote interface; see control.lua). Where skills DO things,
-- queries only LOOK — none of these mutate game state.
--
-- Each query gets (ctx, params):
--   ctx    = {surface, force, character}  — character may be nil; queries that
--            need a position fall back to it only when x/y are not given.
--   params = flat table from the caller (numbers/strings).
-- All queries return a JSON-serialisable table; {error = "..."} on failure.
-- Dispatch is pcall-guarded in AIQueries.run so a bad query never crashes the mod.

AIQueries = {}

local REGISTRY = {}

local function num(v, default) return tonumber(v) or default end
local function round1(n) return math.floor(n * 10 + 0.5) / 10 end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Resolve the query's center point: explicit x/y beats character position.
local function center_of(ctx, p)
  if p.x and p.y then return {x = tonumber(p.x), y = tonumber(p.y)} end
  if ctx.character then return ctx.character.position end
  return nil
end

-- -------------------------------------------------------------------------
-- get_recipe — ingredients/products/craft time for one recipe, plus whether
-- this force has it unlocked and whether it is hand-craftable. Fills the gap
-- left by perception.craftable (names only): the model can now plan multi-step
-- crafts ("gear needs 2 iron-plate") instead of guessing.
-- -------------------------------------------------------------------------
REGISTRY.get_recipe = function(ctx, p)
  local name = p.name
  if not name then return {error = "missing recipe name"} end
  local proto = prototypes.recipe[name]
  if not proto then return {error = "no recipe named '" .. tostring(name) .. "'"} end

  local ingredients = {}
  for _, ing in ipairs(proto.ingredients or {}) do
    ingredients[#ingredients + 1] = {name = ing.name, amount = ing.amount, type = ing.type}
  end
  local products = {}
  for _, pr in ipairs(proto.products or {}) do
    products[#products + 1] = {name = pr.name, amount = pr.amount or pr.amount_max, type = pr.type}
  end

  local frecipe = ctx.force.recipes[name]
  return {
    name           = name,
    category       = proto.category,
    energy         = proto.energy,   -- craft time in seconds at crafting speed 1
    ingredients    = ingredients,
    products       = products,
    enabled        = (frecipe and frecipe.enabled) or false,
    -- Only plain "crafting"-category recipes can be hand-crafted by a character;
    -- smelting/chemistry/etc. need the right machine.
    hand_craftable = proto.category == "crafting",
  }
end

-- -------------------------------------------------------------------------
-- get_resource_patch — bounding box, tile count, and total amount of a
-- resource around a point (FLE-style get_resource_patch). Complements
-- perception.nearby_resources (which only reports the nearest tile): with the
-- bbox the model can plan drill rows along the patch instead of guessing.
-- -------------------------------------------------------------------------
REGISTRY.get_resource_patch = function(ctx, p)
  local resource = p.resource
  if not resource then return {error = "missing resource name"} end
  if not prototypes.entity[resource] then
    return {error = "no resource prototype '" .. tostring(resource) .. "'"}
  end
  local center = center_of(ctx, p)
  if not center then return {error = "no position — pass x,y or spawn the character"} end
  local radius = math.min(num(p.radius, 48), 128)

  local ents = ctx.surface.find_entities_filtered{
    type = "resource", name = resource, position = center, radius = radius,
  }
  if #ents == 0 then
    return {found = false, resource = resource, radius = radius}
  end

  local minx, miny = math.huge, math.huge
  local maxx, maxy = -math.huge, -math.huge
  local total = 0
  local nearest, ndist = nil, math.huge
  for _, r in ipairs(ents) do
    if r.valid then
      local rp = r.position
      if rp.x < minx then minx = rp.x end
      if rp.y < miny then miny = rp.y end
      if rp.x > maxx then maxx = rp.x end
      if rp.y > maxy then maxy = rp.y end
      total = total + (r.amount or 0)
      local d = dist(rp, center)
      if d < ndist then ndist = d; nearest = rp end
    end
  end

  return {
    found        = true,
    resource     = resource,
    tiles        = #ents,
    total_amount = total,
    bounding_box = {
      left_top     = {x = math.floor(minx), y = math.floor(miny)},
      right_bottom = {x = math.ceil(maxx),  y = math.ceil(maxy)},
    },
    nearest          = {x = math.floor(nearest.x), y = math.floor(nearest.y)},
    nearest_distance = math.floor(ndist),
  }
end

-- -------------------------------------------------------------------------
-- can_place — would a manual build of `entity` at {x,y} succeed? Runs the SAME
-- checks the place primitive uses (special cases like offshore-pump-on-water
-- and drill-on-resource, then the authoritative manual build check), so a
-- can_place=true here means a subsequent place_entity will not be rejected.
-- -------------------------------------------------------------------------
REGISTRY.can_place = function(ctx, p)
  if not (p.entity and p.x and p.y) then return {error = "need entity, x, y"} end
  if not prototypes.entity[p.entity] then
    return {error = "no entity prototype '" .. tostring(p.entity) .. "'"}
  end
  local position = {x = tonumber(p.x), y = tonumber(p.y)}
  local dir = AIActions.DIRECTION_MAP[(p.direction or "north"):lower()]
    or defines.direction.north

  local problem = AIActions.placement_problem(ctx.surface, p.entity, position)
  if problem then return {can_place = false, reason = problem} end

  local ok = ctx.surface.can_place_entity{
    name      = p.entity,
    position  = position,
    direction = dir,
    force     = ctx.force,
    build_check_type = defines.build_check_type.manual,
  }
  return {
    can_place = ok,
    reason    = (not ok) and "blocked, misaligned, or wrong tile" or nil,
  }
end

-- -------------------------------------------------------------------------
-- nearest_buildable — nearest clear spot where `entity` fits, spiralling out
-- from a center (FLE nearest_buildable, via the engine's own collision search).
-- NOTE: only checks collision. Entities with placement RULES beyond collision
-- (mining drills need a resource patch, offshore pumps need water) should be
-- planned with get_resource_patch / can_place instead.
-- -------------------------------------------------------------------------
REGISTRY.nearest_buildable = function(ctx, p)
  if not p.entity then return {error = "missing entity name"} end
  if not prototypes.entity[p.entity] then
    return {error = "no entity prototype '" .. tostring(p.entity) .. "'"}
  end
  local center = center_of(ctx, p)
  if not center then return {error = "no position — pass x,y or spawn the character"} end
  local radius = math.min(num(p.radius, 32), 128)

  local pos = ctx.surface.find_non_colliding_position(p.entity, center, radius, 1)
  if not pos then
    return {found = false, entity = p.entity, radius = radius}
  end
  return {
    found    = true,
    entity   = p.entity,
    position = {x = round1(pos.x), y = round1(pos.y)},
    distance = math.floor(dist(pos, center)),
  }
end

-- -------------------------------------------------------------------------
-- inspect_entity — full perception-grade detail of ONE entity at/near {x,y}:
-- status, recipe, fuel/input/output contents, fluid connections, slots — the
-- same entry the autonomous router sees for nearby entities, queryable at any
-- position on the map (ai-companion building_info equivalent).
-- -------------------------------------------------------------------------
REGISTRY.inspect_entity = function(ctx, p)
  if not (p.x and p.y) then return {error = "need x, y"} end
  local position = {x = tonumber(p.x), y = tonumber(p.y)}
  local filter = {position = position, radius = math.min(num(p.radius, 4), 16)}
  if p.name and p.name ~= "" then filter.name = p.name end

  local best, bestd = nil, math.huge
  for _, e in ipairs(ctx.surface.find_entities_filtered(filter)) do
    if e.valid and e.type ~= "character" then
      local d = dist(e.position, position)
      if d < bestd then best, bestd = e, d end
    end
  end
  if not best then
    return {error = string.format("no entity within %d tiles of {%d,%d}",
      filter.radius, position.x, position.y)}
  end

  local entry = AIPerception.describe_entity(best, ctx.force)
  entry.health    = best.health and math.floor(best.health) or nil
  entry.force     = best.force and best.force.name or nil
  entry.direction = best.direction
  entry.minable   = best.minable
  return entry
end

-- -------------------------------------------------------------------------
-- get_enemies — enemies around a point, nearest-first with health and a
-- composition/threat summary (ai-companion world_enemies equivalent).
-- Threat: danger (>5 enemies), caution (1-5), safe (0).
-- -------------------------------------------------------------------------
REGISTRY.get_enemies = function(ctx, p)
  local center = center_of(ctx, p)
  if not center then return {error = "no position — pass x,y or spawn the character"} end
  local radius = math.min(num(p.radius, 50), 200)

  local ents = ctx.surface.find_entities_filtered{
    position = center, radius = radius, force = "enemy",
    type = {"unit", "unit-spawner", "turret"},
  }

  local list = {}
  local composition = {units = 0, spawners = 0, worms = 0}
  for _, e in ipairs(ents) do
    if e.valid then
      if     e.type == "unit"         then composition.units    = composition.units + 1
      elseif e.type == "unit-spawner" then composition.spawners = composition.spawners + 1
      else                                 composition.worms    = composition.worms + 1 end
      list[#list + 1] = {
        name       = e.name,
        type       = e.type,
        position   = {x = math.floor(e.position.x), y = math.floor(e.position.y)},
        health     = e.health and math.floor(e.health) or nil,
        max_health = e.max_health and math.floor(e.max_health) or nil,
        distance   = math.floor(dist(e.position, center)),
      }
    end
  end
  table.sort(list, function(a, b) return a.distance < b.distance end)
  while #list > 20 do table.remove(list) end

  local threat = "safe"
  if #ents > 5 then threat = "danger"
  elseif #ents > 0 then threat = "caution" end

  return {
    count        = #ents,
    threat_level = threat,
    composition  = composition,
    radius       = radius,
    enemies      = list,   -- nearest-first, capped at 20
  }
end

-- -------------------------------------------------------------------------
-- get_character_state — live embodiment state of the AI character, including
-- the HAND-CRAFTING QUEUE, which no other surface exposes (perception shows
-- inventory but not what is mid-craft). Essential for diagnosing "craft was
-- queued but nothing happened" — e.g. the phase-0 craft-trigger issue.
-- -------------------------------------------------------------------------
REGISTRY.get_character_state = function(ctx, p)
  local c = ctx.character
  if not c then return {error = "no ai character — spawn_ai_player first"} end

  local queue = {}
  local okq, q = pcall(function() return c.crafting_queue end)
  if okq and q then
    for _, item in ipairs(q) do
      queue[#queue + 1] = {recipe = item.recipe, count = item.count}
    end
  end

  local home = storage.ai_player and storage.ai_player.home_position
  return {
    position   = {x = round1(c.position.x), y = round1(c.position.y)},
    surface    = c.surface.name,
    force      = c.force.name,
    health     = math.floor(c.health),
    health_pct = math.floor((c.health / (c.max_health or 250)) * 100),
    is_walking = (c.walking_state and c.walking_state.walking) or false,
    is_mining  = (c.mining_state and c.mining_state.mining) or false,
    crafting_queue      = queue,
    crafting_queue_size = c.crafting_queue_size or 0,
    crafting_progress   = round1(c.crafting_queue_progress or 0),
    home = home and {
      position = {x = home.x, y = home.y},
      distance = math.floor(dist(c.position, home)),
    } or nil,
  }
end

-- -------------------------------------------------------------------------
-- Dispatch
-- -------------------------------------------------------------------------

AIQueries.REGISTRY = REGISTRY

function AIQueries.list()
  local names = {}
  for n in pairs(REGISTRY) do names[#names + 1] = n end
  table.sort(names)
  return names
end

function AIQueries.run(name, params)
  local fn = REGISTRY[name]
  if not fn then
    return {error = "unknown query '" .. tostring(name) .. "' — known: "
      .. table.concat(AIQueries.list(), ", ")}
  end
  local character = AICharacter.get_character()
  local ctx = {
    character = character,
    force     = AICharacter.get_force() or game.forces.player,
    surface   = (character and character.surface) or game.surfaces["nauvis"],
  }
  local ok, result = pcall(fn, ctx, params or {})
  if not ok then return {error = tostring(result)} end
  return result
end

return AIQueries
