-- trace_belt: the whole belt line through a tile, both ways (v3).
--
-- Legs (runs of one direction), how the line starts and ends, what feeds it
-- (inserters, drills, side-loads) and what takes from it, and the items on each
-- lane with fill % against the lane's 4 items per tile. Underground belts are
-- explained when unpaired. Complements belt_line (tile-by-tile along a row):
-- this one FOLLOWS the line, around corners and through undergrounds.
-- Lanes are named from the direction of travel ("left"/"right") with the
-- compass side they are on. With fog of war on, known ground only.
-- Ported from llm-play-factorio (scripts/belts.lua), trace only.

AIBelts = {}
local M = AIBelts

local BELT_TYPES = { "transport-belt", "underground-belt", "splitter" }
local IS_BELT = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true }
local DIR = { [0] = "north", [4] = "east", [8] = "south", [12] = "west" }
-- left/right of travel -> compass side, per direction of travel
local SIDES = { [0] = { "west", "east" }, [4] = { "north", "south" }, [8] = { "east", "west" }, [12] = { "south", "north" } }
local MAX_TILES = 400

local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
local function pos(e) return { x = r1(e.position.x), y = r1(e.position.y) } end

local function belt_at(c, p)
  local best, best_d
  for _, e in ipairs(c.surface.find_entities_filtered({ position = p, radius = 1.2, type = BELT_TYPES })) do
    local d = (e.position.x - p.x) ^ 2 + (e.position.y - p.y) ^ 2
    if not best_d or d < best_d then best, best_d = e, d end
  end
  return best
end

-- items on a belt's two lanes: {left = {name = n}, right = {...}}, counts.
-- A 2.0 transport line is read per belt entity, but the internal line it
-- wraps CAN span multiple tiles (line_equals is true across different
-- owners): get_contents reports the LINE's items — where a line spans
-- tiles, more than this tile's. The third return carries the line objects
-- so callers can dedupe lines.
local function lanes(e)
  local out = { left = {}, right = {} }
  local n = { left = 0, right = 0 }
  local lines = {}
  pcall(function()
    for i = 1, math.min(e.get_max_transport_line_index(), 2) do
      local side = i == 1 and "left" or "right"
      local line = e.get_transport_line(i)
      lines[side] = line
      for _, it in ipairs(line.get_contents()) do
        out[side][it.name] = (out[side][it.name] or 0) + it.count
        n[side] = n[side] + it.count
      end
    end
  end)
  return out, n, lines
end

-- whether two LuaTransportLine objects are the same internal line (lines
-- can span multiple tiles). Falls back to identity when line_equals is
-- unavailable — then runs cannot be told apart and counting stays per-tile.
local function same_line(a, b)
  if a == nil or b == nil then return false end
  local same = false
  pcall(function() same = a:line_equals(b) end)
  if not same then same = (a == b) end
  return same
end

-- Belt capacity per lane in items/s: speed (tiles/s) x 4 items per tile, x belt stacking.
local function lane_capacity(e, force)
  local speed = 0
  pcall(function() speed = e.prototype.belt_speed * 60 end)
  local stack = 1
  pcall(function() stack = 1 + (force.belt_stack_size_bonus or 0) end)
  return speed * 4 * stack
end

local UNIT = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }

-- The belt an underground belt is paired with. LuaEntity.neighbours is gone on
-- Factorio 2.1 (and belt_neighbours does not list the pair), so look for it:
-- an entrance pairs with the first exit ahead of it within reach, an exit with
-- the first entrance behind it; a same-kind belt in between blocks the pairing.
local function ug_partner(e)
  local ok, native = pcall(function() return e.neighbours end)
  if ok then return native end
  local input = e.belt_to_ground_type == "input"
  local reach = 5
  pcall(function() reach = e.prototype.max_underground_distance or reach end)
  local u = UNIT[e.direction] or { 0, 0 }
  local sign = input and 1 or -1
  for k = 1, reach + 1 do
    local q = { x = e.position.x + sign * u[1] * k, y = e.position.y + sign * u[2] * k }
    for _, t in ipairs(e.surface.find_entities_filtered({ position = q, radius = 0.3, name = e.name })) do
      if t.valid and t ~= e and t.direction == e.direction then
        if (t.belt_to_ground_type == "input") ~= input then return t end
        return nil
      end
    end
  end
  return nil
end

-- How an underground belt is paired, in words. An entrance (input) pairs with
-- the first exit of the same kind ahead of it within its reach; an exit
-- (output) with the first entrance behind it. Returns (text, paired).
function M.underground_note(e)
  if not (e and e.valid and e.type == "underground-belt") then return nil end
  local input = e.belt_to_ground_type == "input"
  local other = ug_partner(e)
  if other then
    return string.format("%s paired with the %s at (%.1f, %.1f)", input and "entrance" or "exit",
      input and "exit" or "entrance", other.position.x, other.position.y), true
  end
  local reach = 5
  pcall(function() reach = e.prototype.max_underground_distance or reach end)
  local u = UNIT[e.direction] or { 0, 0 }
  local sign = input and 1 or -1 -- an entrance looks ahead, an exit behind
  local want = input and "exit" or "entrance"
  local text = string.format("%s with NO %s — nothing goes through it", input and "entrance" or "exit", want)
  for k = 1, reach do
    local q = { x = e.position.x + sign * u[1] * k, y = e.position.y + sign * u[2] * k }
    for _, t in ipairs(e.surface.find_entities_filtered({ position = q, radius = 0.3, name = e.name })) do
      if t.valid and t ~= e then
        local tin = t.belt_to_ground_type == "input"
        local what = string.format("the %s at (%.1f, %.1f)", tin and "entrance" or "exit", t.position.x, t.position.y)
        if t.direction ~= e.direction then
          return string.format("%s; %s is in the way and faces %s, not %s", text, what,
            DIR[t.direction] or tostring(t.direction), DIR[e.direction] or tostring(e.direction)), false
        elseif tin == input then
          return string.format("%s; %s is in between (two %ss can't pair; the one nearer the %s takes it)",
            text, what, input and "entrance" or "exit", want), false
        elseif ug_partner(t) then
          return string.format("%s; %s is already paired with the %s at (%.1f, %.1f), which is closer", text, what,
            input and "entrance" or "exit", ug_partner(t).position.x, ug_partner(t).position.y), false
        end
      end
    end
  end
  return string.format("%s with NO %s within %d tiles %s of it — nothing goes through it",
    input and "entrance" or "exit", want, reach, DIR[input and e.direction or (e.direction + 8) % 16] or "?"), false
end

local function next_down(e)
  if e.type == "underground-belt" and e.belt_to_ground_type == "input" then
    local n = ug_partner(e)
    if n then return { n } end
  end
  return e.belt_neighbours.outputs or {}
end

-- The belt feeding this one from behind (a straight predecessor, or the only
-- input of a curve); other inputs are side-loads.
local function next_up(e)
  if e.type == "underground-belt" and e.belt_to_ground_type == "output" then
    local n = ug_partner(e)
    if n then return { n } end
  end
  local ins = e.belt_neighbours.inputs or {}
  for _, i in ipairs(ins) do
    if i.direction == e.direction then return { i } end
  end
  if #ins == 1 then return { ins[1] } end
  return {}
end

-- What's in front of a belt that outputs to nothing.
local function dead_end(c, e)
  if e.type == "underground-belt" and e.belt_to_ground_type == "input" then
    return "underground " .. M.underground_note(e)
  end
  local d = e.direction
  local u = UNIT[d] or { 0, 0 }
  local front = { x = e.position.x + u[1], y = e.position.y + u[2] }
  for _, t in ipairs(c.surface.find_entities_filtered({ position = front, radius = 0.45 })) do
    if t.valid and t.type ~= "resource" and t.type ~= "item-entity" and t.type ~= "character" then
      if t.type == "underground-belt" and t.belt_to_ground_type == "output" and t.direction == e.direction then
        return string.format("runs into the back of the underground exit at (%.1f, %.1f) — an exit only puts items out;"
          .. " to go under, this tile needs an entrance", t.position.x, t.position.y)
      end
      if IS_BELT[t.type] then
        return string.format("faces the %s at (%.1f, %.1f), which doesn't take items from this side (it points %s)",
          t.name, t.position.x, t.position.y, DIR[t.direction] or tostring(t.direction))
      end
      return string.format("faces the %s at (%.1f, %.1f) — belts can't feed buildings; an inserter must take from the belt",
        t.name, t.position.x, t.position.y)
    end
  end
  return string.format("dead end: nothing in front at (%.1f, %.1f), so items stop and back up here", front.x, front.y)
end

-- Walk one way from `start`, collecting belts in order (with a cap).
local function walk(start, step, known)
  local list, seen = {}, {}
  local e = start
  while e and e.valid and not seen[e.unit_number] and #list < MAX_TILES do
    if not known(e.position) then break end
    seen[e.unit_number] = true
    list[#list + 1] = e
    e = step(e)[1]
  end
  return list
end

-- c = query ctx ({surface, force, character}); params = {x, y}
function M.trace(c, params)
  local p = {x = tonumber(params.x), y = tonumber(params.y)}
  if not (p.x and p.y) then return {error = "trace_belt: need x and y"} end
  local function known(q) return not AIVision.enabled() or AIVision.is_known(c.surface, c.force, q) end
  if not known(p) then return {error = "trace_belt: that ground is unexplored"} end
  local start = belt_at(c, p)
  if not start then return {error = string.format("no belt at (%.1f, %.1f)", p.x, p.y)} end

  local down = walk(start, next_down, known)
  local up_list = walk(start, next_up, known)
  -- the line in travel order: upstream (reversed, without start) + downstream
  local line = {}
  for i = #up_list, 2, -1 do line[#line + 1] = up_list[i] end
  for _, e in ipairs(down) do line[#line + 1] = e end

  local on_line = {}
  for i, e in ipairs(line) do on_line[math.floor(e.position.x) .. "," .. math.floor(e.position.y)] = i end
  local function line_index(q) return on_line[math.floor(q.x) .. "," .. math.floor(q.y)] end

  -- legs: runs of one direction. Items are counted ONCE per internal line —
  -- where a line spans multiple tiles, every tile of it reports the same
  -- items and summing per-tile reads double-counts. Each leg's fill is
  -- measured against the length of the lines under it (line_length — NOT
  -- total_segment_length, which is a larger scope: the segment of this line
  -- plus every line directly connected front and back; measured against a
  -- 61-tile segment, a 49-tile lab-spine leg read 1% full while holding
  -- 83%. A line can continue through a corner into the next leg; it carries
  -- its items and length to every leg it touches, counted once).
  local legs, cur = {}, nil
  local cap = lane_capacity(start, c.force)
  local runs = { left = {}, right = {} } -- unique internal lines per side
  for _, e in ipairs(line) do
    local items, n, lines = lanes(e)
    local kind = e.type == "underground-belt" and ("underground " .. e.belt_to_ground_type)
      or (e.type == "splitter" and "splitter" or nil)
    if not cur or cur.direction ~= e.direction or kind or cur.kind then
      cur = { direction = e.direction, from = pos(e), to = pos(e), tiles = 0, kind = kind,
        left = {}, right = {}, n_left = 0, n_right = 0,
        note = e.type == "underground-belt" and M.underground_note(e) or nil }
      legs[#legs + 1] = cur
    end
    cur.to = pos(e)
    cur.tiles = cur.tiles + 1
    for _, side in ipairs({ "left", "right" }) do
      local l = lines[side]
      if l then
        local entry
        for _, r in ipairs(runs[side]) do
          if same_line(r.line, l) then entry = r break end
        end
        if not entry then
          local len
          pcall(function() len = l.line_length end)
          entry = { line = l, len = len, tiles = 0, items = {}, n = 0, leg_marks = {} }
          runs[side][#runs[side] + 1] = entry
          -- this run's items, read once, at the tile where the trace first meets it
          for name, k in pairs(items[side] or {}) do entry.items[name] = k end
          entry.n = n[side]
        end
        entry.tiles = entry.tiles + 1
        entry.leg_marks[cur] = true
      else
        -- no line object to compare (the read failed): count per tile
        for name, k in pairs(items[side] or {}) do
          cur[side][name] = (cur[side][name] or 0) + k
        end
        cur["n_" .. side] = cur["n_" .. side] + n[side]
      end
    end
  end
  for _, leg in ipairs(legs) do
    local sides = SIDES[leg.direction] or { "?", "?" }
    leg.left_side, leg.right_side = sides[1], sides[2]
    leg.moving = DIR[leg.direction] or tostring(leg.direction)
    for _, side in ipairs({ "left", "right" }) do
      local n, len = 0, 0
      for _, r in ipairs(runs[side]) do
        if r.leg_marks[leg] then
          for name, k in pairs(r.items) do leg[side][name] = (leg[side][name] or 0) + k end
          n = n + r.n
          len = len + math.max(r.len or r.tiles, r.tiles, 1)
        end
      end
      leg["n_" .. side] = leg["n_" .. side] + n
      local denom = 4 * (len > 0 and len or leg.tiles)
      leg["fill_" .. side] = denom > 0 and math.floor(100 * leg["n_" .. side] / denom + 0.5) or 0
    end
  end

  -- feeders and takers: inserters and drills touching the line, side-loads
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(line) do
    x1, y1 = math.min(x1, e.position.x), math.min(y1, e.position.y)
    x2, y2 = math.max(x2, e.position.x), math.max(y2, e.position.y)
  end
  local feeds, takes = {}, {}
  for _, e in ipairs(c.surface.find_entities_filtered({ area = { { x1 - 4, y1 - 4 }, { x2 + 4, y2 + 4 } },
    type = { "inserter", "mining-drill" } })) do
    pcall(function()
      if e.type == "inserter" then
        if line_index(e.pickup_position) then
          takes[#takes + 1] = string.format("%s at (%.1f, %.1f)", e.name, e.position.x, e.position.y)
        end
      end
      if line_index(e.drop_position) then
        feeds[#feeds + 1] = string.format("%s at (%.1f, %.1f)", e.name, e.position.x, e.position.y)
      end
    end)
  end
  for idx, e in ipairs(line) do
    local prev = line[idx - 1]
    for _, s in ipairs(e.belt_neighbours.inputs or {}) do
      if not (prev and s == prev) and not line_index(s.position) then
        feeds[#feeds + 1] = string.format("side-load from the belt at (%.1f, %.1f)", s.position.x, s.position.y)
      end
    end
  end

  -- ends
  local first, last = line[1], line[#line]
  local start_note
  local up_main = first and next_up(first) or {}
  if #line >= MAX_TILES then start_note = "(traced " .. MAX_TILES .. " tiles; the line goes on)"
  elseif first and #up_main > 0 then start_note = "continues on unexplored ground"
  elseif first.type == "underground-belt" and first.belt_to_ground_type == "output" then
    start_note = string.format("starts at the underground %s at (%.1f, %.1f)", M.underground_note(first),
      first.position.x, first.position.y)
  else start_note = string.format("starts at (%.1f, %.1f): nothing feeds it from behind", first.position.x, first.position.y) end
  local end_note
  local outs = last and next_down(last) or {}
  if #outs == 0 then
    end_note = dead_end(c, last)
  elseif #line >= MAX_TILES then
    end_note = "(traced " .. MAX_TILES .. " tiles; the line goes on)"
  else
    local o = outs[1]
    if o and o.valid and o.direction ~= last.direction and IS_BELT[o.type] and not line_index(o.position) then
      end_note = string.format("side-loads onto the belt at (%.1f, %.1f) (items go onto its near lane)", o.position.x,
        o.position.y)
    else
      end_note = "continues on unexplored ground"
    end
  end

  return {
    start = pos(start), tiles = #line, legs = legs, begins = start_note, ends = end_note,
    fed_by = feeds, taken_by = takes, lane_capacity_per_min = math.floor(cap * 60 + 0.5),
  }
end

return AIBelts
