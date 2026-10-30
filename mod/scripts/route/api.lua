-- route_belt / route_pipe RPCs: resolve endpoints, scan the area, search,
-- validate, and return build steps (usable by build_plan). Read-only.
-- Ported from llm-play-factorio (scripts/route/api.lua); the character and
-- surface come from the query context instead of the companion registry.
local core = require("scripts.route.core")
local scan = require("scripts.route.scan")

local M = {}

local MAX_SIDE = 160           -- grid side limit (tiles)
local DEFAULT_MARGIN = 12
local MAX_RETRIES = 3
local DIR_NAME = { [0] = "north", "east", "south", "west" }

local function d4(dir16) return math.floor((tonumber(dir16) or 0) / 4) % 4 end

local function underground_for(belt)
  local ug = belt:gsub("transport%-belt", "underground-belt")
  if ug == belt then ug = "underground-belt" end
  return ug
end

-- Whole-number coordinates name a tile: look at its centre.
local function tile_point(pos)
  local x, y = pos.x, pos.y
  if x == math.floor(x) then x = x + 0.5 end
  if y == math.floor(y) then y = y + 0.5 end
  return { x = x, y = y }
end

-- Items the character has, or can hand-craft now (recipe unlocked).
local function obtainable(c, item)
  if c.get_item_count(item) > 0 then return true end
  local r = c.force.recipes[item]
  return r ~= nil and r.enabled
end

local function own_entity(c, pos, filter)
  pos = tile_point(pos)
  if AIVision.enabled() and not AIVision.is_known(c.surface, c.force, pos) then error("that ground is unexplored", 0) end
  local f = { position = pos, radius = 1.2, force = c.force }
  for k, v in pairs(filter or {}) do f[k] = v end
  local best, bd
  for _, e in ipairs(c.surface.find_entities_filtered(f)) do
    local dx, dy = e.position.x - pos.x, e.position.y - pos.y
    local d = dx * dx + dy * dy
    if not bd or d < bd then best, bd = e, d end
  end
  return best
end

-- Endpoint spec -> { tile = {x, y}, dirs = {d...}|nil, join = belt entity|nil, src = {x,y}|nil, label }
local function resolve(c, spec, role, kind)
  if type(spec) ~= "table" or type(spec.x) ~= "number" or type(spec.y) ~= "number" then
    error(role .. " needs {x, y}")
  end
  local port = spec.port or "tile"
  local pos = { x = spec.x, y = spec.y }
  local dirs = spec.direction ~= nil and { d4(spec.direction) } or nil
  if port == "tile" then
    return { tile = { math.floor(pos.x), math.floor(pos.y) }, dirs = dirs, label = "tile" }
  elseif port == "drop" then
    local e = own_entity(c, pos, { type = { "mining-drill", "inserter" } })
    if not e then error(role .. ": no mining drill or inserter of your force at that position") end
    local p = e.drop_position
    return { tile = { math.floor(p.x), math.floor(p.y) }, dirs = dirs, label = e.name .. " output" }
  elseif port == "pickup" then
    local e = own_entity(c, pos, { type = "inserter" })
    if not e then error(role .. ": no inserter of your force at that position") end
    local p = e.pickup_position
    return { tile = { math.floor(p.x), math.floor(p.y) }, dirs = dirs, label = e.name .. " pickup" }
  elseif port == "belt" then
    local e = own_entity(c, pos, { type = { "transport-belt", "underground-belt" } })
    if not e then error(role .. ": no belt of your force at that position") end
    return { belt = e, label = e.name }
  elseif port == "fluid" then
    local e = own_entity(c, pos, nil)
    if not (e and e.fluidbox and #e.fluidbox > 0) then error(role .. ": no fluid entity of your force at that position") end
    for k = 1, #e.fluidbox do
      for _, conn in ipairs(e.fluidbox.get_pipe_connections(k)) do
        if conn.connection_type ~= "underground" and conn.target_position and not conn.target then
          local tp = conn.target_position
          return { tile = { math.floor(tp.x), math.floor(tp.y) }, src = { math.floor(conn.position.x), math.floor(conn.position.y) },
            label = e.name .. " fluid connection" }
        end
      end
    end
    error(role .. ": every fluid connection of that " .. e.name .. " is already connected")
  end
  error("port must be tile, drop, pickup, belt or fluid")
end

local function unit(d) return core.DX[d], core.DY[d] end

function M.route(ctx, params, kind)
  local c = ctx.character
  if not (c and c.valid) then error("no AI character to route for", 0) end
  local is_belt = kind == "belt"
  local place = is_belt and (params.belt or "transport-belt") or (params.pipe or "pipe")
  local ug_name = params.underground or (is_belt and underground_for(place) or "pipe-to-ground")
  local proto, ug_proto = prototypes.entity[place], prototypes.entity[ug_name]
  if not proto then error("no entity called '" .. place .. "'") end
  -- allow_underground: true/false, or nil = only if the character has or can craft them
  local allow_ug = ug_proto ~= nil
  if params.allow_underground == false then allow_ug = false
  elseif params.allow_underground == nil then allow_ug = allow_ug and obtainable(c, ug_name) end
  local ug_max = 5
  if ug_proto then
    pcall(function() ug_max = ug_proto.max_underground_distance or ug_max end)
    if not is_belt then
      pcall(function()
        for _, pc in pairs(ug_proto.fluidbox_prototypes[1].pipe_connections) do
          if pc.connection_type == "underground" and pc.max_underground_distance then ug_max = pc.max_underground_distance end
        end
      end)
    end
  end

  local from = resolve(c, params.from, "from", kind)
  local to = resolve(c, params.to, "to", kind)
  if from.belt then
    -- continue an existing belt: start on the tile it outputs into
    local e = from.belt
    local dx, dy = unit(d4(e.direction))
    from = { tile = { math.floor(e.position.x) + dx, math.floor(e.position.y) + dy }, dirs = from.dirs, continues = e, label = from.label }
  end

  -- grid bounds
  local pts = { from.tile or { math.floor(to.belt.position.x), math.floor(to.belt.position.y) } }
  pts[#pts + 1] = to.tile or { math.floor(to.belt.position.x), math.floor(to.belt.position.y) }
  local margin = math.max(2, math.min(tonumber(params.margin) or DEFAULT_MARGIN, 40))
  local x1, y1 = math.min(pts[1][1], pts[2][1]) - margin, math.min(pts[1][2], pts[2][2]) - margin
  local x2, y2 = math.max(pts[1][1], pts[2][1]) + margin, math.max(pts[1][2], pts[2][2]) + margin
  if x2 - x1 + 1 > MAX_SIDE or y2 - y1 + 1 > MAX_SIDE then
    error(string.format("the endpoints are too far apart for one route (area %dx%d > %d) — route it in segments",
      x2 - x1 + 1, y2 - y1 + 1, MAX_SIDE))
  end
  local g = scan.build({ surface = c.surface, force = c.force, place_name = place, fluid = not is_belt,
    clear_obstacles = params.clear_obstacles == true, avoid = params.avoid, planned = params.planned_belts }, x1, y1, x2, y2)

  local endpoint, endpoint_src = {}, {}
  local s_i = from.tile and g.idx(from.tile[1], from.tile[2])
  -- a start on an occupied tile can't route at all ("0 expansions"): say why
  if s_i and not from.belt and not from.continues and (g.blocked[s_i] or (g.belt and g.belt[s_i])) then
    local tx, ty = from.tile[1] + 0.5, from.tile[2] + 0.5
    local what = c.surface.find_entities_filtered({ position = { tx, ty }, radius = 0.5, limit = 1 })[1]
    error(string.format("the start tile (%.1f, %.1f) is not free%s — start on a free tile next to it, or use a port "
      .. "(drop/pickup/belt) of the entity there", tx, ty, what and (": " .. what.name .. " is there") or ""))
  end
  if not s_i then error("from is outside the routing area") end
  endpoint[s_i] = true
  if from.src then local si = g.idx(from.src[1], from.src[2]); if si then endpoint_src[si] = true end end

  local goal_tiles, goal_dirs = {}, nil
  local join_info = {}
  if to.belt then
    local e = to.belt
    local bx, by = math.floor(e.position.x), math.floor(e.position.y)
    local bd = d4(e.direction)
    goal_dirs = {}
    for d = 0, 3 do
      local nx, ny = bx - core.DX[d], by - core.DY[d]   -- tile from which facing d points into the belt
      local ni = g.idx(nx, ny)
      if ni and d ~= core.opposite(bd) then
        goal_tiles[ni] = true
        goal_dirs[ni] = { [d] = true }
        endpoint[ni] = true
        join_info[ni] = (d == bd) and "extends" or "side"
      end
    end
  else
    local t_i = g.idx(to.tile[1], to.tile[2])
    if not t_i then error("to is outside the routing area") end
    goal_tiles[t_i] = true
    endpoint[t_i] = true
    if to.dirs and is_belt then goal_dirs = { [t_i] = { [to.dirs[1]] = true } } end
    if to.src then local ti = g.idx(to.src[1], to.src[2]); if ti then endpoint_src[ti] = true end end
  end
  if s_i and goal_tiles[s_i] then error("from and to are the same tile") end

  local cost = params.costs or {}
  local opts = {
    kind = kind, starts = { { tile = s_i, dirs = from.dirs } }, goal_tiles = goal_tiles, goal_dirs = goal_dirs,
    endpoint = endpoint, endpoint_src = endpoint_src, allow_ug = allow_ug, ug_name = ug_name, ug_max = ug_max,
    cost = { step = cost.step, turn = cost.turn, ug = cost.underground, soft = cost.obstacle, near_belt = cost.near_belt },
    max_expansions = math.min(tonumber(params.max_expansions) or 60000, 200000), banned = {},
    allow_touch = params.through_inserters == true,
  }

  local path, stats, pl, why
  local expansions = 0
  for attempt = 1, MAX_RETRIES + 1 do
    path, stats = core.search(g, opts)
    expansions = expansions + (stats.expansions or 0)
    if not path then break end
    pl = core.placements(g, path, kind)
    if not is_belt then break end
    local bad
    bad, why = core.validate_belts(g, pl, ug_max, ug_name)
    if not bad then break end
    opts.banned[bad] = true
    path = nil
  end
  if not path then
    local reason = stats and stats.exhausted and "search budget exhausted" or "no legal path"
    error(string.format("no %s route from %s to %s (%s after %d expansions%s) — try a larger margin, clear_obstacles=true, allow_underground, or other endpoints",
      kind, from.label, to.label, reason, expansions, why and ("; last conflict: " .. why) or ""))
  end

  -- placements -> steps in map coordinates
  local steps, bill, turns, ug_pairs = {}, {}, 0, 0
  local mine_first = {}
  local prev_d
  for _, p in ipairs(pl) do
    local lx, ly = core.xy(g, p.tile)
    local x, y = lx + x1 + 0.5, ly + y1 + 0.5
    local item = (p.kind == "belt" or p.kind == "pipe") and place or ug_name
    -- x/y flat as in the source repo, plus position = {x, y} and a direction NAME, which is what this mod's build_plan reads
    local step = { item = item, x = x, y = y, position = { x = x, y = y }, direction = DIR_NAME[p.d] }
    if p.ug_type then step.underground_type = p.ug_type end
    steps[#steps + 1] = step
    bill[item] = (bill[item] or 0) + 1
    if p.kind == "ug" and p.ug_type == "input" then ug_pairs = ug_pairs + 1 end
    if is_belt and prev_d and prev_d ~= p.d then turns = turns + 1 end
    prev_d = p.d
    for _, o in ipairs(g.obstacles[p.tile] or {}) do
      if o.valid then mine_first[#mine_first + 1] = { name = o.name, x = o.position.x, y = o.position.y } end
    end
  end
  if not is_belt then
    local n = 0
    for _, p in ipairs(pl) do if p.kind == "ptg" then n = n + 1 end end
    ug_pairs = math.floor(n / 2)
  end

  local effects = {}
  local last = pl[#pl]
  if to.belt and last then
    local kindj = join_info[last.tile]
    if kindj == "extends" then
      effects[#effects + 1] = "the last belt feeds " .. to.label .. " from behind (extends it)"
    else
      local e = to.belt
      local behind = g.idx(math.floor(e.position.x) - core.DX[d4(e.direction)], math.floor(e.position.y) - core.DY[d4(e.direction)])
      local fed = behind and g.feed[behind]
      if fed then
        effects[#effects + 1] = "side-loads onto " .. to.label .. " (items go onto the lane nearest this belt)"
      else
        effects[#effects + 1] = "joins " .. to.label .. " from the side while nothing feeds it from behind, so that belt becomes a curve"
      end
    end
  end
  if from.continues then effects[#effects + 1] = "continues " .. from.label .. " from its output end" end

  -- inventory check: missing = not carried; unavailable = missing and not craftable now
  local missing, unavailable = {}, {}
  for item, n in pairs(bill) do
    local have = c.get_item_count(item)
    if have < n then
      missing[item] = n - have
      local r = c.force.recipes[item]
      if not (r and r.enabled) then unavailable[#unavailable + 1] = item end
    end
  end

  -- Did avoiding inserter/drill tiles make the route longer? Say so (it used
  -- to detour silently): a quick second search that may pass through them.
  if is_belt and not opts.allow_touch and next(g.touch) ~= nil then
    local o2 = {}
    for k, v in pairs(opts) do o2[k] = v end
    o2.allow_touch, o2.banned, o2.max_expansions = true, {}, math.min(opts.max_expansions, 30000)
    local p2 = core.search(g, o2)
    if p2 then
      local pl2 = core.placements(g, p2, kind)
      if #pl2 < #pl then
        effects[#effects + 1] = string.format("detoured %d tile(s) to keep clear of inserter pickup/drop and drill "
          .. "drop tiles; pass through_inserters=true to route through them (a belt through an inserter's pickup "
          .. "tile feeds that inserter)", #pl - #pl2)
      end
    end
  end

  return {
    kind = kind, steps = steps, bill = bill, missing = missing, unavailable = unavailable,
    underground_used = allow_ug, mine_first = mine_first, effects = effects,
    length = #pl, turns = turns, underground_pairs = ug_pairs, cost = stats.cost, expansions = expansions,
    from = from.label, to = to.label, start = { x = steps[1].x, y = steps[1].y },
    finish = { x = steps[#steps].x, y = steps[#steps].y, direction = DIR_NAME[last and last.d or 0] },
  }
end

function M.route_belt(ctx, params) return M.route(ctx, params, "belt") end
function M.route_pipe(ctx, params) return M.route(ctx, params, "pipe") end

AIRoute = M   -- queries.lua reaches it as a global; require() is not allowed at runtime
return M
