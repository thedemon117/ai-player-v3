-- Space Age platform tooling (v3): build ghosts on a platform, deconstruct,
-- configure a building, set hub / landing pad / chest requests, set the
-- platform schedule, and drop the character to the planet in a cargo pod.
-- A platform has no character on it; the hub builds ghosts from its own
-- inventory and rockets bring it items. Every function takes (character, params),
-- throws on bad input (the skill wrappers in skills.lua turn that into a failed
-- result) and returns a JSON-serialisable table. Ported from llm-play-factorio
-- (scripts/space.lua); ride_rocket (riding a launched rocket) is not ported.

AISpace = {}
local M = AISpace

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

local MAX_BUILD_STEPS = 400
local FOUNDATION = "space-platform-foundation"

local function need_space_age()
  if not script.active_mods["space-age"] then error("Space Age is not active on this server") end
end

local function state_name(v)
  for k, x in pairs(defines.space_platform_state) do
    if x == v then return k end
  end
  return tostring(v)
end

local function platforms_of(force)
  local out = {}
  for _, p in pairs(force.platforms) do
    if p.valid then out[#out + 1] = p end
  end
  table.sort(out, function(a, b) return a.index < b.index end)
  return out
end

-- A platform by name (exact, or case-insensitive) or index.
function M.find_platform(force, ref)
  if ref == nil or ref == "" then error("give platform = <name or index> (see platforms)") end
  local lower = string.lower(tostring(ref))
  for _, p in ipairs(platforms_of(force)) do
    if p.name == ref or tostring(p.index) == tostring(ref) or string.lower(p.name) == lower then return p end
  end
  local names = {}
  for _, p in ipairs(platforms_of(force)) do names[#names + 1] = p.name end
  error("no platform '" .. tostring(ref) .. "'" .. (#names > 0 and (" — platforms: " .. table.concat(names, ", ")) or
    " — the force has no platforms yet (platform_order)"))
end

local function platform_surface(p)
  local s = p.surface
  if not (s and s.valid) then
    error("platform '" .. p.name .. "' has no surface yet (" .. state_name(p.state):gsub("_", " ")
      .. ") — a silo has to launch its starter pack first")
  end
  return s
end


-- The platform a surface belongs to, if any.
function M.platform_of_surface(surface)
  local ok, p = pcall(function() return surface.platform end)
  if ok and p and p.valid then return p end
  return nil
end


local function schedule_of(p)
  local sched = p.schedule
  if not (sched and sched.records and #sched.records > 0) then return nil end
  local stops = {}
  for _, r in ipairs(sched.records) do stops[#stops + 1] = r.station or "?" end
  return { stops = stops, current = sched.current }
end

local function hub_requests(hub)
  local out = {}
  pcall(function()
    local secs = hub.get_logistic_sections()
    for i = 1, secs.sections_count do
      local sec = secs.get_section(i)
      if sec.active then
        for j = 1, sec.filters_count do
          local f = sec.get_slot(j)
          if f and f.value and f.value.name then
            out[f.value.name] = (out[f.value.name] or 0) + (f.min or 0)
          end
        end
      end
    end
  end)
  return out
end


local function item_place(name)
  local it = prototypes.item[name]
  if it then
    if it.place_as_tile_result then return "tile", it.place_as_tile_result.result.name end
    if it.place_result then return "entity", it.place_result.name end
  end
  if prototypes.entity[name] then return "entity", name end
  if prototypes.tile[name] then return "tile", name end
  return nil, nil
end

-- rpc "platform_build": ghosts on a platform, each checked first.
-- steps = [{name, x, y, direction?, recipe?}]; name is an item or entity
-- (space-platform-foundation places a foundation tile ghost).
function M.platform_build(c, params)
  need_space_age()
  local p = M.find_platform(c.force, params.platform)
  local s = platform_surface(p)
  local steps = params.steps
  if type(steps) ~= "table" or #steps == 0 then
    error('give steps = [{"name":"space-platform-foundation","x":5,"y":0}, {"name":"asteroid-collector","x":0,"y":-7,"direction":0}]')
  end
  if #steps > MAX_BUILD_STEPS then error("at most " .. MAX_BUILD_STEPS .. " steps per call") end
  local placed, rejected = 0, {}
  local by_name = {}
  for i, st in ipairs(steps) do
    local why
    local kind, target = item_place(st.name)
    local x, y = tonumber(st.x), tonumber(st.y)
    if not kind then
      why = "unknown item/entity '" .. tostring(st.name) .. "'"
    elseif not x or not y then
      why = "needs x and y"
    elseif kind == "tile" then
      local tile = s.get_tile(x, y)
      local function floor_at(tx, ty)
        if s.get_tile(tx, ty).name ~= "empty-space" then return true end
        return s.count_entities_filtered({ name = "tile-ghost", position = { tx + 0.5, ty + 0.5 } }) > 0
      end
      local tx, ty = math.floor(x), math.floor(y)
      if tile.name == target then
        why = "already " .. target
      elseif not (floor_at(tx + 1, ty) or floor_at(tx - 1, ty) or floor_at(tx, ty + 1) or floor_at(tx, ty - 1)) then
        why = "not next to the floor or another floor ghost (place floor outward from the existing floor, in order)"
      else
        local g = s.create_entity({ name = "tile-ghost", inner_name = target, position = { x, y }, force = c.force })
        if not (g and g.valid) then why = "the game refused a tile ghost here" end
      end
    else
      local dir = tonumber(st.direction) or 0
      local spec = { name = target, position = { x, y }, direction = dir, force = c.force,
        build_check_type = defines.build_check_type.manual_ghost }
      if not s.can_place_entity(spec) then
        why = "blocked (no foundation under it, overlaps a building, or invalid here)"
        local proto = prototypes.entity[target]
        for _, rule in pairs(proto and proto.tile_buildability_rules or {}) do
          if rule.required_tiles and rule.required_tiles.layers and rule.required_tiles.layers.empty_space then
            why = "blocked: a " .. target .. " must sit on the floor's edge with empty space (no floor) in "
              .. "front of it, in the direction it faces (dir 0=N 4=E 8=S 12=W)"
            break
          end
        end
      else
        local g = s.create_entity({ name = "entity-ghost", inner_name = target, position = { x, y },
          direction = dir, force = c.force })
        if not (g and g.valid) then
          why = "the game refused the ghost"
        elseif st.recipe then
          local okr, err = pcall(function() g.set_recipe(st.recipe) end)
          if not okr then why = "ghost placed, but recipe '" .. tostring(st.recipe) .. "' was refused: " .. tostring(err) end
        end
      end
    end
    if why then
      if #rejected < 30 then rejected[#rejected + 1] = { i = i, name = st.name, x = x, y = y, why = why } end
    else
      placed = placed + 1
      by_name[st.name] = (by_name[st.name] or 0) + 1
    end
  end
  return { platform = p.name, placed = placed, placed_by_name = by_name, rejected = rejected,
    rejected_total = #steps - placed, hub_items = inventory_map(p.hub.get_inventory(defines.inventory.hub_main)) }
end

-- rpc "platform_deconstruct": mark buildings in an area for removal (the hub
-- takes them back into its inventory). names = optional filter.
function M.platform_deconstruct(c, params)
  need_space_age()
  local p = M.find_platform(c.force, params.platform)
  local s = platform_surface(p)
  local x1, y1, x2, y2 = tonumber(params.x1), tonumber(params.y1), tonumber(params.x2), tonumber(params.y2)
  if not (x1 and y1 and x2 and y2) then error("give x1, y1, x2, y2") end
  local filter = { area = { { math.min(x1, x2), math.min(y1, y2) }, { math.max(x1, x2), math.max(y1, y2) } }, force = c.force }
  if type(params.names) == "table" and #params.names > 0 then filter.name = params.names end
  local n, ghosts = 0, 0
  for _, e in ipairs(s.find_entities_filtered(filter)) do
    if e.name == "space-platform-hub" then
      -- never
    elseif e.name == "entity-ghost" or e.name == "tile-ghost" then
      e.destroy(); ghosts = ghosts + 1
    elseif e.order_deconstruction(c.force) then
      n = n + 1
    end
  end
  return { platform = p.name, marked = n, ghosts_removed = ghosts }
end

local function find_entity(s, x, y, force)
  local best, bd
  for _, e in ipairs(s.find_entities_filtered({ position = { x, y }, radius = 1.5, force = force })) do
    if e.name ~= "tile-ghost" then
      local dx, dy = e.position.x - x, e.position.y - y
      local d = dx * dx + dy * dy
      if not best or d < bd then best, bd = e, d end
    end
  end
  return best
end

-- rpc "platform_configure": recipe and/or filters of one entity (or ghost)
-- on a platform, like clicking it in remote view.
function M.platform_configure(c, params)
  need_space_age()
  local p = M.find_platform(c.force, params.platform)
  local s = platform_surface(p)
  local x, y = tonumber(params.x), tonumber(params.y)
  if not (x and y) then error("give x and y of the entity") end
  local e = find_entity(s, x, y, c.force)
  if not e then error(string.format("no building of yours within 1.5 tiles of (%g, %g) on %s", x, y, p.name)) end
  local done = {}
  if params.recipe ~= nil then
    local ok, err = pcall(function() e.set_recipe(params.recipe ~= "" and params.recipe or nil) end)
    if not ok then error("recipe refused: " .. tostring(err)) end
    done[#done + 1] = "recipe " .. tostring(params.recipe)
  end
  if type(params.filters) == "table" then
    local etype = e.type == "entity-ghost" and e.ghost_type or e.type
    local ok, err = pcall(function()
      if etype == "asteroid-collector" then
        -- collector filters are asteroid-chunk names, set as plain strings
        for i = 1, math.max(5, #params.filters) do
          local f = params.filters[i]
          if f and not prototypes.asteroid_chunk[f] then
            error("'" .. f .. "' is not an asteroid chunk (metallic-asteroid-chunk, carbonic-asteroid-chunk, oxide-asteroid-chunk)")
          end
          pcall(function() e.set_filter(i, f) end)
        end
        return
      end
      local slots = e.filter_slot_count or 0
      if slots == 0 and e.type ~= "entity-ghost" then error("this building has no filter slots") end
      pcall(function() e.use_filters = true end)
      for i = 1, math.max(slots, #params.filters) do
        local f = params.filters[i]
        if i <= slots or f then e.set_filter(i, f and { name = f } or nil) end
      end
    end)
    if not ok then error("filters refused: " .. tostring(err)) end
    done[#done + 1] = "filters " .. table.concat(params.filters, ", ")
  end
  if params.direction ~= nil then
    local ok, err = pcall(function() e.direction = tonumber(params.direction) end)
    if not ok then error("direction refused: " .. tostring(err)) end
    done[#done + 1] = "direction " .. tostring(params.direction)
  end
  if #done == 0 then error("give recipe, filters and/or direction") end
  return { platform = p.name, entity = e.type == "entity-ghost" and (e.ghost_name .. " (ghost)") or e.name,
    position = { x = e.position.x, y = e.position.y }, set = done }
end

-- rpc "platform_requests": the hub's item requests (what rockets bring up),
-- replacing the first request section. items = {name = count}; {} clears.
function M.platform_requests(c, params)
  need_space_age()
  local p = M.find_platform(c.force, params.platform)
  local hub = p.hub
  if not (hub and hub.valid) then error("platform '" .. p.name .. "' has no hub yet") end
  if type(params.items) ~= "table" then error('give items = {"name": count, ...} ({} clears)') end
  local secs = hub.get_logistic_sections()
  local sec
  for i = 1, secs.sections_count do
    local s = secs.get_section(i)
    if s.is_manual then sec = s break end
  end
  sec = sec or secs.add_section()
  for j = sec.filters_count, 1, -1 do sec.clear_slot(j) end
  local names = {}
  for name in pairs(params.items) do names[#names + 1] = name end
  table.sort(names)
  local from = params.import_from
  if from == nil or from == "" then
    from = (p.space_location and p.space_location.type == "planet") and p.space_location.name or "nauvis"
  end
  if not prototypes.space_location[from] then error("import_from must be a planet name (nauvis, vulcanus, ...)") end
  local slot = 0
  for _, name in ipairs(names) do
    if not prototypes.item[name] then error("unknown item '" .. name .. "'") end
    local n = math.floor(tonumber(params.items[name]) or 0)
    if n > 0 then
      slot = slot + 1
      sec.set_slot(slot, { value = { type = "item", name = name, quality = "normal" }, min = n, import_from = from })
    end
  end
  return { platform = p.name, requests = hub_requests(hub), import_from = from }
end

-- rpc "landing_pad_requests": what a cargo landing pad on your surface asks
-- for. Platforms parked above the planet that hold requested items drop them
-- down by cargo pod. items = {name = count}; {} clears.
function M.landing_pad_requests(c, params)
  need_space_age()
  if type(params.x) ~= "number" or type(params.y) ~= "number" then error("give x, y of the cargo landing pad") end
  if type(params.items) ~= "table" then error('give items = {"name": count, ...} ({} clears)') end
  local pad = c.surface.find_entities_filtered({ type = "cargo-landing-pad", position = { params.x, params.y },
    radius = 5, force = c.force })[1]
  if not pad then error(string.format("no cargo landing pad near (%.1f, %.1f)", params.x, params.y)) end
  local secs = pad.get_logistic_sections()
  local sec
  for i = 1, secs.sections_count do
    local s = secs.get_section(i)
    if s.is_manual then sec = s break end
  end
  sec = sec or secs.add_section()
  for j = sec.filters_count, 1, -1 do sec.clear_slot(j) end
  local names = {}
  for name in pairs(params.items) do names[#names + 1] = name end
  table.sort(names)
  local slot = 0
  for _, name in ipairs(names) do
    if not prototypes.item[name] then error("unknown item '" .. name .. "'") end
    local n = math.floor(tonumber(params.items[name]) or 0)
    if n > 0 then
      slot = slot + 1
      sec.set_slot(slot, { value = { type = "item", name = name, quality = "normal" }, min = n })
    end
  end
  local inv = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
  return { position = { x = pad.position.x, y = pad.position.y }, requests = hub_requests(pad),
    holds = inv and inventory_map(inv) or {} }
end

-- rpc "chest_requests": what a requester or buffer chest at x,y asks the
-- logistic network for. items = {name = count}; {} clears.
function M.chest_requests(c, params)
  if type(params.x) ~= "number" or type(params.y) ~= "number" then error("give x, y of the requester chest") end
  if type(params.items) ~= "table" then error('give items = {"name": count, ...} ({} clears)') end
  local chest = c.surface.find_entities_filtered({ type = "logistic-container", position = { params.x, params.y },
    radius = 1, force = c.force })[1]
  if not chest then error(string.format("no logistic chest at (%.1f, %.1f)", params.x, params.y)) end
  local mode = chest.prototype.logistic_mode
  if mode ~= "requester" and mode ~= "buffer" then
    error(chest.name .. " is a " .. tostring(mode) .. " chest; only requester and buffer chests take requests")
  end
  local secs = chest.get_logistic_sections()
  local sec
  for i = 1, secs.sections_count do
    local s = secs.get_section(i)
    if s.is_manual then sec = s break end
  end
  sec = sec or secs.add_section()
  for j = sec.filters_count, 1, -1 do sec.clear_slot(j) end
  local names = {}
  for name in pairs(params.items) do names[#names + 1] = name end
  table.sort(names)
  local slot = 0
  for _, name in ipairs(names) do
    if not prototypes.item[name] then error("unknown item '" .. name .. "'") end
    local n = math.floor(tonumber(params.items[name]) or 0)
    if n > 0 then
      slot = slot + 1
      sec.set_slot(slot, { value = { type = "item", name = name, quality = "normal" }, min = n })
    end
  end
  local inv = chest.get_inventory(defines.inventory.chest)
  local net = chest.logistic_network
  return { name = chest.name, position = { x = chest.position.x, y = chest.position.y },
    requests = hub_requests(chest), holds = inv and inventory_map(inv) or {},
    network = net and true or false, robots = net and net.available_logistic_robots or 0 }
end


local WAITS = {
  requests = { type = "all_requests_satisfied", compare_type = "or" },
}

-- rpc "platform_schedule": stops are planets with a wait; paused toggles thrust.
-- stops = [{planet, wait = <seconds> | "requests" | nil}], optional paused.
function M.platform_schedule(c, params)
  need_space_age()
  local p = M.find_platform(c.force, params.platform)
  if type(params.stops) == "table" then
    local records = {}
    for i, st in ipairs(params.stops) do
      local loc = type(st) == "table" and st.planet
      if type(loc) ~= "string" or not prototypes.space_location[loc] then
        error("stop " .. i .. ": planet must be a space location name (nauvis, vulcanus, fulgora, gleba, aquilo, solar-system-edge, ...)")
      end
      local conds
      if type(st.wait) == "number" and st.wait > 0 then
        conds = { { type = "time", compare_type = "or", ticks = math.floor(st.wait * 60) } }
      elseif st.wait == "requests" then
        conds = { WAITS.requests }
      elseif st.wait ~= nil then
        error('stop ' .. i .. ': wait is a number of seconds or "requests"')
      end
      records[#records + 1] = { station = loc, wait_conditions = conds }
    end
    if #records == 0 then p.schedule = nil else p.schedule = { current = 1, records = records } end
  end
  if params.paused ~= nil then p.paused = params.paused and true or false end
  return { platform = p.name, paused = p.paused, schedule = schedule_of(p) }
end


-- Re-create a character body in place (same name, inventories moved over):
-- a body that arrived in a hub by rocket can't board a cargo pod itself.
local INVENTORIES = { "character_main", "character_guns", "character_ammo", "character_armor", "character_trash" }

local function rebuild_body(old, surface, position)
  local new = surface.create_entity({ name = "character", position = position, force = old.force })
  if not new then error("could not create a body on " .. surface.name) end
  for _, inv_name in ipairs(INVENTORIES) do
    local id = defines.inventory[inv_name]
    local from, to
    pcall(function() from = old.get_inventory(id) to = new.get_inventory(id) end)
    if from and to then
      for i = 1, #from do
        if from[i].valid_for_read then
          if i <= #to then to[i].transfer_stack(from[i]) end
          if from[i].valid_for_read then to.insert(from[i]) end
        end
      end
    end
  end
  old.destroy()
  storage.ai_player.character = new   -- the mod's one character reference
  return new
end

-- rpc "drop_to_planet": from a platform parked at a planet, ride a cargo pod
-- down to that planet's surface (near position, default its landing pad or
-- the force's spawn).
function M.drop_to_planet(c, params)
  need_space_age()
  local p = M.platform_of_surface(c.surface)
  if not p then error("you are not on a space platform") end
  local loc = p.space_location
  if not (loc and loc.type == "planet") then
    error("the platform is not parked at a planet (it is " .. (p.space_connection and "travelling" or "in space") .. ")")
  end
  local hub = p.hub
  if not (hub and hub.valid) then error("the platform has no hub") end
  local planet = game.planets[loc.name]
  local target = planet.surface or planet.create_surface()
  local body = c
  local pod = hub.create_cargo_pod()
  if not pod then error("the hub has no free hatch for a cargo pod right now — try again in a few seconds") end
  pcall(function() pod.set_passenger(body) end)
  if pod.get_passenger() ~= body then
    local pos = p.surface.find_non_colliding_position("character", { 0, 5 }, 12, 0.5) or { 0, 5 }
    body = rebuild_body(c, p.surface, pos)
    pod.set_passenger(body)
  end
  if pod.get_passenger() ~= body then
    pod.destroy()
    error("could not board the cargo pod")
  end
  local dest = { type = defines.cargo_destination.surface, surface = target }
  if type(params.position) == "table" and tonumber(params.position.x) and tonumber(params.position.y) then
    dest.position = { x = tonumber(params.position.x), y = tonumber(params.position.y) }
  end
  pod.cargo_pod_destination = dest
  return { platform = p.name, planet = loc.name, position = dest.position }
end

return AISpace
