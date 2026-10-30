-- Game -> routing grid (see route/core.lua for the grid fields).
--
-- Per-tile legality is lazy and memoized: a tile is free when it is on
-- explored ground and a forced ghost of the belt/pipe fits there (the
-- blueprint_ghost check with forced=true treats trees and rocks as removable
-- — they become "soft" tiles the character mines first — but still refuses
-- buildings, water and other terrain) and no cliff overlaps it. Technique from
-- FactorioMayor's route planner (field.lua), extended with drill drop tiles,
-- precise fluid connections and fog of war (AIVision, when enabled).
-- Ported from llm-play-factorio (scripts/route/scan.lua).

local M = {}

local UNIT = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } }
local BELT_TYPES = { "transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt" }

local function d4(dir16) return math.floor((dir16 or 0) / 4) % 4 end

-- Build a grid covering [x1..x2] x [y1..y2] (tile coordinates, inclusive).
-- opts = {surface, force, place_name (belt or pipe entity), ug_name,
--         clear_obstacles, avoid = {{x1,y1,x2,y2},...}, planned = {{x,y,dir16},...}}
function M.build(opts, x1, y1, x2, y2)
  local surface, force = opts.surface, opts.force
  local W, H = x2 - x1 + 1, y2 - y1 + 1
  local g = { W = W, H = H, x0 = x1, y0 = y1, feed = {}, touch = {}, belt = {}, ug = {}, fluid_src = {} }

  local function idx(x, y)
    x, y = math.floor(x) - x1, math.floor(y) - y1
    if x < 0 or y < 0 or x >= W or y >= H then return nil end
    return y * W + x
  end
  g.idx = idx

  local area = { { x1 - 1, y1 - 1 }, { x2 + 2, y2 + 2 } }

  -- belts of every force: their tiles are taken, and the tile each outputs into is fed
  for _, e in ipairs(surface.find_entities_filtered({ area = area, type = BELT_TYPES })) do
    local d = d4(e.direction)
    local u = UNIT[d]
    local tiles
    if e.type == "splitter" then
      local px, py = -u[2] * 0.5, u[1] * 0.5
      tiles = { { e.position.x + px, e.position.y + py }, { e.position.x - px, e.position.y - py } }
    else
      tiles = { { e.position.x, e.position.y } }
    end
    for _, t in ipairs(tiles) do
      local i = idx(t[1], t[2])
      if i then g.belt[i] = true end
      if e.type == "underground-belt" and i then g.ug[i] = e.name end
      local feeds = not (e.type == "underground-belt" and e.belt_to_ground_type == "input")
      if feeds then
        local j = idx(t[1] + u[1], t[2] + u[2])
        if j then g.feed[j] = true end
      end
    end
  end

  -- inserters pick up / drop, drills drop: those tiles interact with anything placed there
  for _, e in ipairs(surface.find_entities_filtered({ area = area, type = { "inserter", "mining-drill" } })) do
    local ok = pcall(function()
      if e.type == "inserter" then
        local i = idx(e.pickup_position.x, e.pickup_position.y)
        if i then g.touch[i] = true end
      end
      local j = idx(e.drop_position.x, e.drop_position.y)
      if j then g.touch[j] = true end
    end)
    if not ok then end
  end

  -- fluid connections: record which tiles foreign connections point at
  if opts.fluid then
    for _, e in ipairs(surface.find_entities_filtered({ area = area })) do
      pcall(function()
        local fb = e.fluidbox
        if not fb or #fb == 0 then return end
        if e.type == "pipe-to-ground" then
          local i = idx(e.position.x, e.position.y)
          if i then g.ug[i] = e.name end
        end
        local src = idx(e.position.x, e.position.y)
        for k = 1, #fb do
          for _, c in ipairs(fb.get_pipe_connections(k)) do
            if c.connection_type ~= "underground" and c.target_position then
              local t = idx(c.target_position.x, c.target_position.y)
              if t then
                g.fluid_src[t] = g.fluid_src[t] or {}
                local s = idx(c.position.x, c.position.y) or src
                table.insert(g.fluid_src[t], s or -1)
              end
            end
          end
        end
      end)
    end
  end

  -- agent-supplied areas to keep clear and belts planned but not built yet
  local avoid = {}
  for _, b in ipairs(opts.avoid or {}) do
    for x = math.floor(b[1]), math.ceil(b[3]) - 1 do
      for y = math.floor(b[2]), math.ceil(b[4]) - 1 do
        local i = idx(x, y)
        if i then avoid[i] = true end
      end
    end
  end
  for _, b in ipairs(opts.planned or {}) do
    local i = idx(b[1], b[2])
    if i then
      g.belt[i] = true
      local u = UNIT[d4(b[3])]
      local j = idx(b[1] + u[1], b[2] + u[2])
      if j then g.feed[j] = true end
    end
  end

  -- lazy, memoized legality
  local known_chunk = {}
  local soft_memo = {}
  local function known(x, y)
    local k = math.floor(x / 32) .. "," .. math.floor(y / 32)
    local v = known_chunk[k]
    if v == nil then
      v = not AIVision.enabled() or AIVision.is_known(surface, force, { x = x, y = y })
      known_chunk[k] = v
    end
    return v
  end
  local function check(i)
    local x, y = (i % W) + x1, math.floor(i / W) + y1
    if avoid[i] or not known(x, y) then return true end
    local pos = { x + 0.5, y + 0.5 }
    local fits = surface.can_place_entity({ name = opts.place_name, position = pos, direction = 0, force = force,
      build_check_type = defines.build_check_type.blueprint_ghost, forced = true })
    if not fits then return true end
    local tile_area = { { x + 0.05, y + 0.05 }, { x + 0.95, y + 0.95 } }
    if surface.count_entities_filtered({ area = tile_area, type = "cliff", limit = 1 }) > 0 then return true end
    local obstacles = surface.find_entities_filtered({ area = tile_area, type = { "tree", "simple-entity" } })
    if #obstacles > 0 then
      if not opts.clear_obstacles then return true end
      soft_memo[i] = obstacles
    end
    return false
  end
  g.blocked = setmetatable({}, { __index = function(t, i)
    local v = check(i)
    rawset(t, i, v)
    return v
  end })
  g.soft = setmetatable({}, { __index = function(_, i)
    local _ = g.blocked[i]
    return soft_memo[i] ~= nil
  end })
  g.obstacles = soft_memo
  return g
end

return M
