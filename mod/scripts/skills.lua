-- Skill layer (v3).
--
-- A "skill" is a parameterized basic loop. Skills own the deterministic MECHANICS
-- (positions, orientation, fuelling, drop-positions); the LLM only chooses which
-- skill and its params. Skills orchestrate the proven PRIMITIVE handlers
-- (AIActions.run) wherever possible, so placement legality / slot resolution /
-- mining all stay in one place (primitives.lua).
--
-- Each skill: function(character, params) -> (ok:boolean, detail:string)
-- detail feeds the E1 result loop, so make it specific and actionable.

AISkills = {}

local function inv_of(character)
  return character.get_inventory(defines.inventory.character_main)
end

-- -------------------------------------------------------------------------
-- gather(item, count) — mine the nearest sources of `item` until `count`.
-- Handles wood (mine trees by type) and ores/rocks (mine by name).
-- -------------------------------------------------------------------------
local function skill_gather(character, p)
  local item = p.item
  if not item then return false, "gather: missing 'item'" end
  local need = math.min(p.count or 50, 300)
  local surface = character.surface
  local inv = inv_of(character)
  local is_wood = (item == "wood")
  local gained = 0

  for _ = 1, 150 do
    if inv.get_item_count(item) >= need then break end
    local filter = {position = character.position, radius = 40, limit = 60}
    if is_wood then filter.type = "tree" else filter.name = item end
    local sources = surface.find_entities_filtered(filter)
    local src, sd = nil, math.huge
    for _, e in ipairs(sources) do
      if e.valid and e.minable and e ~= character then
        local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
        local d = dx * dx + dy * dy
        if d < sd then sd = d; src = e end
      end
    end
    if not src then break end
    -- Out of mining reach: walk there (takes game time) instead of mining at a
    -- distance. Report what we already gathered; the caller retries next turn.
    if not character.can_reach_entity(src) then
      local sp = surface.find_non_colliding_position("character", src.position, 3, 0.5) or src.position
      local _, walk = AIMovement.walk_to(character, sp)
      if gained > 0 then
        return true, string.format("gathered %d %s (now have %d); next source out of reach — %s",
          gained, item, inv.get_item_count(item), walk)
      end
      return false, "gather: " .. item .. " out of reach — " .. walk .. "; retry gather next turn"
    end
    local before = inv.get_item_count()
    character.mine_entity(src, true)
    local delta = inv.get_item_count() - before
    if delta <= 0 then break end  -- inventory full or stuck
    gained = gained + delta
  end

  local have = inv.get_item_count(item)
  if gained == 0 then
    return false, "gather: no reachable " .. item .. " sources within 40 tiles"
  end
  return true, string.format("gathered %d %s (now have %d)", gained, item, have)
end

-- -------------------------------------------------------------------------
-- build_smelter(ore, count) — place stone-furnaces, fuel them, feed ore.
-- Orchestrates the place + insert primitives at computed positions.
-- -------------------------------------------------------------------------
local function skill_build_smelter(character, p)
  local ore = p.ore or p.item or "iron-ore"
  local want = math.min(p.count or 2, 6)
  local surface = character.surface
  local inv = inv_of(character)

  local have_furnace = inv.get_item_count("stone-furnace")
  if have_furnace == 0 then
    local queued = character.begin_crafting{recipe = "stone-furnace", count = 1}
    AITriggers.on_crafted("stone-furnace", queued)
    if queued > 0 then
      return false, "build_smelter: out of stone-furnaces — hand-crafting one, retry next turn"
    end
    return false, "build_smelter: no stone-furnace and can't craft one (need stone)"
  end

  local count = math.min(want, have_furnace)
  local base = character.position
  local placed = 0
  for i = 1, count do
    local anchor = {x = base.x + i * 2, y = base.y - 1}
    local pos = surface.find_non_colliding_position("stone-furnace", anchor, 6, 1)
    if pos then
      local ok = AIActions.run(character, {action = "place", item = "stone-furnace", position = pos})
      if ok then
        placed = placed + 1
        if inv.get_item_count("coal") > 0 then
          AIActions.run(character, {action = "insert", item = "coal", count = 8, position = pos, inventory = "fuel"})
        end
        if inv.get_item_count(ore) > 0 then
          AIActions.run(character, {action = "insert", item = ore, count = 12, position = pos, inventory = "input"})
        end
      end
    end
  end

  if placed == 0 then
    return false, "build_smelter: couldn't place any furnace (no clear space nearby)"
  end
  local detail = string.format("built %d stone-furnace(s) for %s", placed, ore)
  if inv.get_item_count(ore) == 0 then
    detail = detail .. " — but you have no " .. ore .. " to smelt; gather " .. ore .. " first"
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- build_miner(resource, output) — place a burner-mining-drill ON the nearest
-- resource patch, fuel it, and place a collector (chest/furnace/belt) at its
-- drop_position. The drill→output basic loop.
-- -------------------------------------------------------------------------
local OUTPUT_ITEM = {chest = "iron-chest", furnace = "stone-furnace", belt = "transport-belt"}

local function skill_build_miner(character, p)
  local resource = p.resource or p.item or "iron-ore"
  local out_kind = (p.output or "chest"):lower()
  local out_item = OUTPUT_ITEM[out_kind] or "iron-chest"
  local surface = character.surface
  local inv = inv_of(character)

  if inv.get_item_count("burner-mining-drill") == 0 then
    AITriggers.on_crafted("burner-mining-drill",
      character.begin_crafting{recipe = "burner-mining-drill", count = 1})
    return false, "build_miner: no burner-mining-drill in inventory — crafting one, retry next turn"
  end

  -- nearest patch of the resource
  local patch, pd = nil, math.huge
  for _, e in ipairs(surface.find_entities_filtered{name = resource, type = "resource",
                                                    position = character.position, radius = 64}) do
    local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
    local d = dx * dx + dy * dy
    if d < pd then pd = d; patch = e end
  end
  if not patch then
    return false, "build_miner: no '" .. resource .. "' patch within 64 tiles — gather/explore first"
  end

  -- Do NOT teleport onto the patch first: ore has no collision box, so
  -- find_non_colliding_position returns the patch tile itself and the character
  -- ends up standing on it — then can_place(manual) fails and the drill can't be
  -- placed. place/insert here all use explicit positions (find_entity searches
  -- around action.position, not the character), so no character reach is needed.

  -- place the drill on the patch (place primitive enforces drill-on-resource)
  local drill
  for _, dir in ipairs({"south", "north", "east", "west"}) do
    if AIActions.run(character, {action = "place", item = "burner-mining-drill",
                                 position = patch.position, direction = dir}) then
      drill = surface.find_entities_filtered{name = "burner-mining-drill",
                                             position = patch.position, radius = 2}[1]
      if drill then break end
    end
  end
  if not drill then
    return false, "build_miner: couldn't place a drill on the " .. resource .. " patch (blocked?)"
  end

  -- fuel the drill
  AIActions.run(character, {action = "insert", item = "coal", count = 5,
                            position = drill.position, inventory = "fuel"})

  -- place the collector at the drill's drop_position
  local drop = drill.drop_position
  local detail = "placed burner-mining-drill on " .. resource
  if inv.get_item_count(out_item) > 0 then
    if AIActions.run(character, {action = "place", item = out_item, position = drop}) then
      detail = detail .. " + " .. out_item .. " at drop position"
      if out_item == "stone-furnace" and inv.get_item_count("coal") > 0 then
        AIActions.run(character, {action = "insert", item = "coal", count = 5,
                                  position = drop, inventory = "fuel"})
      end
    else
      detail = detail .. string.format(" (couldn't place %s at drop {%d,%d})",
        out_item, math.floor(drop.x), math.floor(drop.y))
    end
  else
    detail = detail .. string.format(" — no %s to collect output; place one at {%d,%d}",
      out_item, math.floor(drop.x), math.floor(drop.y))
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- fuel_all() — top up every nearby AI-force burner that's low on fuel.
-- -------------------------------------------------------------------------
local function skill_fuel_all(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  if inv.get_item_count("coal") == 0 then
    return false, "fuel_all: no coal in inventory"
  end
  local force = AICharacter.get_force()
  local fueled = 0
  for _, e in ipairs(surface.find_entities_filtered{force = force, position = character.position, radius = 64}) do
    if e.valid and e.type ~= "character" then
      local fb = e.get_fuel_inventory and e.get_fuel_inventory()
      if fb and fb.valid and fb.get_item_count("coal") < 5 then
        local avail = inv.get_item_count("coal")
        if avail > 0 then
          local ins = fb.insert{name = "coal", count = math.min(5, avail)}
          if ins > 0 then inv.remove{name = "coal", count = ins}; fueled = fueled + 1 end
        end
      end
    end
  end
  if fueled == 0 then return false, "fuel_all: nothing nearby needed fuel" end
  return true, string.format("fueled %d burner(s)", fueled)
end

-- -------------------------------------------------------------------------
-- loot_chests(radius?, items?) — pull items from nearby chests (any force)
-- into the character's inventory. Enables human→AI resource sharing (coal,
-- building materials, etc.) and AI self-restocking before build_ghosts.
-- items: comma-separated item names to restrict looting; empty = take all.
-- -------------------------------------------------------------------------
local function skill_loot_chests(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local inv     = inv_of(character)

  local filter = nil
  if p.items and p.items ~= "" then
    filter = {}
    for name in p.items:gmatch("[^,]+") do
      filter[name:match("^%s*(.-)%s*$")] = true
    end
  end

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "loot_chests: no chests within " .. radius .. " tiles"
  end

  local taken = {}
  for _, chest in ipairs(chests) do
    if chest.valid then
      local ci = chest.get_inventory(defines.inventory.chest)
      if ci then
        for _, slot in ipairs(ci.get_contents()) do
          local name, avail = slot.name, slot.count
          if not filter or filter[name] then
            local n = inv.insert{name = name, count = avail}
            if n > 0 then
              ci.remove{name = name, count = n}
              taken[name] = (taken[name] or 0) + n
            end
          end
        end
      end
    end
  end

  if not next(taken) then
    return false, "loot_chests: nothing taken (chests empty, inventory full, or filter matched nothing)"
  end
  local parts = {}
  for name, count in pairs(taken) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "looted " .. table.concat(parts, ", ")
end

-- -------------------------------------------------------------------------
-- deposit_to_chest(radius?, keep?) — deposit excess inventory into a nearby
-- chest. Keeps `keep` of each item; deposits the rest. Use for inventory
-- management and AI→human resource sharing.
-- -------------------------------------------------------------------------
local function skill_deposit_to_chest(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local keep    = math.max(p.keep or 50, 0)
  local inv     = inv_of(character)

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "deposit_to_chest: no chests within " .. radius .. " tiles"
  end

  local cp = character.position
  table.sort(chests, function(a, b)
    local da = (a.position.x - cp.x)^2 + (a.position.y - cp.y)^2
    local db = (b.position.x - cp.x)^2 + (b.position.y - cp.y)^2
    return da < db
  end)

  local deposited = {}
  for _, slot in ipairs(inv.get_contents()) do
    local name, have = slot.name, slot.count
    local excess = have - keep
    if excess > 0 then
      for _, chest in ipairs(chests) do
        if chest.valid then
          local ci = chest.get_inventory(defines.inventory.chest)
          if ci then
            local n = ci.insert{name = name, count = excess}
            if n > 0 then
              inv.remove{name = name, count = n}
              deposited[name] = (deposited[name] or 0) + n
              excess = excess - n
            end
          end
        end
        if excess <= 0 then break end
      end
    end
  end

  if not next(deposited) then
    return false, "deposit_to_chest: nothing deposited (nothing exceeds keep=" .. keep .. " or chests full)"
  end
  local parts = {}
  for name, count in pairs(deposited) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "deposited " .. table.concat(parts, ", ")
end

-- -------------------------------------------------------------------------
-- build_ghosts() — build the human's placed entity-ghosts (validated mechanic).
-- Highest-priority skill: ghosts are explicit human intent.
-- -------------------------------------------------------------------------
-- can_reach_entity() is always true for ghosts (it only gates ghost PLACEMENT),
-- so reviving one has to be checked against the character's build distance.
local function ghost_in_reach(character, ghost)
  local dx, dy = ghost.position.x - character.position.x, ghost.position.y - character.position.y
  return dx * dx + dy * dy <= character.build_distance * character.build_distance
end

local function skill_build_ghosts(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  -- Search the ENTIRE surface — ghosts may be far from the character's current
  -- position (e.g. an oil outpost blueprinted 200+ tiles away). Only ghosts
  -- within the character's reach are revived; if none are, walk toward the
  -- nearest buildable one and let the caller retry next turn.
  local ghosts = surface.find_entities_filtered{type = "entity-ghost"}
  if #ghosts == 0 then return false, "build_ghosts: no ghosts on surface to build" end

  local cp = character.position
  table.sort(ghosts, function(a, b)
    local dax, day = a.position.x - cp.x, a.position.y - cp.y
    local dbx, dby = b.position.x - cp.x, b.position.y - cp.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local built = 0
  local missing = {}
  local far = nil        -- nearest buildable ghost that is out of reach
  local in_the_way = nil -- reachable ghost whose revive failed (character on it?)
  for _, g in ipairs(ghosts) do
    if g.valid then
      local proto = prototypes.entity[g.ghost_name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
        and proto.items_to_place_this[1].name
      if item and inv.get_item_count(item) > 0 then
        if not ghost_in_reach(character, g) then
          far = far or g
        else
          -- Ghosts have no collision box, so the CHARACTER standing on one makes
          -- revive() fail; remember it and step aside below.
          local _, ent = g.revive{raise_revive = false}
          if ent and ent.valid then
            inv.remove{name = item, count = 1}
            built = built + 1
          else
            in_the_way = in_the_way or g
          end
        end
      elseif item then
        missing[item] = (missing[item] or 0) + 1
      end
    end
  end

  local parts = {}
  for it, c in pairs(missing) do parts[#parts + 1] = c .. "x " .. it end
  local detail = string.format("built %d ghost(s)", built)
  if #parts > 0 then detail = detail .. "; need items: " .. table.concat(parts, ", ") end

  if in_the_way then
    local aside = surface.find_non_colliding_position(
      "character", {x = in_the_way.position.x + 3, y = in_the_way.position.y + 3}, 8, 0.5)
    if aside then
      local _, walk = AIMovement.walk_to(character, aside)
      detail = detail .. "; a ghost is blocked (character in the way) — " .. walk
    end
  elseif far then
    local near = surface.find_non_colliding_position(
      "character", {x = far.position.x + 3, y = far.position.y + 3}, 12, 0.5) or far.position
    local _, walk = AIMovement.walk_to(character, near)
    detail = detail .. "; more ghosts out of reach — " .. walk .. "; retry build_ghosts next turn"
  end

  if built == 0 and #parts == 0 and not far and not in_the_way then
    return false, "build_ghosts: no buildable ghosts"
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- deconstruct() — mine everything the human marked for deconstruction
-- (buildings, trees, rocks). SECOND priority after build_ghosts: a
-- deconstruction mark is explicit human "remove this" intent, the mirror of a
-- ghost. Targets must be within reach; otherwise the character walks toward the
-- nearest one and the caller retries next turn.
-- -------------------------------------------------------------------------
local function skill_deconstruct(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local radius = math.min(p.radius or 96, 200)
  local marked = surface.find_entities_filtered{
    to_be_deconstructed = true, position = character.position, radius = radius, limit = 100}
  if #marked == 0 then
    return false, "deconstruct: nothing marked for deconstruction within " .. radius .. " tiles"
  end

  -- Nearest-first so the character walks an efficient path and stays near base.
  local cp = character.position
  table.sort(marked, function(a, b)
    local dax, day = a.position.x - cp.x, a.position.y - cp.y
    local dbx, dby = b.position.x - cp.x, b.position.y - cp.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local removed, skipped = 0, 0
  for _, m in ipairs(marked) do
    if m.valid and m ~= character then
      if not m.minable then
        skipped = skipped + 1
      else
        if not character.can_reach_entity(m) then
          -- Out of reach: walk there and let the caller retry next turn.
          local sp = surface.find_non_colliding_position("character", m.position, 3, 0.5) or m.position
          local _, walk = AIMovement.walk_to(character, sp)
          if removed > 0 then
            return true, string.format("deconstructed %d marked object(s); next one out of reach — %s", removed, walk)
          end
          return false, "deconstruct: target out of reach — " .. walk .. "; retry deconstruct next turn"
        end
        local ok = character.mine_entity(m, true)
        if ok and not m.valid then
          removed = removed + 1
        elseif m.valid then
          break  -- inventory full or out of reach — stop rather than spin
        end
      end
    end
  end

  if removed == 0 then
    if skipped > 0 then return false, "deconstruct: marked objects can't be mined (unminable)" end
    return false, "deconstruct: couldn't mine any marked object (inventory full?)"
  end
  local detail = string.format("deconstructed %d marked object(s)", removed)
  if skipped > 0 then detail = detail .. string.format("; %d unminable skipped", skipped) end
  return true, detail
end

-- -------------------------------------------------------------------------
-- return_home() — start walking back to the home anchor (takes game time).
-- -------------------------------------------------------------------------
local function skill_return_home(character, _)
  local home = storage.ai_player and storage.ai_player.home_position
  if not home then return false, "return_home: no home anchor set" end
  local surface = character.surface
  local sp = surface.find_non_colliding_position("character", {x = home.x, y = home.y}, 8, 0.5)
  if not sp then return false, "return_home: home area is blocked" end
  local ok, detail = AIMovement.walk_to(character, sp)
  return ok, "return_home: " .. detail
end

-- -------------------------------------------------------------------------
-- research(tech?) — queue a technology on the AI force. WITHOUT this, a fed
-- lab does nothing: a separate force researches nothing unless something is
-- queued. Picks a sensible next tech if none is given.
-- -------------------------------------------------------------------------
local PREFERRED_TECH = {
  "automation", "electronics", "steel-processing", "logistics",
  "fast-inserter", "logistic-science-pack",
}

local function prereqs_met(tech)
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then return false end
  end
  return true
end

-- A tech is QUEUEABLE only if it isn't a research_trigger tech (those are
-- completed by crafting/doing something, not by add_research) and add_research
-- actually accepts it. Returns true on success (it queues as a side effect).
local function try_queue(force, tech)
  if not (tech and tech.enabled and not tech.researched and prereqs_met(tech)) then return false end
  if tech.prototype.research_trigger ~= nil then return false end
  return force.add_research(tech)
end

local function skill_research(character, p)
  local force = character.force

  if p.tech then
    local tech = force.technologies[p.tech]
    if try_queue(force, tech) then
      return true, "queued research: " .. p.tech .. " — feed a lab with science packs to progress"
    end
    -- An explicit request that can't be met is reported, not silently swapped for another tech.
    if not tech then return false, "research: unknown technology '" .. tostring(p.tech) .. "' (list_technologies shows the names)" end
    if tech.researched then return false, "research: " .. p.tech .. " is already researched" end
    for _, q in ipairs(force.research_queue or {}) do
      if q.name == p.tech then return false, "research: " .. p.tech .. " is already in the queue" end
    end
    local missing = {}
    for name, pre in pairs(tech.prerequisites) do
      if not pre.researched then
        missing[#missing + 1] = name .. (pre.prototype.research_trigger ~= nil
          and " (a trigger tech: " .. AITriggers.describe(pre.prototype.research_trigger) .. ")" or "")
      end
    end
    if #missing > 0 then
      table.sort(missing)
      return false, "research: can't queue " .. p.tech .. " yet — missing prerequisites: " .. table.concat(missing, "; ")
    end
    if tech.prototype.research_trigger ~= nil then
      return false, "research: '" .. p.tech .. "' is a TRIGGER tech — it completes by doing, not queuing. "
        .. AITriggers.describe(tech.prototype.research_trigger)
    end
    return false, "research: the game refused to queue " .. p.tech .. (tech.enabled and "" or " (it is not enabled)")
  end
  for _, name in ipairs(PREFERRED_TECH) do
    if try_queue(force, force.technologies[name]) then
      return true, "queued research: " .. name .. " — feed a lab with science packs to progress"
    end
  end
  for _, t in pairs(force.technologies) do
    if try_queue(force, t) then
      return true, "queued research: " .. t.name .. " — feed a lab with science packs to progress"
    end
  end

  -- Nothing queueable: the next research is a TRIGGER tech (Factorio 2.0
  -- bootstraps via doing, not queuing). Name the exact condition so the model
  -- can act on it — AITriggers credits it within ~2s of the condition being met.
  for _, t in pairs(force.technologies) do
    if t.enabled and not t.researched and prereqs_met(t) and t.prototype.research_trigger ~= nil then
      return false, "research: '" .. t.name .. "' is a TRIGGER tech — it completes by doing, not queuing. "
        .. AITriggers.describe(t.prototype.research_trigger)
        .. " Do that and it completes automatically; then more tech becomes queueable."
    end
  end
  return false, "research: nothing to queue right now"
end

-- -------------------------------------------------------------------------
-- set_train_schedule(train_id, stops) — stops = [{station, wait?}], wait is
-- "full", "empty" or seconds (default 5). Station names must be existing train
-- stops of the force. Puts the train in automatic mode and warns when no
-- locomotive has fuel (a schedule without fuel goes nowhere).
-- -------------------------------------------------------------------------
local function skill_set_train_schedule(character, p)
  local id = tonumber(p.train_id)
  if not id then return false, "set_train_schedule: need train_id (list_trains shows ids)" end
  local stops = p.stops
  if type(stops) ~= "table" or #stops == 0 then
    return false, 'set_train_schedule: need stops = [{"station":"Name","wait":"full"|"empty"|<seconds>}]'
  end
  local ctx = {surface = character.surface, force = character.force}
  local train
  for _, t in ipairs(game.train_manager.get_trains{surface = character.surface}) do
    if t.id == id then train = t; break end
  end
  if not train then return false, "set_train_schedule: no train " .. id .. " on this surface (list_trains)" end
  local _, known = AIQueries.station_names(ctx)
  local records = {}
  for i, s in ipairs(stops) do
    if type(s) ~= "table" or type(s.station) ~= "string" then
      return false, "set_train_schedule: stop " .. i .. " needs a station name"
    end
    if not known[s.station] then
      return false, 'set_train_schedule: no train stop called "' .. s.station .. '" (names are case-sensitive; build the stop first)'
    end
    local cond
    local wait = s.wait
    if wait == "full" then cond = {type = "full", compare_type = "or"}
    elseif wait == "empty" then cond = {type = "empty", compare_type = "or"}
    elseif type(wait) == "number" and wait > 0 then cond = {type = "time", compare_type = "or", ticks = math.floor(wait * 60)}
    elseif wait == nil then cond = {type = "time", compare_type = "or", ticks = 300}
    else return false, 'set_train_schedule: stop ' .. i .. ' wait must be "full", "empty" or seconds' end
    records[#records + 1] = {station = s.station, wait_conditions = {cond}}
  end
  train.schedule = {current = 1, records = records}
  train.manual_mode = false
  local fueled = false
  pcall(function()
    for _, c in ipairs(train.carriages) do
      if c.type == "locomotive" and c.burner and (c.burner.currently_burning ~= nil or c.burner.inventory.get_item_count() > 0) then
        fueled = true
      end
    end
  end)
  return true, string.format("train %d now runs %d stop(s) in automatic mode%s", id, #records,
    fueled and "" or " — WARNING: no locomotive has fuel, it will not move until fuelled")
end

-- -------------------------------------------------------------------------
-- cancel_research(tech) — remove a QUEUED technology that has not started.
-- The one in progress is refused: dropping it would discard its progress.
-- -------------------------------------------------------------------------
local function skill_cancel_research(character, p)
  local force = character.force
  local name = p.tech
  if type(name) ~= "string" or not force.technologies[name] then
    return false, "cancel_research: give tech = a technology name from the queue"
  end
  local cur = force.current_research
  if cur and cur.name == name then
    return false, "cancel_research: " .. name .. " is the research in progress — cancelling would discard its progress"
  end
  local queue, idx = {}, nil
  for i, t in ipairs(force.research_queue or {}) do
    queue[#queue + 1] = t
    if t.name == name then idx = i end
  end
  if not idx then
    return false, "cancel_research: " .. name .. (force.technologies[name].researched and " is already researched" or " is not in the queue")
  end
  local head, progress = queue[1] and queue[1].name, force.research_progress
  table.remove(queue, idx)
  force.research_queue = queue   -- the API has no remove-one; write the queue back without it
  -- a rewrite must not reset the head's progress (no tick passes in between)
  local now = force.current_research
  if head and now and now.name == head and force.research_progress < progress then force.research_progress = progress end
  local names = {}
  for _, t in ipairs(force.research_queue or {}) do names[#names + 1] = t.name end
  return true, "removed " .. name .. " from the queue; queue now: " .. (#names > 0 and table.concat(names, ", ") or "empty")
end

-- -------------------------------------------------------------------------
-- goto(position) — start walking to an arbitrary map coordinate. The walk
-- continues over the following ticks; its outcome (arrived / blocked / timeout)
-- is reported in the next turn's action results.
-- -------------------------------------------------------------------------
local function skill_goto(character, p)
  local pos = p.position
  if not pos or pos.x == nil or pos.y == nil then
    return false, "goto: 'position' must be {x=N, y=N}"
  end
  local surface = character.surface
  local target = {x = tonumber(pos.x), y = tonumber(pos.y)}
  local fog = AIVision.walk_goal_problem(character, target)
  if fog then return false, "goto: " .. fog end
  local safe = surface.find_non_colliding_position("character", target, 5, 0.5) or target
  return AIMovement.walk_to(character, safe)
end

-- -------------------------------------------------------------------------
-- build_plan(steps) — place many entities from one call. Each step:
--   {item, position={x,y}, direction?="north"..,  recipe?, insert?={coal=5},
--    underground_type?="input"|"output"}
-- (insert: fuel items go to the fuel slot, anything else to the input slot)
-- Steps go through the same place / set_recipe / insert primitives as single
-- actions, so the validation rules are identical. The character builds what is
-- within build reach, then walks toward the first step that is not and returns;
-- call build_plan again with the same steps to continue (steps whose entity
-- already stands there are skipped, so repeating is safe). A failed step is
-- recorded and skipped unless stop_on_error is set.
-- -------------------------------------------------------------------------
local PLAN_MAX_STEPS = 100
local PLAN_MAX_FAILURES_LISTED = 5

local function skill_build_plan(character, p)
  local steps = p.steps
  if type(steps) ~= "table" or #steps == 0 then
    return false, "build_plan: 'steps' must be a non-empty list of {item, position[, direction, recipe, insert]}"
  end
  if #steps > PLAN_MAX_STEPS then
    return false, "build_plan: at most " .. PLAN_MAX_STEPS .. " steps per call"
  end
  local surface = character.surface
  local reach = character.build_distance
  local built, skipped, failed = 0, 0, {}
  local walking

  for i, step in ipairs(steps) do
    local pos = type(step) == "table" and step.position
    if type(step) ~= "table" or type(step.item) ~= "string"
       or type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
      failed[#failed + 1] = string.format("step %d: needs item and position {x,y}", i)
      if p.stop_on_error then break end
    else
      pos = {x = tonumber(pos.x), y = tonumber(pos.y)}
      local proto = prototypes.item[step.item]
      local entity_name = step.entity or (proto and proto.place_result and proto.place_result.name)
      local ok, detail = true, nil
      local existing
      if not proto then
        ok, detail = false, "unknown item '" .. step.item .. "'"
      elseif entity_name and prototypes.entity[entity_name] then
        existing = surface.find_entities_filtered{name = entity_name, position = pos, radius = 0.4}[1]
      end
      if not ok then
        -- fall through to the failure bookkeeping below
      elseif existing and existing.valid then
        skipped = skipped + 1
      else
        local dx, dy = pos.x - character.position.x, pos.y - character.position.y
        if dx * dx + dy * dy > reach * reach then
          local near = surface.find_non_colliding_position("character", pos, 6, 0.5) or pos
          local _, w = AIMovement.walk_to(character, near)
          walking = string.format("step %d out of reach — %s", i, w)
          break
        end
        ok, detail = AIActions.run(character, {action = "place", item = step.item,
          position = pos, direction = step.direction, underground_type = step.underground_type})
        if ok then
          built = built + 1
          if step.recipe then
            ok, detail = AIActions.run(character, {action = "set_recipe", recipe = step.recipe, position = pos})
          end
          if ok and type(step.insert) == "table" then
            for name, count in pairs(step.insert) do
              -- Fuel items go to the fuel slot, anything else to the input slot.
              local ip = prototypes.item[name]
              local slot = (ip and ip.fuel_value and ip.fuel_value > 0) and "fuel" or "input"
              ok, detail = AIActions.run(character, {action = "insert", item = name, count = count,
                position = pos, slot = slot})
              if not ok then break end
            end
          end
        end
      end
      if not ok then
        failed[#failed + 1] = string.format("step %d (%s): %s", i, step.item, detail or "failed")
        if p.stop_on_error then break end
      end
    end
  end

  local msg = string.format("build_plan: placed %d, already built %d, %d failed", built, skipped, #failed)
  for k = 1, math.min(#failed, PLAN_MAX_FAILURES_LISTED) do msg = msg .. "; " .. failed[k] end
  if #failed > PLAN_MAX_FAILURES_LISTED then
    msg = msg .. string.format("; +%d more", #failed - PLAN_MAX_FAILURES_LISTED)
  end
  if walking then return true, msg .. "; " .. walking .. "; call build_plan again to continue" end
  return built > 0 or skipped > 0, msg
end

-- -------------------------------------------------------------------------
-- launch_rocket([position]) — walk to the nearest rocket silo and launch its
-- rocket, like pressing the launch button in the silo window. Returns at once:
-- a silo without a finished rocket fails with the parts count, a rocket still
-- rising says so (call again), and a launch is recorded by the
-- on_rocket_launched handler in control.lua. Cargo is whatever was inserted
-- into the silo (insert primitive).
-- -------------------------------------------------------------------------
local function skill_launch_rocket(character, p)
  local surface = character.surface
  local center = (p.position and tonumber(p.position.x) and tonumber(p.position.y))
    and {x = tonumber(p.position.x), y = tonumber(p.position.y)} or character.position
  local silos = surface.find_entities_filtered{type = "rocket-silo", force = character.force}
  local silo, sd = nil, math.huge
  for _, e in ipairs(silos) do
    local dx, dy = e.position.x - center.x, e.position.y - center.y
    local d = dx * dx + dy * dy
    if d < sd then sd = d; silo = e end
  end
  if not silo then return false, "launch_rocket: no rocket silo of your force on this surface" end

  local info = AIQueries.silo_info(silo)
  if info.launching then return false, "launch_rocket: the silo " .. AIQueries.describe_silo(info) end
  if not info.ready then
    if not info.has_rocket then
      return false, string.format("launch_rocket: can't launch — %s (a rocket is built once the silo has %d parts)",
        AIQueries.describe_silo(info), info.parts_required)
    end
    return false, "launch_rocket: " .. AIQueries.describe_silo(info) .. "; call launch_rocket again once it is ready"
  end

  local dx, dy = silo.position.x - character.position.x, silo.position.y - character.position.y
  local reach = character.reach_distance + 4.5   -- silo is 9x9: its edge is ~4.5 tiles from the centre
  if dx * dx + dy * dy > reach * reach then
    -- Aim for a point just outside the silo on the character's side: the
    -- centre is inside its collision box and can never be reached.
    local d = math.sqrt(dx * dx + dy * dy)
    local stand = {x = silo.position.x - dx / d * 7, y = silo.position.y - dy / d * 7}
    local _, walk = AIMovement.walk_to(character, stand)
    return false, "launch_rocket: out of reach of the silo — " .. walk .. "; call launch_rocket again"
  end

  -- Optional destination: a platform parked above this planet takes the cargo into its
  -- hub. (Riding along was tried and dropped: see changelog 0.21.0.)
  local dest, plat
  if p.platform ~= nil and p.platform ~= "" then
    if not script.active_mods["space-age"] then return false, "launch_rocket: Space Age is not active" end
    local fok, found = pcall(AISpace.find_platform, character.force, p.platform)
    if not fok then return false, "launch_rocket: " .. (tostring(found):gsub("^.-:%d+:%s*", "")) end
    plat = found
    local planet = character.surface.planet
    if not (planet and plat.space_location and plat.space_location.name == planet.name) then
      return false, "launch_rocket: platform '" .. plat.name .. "' is not parked above " .. (planet and planet.name or "this surface")
    end
    if not (plat.hub and plat.hub.valid) then return false, "launch_rocket: platform '" .. plat.name .. "' has no hub yet" end
    dest = {type = defines.cargo_destination.station, station = plat.hub}
  end

  local ok, res = pcall(function()
    if dest then return silo.launch_rocket(dest) end
    return silo.launch_rocket()
  end)
  if not ok then return false, "launch_rocket: the silo refused to launch: " .. (tostring(res):gsub("^.-:%d+:%s*", "")) end
  if res == false then
    return false, "launch_rocket: the silo refused to launch (" .. AIQueries.describe_silo(AIQueries.silo_info(silo)) .. ")"
  end
  return true, string.format("launching the rocket at (%.0f, %.0f)%s; cargo: %s", silo.position.x, silo.position.y,
    plat and (" to platform '" .. plat.name .. "'") or "",
    next(info.cargo) and helpers.table_to_json(info.cargo) or "none")
end

-- -------------------------------------------------------------------------
-- drive_to(position, arrive_within?) — walk to the nearest free car of the
-- force within 30 tiles, fuel it from the inventory, and drive it to the point.
-- Starts the job; the outcome ("parked"/"failed") arrives in the next turn's
-- action results. exit_vehicle gets the character out again.
-- -------------------------------------------------------------------------
local function skill_drive_to(character, p)
  if character.vehicle and AIDriving.status() then
    return false, "drive_to: already driving — wait for the result or call exit_vehicle"
  end
  return AIDriving.start(character, p.position, p.arrive_within)
end

local function skill_exit_vehicle(character, _)
  return AIDriving.exit(character)
end

-- -------------------------------------------------------------------------
-- Space Age platform tooling (scripts/space.lua): platform_build,
-- platform_deconstruct, platform_configure, platform_requests,
-- landing_pad_requests, chest_requests, platform_schedule, drop_to_planet.
-- Each returns its result table as JSON in the detail; bad input comes back
-- as a failed skill with the reason.
-- -------------------------------------------------------------------------
local function space_skill(fn_name)
  return function(character, p)
    local ok, res = pcall(AISpace[fn_name], character, p)
    if not ok then return false, fn_name .. ": " .. (tostring(res):gsub("^.-:%d+:%s*", "")) end
    return true, helpers.table_to_json(res)
  end
end

-- -------------------------------------------------------------------------
-- queue_jobs(steps, on_fail?) / cancel_jobs — run a list of skill entries one
-- after another in the background (scripts/jobs.lua). Waits out walks and
-- drives and re-runs skills that ask to be called again. job_status (query)
-- shows progress.
-- -------------------------------------------------------------------------
local function skill_queue_jobs(_, p) return AIJobs.enqueue(p.steps, p.on_fail) end

local function skill_cancel_jobs(character, _)
  local n = AIJobs.cancel(character)
  return n > 0, n > 0 and ("cancelled " .. n .. " job(s)") or "cancel_jobs: nothing queued"
end

-- -------------------------------------------------------------------------
-- equip(gun?, ammo?, armor?) — put items from the main inventory into the
-- character's gun / ammo / armor slots. A new gun goes to an empty slot (else
-- swaps the selected one); ammo tops up the slot paired with the gun, up to a
-- stack; armor swaps. Whatever was in the slot goes back to the inventory.
-- Nothing is created: every item must already be in the inventory.
-- -------------------------------------------------------------------------
local function skill_equip(character, p)
  local main = inv_of(character)
  local done = {}
  local gun_slot   -- gun slot i shoots from ammo slot i
  local function check(name, wanted)
    local proto = type(name) == "string" and prototypes.item[name]
    if not proto then return "no item called '" .. tostring(name) .. "'" end
    if proto.type ~= wanted then return string.format("%s is not %s item", name, wanted) end
  end
  local function swap_back(stack)
    if stack.valid_for_read then
      local n, c = stack.name, stack.count
      local ins = main.insert{name = n, count = c}
      if ins < c then character.surface.spill_item_stack{position = character.position, stack = {name = n, count = c - ins}} end
    end
  end

  if p.gun then
    local err = check(p.gun, "gun"); if err then return false, "equip: " .. err end
    local guns = character.get_inventory(defines.inventory.character_guns)
    local slot
    for i = 1, #guns do if guns[i].valid_for_read and guns[i].name == p.gun then slot = i end end
    if not slot then
      if main.get_item_count(p.gun) == 0 then return false, "equip: no " .. p.gun .. " in inventory — craft or loot one first" end
      for i = 1, #guns do if not guns[i].valid_for_read then slot = i; break end end
      slot = slot or character.selected_gun_index or 1
      main.remove{name = p.gun, count = 1}
      local old = {name = guns[slot].valid_for_read and guns[slot].name, count = guns[slot].valid_for_read and guns[slot].count}
      if old.name then swap_back(guns[slot]) end
      guns[slot].set_stack{name = p.gun, count = 1}
    end
    gun_slot = slot
    done[#done + 1] = p.gun .. " in gun slot " .. slot
  end
  if p.ammo then
    local err = check(p.ammo, "ammo"); if err then return false, "equip: " .. err end
    local ammo = character.get_inventory(defines.inventory.character_ammo)
    local slot = gun_slot or character.selected_gun_index or 1
    if slot > #ammo then slot = 1 end
    local stack = ammo[slot]
    local current = (stack.valid_for_read and stack.name == p.ammo) and stack.count or 0
    local n = math.min(main.get_item_count(p.ammo), prototypes.item[p.ammo].stack_size - current)
    if n <= 0 and current == 0 then return false, "equip: no " .. p.ammo .. " in inventory — craft some first" end
    if n > 0 then
      if stack.valid_for_read and stack.name ~= p.ammo then swap_back(stack); stack.clear() end
      main.remove{name = p.ammo, count = n}
      if current > 0 then stack.count = current + n else stack.set_stack{name = p.ammo, count = n} end
    end
    done[#done + 1] = string.format("%d %s in ammo slot %d", current + math.max(n, 0), p.ammo, slot)
  end
  if p.armor then
    local err = check(p.armor, "armor"); if err then return false, "equip: " .. err end
    local armor = character.get_inventory(defines.inventory.character_armor)[1]
    if not (armor.valid_for_read and armor.name == p.armor) then
      if main.get_item_count(p.armor) == 0 then return false, "equip: no " .. p.armor .. " in inventory — craft or loot one first" end
      main.remove{name = p.armor, count = 1}
      swap_back(armor)
      armor.set_stack{name = p.armor, count = 1}
    end
    done[#done + 1] = p.armor .. " worn"
  end
  if #done == 0 then return false, "equip: give at least one of gun, ammo, armor (item names)" end
  return true, "equipped: " .. table.concat(done, "; ")
end

-- -------------------------------------------------------------------------
-- supply_turrets(ammo, per_turret?, radius?) — load ammo from the inventory into
-- own gun turrets that are below `per_turret` (default 10) rounds. Walks to the
-- nearest turret out of reach first; call again to continue.
-- -------------------------------------------------------------------------
local function skill_supply_turrets(character, p)
  local ammo = p.ammo
  if type(ammo) ~= "string" or not prototypes.item[ammo] or prototypes.item[ammo].type ~= "ammo" then
    return false, "supply_turrets: give ammo = an ammo item name (e.g. firearm-magazine)"
  end
  local main = inv_of(character)
  if main.get_item_count(ammo) == 0 then return false, "supply_turrets: no " .. ammo .. " in inventory" end
  local want = math.max(1, math.floor(tonumber(p.per_turret) or 10))
  local radius = math.min(tonumber(p.radius) or 40, 100)
  local force = AICharacter.get_force()
  local needy = {}
  for _, e in ipairs(character.surface.find_entities_filtered{
      type = "ammo-turret", force = force, position = character.position, radius = radius}) do
    local inv = e.get_inventory(defines.inventory.turret_ammo)
    if inv and inv.valid and inv.get_item_count(ammo) < want then needy[#needy + 1] = e end
  end
  if #needy == 0 then return false, "supply_turrets: no turret within " .. radius .. " tiles needs " .. ammo end
  table.sort(needy, function(a, b)
    local da, db = a.position, b.position
    local c = character.position
    return (da.x - c.x) ^ 2 + (da.y - c.y) ^ 2 < (db.x - c.x) ^ 2 + (db.y - c.y) ^ 2
  end)
  local filled, loaded, far = 0, 0, nil
  for _, e in ipairs(needy) do
    if character.can_reach_entity(e) then
      local inv = e.get_inventory(defines.inventory.turret_ammo)
      local n = math.min(want - inv.get_item_count(ammo), main.get_item_count(ammo))
      if n > 0 then
        local ins = inv.insert{name = ammo, count = n}
        if ins > 0 then main.remove{name = ammo, count = ins}; loaded = loaded + ins; filled = filled + 1 end
      end
    elseif not far then
      far = e
    end
  end
  if far then
    local _, walk = AIMovement.walk_to(character, {x = far.position.x, y = far.position.y + 2})
    return filled > 0, string.format("loaded %d %s into %d turret(s); %d more out of reach — %s; call supply_turrets again",
      loaded, ammo, filled, #needy - filled, walk)
  end
  if filled == 0 then return false, "supply_turrets: could not insert " .. ammo .. " (wrong ammo type for these turrets?)" end
  return true, string.format("loaded %d %s into %d turret(s)", loaded, ammo, filled)
end

-- -------------------------------------------------------------------------
-- order_platform(name) — Space Age: order a new space platform above the
-- planet the character stands on. It waits for a starter pack, which a rocket
-- silo holding one launches by itself (the platform_starter_pack item).
-- -------------------------------------------------------------------------
local function skill_order_platform(character, p)
  if not script.active_mods["space-age"] then return false, "order_platform: Space Age is not active" end
  local name = p.name
  if type(name) ~= "string" or name == "" or #name > 40 then
    return false, "order_platform: give name = a platform name (1-40 characters)"
  end
  local planet = character.surface.planet
  if not planet then return false, "order_platform: you are not on a planet's surface" end
  for _, existing in pairs(character.force.platforms) do
    if existing.valid and existing.name == name then
      return false, "order_platform: a platform called '" .. name .. "' already exists"
    end
  end
  local ok, platform = pcall(function()
    return character.force.create_space_platform{
      name = name, planet = planet.name, starter_pack = "space-platform-starter-pack"}
  end)
  if not ok or not platform then
    return false, "order_platform: the game refused a new platform (" .. tostring(platform)
      .. ") — research rocket-silo first, which unlocks space platforms"
  end
  return true, string.format("ordered platform '%s' above %s; it waits for a space-platform-starter-pack launched from a silo",
    name, planet.name)
end

-- -------------------------------------------------------------------------
-- Registry + required params (mirrored in the bridge router prompt/validation)
-- -------------------------------------------------------------------------
AISkills.REGISTRY = {
  build_ghosts     = skill_build_ghosts,
  build_plan       = skill_build_plan,
  launch_rocket    = skill_launch_rocket,
  order_platform   = skill_order_platform,
  equip            = skill_equip,
  queue_jobs       = skill_queue_jobs,
  cancel_jobs      = skill_cancel_jobs,
  platform_build         = space_skill("platform_build"),
  platform_deconstruct   = space_skill("platform_deconstruct"),
  platform_configure     = space_skill("platform_configure"),
  platform_requests      = space_skill("platform_requests"),
  landing_pad_requests   = space_skill("landing_pad_requests"),
  chest_requests         = space_skill("chest_requests"),
  platform_schedule      = space_skill("platform_schedule"),
  drop_to_planet         = space_skill("drop_to_planet"),
  drive_to         = skill_drive_to,
  exit_vehicle     = skill_exit_vehicle,
  supply_turrets   = skill_supply_turrets,
  deconstruct      = skill_deconstruct,
  gather           = skill_gather,
  build_miner      = skill_build_miner,
  build_smelter    = skill_build_smelter,
  fuel_all         = skill_fuel_all,
  loot_chests      = skill_loot_chests,
  deposit_to_chest = skill_deposit_to_chest,
  return_home      = skill_return_home,
  research         = skill_research,
  cancel_research  = skill_cancel_research,
  set_train_schedule = skill_set_train_schedule,
  ["goto"]         = skill_goto,
}

-- -------------------------------------------------------------------------
-- Unified executor: a response entry is either a skill {skill=...} or a
-- primitive {action=...}. Dispatch each, collect E1 results.
-- -------------------------------------------------------------------------
-- Run a single entry (skill OR primitive) with error isolation.
-- Returns (ok, detail, label). Shared by execute() and the external run()
-- entrypoint so there is exactly one dispatch path to keep correct.
local function run_entry(character, entry)
  local ok, detail, label
  if entry.skill then
    label = "skill:" .. tostring(entry.skill)
    local handler = AISkills.REGISTRY[entry.skill]
    if handler then
      local call_ok, rok, rdetail = pcall(handler, character, entry)
      if not call_ok then ok, detail = false, "error: " .. tostring(rok)
      else ok, detail = (rok ~= false), rdetail end
    else
      ok, detail = false, "unknown skill '" .. tostring(entry.skill) .. "'"
    end
  elseif entry.action then
    label = entry.action
    ok, detail = AIActions.run(character, entry)
  else
    label = "?"
    ok, detail = false, "entry has neither 'skill' nor 'action'"
  end
  return (ok ~= false), detail, label
end

function AISkills.execute(character, entries)
  if not character or not character.valid then return end
  local results = {}
  for _, entry in ipairs(entries) do
    local ok, detail, label = run_entry(character, entry)
    results[#results + 1] = {action = label, ok = ok, detail = detail}
  end
  storage.ai_player.memory.last_action_results = results
end

-- Single-entry runner for external (RCON/remote) callers. Same dispatch and
-- error isolation as execute(), but returns (ok, detail) directly instead of
-- recording into memory. Used by the "ai_player" remote interface (control.lua).
function AISkills.run(character, entry)
  if not character or not character.valid then
    return false, "no valid character"
  end
  local ok, detail = run_entry(character, entry)
  return ok, detail or ""
end

return AISkills
