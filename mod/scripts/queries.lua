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

  local ents = AIVision.filter_known(ctx.surface.find_entities_filtered{
    type = "resource", name = resource, position = center, radius = radius,
  }, ctx.surface, ctx.force)
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
  for _, e in ipairs(AIVision.filter_known(ctx.surface.find_entities_filtered(filter), ctx.surface, ctx.force)) do
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

  local ents = AIVision.filter_visible(ctx.surface.find_entities_filtered{
    position = center, radius = radius, force = "enemy",
    type = {"unit", "unit-spawner", "turret"},
  }, ctx.surface, ctx.force)

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
-- analyze_factory — one-call diagnosis of everything stuck within `radius` of
-- the point: machines grouped by (name, problem) with the nearest sample
-- position and, for starved crafters, the ingredient they are short of. Saves
-- the model a dozen inspect_entity calls. Idle-but-healthy states (an inserter
-- waiting for items) are tallied under other_states, not reported as problems.
-- -------------------------------------------------------------------------
local AF_MAX_RADIUS = 150
local AF_MAX_GROUPS = 15
local AF_WORKING = { working = true, normal = true, charging = true,
                     discharging = true, fully_charged = true }
local AF_PROBLEMS = {
  no_power = true, low_power = true, no_fuel = true, no_ingredients = true,
  no_input_fluid = true, no_recipe = true, no_research_in_progress = true,
  missing_required_fluid = true, no_minable_resources = true, output_full = true,
  full_output = true, full_burnt_result_output = true,
  not_enough_space_in_output = true, waiting_for_space_in_destination = true,
  no_ammo = true, missing_science_packs = true,
  not_plugged_in_electric_network = true, recipe_not_researched = true,
  no_filter = true, item_ingredient_shortage = true,
  fluid_ingredient_shortage = true, low_input_fluid = true,
  networks_disconnected = true,
}
local AF_STARVED = { no_ingredients = true, item_ingredient_shortage = true,
                     fluid_ingredient_shortage = true, no_input_fluid = true }

-- Which recipe ingredients a stalled crafting machine lacks (best effort).
local function missing_ingredients(e)
  local result
  pcall(function()
    local recipe = e.get_recipe()
    if not recipe then return end
    local inv = e.get_inventory((defines.inventory.assembling_machine_input or defines.inventory.crafter_input))
      or e.get_inventory((defines.inventory.furnace_source or defines.inventory.crafter_input))
    local missing = {}
    for _, ing in ipairs(recipe.ingredients) do
      local have = 0
      if ing.type == "item" then
        have = inv and inv.get_item_count(ing.name) or 0
      else
        pcall(function() have = e.get_fluid_count(ing.name) end)
      end
      if have < (ing.amount or 1) then missing[#missing + 1] = ing.name end
    end
    if #missing > 0 then result = table.concat(missing, ", ") end
  end)
  return result
end

REGISTRY.analyze_factory = function(ctx, p)
  local origin = center_of(ctx, p)
  if not origin then return {error = "analyze_factory: no x/y given and no AI character"} end
  local radius = math.max(1, math.min(num(p.radius, 40), AF_MAX_RADIUS))

  local status_names = {}
  for name, value in pairs(defines.entity_status) do status_names[value] = name end

  local groups, others = {}, {}
  local working, checked = 0, 0
  for _, e in ipairs(AIVision.filter_known(ctx.surface.find_entities_filtered{
      position = origin, radius = radius, force = ctx.force}, ctx.surface, ctx.force)) do
    if e.valid and e.type ~= "character" then
      local ok, st = pcall(function() return e.status end)
      if ok and st ~= nil then
        checked = checked + 1
        local sname = status_names[st] or tostring(st)
        local key = e.name .. "|" .. sname
        if AF_WORKING[sname] then
          working = working + 1
        elseif not AF_PROBLEMS[sname] then
          others[key] = (others[key] or 0) + 1
        else
          local g = groups[key]
          if not g then
            g = {name = e.name, problem = sname, count = 0, _d = math.huge}
            groups[key] = g
          end
          g.count = g.count + 1
          local d = dist(e.position, origin)
          if d < g._d then
            g._d, g._entity = d, e
            g.sample = {x = math.floor(e.position.x * 2 + 0.5) / 2,
                        y = math.floor(e.position.y * 2 + 0.5) / 2}
          end
        end
      end
    end
  end

  local problems, problem_count = {}, 0
  for _, g in pairs(groups) do
    problems[#problems + 1] = g
    problem_count = problem_count + g.count
  end
  table.sort(problems, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a._d < b._d
  end)
  while #problems > AF_MAX_GROUPS do table.remove(problems) end
  for _, g in ipairs(problems) do
    if AF_STARVED[g.problem] and g._entity and g._entity.valid then
      g.missing = missing_ingredients(g._entity)
    end
    g._entity, g._d = nil, nil
  end

  local other_list, other_count = {}, 0
  for key, n in pairs(others) do
    local name, st = key:match("^(.-)|(.*)$")
    other_list[#other_list + 1] = {name = name, state = st, count = n}
    other_count = other_count + n
  end
  table.sort(other_list, function(a, b) return a.count > b.count end)

  local out = {
    radius = radius, machines_checked = checked, working = working,
    with_problems = problem_count, in_other_states = other_count,
  }
  if #problems > 0 then out.problems = problems end
  if #other_list > 0 then out.other_states = other_list end
  return out
end

-- -------------------------------------------------------------------------
-- map_warnings — the map screen's warning icons as one punch list: every
-- machine of the force with a problem status (same classification as
-- analyze_factory), grouped by problem, nearest-first, with positions.
-- analyze_factory looks at a radius; this sweeps the whole surface. Idle but
-- healthy inserters (waiting_for_source_items) are reported last, separately.
-- charted_only=true restricts it to known chunks (explored by the AI character
-- or charted by the force), i.e. what a player would see on the map; the
-- default reports everything the force owns unless the fog-of-war setting is on.
-- -------------------------------------------------------------------------
local MW_MAX_PER_GROUP = 60
local MW_MAX_IDLE = 20

REGISTRY.map_warnings = function(ctx, p)
  local surface, force = ctx.surface, ctx.force
  local origin = ctx.character and ctx.character.position or {x = 0, y = 0}
  local charted_only = (p.charted_only == true or p.charted_only == "true")

  local status_names = {}
  for name, value in pairs(defines.entity_status) do status_names[value] = name end

  local groups, order, idle = {}, {}, nil
  local checked = 0
  local function add_to(g, e)
    g.count = g.count + 1
    g.by_name[e.name] = (g.by_name[e.name] or 0) + 1
    g.entities[#g.entities + 1] = {
      name = e.name, x = round1(e.position.x), y = round1(e.position.y),
      _d = (e.position.x - origin.x) ^ 2 + (e.position.y - origin.y) ^ 2,
    }
  end
  for _, e in ipairs(AIVision.filter_known(surface.find_entities_filtered{force = force},
                                           surface, force, charted_only)) do
    if e.valid and e.type ~= "character" then
      local ok, st = pcall(function() return e.status end)
      if ok and st ~= nil then
        checked = checked + 1
        local sname = status_names[st] or tostring(st)
        if AF_PROBLEMS[sname] and not AF_WORKING[sname] then
          local g = groups[sname]
          if not g then
            g = {problem = sname, count = 0, by_name = {}, entities = {}}
            groups[sname] = g
            order[#order + 1] = g
          end
          add_to(g, e)
        elseif sname == "waiting_for_source_items" then
          idle = idle or {problem = sname, count = 0, by_name = {}, entities = {}, idle = true}
          add_to(idle, e)
        end
      end
    end
  end

  local total = 0
  for _, g in ipairs(order) do total = total + g.count end
  local function finish(g, cap)
    table.sort(g.entities, function(a, b) return a._d < b._d end)
    if #g.entities > cap then
      g.more = #g.entities - cap
      for i = #g.entities, cap + 1, -1 do g.entities[i] = nil end
    end
    for _, ent in ipairs(g.entities) do ent._d = nil end
  end
  for _, g in ipairs(order) do finish(g, MW_MAX_PER_GROUP) end
  table.sort(order, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.problem < b.problem
  end)
  if idle then
    finish(idle, MW_MAX_IDLE)
    order[#order + 1] = idle  -- always last, after the warning groups
  end
  return {surface = surface.name, entities_checked = checked,
          with_problems = total, groups = order}
end

-- -------------------------------------------------------------------------
-- production_stats — the force's item/fluid production and consumption on the
-- surface over a time window: what the player's production-statistics window
-- shows. Rates are per minute, derived from the window's total count.
--   window = 5s|1m|10m|1h|10h|50h|250h|1000h (default 1m)
--   names  = {"iron-plate", "water", ...} (default: everything seen)
--   kind   = item|fluid|both (default both), top = rows to return (default 20)
-- -------------------------------------------------------------------------
local PS_WINDOWS = {
  ["5s"]    = {index = "five_seconds",             minutes = 5 / 60},
  ["1m"]    = {index = "one_minute",               minutes = 1},
  ["10m"]   = {index = "ten_minutes",              minutes = 10},
  ["1h"]    = {index = "one_hour",                 minutes = 60},
  ["10h"]   = {index = "ten_hours",                minutes = 600},
  ["50h"]   = {index = "fifty_hours",              minutes = 3000},
  ["250h"]  = {index = "two_hundred_fifty_hours",  minutes = 15000},
  ["1000h"] = {index = "one_thousand_hours",       minutes = 60000},
}

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

local function flow_total(stats, name, category, precision)
  local n = 0
  pcall(function()
    n = stats.get_flow_count{name = name, category = category,
                             precision_index = precision, count = true}
  end)
  return n
end

local function collect_flows(stats, kind, precision, minutes, wanted, out)
  local names = {}
  if wanted then
    names = wanted
  else
    local seen = {}
    for _, counts in ipairs({stats.input_counts, stats.output_counts}) do
      for n in pairs(counts) do
        if not seen[n] then seen[n] = true; names[#names + 1] = n end
      end
    end
  end
  for _, name in ipairs(names) do
    local produced = flow_total(stats, name, "input", precision)
    local consumed = flow_total(stats, name, "output", precision)
    local total_p = stats.input_counts[name] or 0
    local total_c = stats.output_counts[name] or 0
    if wanted or produced > 0 or consumed > 0 or total_p > 0 or total_c > 0 then
      out[#out + 1] = {
        name = name, kind = kind,
        produced_per_min = round2(produced / minutes),
        consumed_per_min = round2(consumed / minutes),
        net_per_min = round2((produced - consumed) / minutes),
        produced_all_time = math.floor(total_p),
        consumed_all_time = math.floor(total_c),
      }
    end
  end
end

REGISTRY.production_stats = function(ctx, p)
  local wname = p.window or "1m"
  local w = PS_WINDOWS[wname]
  if not w then return {error = "production_stats: window must be one of 5s, 1m, 10m, 1h, 10h, 50h, 250h, 1000h"} end
  local precision = defines.flow_precision_index[w.index]

  local wanted_items, wanted_fluids
  if type(p.names) == "table" and #p.names > 0 then
    wanted_items, wanted_fluids = {}, {}
    for _, n in ipairs(p.names) do
      if prototypes.fluid[n] then
        wanted_fluids[#wanted_fluids + 1] = n
      elseif prototypes.item[n] then
        wanted_items[#wanted_items + 1] = n
      else
        return {error = "production_stats: no item or fluid called '" .. tostring(n) .. "'"}
      end
    end
  end

  local rows = {}
  local kind = p.kind or "both"
  if kind == "both" or kind == "item" then
    collect_flows(ctx.force.get_item_production_statistics(ctx.surface), "item",
                  precision, w.minutes, wanted_items, rows)
  end
  if kind == "both" or kind == "fluid" then
    collect_flows(ctx.force.get_fluid_production_statistics(ctx.surface), "fluid",
                  precision, w.minutes, wanted_fluids, rows)
  end
  table.sort(rows, function(a, b)
    local ra, rb = math.max(a.produced_per_min, a.consumed_per_min),
                   math.max(b.produced_per_min, b.consumed_per_min)
    if ra ~= rb then return ra > rb end
    return a.produced_all_time > b.produced_all_time
  end)
  local top = math.max(1, math.min(num(p.top, 20), 200))
  local out = {}
  for i = 1, math.min(#rows, top) do out[i] = rows[i] end
  return {window = wname, surface = ctx.surface.name, rows = out, total_rows = #rows}
end

-- -------------------------------------------------------------------------
-- belt_line / inserter_at / power_report — wiring diagnostics distilled from
-- debugging a real build: the failures that look like "supply problem" but are
-- a geometry mistake (a gap in a belt row, one lane packed and the other empty,
-- an inserter wired backwards, an islanded power network).
-- -------------------------------------------------------------------------
local BELT_TYPES = {["transport-belt"] = true, ["underground-belt"] = true, splitter = true}

-- Per-lane item counts of a belt-like entity. get_transport_line(1) is the
-- left lane relative to travel, (2) the right.
local function belt_lanes(e)
  local lanes = {}
  for i = 1, 2 do
    local contents = {}
    local ok, line = pcall(function() return e.get_transport_line(i) end)
    if ok and line then
      for _, st in ipairs(line.get_contents()) do
        contents[st.name] = (contents[st.name] or 0) + st.count
      end
    end
    lanes[i] = contents
  end
  return {left = lanes[1], right = lanes[2]}
end

local function non_resource_at(surface, pos)
  local names = {}
  for _, z in ipairs(surface.find_entities_filtered{position = pos, radius = 0.35}) do
    if z.type ~= "resource" then names[#names + 1] = z.name end
  end
  return names
end

-- belt_line — walk a belt row (horizontal: tile row `at`, tiles from..to) or
-- column (tile column `at`) tile by tile, in tile coordinates (floor of the position) and report gaps/obstructions and each
-- belt's direction and lane contents. A gap or an unexpected direction are the
-- two ways a line is silently cut in half (usually a pole dropped on the row);
-- one packed lane against an empty one is the signature of a bad side-load.
REGISTRY.belt_line = function(ctx, p)
  local at, from, to = tonumber(p.at), tonumber(p.from), tonumber(p.to)
  if not (at and from and to) then return {error = "belt_line: need at, from, to"} end
  local horizontal = p.horizontal ~= false
  if math.abs(to - from) > 300 then return {error = "belt_line: span capped at 300 tiles"} end
  local step = to >= from and 1 or -1
  local tiles, problems = {}, 0
  for i = from, to, step do
    -- Sample the tile centre: entity positions sit on .5 for 1x1 belts.
    local c, f = math.floor(i) + 0.5, math.floor(at) + 0.5
    local pos = horizontal and {x = c, y = f} or {x = f, y = c}
    local e = ctx.surface.find_entities_filtered{position = pos, radius = 0.35}[1]
    local row = {at = i}
    if not e then
      row.gap = true; problems = problems + 1
    elseif BELT_TYPES[e.type] then
      row.name, row.direction, row.lanes = e.name, e.direction, belt_lanes(e)
    else
      row.blocked_by = e.name; problems = problems + 1
    end
    tiles[#tiles + 1] = row
  end
  return {axis = horizontal and "x" or "y", fixed = at, obstructions = problems, tiles = tiles}
end

-- inserter_at — resolved pickup/drop positions of the inserter at {x,y} and what
-- stands on each. `direction` names the side an inserter PICKS UP from (it drops
-- opposite), so reading the resolved positions is the reliable wiring check.
REGISTRY.inserter_at = function(ctx, p)
  local x, y = tonumber(p.x), tonumber(p.y)
  if not (x and y) then return {error = "inserter_at: need x, y"} end
  local e = ctx.surface.find_entities_filtered{
    position = {x = x, y = y}, radius = 0.35, type = "inserter"}[1]
  if not e then return {error = "no inserter at {" .. x .. "," .. y .. "}"} end
  local status
  for name, value in pairs(defines.entity_status) do
    if value == e.status then status = name end
  end
  return {
    name = e.name, direction = e.direction, status = status,
    pickup = {x = e.pickup_position.x, y = e.pickup_position.y,
              target = non_resource_at(ctx.surface, e.pickup_position)},
    drop   = {x = e.drop_position.x, y = e.drop_position.y,
              target = non_resource_at(ctx.surface, e.drop_position)},
  }
end

-- power_report — generation vs capacity and every electric-pole network on the
-- surface. More than one network means something is islanded: the usual reason
-- for a correctly built block sitting at no_power.
REGISTRY.power_report = function(ctx, _)
  local s = ctx.surface
  local gen, cap = 0, 0
  for _, e in ipairs(s.find_entities_filtered{type = "generator", force = ctx.force}) do
    gen = gen + e.energy_generated_last_tick * 60
    cap = cap + e.prototype.get_max_energy_production(e.quality) * 60
  end
  local nets = {}
  for _, pole in ipairs(s.find_entities_filtered{type = "electric-pole", force = ctx.force}) do
    local id = pole.electric_network_id or 0
    local n = nets[id]
    if not n then
      n = {id = id, poles = 0, x1 = math.huge, x2 = -math.huge, y1 = math.huge, y2 = -math.huge}
      nets[id] = n
    end
    n.poles = n.poles + 1
    n.x1, n.x2 = math.min(n.x1, pole.position.x), math.max(n.x2, pole.position.x)
    n.y1, n.y2 = math.min(n.y1, pole.position.y), math.max(n.y2, pole.position.y)
  end
  local list = {}
  for _, n in pairs(nets) do list[#list + 1] = n end
  table.sort(list, function(a, b) return a.poles > b.poles end)
  local unpowered = 0
  for _, e in ipairs(s.find_entities_filtered{force = ctx.force}) do
    if e.status == defines.entity_status.no_power
       or e.status == defines.entity_status.not_plugged_in_electric_network then
      unpowered = unpowered + 1
    end
  end
  return {generation_mw = round1(gen / 1e6 * 100) / 100, capacity_mw = round1(cap / 1e6 * 100) / 100,
          networks = list, unpowered_entities = unpowered}
end

-- -------------------------------------------------------------------------
-- silo_status / platforms — the end of the run: rocket silos and (Space Age)
-- space platforms of the force.
-- -------------------------------------------------------------------------
local function try(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

local function inventory_map(inv)
  local out = {}
  if inv then
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read then out[st.name] = (out[st.name] or 0) + st.count end
    end
  end
  return out
end

local function enum_name(enum, value)
  if value == nil then return nil end
  for k, v in pairs(enum) do if v == value then return k end end
  return tostring(value)
end

-- Rocket progress of one silo: parts built, phase, whether the rocket can be
-- launched, and what it carries. Shared with the launch_rocket skill.
function AIQueries.silo_info(silo)
  local code = try(function() return silo.rocket_silo_status end)
  local phase = enum_name(defines.rocket_silo_status, code)
  return {
    x = silo.position.x, y = silo.position.y,
    parts = try(function() return silo.rocket_parts end) or 0,
    parts_required = try(function() return silo.prototype.rocket_parts_required end) or 100,
    phase = phase,
    has_rocket = try(function() return silo.rocket end) ~= nil,
    ready = phase == "rocket_ready",
    launching = code ~= nil and code >= defines.rocket_silo_status.launch_starting,
    status = enum_name(defines.entity_status, try(function() return silo.status end)),
    cargo = inventory_map(try(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket) end)),
  }
end

function AIQueries.describe_silo(info)
  if info.launching then
    return "a rocket is already launching (" .. tostring(info.phase):gsub("_", " ") .. ")"
  end
  if info.ready then return "the rocket is ready" end
  if info.has_rocket then
    return "the rocket is being prepared (" .. tostring(info.phase):gsub("_", " ") .. ")"
  end
  return string.format("no rocket yet: %d/%d rocket parts", info.parts, info.parts_required)
end

REGISTRY.silo_status = function(ctx, _)
  local silos = {}
  for _, e in ipairs(AIVision.filter_known(
      ctx.surface.find_entities_filtered{type = "rocket-silo", force = ctx.force}, ctx.surface, ctx.force)) do
    local info = AIQueries.silo_info(e)
    info.summary = AIQueries.describe_silo(info)
    silos[#silos + 1] = info
  end
  table.sort(silos, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  return {silos = silos, launches = storage.ai_player and storage.ai_player.launches or {}}
end

local function platform_location(p)
  local loc = p.space_location
  if loc then return {at = loc.name} end
  local conn = p.space_connection
  if conn then return {between = conn.from.name, to_location = conn.to.name, distance = p.distance} end
  return {}
end

REGISTRY.platforms = function(ctx, _)
  if not script.active_mods["space-age"] then return {error = "platforms: Space Age is not active"} end
  local out = {}
  for _, p in pairs(ctx.force.platforms) do
    if p.valid then
      local info = {
        name = p.name, index = p.index,
        state = enum_name(defines.space_platform_state, p.state),
        paused = p.paused, speed = p.speed, has_hub = (p.hub and p.hub.valid) or false,
      }
      for k, v in pairs(platform_location(p)) do info[k] = v end
      local sched = p.schedule
      if sched and sched.records and #sched.records > 0 then
        local stops = {}
        for _, r in ipairs(sched.records) do stops[#stops + 1] = r.station or "?" end
        info.schedule = {stops = stops, current = sched.current}
      end
      if info.has_hub then
        info.hub_items = inventory_map(try(function() return p.hub.get_inventory(defines.inventory.hub_main) end))
      end
      out[#out + 1] = info
    end
  end
  table.sort(out, function(a, b) return a.index < b.index end)
  local here = try(function() return ctx.surface.platform end)
  return {platforms = out, character_on = (here and here.valid) and here.name or ctx.surface.name}
end

-- find_buildable_area{width, height, near={x,y}, max_distance?} and
-- describe_prototype{names=[...]} — scripts/spatial.lua. Errors come back as
-- {error = "..."} with the source location stripped.
local function spatial(fn_name)
  return function(ctx, p)
    local ok, res = pcall(AISpatial[fn_name], ctx, p or {})
    if ok then return res end
    return {error = (tostring(res):gsub("^.-:%d+:%s*", ""))}
  end
end
REGISTRY.find_buildable_area = spatial("find_buildable_area")
REGISTRY.describe_prototype = spatial("describe_prototype")
REGISTRY.map_overview = spatial("map_overview")
REGISTRY.layout_context = spatial("layout_context")

-- alerts — the in-game alert panel (turret out of ammo, entity destroyed, no
-- power, ...) as the force's players see it. In 2.x alerts live on players, so
-- this needs a connected player of the force; headless it says so and
-- battle_report covers the same ground.
REGISTRY.alerts = function(ctx, _)
  local out = {surface = ctx.surface.name, tick = game.tick, groups = {}}
  local panel, pname
  for _, pl in ipairs(game.connected_players) do
    if pl.force == ctx.force then
      pname = pl.name
      local ok, by_surface = pcall(function() return pl.get_alerts({}) end)
      if ok and type(by_surface) == "table" then panel = by_surface end
      break
    end
  end
  if not panel then
    out.note = pname and ("player " .. pname .. " exposes no alert read")
      or "no connected player on this force — in 2.x the alert panel lives on players; battle_report covers the same ground headless"
    return out
  end
  local by_type = panel[ctx.surface.index]
  if not by_type then return out end
  local names = {}
  for name, value in pairs(defines.alert_type) do names[value] = name end
  for type_id, alerts in pairs(by_type) do
    local entries = {}
    for _, a in ipairs(alerts) do
      local name, pos = "?", a.position
      if a.target and a.target.valid then name = a.target.name; pos = a.target.position or pos
      elseif a.prototype then name = a.prototype.name end
      entries[#entries + 1] = {name = name, x = pos and round1(pos.x), y = pos and round1(pos.y), tick = a.tick}
    end
    table.sort(entries, function(x, y) return x.tick < y.tick end)
    out.groups[#out.groups + 1] = {type = names[type_id] or tostring(type_id), count = #entries, alerts = entries}
  end
  table.sort(out.groups, function(a, b) return a.count > b.count end)
  return out
end

-- job_status — the background job queue (current step, waiting steps, last results).
REGISTRY.job_status = function(_, _) return AIJobs.status() end

-- route_belt / route_pipe — weighted A* between two endpoints on the real map
-- (scripts/route/): returns build steps for build_plan (item, x, y, direction,
-- underground_type), the bill vs. what the character carries, trees/rocks to
-- mine first, and notes on how the route joins existing belts. Read-only.
local function routed(kind)
  return function(ctx, p)
    local ok, res = pcall(AIRoute.route, ctx, p or {}, kind)
    if ok then return res end
    return {error = (tostring(res):gsub("^.-:%d+:%s*", ""))}
  end
end
REGISTRY.route_belt = routed("belt")
REGISTRY.route_pipe = routed("pipe")

-- list_registered_blueprints — the provenance registry (blueprints made in this
-- run), oldest first, and whether the gate is enforced.
REGISTRY.list_registered_blueprints = function(_, _)
  local list = AIBPRegistry.list()
  return {enforced = AIBPRegistry.enforced(), total = #list, blueprints = list}
end

-- trace_belt{x, y} — follow the belt line through a tile (scripts/belts.lua):
-- legs, start/end, feeders and takers, per-lane fill.
REGISTRY.trace_belt = function(ctx, p) return AIBelts.trace(ctx, p) end

-- -------------------------------------------------------------------------
-- list_trains — fleet overview (state, size, position, station, schedule,
-- cargo; at most 20) and the names of the force's train stops, which are the
-- only valid targets for set_train_schedule.
-- -------------------------------------------------------------------------
local function train_state_name(state)
  for name, value in pairs(defines.train_state) do if value == state then return name end end
  return tostring(state)
end

local function station_names(ctx)
  local names, seen = {}, {}
  local stops = ctx.surface.find_entities_filtered{type = "train-stop", force = ctx.force}
  for _, stop in ipairs(AIVision.filter_known(stops, ctx.surface, ctx.force)) do
    if stop.valid and not seen[stop.backer_name] then seen[stop.backer_name] = true; names[#names + 1] = stop.backer_name end
  end
  table.sort(names)
  return names, seen
end
AIQueries.station_names = station_names

REGISTRY.list_trains = function(ctx, _)
  local out = {}
  for _, t in ipairs(game.train_manager.get_trains{surface = ctx.surface}) do
    if #out >= 20 then break end
    local entry = {id = t.id, state = train_state_name(t.state), manual = t.manual_mode}
    try(function()
      local locos, wagons = 0, 0
      for _, c in ipairs(t.carriages) do if c.type == "locomotive" then locos = locos + 1 else wagons = wagons + 1 end end
      entry.locomotives, entry.wagons = locos, wagons
      local front = t.carriages[1]
      if front then entry.position = {x = round1(front.position.x), y = round1(front.position.y)} end
    end)
    try(function() if t.station then entry.at_station = t.station.backer_name end end)
    try(function()
      local sched = t.schedule
      if sched and sched.records and #sched.records > 0 then
        local stops = {}
        for _, rec in ipairs(sched.records) do stops[#stops + 1] = rec.station or "(coordinates)" end
        entry.schedule = stops
        entry.next_stop = sched.records[sched.current] and sched.records[sched.current].station or nil
      end
    end)
    try(function()
      local cargo = {}
      for _, item in ipairs(t.get_contents()) do cargo[item.name] = (cargo[item.name] or 0) + item.count end
      if next(cargo) ~= nil then entry.cargo = cargo end
    end)
    out[#out + 1] = entry
  end
  return {trains = out, stations = (station_names(ctx))}
end

-- -------------------------------------------------------------------------
-- list_technologies(status?, search?, limit?) — the tech tree with the exact
-- internal names `research` takes: status (researched, in-progress, queued,
-- available = prerequisites done, trigger = prerequisites done and it completes
-- by doing something, locked = prerequisites missing, all; default available), prerequisites and which
-- are missing, the science bill, and for trigger techs the action that
-- completes them. Also the live queue. Capped at `limit` rows (default 60).
-- -------------------------------------------------------------------------
local TECH_STATUS = {researched = true, ["in-progress"] = true, queued = true, available = true, trigger = true, locked = true, all = true}

REGISTRY.list_technologies = function(ctx, p)
  local want = p.status or "available"
  if not TECH_STATUS[want] then return {error = "list_technologies: status must be researched, in-progress, queued, available, trigger, locked or all"} end
  local search = type(p.search) == "string" and p.search:lower() or ""
  local limit = math.min(math.max(math.floor(num(p.limit, 60)), 1), 300)
  local force = ctx.force
  local queue, qpos = {}, {}
  for i, t in ipairs(force.research_queue or {}) do qpos[t.name] = i; queue[#queue + 1] = t.name end
  local cur = force.current_research
  local counts = {researched = 0, ["in-progress"] = 0, queued = 0, available = 0, trigger = 0, locked = 0}
  local rows = {}
  for name, tech in pairs(force.technologies) do
    local status
    if tech.researched then status = "researched"
    elseif cur and cur.name == name then status = "in-progress"
    elseif qpos[name] then status = "queued"
    else
      -- only techs whose prerequisites are all researched can be worked on now
      local ready = tech.enabled
      for _, pre in pairs(tech.prerequisites or {}) do if not pre.researched then ready = false end end
      if not ready then status = "locked"
      elseif try(function() return tech.prototype.research_trigger ~= nil end) then status = "trigger"
      else status = "available" end
    end
    counts[status] = counts[status] + 1
    if (want == "all" or want == status) and (search == "" or name:lower():find(search, 1, true)) then
      local prereqs, missing = {}, {}
      for pn, pre in pairs(tech.prerequisites or {}) do
        prereqs[#prereqs + 1] = pn
        if not pre.researched then missing[#missing + 1] = pn end
      end
      table.sort(prereqs); table.sort(missing)
      local count = try(function() return tech.research_unit_count end) or 0
      local bill = {}
      for _, ing in ipairs(try(function() return tech.research_unit_ingredients end) or {}) do
        bill[ing.name] = (ing.amount or 0) * count
      end
      local row = {name = name, status = status, prereqs = prereqs, missing = missing, bill = bill,
        unit_time_s = math.floor((try(function() return tech.research_unit_energy end) or 0) / 60 + 0.5),
        order = try(function() return tech.prototype.order end) or name}
      local tr = try(function() return tech.prototype.research_trigger end)
      if tr then row.trigger = AITriggers.describe(tr) end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b) if a.order ~= b.order then return a.order < b.order end; return a.name < b.name end)
  local total = #rows
  while #rows > limit do table.remove(rows) end
  return {filter = want, search = search ~= "" and search or nil, current = cur and cur.name,
          progress = math.floor(force.research_progress * 100 + 0.5), queue = queue, counts = counts,
          total_matching = total, techs = rows}
end

-- -------------------------------------------------------------------------
-- battle_report — what a defender needs in one call: own entities below max
-- health (healthy machines never lose any, so it is combat/collision damage),
-- turrets with no ammo, and enemy clusters (8-tile cells, flood-filled) with the
-- distance to the nearest own entity, nearest first. With fog of war on,
-- enemies are limited to explored ground.
-- -------------------------------------------------------------------------
local TURRET_TYPES = {"ammo-turret", "electric-turret", "fluid-turret"}

local function cluster_enemies(entities)
  local cells = {}
  for _, e in ipairs(entities) do
    if e.valid then
      local cx, cy = math.floor(e.position.x / 8), math.floor(e.position.y / 8)
      local k = cx .. "," .. cy
      local c = cells[k]
      if not c then c = {cx = cx, cy = cy, count = 0, sx = 0, sy = 0, by_name = {}}; cells[k] = c end
      c.count, c.sx, c.sy = c.count + 1, c.sx + e.position.x, c.sy + e.position.y
      c.by_name[e.name] = (c.by_name[e.name] or 0) + 1
    end
  end
  local clusters = {}
  for _, cell in pairs(cells) do
    if not cell.seen then
      cell.seen = true
      local stack, count, sx, sy, by_name = {cell}, 0, 0, 0, {}
      while #stack > 0 do
        local cl = table.remove(stack)
        count, sx, sy = count + cl.count, sx + cl.sx, sy + cl.sy
        for n, k in pairs(cl.by_name) do by_name[n] = (by_name[n] or 0) + k end
        for dx = -1, 1 do for dy = -1, 1 do
          local nc = cells[(cl.cx + dx) .. "," .. (cl.cy + dy)]
          if nc and not nc.seen then nc.seen = true; stack[#stack + 1] = nc end
        end end
      end
      clusters[#clusters + 1] = {count = count, center = {x = round1(sx / count), y = round1(sy / count)}, by_name = by_name}
    end
  end
  return clusters
end

REGISTRY.battle_report = function(ctx, _)
  local surface, force = ctx.surface, ctx.force
  local out = {surface = surface.name, tick = game.tick}

  local damaged = {}
  for _, e in ipairs(surface.find_entities_filtered{force = force}) do
    local ok, hp, max_hp = pcall(function() return e.health, e.max_health end)
    if ok and hp and max_hp and max_hp > 0 and hp < max_hp then
      damaged[#damaged + 1] = {name = e.name, x = round1(e.position.x), y = round1(e.position.y),
        hp = math.floor(hp + 0.5), max_hp = math.floor(max_hp + 0.5), pct = math.floor(hp / max_hp * 100 + 0.5)}
    end
  end
  table.sort(damaged, function(a, b) return a.pct < b.pct end)
  while #damaged > 30 do table.remove(damaged) end
  if #damaged > 0 then out.damaged = damaged end

  local dry = {}
  for _, e in ipairs(surface.find_entities_filtered{force = force, type = "ammo-turret"}) do
    local inv = e.get_inventory(defines.inventory.turret_ammo)
    if inv and inv.is_empty() then dry[#dry + 1] = {name = e.name, x = round1(e.position.x), y = round1(e.position.y)} end
  end
  if #dry > 0 then out.turrets_no_ammo = dry end

  local enemies = AIVision.filter_known(surface.find_entities_filtered{force = "enemy"}, surface, force)
  local clusters = cluster_enemies(enemies)
  for _, cl in ipairs(clusters) do
    local best, best_d
    for _, e in ipairs(surface.find_entities_filtered{position = cl.center, radius = 120, force = force}) do
      local d = dist(cl.center, e.position)
      if not best_d or d < best_d then best_d, best = d, e.name end
    end
    cl.nearest = best and {name = best, distance = math.floor(best_d + 0.5)} or nil
    local names = {}
    for n in pairs(cl.by_name) do names[#names + 1] = n end
    table.sort(names, function(a, b) return cl.by_name[a] > cl.by_name[b] end)
    cl.top_names = {}
    for i = 1, math.min(#names, 4) do cl.top_names[i] = string.format("%dx %s", cl.by_name[names[i]], names[i]) end
    cl.by_name = nil
  end
  table.sort(clusters, function(a, b)
    return (a.nearest and a.nearest.distance or math.huge) < (b.nearest and b.nearest.distance or math.huge)
  end)
  while #clusters > 10 do table.remove(clusters) end
  if #clusters > 0 then out.enemy_clusters = clusters end
  return out
end

-- -------------------------------------------------------------------------
-- area_snapshot — JSON picture of a rectangle (<= 200x200 tiles) for the
-- tools/lpf schematic renderer: entities with boxes/direction/status, resources
-- per tile, water tiles, trees/rocks/cliffs. With fog of war on, only explored
-- chunks are drawn and the skipped ones are listed.
-- -------------------------------------------------------------------------
local SNAP_SKIP = {
  resource = true, tree = true, cliff = true, ["simple-entity"] = true, ["item-entity"] = true,
  corpse = true, ["character-corpse"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true,
  fish = true, ["rail-remnants"] = true, ["particle-source"] = true, explosion = true,
  ["smoke-with-trigger"] = true, fire = true, ["flying-text"] = true, sticker = true,
  stream = true, projectile = true, ["highlight-box"] = true, ["speech-bubble"] = true,
}
local function r2(v) local r = tonumber(string.format("%.2f", v)); if r == 0 then r = 0 end; return r end
local function box_of(e)
  local b = e.bounding_box
  return {r2(b.left_top.x), r2(b.left_top.y), r2(b.right_bottom.x), r2(b.right_bottom.y)}
end
local function pt(v) if v and v.x then return {r2(v.x), r2(v.y)} end end

REGISTRY.area_snapshot = function(ctx, p)
  local x1, y1, x2, y2 = tonumber(p.x1), tonumber(p.y1), tonumber(p.x2), tonumber(p.y2)
  if not (x1 and y1 and x2 and y2) then return {error = "area_snapshot: need x1, y1, x2, y2"} end
  if x1 > x2 then x1, x2 = x2, x1 end
  if y1 > y2 then y1, y2 = y2, y1 end
  if x2 - x1 > 200 or y2 - y1 > 200 then return {error = "area_snapshot: limited to 200x200 tiles"} end
  local surface, area = ctx.surface, {{x1, y1}, {x2, y2}}
  local function known(x, y)
    return not AIVision.enabled() or AIVision.is_known(surface, ctx.force, {x = x, y = y})
  end
  local unexplored = {}
  for cy = math.floor(y1 / 32), math.floor((y2 - 1e-6) / 32) do
    for cx = math.floor(x1 / 32), math.floor((x2 - 1e-6) / 32) do
      if not known(cx * 32 + 16, cy * 32 + 16) then unexplored[#unexplored + 1] = {cx, cy} end
    end
  end
  local entities, obstacles, resources = {}, {}, {}
  for _, e in ipairs(surface.find_entities_filtered{area = area}) do
    if e.valid and known(e.position.x, e.position.y) then
      local t = e.type
      if t == "resource" then
        if e.position.x >= x1 and e.position.x < x2 and e.position.y >= y1 and e.position.y < y2 then
          resources[e.name] = resources[e.name] or {}
          table.insert(resources[e.name], {math.floor(e.position.x), math.floor(e.position.y), e.amount})
        end
      elseif t == "tree" or t == "simple-entity" or t == "cliff" then
        local b = box_of(e)
        obstacles[#obstacles + 1] = {b[1], b[2], b[3], b[4], t == "tree" and "tree" or (t == "cliff" and "cliff" or "rock")}
      elseif not SNAP_SKIP[t] then
        local ghost = t == "entity-ghost"
        local rec = {
          name = ghost and e.ghost_name or e.name, type = ghost and e.ghost_type or t,
          x = r2(e.position.x), y = r2(e.position.y), dir = try(function() return e.direction end) or 0,
          box = box_of(e), force = e.force and e.force.name or "neutral",
        }
        if ghost then rec.ghost = true end
        rec.status = try(function() return enum_name(defines.entity_status, e.status) end)
        if rec.type == "assembling-machine" or rec.type == "furnace" then
          local r = try(function() return e.get_recipe() end)
          if r then rec.recipe = type(r) == "string" and r or r.name end
        elseif rec.type == "underground-belt" then
          local u = try(function() return e.belt_to_ground_type end)
          if u == "input" or u == "output" then rec.ug = u end
        elseif rec.type == "inserter" and not ghost then
          rec.pickup, rec.drop = pt(try(function() return e.pickup_position end)), pt(try(function() return e.drop_position end))
        elseif rec.type == "mining-drill" and not ghost then
          rec.out = pt(try(function() return e.drop_position end))
        end
        entities[#entities + 1] = rec
      end
    end
  end
  local water = {}
  local tiles = try(function() return surface.find_tiles_filtered{area = area, collision_mask = "water_tile"} end)
  for _, tile in ipairs(tiles or {}) do
    if known(tile.position.x, tile.position.y) then water[#water + 1] = {tile.position.x, tile.position.y} end
  end
  return {tick = game.tick, area = {x1, y1, x2, y2}, unexplored_chunks = unexplored,
          entities = entities, resources = resources, water = water, obstacles = obstacles}
end

-- -------------------------------------------------------------------------
-- map_view — the area around {x,y} (default: the character) as a character
-- grid a model can read, one glyph per tile, with a legend. `to = {x, y}` also
-- traces the DIRECT line with the engine's own collision test for a character
-- and names the first thing in the way (water, a tree, a building). goto routes
-- around those through the pathfinder; the trace shows what detour to expect.
-- -------------------------------------------------------------------------
local RES_GLYPH = {["iron-ore"] = "f", ["copper-ore"] = "c", coal = "k", stone = "s", ["uranium-ore"] = "u", ["crude-oil"] = "O"}
local TYPE_GLYPH = {
  ["assembling-machine"] = "A", furnace = "F", ["mining-drill"] = "D", lab = "L", container = "B",
  ["logistic-container"] = "B", inserter = "i", ["electric-pole"] = "+", pipe = "=", ["pipe-to-ground"] = "=",
  ["storage-tank"] = "S", generator = "E", boiler = "b", ["offshore-pump"] = "o", ["underground-belt"] = ")",
  splitter = "Y", ["ammo-turret"] = "X", ["electric-turret"] = "X", ["fluid-turret"] = "X", wall = "W", gate = "W",
  ["rocket-silo"] = "H", car = "V", locomotive = "V", ["cargo-wagon"] = "V", ["fluid-wagon"] = "V", tank = "V",
  ["straight-rail"] = "%", ["curved-rail-a"] = "%", ["curved-rail-b"] = "%", ["half-diagonal-rail"] = "%",
  ["train-stop"] = "%", ["rail-signal"] = "%", ["rail-chain-signal"] = "%", radar = "R", roboport = "P",
  reactor = "N", ["solar-panel"] = "E", accumulator = "E", ["heat-pipe"] = "=",
}
local BELT_ARROW = {[0] = "^", [4] = ">", [8] = "v", [12] = "<"}

REGISTRY.map_view = function(ctx, p)
  local c = center_of(ctx, p)
  if not c then return {error = "map_view: no character and no x/y given"} end
  local r = math.min(math.max(math.floor(num(p.radius, 20)), 4), 40)
  local x1, y1 = math.floor(c.x) - r, math.floor(c.y) - r
  local x2, y2 = math.floor(c.x) + r + 1, math.floor(c.y) + r + 1
  local snap = REGISTRY.area_snapshot(ctx, {x1 = x1, y1 = y1, x2 = x2, y2 = y2})
  if snap.error then return snap end

  local W, H = x2 - x1, y2 - y1
  local grid = {}
  for j = 1, H do grid[j] = {}; for i = 1, W do grid[j][i] = "." end end
  local function put(tx, ty, g)
    local i, j = tx - x1 + 1, ty - y1 + 1
    if i >= 1 and i <= W and j >= 1 and j <= H then grid[j][i] = g end
  end
  local function fill(box, g)
    for ty = math.floor(box[2] + 1e-3), math.ceil(box[4] - 1e-3) - 1 do
      for tx = math.floor(box[1] + 1e-3), math.ceil(box[3] - 1e-3) - 1 do put(tx, ty, g) end
    end
  end
  local used = {}
  for name, list in pairs(snap.resources) do
    local g = RES_GLYPH[name] or "r"
    used[g] = used[g] or name
    for _, t in ipairs(list) do put(t[1], t[2], g) end
  end
  for _, t in ipairs(snap.water) do put(t[1], t[2], "~") end
  for _, cc in ipairs(snap.unexplored_chunks) do
    for ty = cc[2] * 32, cc[2] * 32 + 31 do for tx = cc[1] * 32, cc[1] * 32 + 31 do put(tx, ty, "?") end end
  end
  for _, o in ipairs(snap.obstacles) do fill(o, o[5] == "tree" and "T" or (o[5] == "cliff" and "C" or "R")) end
  local blocking = {}
  table.sort(snap.entities, function(a, b) return (a.ghost and 0 or 1) < (b.ghost and 0 or 1) end)
  for _, e in ipairs(snap.entities) do
    local g
    if e.ghost then g = "g"
    elseif e.type == "transport-belt" then g = BELT_ARROW[e.dir] or ">"
    elseif e.force == "enemy" then g = e.type == "unit-spawner" and "N" or (e.type == "unit" and "e" or "x")
    elseif e.type == "character" then g = "@"
    else g = TYPE_GLYPH[e.type] or "#" end
    fill(e.box, g)
  end

  -- Straight-line check toward `to`, independent of the window size.
  local path
  local tx, ty = p.to and tonumber(p.to.x) or tonumber(p.to_x), p.to and tonumber(p.to.y) or tonumber(p.to_y)
  if tx and ty and ctx.character then
    local from = ctx.character.position
    local dx, dy = tx - from.x, ty - from.y
    local len = math.sqrt(dx * dx + dy * dy)
    path = {distance = round1(len), clear = true}
    local steps = math.min(math.ceil(len * 2), 800)
    for k = 1, steps do
      local f = k / steps
      local px, py = from.x + dx * f, from.y + dy * f
      if k > 3 then  -- the character itself overlaps the first tiles
        local ok, free = pcall(function()
          return ctx.surface.can_place_entity{name = "character", position = {x = px, y = py}}
        end)
        if ok and not free then
          local tile = ctx.surface.get_tile(math.floor(px), math.floor(py))
          local by = (tile.name:find("water") and tile.name) or nil
          if not by then
            local e = ctx.surface.find_entities_filtered{position = {x = px, y = py}, radius = 1.2}
            for _, z in ipairs(e) do
              if z.type ~= "resource" and z.type ~= "character" and z.type ~= "item-entity" then by = z.name; break end
            end
          end
          path.clear, path.blocked_at, path.blocked_by = false, {x = round1(px), y = round1(py)}, by or "unknown"
          path.tiles_before_block = round1(f * len)
          break
        end
      end
      local gx, gy = math.floor(px), math.floor(py)
      local i, j = gx - x1 + 1, gy - y1 + 1
      if i >= 1 and i <= W and j >= 1 and j <= H and (grid[j][i] == "." or used[grid[j][i]]) then
        grid[j][i] = "*"
      end
    end
    put(math.floor(tx), math.floor(ty), "X")
    if not path.clear then
      path.hint = "the direct line is blocked; goto finds a route around it with the pathfinder (a detour), or falls back to this line when the target is unreachable"
    end
  end

  -- Text with a coordinate ruler: tick every 10 columns, y label every 5 rows.
  local lines, ruler = {}, {}
  for i = 1, W do
    local x = x1 + i - 1
    ruler[i] = " "
    if x % 10 == 0 then ruler[i] = "|" end
  end
  local labels = {}
  for i = 1, W do
    local x = x1 + i - 1
    if x % 10 == 0 then
      local lab = tostring(x)
      for k = 1, #lab do if i + k <= W then labels[i + k] = lab:sub(k, k) end end
    end
  end
  local lab_row = {}
  for i = 1, W do lab_row[i] = labels[i] or " " end
  lines[1] = "     " .. table.concat(lab_row)
  lines[2] = "     " .. table.concat(ruler)
  for j = 1, H do
    local y = y1 + j - 1
    lines[#lines + 1] = string.format("%4s ", y % 5 == 0 and tostring(y) or "") .. table.concat(grid[j])
  end
  local legend = {
    ["@"] = "the AI character", ["."] = "free ground", ["~"] = "water (impassable)", T = "tree", R = "rock",
    C = "cliff", ["?"] = "unexplored (fog)", g = "ghost (planned build)", ["*"] = "straight path to `to`",
    X = "`to` target / turret", ["> < ^ v"] = "transport belt (flow direction)", [")"] = "underground belt",
    Y = "splitter", i = "inserter", ["+"] = "power pole", ["="] = "pipe", A = "assembler", F = "furnace",
    D = "mining drill", L = "lab", B = "chest", E = "generator/solar/accumulator", b = "boiler", S = "tank",
    H = "rocket silo", V = "vehicle", W = "wall/gate", N = "spawner/reactor", e = "enemy unit", x = "worm/enemy turret",
    ["#"] = "other building",
  }
  for g, name in pairs(used) do legend[g] = name .. " ore/patch" end
  return {x0 = x1, y0 = y1, width = W, height = H, character = ctx.character and
            {x = round1(ctx.character.position.x), y = round1(ctx.character.position.y)} or nil,
          text = table.concat(lines, "\n"), legend = legend, path = path,
          note = "one glyph per 1x1 tile; column i is x = x0 + i, row j is y = y0 + j; y grows southward"}
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
