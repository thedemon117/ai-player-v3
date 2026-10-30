-- Pure routing core (no game API): weighted A* for belts and pipes on a tile
-- grid built by route/scan.lua. Unit-tested offline (tests/mod/route_test.lua).
--
-- Directions are 0..3 = north, east, south, west (Factorio's 16-way value is d*4).
--
-- Belts: state = (tile, d) where d is the direction the belt on the tile
-- outputs to. From (i, d) the next tile is i+d; the belt placed there may keep
-- d or turn left/right (a belt fed from one side with nothing behind it is a
-- curve). Underground: entrance on n = i+d facing d, exit on n + k*d, also
-- facing d, for k = 2 .. max_underground_distance (yellow: 5, i.e. 4 tiles between).
--
-- Pipes: state = (tile, d) where d is the direction we arrived from (only
-- matters for pipe-to-ground). Pipes connect on all four sides; a pipe-to-ground
-- has one normal connection and one underground connection.
local M = {}

M.DX = { [0] = 0, 1, 0, -1 }
M.DY = { [0] = -1, 0, 1, 0 }

function M.opposite(d) return (d + 2) % 4 end

-- ------------------------------------------------------------ binary heap
local function heap_new() return { keys = {}, vals = {}, n = 0 } end

local function heap_push(h, key, val)
  local n = h.n + 1
  h.n = n
  local keys, vals = h.keys, h.vals
  while n > 1 do
    local p = math.floor(n / 2)
    if keys[p] <= key then break end
    keys[n], vals[n] = keys[p], vals[p]
    n = p
  end
  keys[n], vals[n] = key, val
end

local function heap_pop(h)
  if h.n == 0 then return nil end
  local keys, vals = h.keys, h.vals
  local top = vals[1]
  local lk, lv = keys[h.n], vals[h.n]
  keys[h.n], vals[h.n] = nil, nil
  h.n = h.n - 1
  local n, i = h.n, 1
  if n > 0 then
    while true do
      local c = i * 2
      if c > n then break end
      if c < n and keys[c + 1] < keys[c] then c = c + 1 end
      if keys[c] >= lk then break end
      keys[i], vals[i] = keys[c], vals[c]
      i = c
    end
    keys[i], vals[i] = lk, lv
  end
  return top
end

-- ------------------------------------------------------------------ grid
-- grid = { W, H, x0, y0,
--   blocked[i]   nothing may be placed (unknown chunk, occupied, water, cliff)
--   soft[i]      tree/rock: placeable only after mining (extra cost)
--   feed[i]      a foreign belt outputs into this tile
--   touch[i]     a foreign inserter picks/drops here, or a drill drops here
--   belt[i]      a foreign belt-like entity occupies the tile
--   fluid_src[i] list of tile indices whose foreign fluid connection targets i
--   ug[i]        name of a foreign underground (belt or pipe-to-ground) on i
-- } with i = y*W + x (0-based local coordinates).

function M.index(g, x, y) return y * g.W + x end
function M.xy(g, i) return i % g.W, math.floor(i / g.W) end

local function neighbour(g, i, d)
  local x, y = i % g.W, math.floor(i / g.W)
  x, y = x + M.DX[d], y + M.DY[d]
  if x < 0 or y < 0 or x >= g.W or y >= g.H then return nil end
  return y * g.W + x
end
M.neighbour = neighbour

local function step_to(g, i, d, k)
  local x, y = i % g.W, math.floor(i / g.W)
  x, y = x + M.DX[d] * k, y + M.DY[d] * k
  if x < 0 or y < 0 or x >= g.W or y >= g.H then return nil end
  return y * g.W + x
end

-- A same-named foreign underground anywhere on the line near the span would
-- pair with (or steal) one of our ends: reject conservatively.
local function ug_conflict(g, a, b, d, name, maxd)
  if not g.ug then return false end
  local lo = -maxd
  local x, y = a % g.W, math.floor(a / g.W)
  local dist = 0
  do
    local bx, by = b % g.W, math.floor(b / g.W)
    dist = math.abs(bx - x) + math.abs(by - y)
  end
  for k = lo, dist + maxd do
    local j = step_to(g, a, d, k)
    if j and g.ug[j] == name then return true end
  end
  return false
end

-- --------------------------------------------------------------- search
-- opts = {
--   kind = "belt" | "pipe",
--   starts = { {tile=i, dirs={d...}|nil} },   -- belt: first belt's direction(s); pipe: dirs ignored
--   goal_tiles = {[i]=true}, goal_dirs = {[i]={[d]=true}}|nil,   -- belt: required final direction per goal tile
--   endpoint = {[i]=true},                   -- start/goal tiles exempt from touch/feed/fluid rules
--   endpoint_src = {[i]=true},               -- fluid sources that belong to endpoint entities
--   allow_ug, ug_name, ug_max,               -- underground item name and max distance (entrance..exit)
--   cost = {step, turn, ug, soft, near_belt},
--   max_expansions, weight,
--   banned = {[state]=true},                 -- states excluded (validator feedback)
-- }
function M.search(g, opts)
  local cost = opts.cost or {}
  local c_step, c_turn = cost.step or 1, cost.turn or 0.5
  -- an underground pair costs its span plus a surcharge, so plain belts/pipes
  -- win on open ground and undergrounds are used to pass obstacles
  local c_ug, c_soft = cost.ug or 4, cost.soft or 3
  local c_near = cost.near_belt or 0.2
  local weight = opts.weight or 1.2
  local max_exp = opts.max_expansions or 60000
  local banned = opts.banned or {}
  local endpoint = opts.endpoint or {}
  local ep_src = opts.endpoint_src or {}
  local allow_touch = opts.allow_touch == true -- belts may pass inserter pickup/drop and drill drop tiles
  local is_belt = opts.kind ~= "pipe"

  -- heuristic target: centroid-free — take the nearest goal tile by Manhattan
  local goals = {}
  for i in pairs(opts.goal_tiles) do goals[#goals + 1] = { i % g.W, math.floor(i / g.W) } end
  local function h(i)
    local x, y = i % g.W, math.floor(i / g.W)
    local best = math.huge
    for _, t in ipairs(goals) do
      local dd = math.abs(t[1] - x) + math.abs(t[2] - y)
      if dd < best then best = dd end
    end
    return best * c_step
  end

  local function free(i)
    return not g.blocked[i] and not (g.belt and g.belt[i])
  end

  -- belt at tile i facing d
  local function belt_ok(i, d)
    if not free(i) then return false end
    if not endpoint[i] then
      if g.feed[i] or (g.touch[i] and not allow_touch) then return false end
    end
    return true
  end

  -- pipe at tile i (all four sides connect)
  local function pipe_ok(i)
    if not free(i) then return false end
    local src = g.fluid_src and g.fluid_src[i]
    if src then
      for _, s in ipairs(src) do
        if not ep_src[s] then return false end
      end
    end
    return true
  end

  -- pipe-to-ground at i whose normal connection faces c
  local function ptg_ok(i, c)
    if not free(i) then return false end
    local src = g.fluid_src and g.fluid_src[i]
    if src then
      local facing = neighbour(g, i, c)
      for _, s in ipairs(src) do
        if s == facing and not ep_src[s] then return false end
      end
    end
    return true
  end

  local function extra(i)
    local e = 0
    if g.soft[i] then e = e + c_soft end
    if is_belt and c_near > 0 and g.belt then
      for d = 0, 3 do
        local n = neighbour(g, i, d)
        if n and g.belt[n] then e = e + c_near break end
      end
    end
    return e
  end

  -- States are tile*4 + d. Pipe-to-ground exits get their own states
  -- (N4 + tile*4 + d): from an exit only its opening connects, so an exit
  -- arrival must not block a plain-pipe arrival at the same tile.
  local N4 = g.W * g.H * 4
  local function tile_of(st) return math.floor((st % N4) / 4) end
  local gscore, parent, move = {}, {}, {}
  local open = heap_new()
  for _, s in ipairs(opts.starts) do
    local dirs = s.dirs or { 0, 1, 2, 3 }
    for _, d in ipairs(dirs) do
      local ok = is_belt and belt_ok(s.tile, d) or (not is_belt and pipe_ok(s.tile))
      local st = s.tile * 4 + d
      if ok and not banned[st] then
        local c0 = extra(s.tile)
        if gscore[st] == nil or c0 < gscore[st] then
          gscore[st] = c0
          parent[st] = -1
          move[st] = 0
          heap_push(open, c0 + weight * h(s.tile), st)
        end
      end
    end
  end

  local closed = {}
  local expansions = 0
  local function relax(from, to, c, mv)
    if banned[to] or closed[to] then return end
    local ng = gscore[from] + c
    if gscore[to] == nil or ng < gscore[to] - 1e-9 then
      gscore[to] = ng
      parent[to] = from
      move[to] = mv
      heap_push(open, ng + weight * h(tile_of(to)), to)
    end
  end

  local found
  while true do
    local st = heap_pop(open)
    if not st then break end
    if not closed[st] then
      closed[st] = true
      local i, d = tile_of(st), st % 4
      local from_ptg = st >= N4
      local goal_ok = opts.goal_tiles[i] and not from_ptg -- a pipe route never ends on an exit
      if goal_ok and opts.goal_dirs and opts.goal_dirs[i] then goal_ok = opts.goal_dirs[i][d] end
      if goal_ok then found = st break end
      expansions = expansions + 1
      if expansions > max_exp then break end

      if is_belt then
        local n = neighbour(g, i, d)
        if n then
          for _, d2 in ipairs({ d, (d + 1) % 4, (d + 3) % 4 }) do
            if belt_ok(n, d2) then
              relax(st, n * 4 + d2, c_step + (d2 ~= d and c_turn or 0) + extra(n), 0)
            end
          end
          if opts.allow_ug and belt_ok(n, d) then
            for k = 2, opts.ug_max or 5 do
              local m = step_to(g, n, d, k)
              if not m then break end
              if belt_ok(m, d) and not ug_conflict(g, n, m, d, opts.ug_name, opts.ug_max or 5) then
                relax(st, m * 4 + d, k * c_step + c_ug + extra(n) + extra(m), k)
              end
            end
          end
        end
      else
        -- after a pipe-to-ground exit only its opening connects: go straight on
        for d2 = 0, 3 do
          local n = (not from_ptg or d2 == d) and neighbour(g, i, d2) or nil
          if n then
            if pipe_ok(n) then relax(st, n * 4 + d2, c_step + extra(n), 0) end
            if opts.allow_ug and ptg_ok(n, M.opposite(d2)) then
              for k = 2, opts.ug_max or 10 do
                local m = step_to(g, n, d2, k)
                if not m then break end
                if ptg_ok(m, d2) and not ug_conflict(g, n, m, d2, opts.ug_name, opts.ug_max or 10) then
                  relax(st, N4 + m * 4 + d2, k * c_step + c_ug + extra(n) + extra(m), k)
                end
              end
            end
          end
        end
      end
    end
  end

  if not found then
    return nil, { expansions = expansions, exhausted = expansions > max_exp }
  end

  -- reconstruct: list of {tile, d, move}
  local rev = {}
  local st = found
  while st ~= -1 do
    rev[#rev + 1] = st
    st = parent[st]
  end
  local path = {}
  for k = #rev, 1, -1 do
    local s = rev[k]
    path[#path + 1] = { tile = tile_of(s), d = s % 4, move = move[s], state = s }
  end
  return path, { expansions = expansions, cost = gscore[found] }
end

-- Path -> placements (local tile coordinates). Belts: {kind, tile, d,
-- ug_type}. Pipes: {kind="pipe"|"ptg", tile, d (ptg: normal connection side)}.
function M.placements(g, path, kind)
  local out = {}
  for idx, p in ipairs(path) do
    if kind ~= "pipe" then
      if p.move == 0 then
        out[#out + 1] = { kind = "belt", tile = p.tile, d = p.d, state = p.state }
      else
        local entrance = step_to(g, p.tile, p.d, -p.move)
        out[#out + 1] = { kind = "ug", tile = entrance, d = p.d, ug_type = "input", state = p.state }
        out[#out + 1] = { kind = "ug", tile = p.tile, d = p.d, ug_type = "output", state = p.state }
      end
    else
      if p.move == 0 then
        out[#out + 1] = { kind = "pipe", tile = p.tile, d = 0, state = p.state }
      else
        local entrance = step_to(g, p.tile, p.d, -p.move)
        out[#out + 1] = { kind = "ptg", tile = entrance, d = M.opposite(p.d), state = p.state }
        out[#out + 1] = { kind = "ptg", tile = p.tile, d = p.d, state = p.state }
      end
    end
  end
  return out
end

-- ------------------------------------------------------------- validate
-- Replays belt placements: every belt tile may only be fed by its
-- predecessor (no side-loading into ourselves, nothing foreign feeding us),
-- and each underground entrance must pair with our own exit. Returns nil or
-- the state to ban.
function M.validate_belts(g, pl, ug_max, ug_name)
  local at = {}
  for idx, p in ipairs(pl) do at[p.tile] = { idx = idx, p = p } end
  for idx, p in ipairs(pl) do
    -- where does this placement output to?
    if p.kind == "belt" or (p.kind == "ug" and p.ug_type == "output") then
      local n = neighbour(g, p.tile, p.d)
      local nxt = pl[idx + 1]
      local target = n and at[n]
      if target and (not nxt or target.idx ~= idx + 1) then
        return target.p.state or p.state, "belt at step " .. idx .. " feeds into step " .. target.idx
      end
    end
    if p.kind == "ug" and p.ug_type == "input" then
      -- nearest underground of the same name ahead must be our exit
      local partner = pl[idx + 1]
      for k = 1, ug_max do
        local j = step_to(g, p.tile, p.d, k)
        if not j then break end
        local here = at[j]
        if (here and here.p.kind == "ug") or (g.ug and g.ug[j] == ug_name) then
          if not (here and here.idx == idx + 1 and partner and partner.ug_type == "output") then
            return p.state, "underground at step " .. idx .. " would pair with the wrong exit"
          end
          break
        end
      end
    end
  end
  return nil
end

return M
