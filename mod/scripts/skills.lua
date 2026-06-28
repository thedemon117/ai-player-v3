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
    -- Teleport adjacent so the source is within mining reach, then mine.
    local sp = surface.find_non_colliding_position("character", src.position, 3, 0.5)
    if sp then character.teleport(sp) end
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
    character.begin_crafting{recipe = "burner-mining-drill", count = 1}
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
local function skill_build_ghosts(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  local ghosts = surface.find_entities_filtered{type = "entity-ghost", position = character.position, radius = 96}
  if #ghosts == 0 then return false, "build_ghosts: no ghosts within range to build" end

  local built = 0
  local missing = {}
  for _, g in ipairs(ghosts) do
    if g.valid then
      local proto = prototypes.entity[g.ghost_name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
        and proto.items_to_place_this[1].name
      if item and inv.get_item_count(item) > 0 then
        -- NB: do NOT teleport the character to the ghost first. Ghosts have no
        -- collision box, so find_non_colliding_position returns the ghost's own
        -- tile; teleporting there makes the CHARACTER block the spot and revive()
        -- fails. revive() is a force-level op and needs no character reach.
        local _, ent = g.revive{raise_revive = false}
        if not (ent and ent.valid) then
          -- The character may be standing ON this ghost (e.g. its home tile).
          -- Step aside to a spot clear of the ghost footprint and retry once.
          local aside = surface.find_non_colliding_position(
            "character", {x = g.position.x + 3, y = g.position.y + 3}, 8, 0.5)
          if aside then
            character.teleport(aside)
            _, ent = g.revive{raise_revive = false}
          end
        end
        if ent and ent.valid then
          inv.remove{name = item, count = 1}
          built = built + 1
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
  if built == 0 and #parts == 0 then return false, "build_ghosts: no buildable ghosts" end
  return true, detail
end

-- -------------------------------------------------------------------------
-- deconstruct() — mine everything the human marked for deconstruction
-- (buildings, trees, rocks). SECOND priority after build_ghosts: a
-- deconstruction mark is explicit human "remove this" intent, the mirror of a
-- ghost. Unlike ghosts/ore, these targets HAVE collision, so teleporting
-- adjacent (the gather pattern) is safe — find_non_colliding_position lands the
-- character beside the target, not on it, and mine_entity collects the products.
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
        local sp = surface.find_non_colliding_position("character", m.position, 3, 0.5)
        if sp then character.teleport(sp) end
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
-- return_home() — walk back to the home anchor.
-- -------------------------------------------------------------------------
local function skill_return_home(character, _)
  local home = storage.ai_player and storage.ai_player.home_position
  if not home then return false, "return_home: no home anchor set" end
  local surface = character.surface
  local sp = surface.find_non_colliding_position("character", {x = home.x, y = home.y}, 8, 0.5)
  if not sp then return false, "return_home: home area is blocked" end
  character.teleport(sp)
  return true, string.format("returned home to {%d,%d}", home.x, home.y)
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
    if try_queue(force, force.technologies[p.tech]) then
      return true, "queued research: " .. p.tech .. " — feed a lab with science packs to progress"
    end
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

  -- Nothing queueable: the next research is likely a TRIGGER tech (Factorio 2.0
  -- bootstraps via crafting, not queuing). Tell the model to craft the science.
  for _, t in pairs(force.technologies) do
    if t.enabled and not t.researched and prereqs_met(t) and t.prototype.research_trigger ~= nil then
      return false, "research: '" .. t.name .. "' is unlocked by CRAFTING, not queuing — hand-craft "
        .. "automation-science-pack (1 copper-plate + 1 iron-gear-wheel) to trigger it; then more tech becomes queueable"
    end
  end
  return false, "research: nothing to queue right now"
end

-- -------------------------------------------------------------------------
-- Registry + required params (mirrored in the bridge router prompt/validation)
-- -------------------------------------------------------------------------
AISkills.REGISTRY = {
  build_ghosts     = skill_build_ghosts,
  deconstruct      = skill_deconstruct,
  gather           = skill_gather,
  build_miner      = skill_build_miner,
  build_smelter    = skill_build_smelter,
  fuel_all         = skill_fuel_all,
  loot_chests      = skill_loot_chests,
  deposit_to_chest = skill_deposit_to_chest,
  return_home      = skill_return_home,
  research         = skill_research,
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
