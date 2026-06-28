-- Executes the action list returned by the bridge.
-- Each action is wrapped in pcall — errors are logged but do not crash the mod.

AIActions = {}

local LOG_FILE = "ai-player/errors.log"

local function log_error(msg)
  local line = string.format("[tick=%d] %s\n", game.tick, msg)
  helpers.write_file(LOG_FILE, line, true)
  if settings.global["ai-player-debug-chat"] and settings.global["ai-player-debug-chat"].value then
    game.print("[AI Error] " .. msg, {r=1, g=0.3, b=0.3})
  end
end

local function debug_print(msg)
  if settings.global["ai-player-debug-chat"] and settings.global["ai-player-debug-chat"].value then
    game.print("[AI] " .. msg, {r=0.7, g=0.9, b=1})
  end
end

-- Validate an item name before inserting/taking. Returns nil if valid, else a
-- reason the model can act on — notably the common mistake of treating a fluid
-- (water, steam, crude-oil…) as an insertable item.
local function item_problem(name)
  if not name then return "no item specified" end
  if prototypes.item[name] then return nil end
  if prototypes.fluid and prototypes.fluid[name] then
    return "'" .. name .. "' is a FLUID, not an item — move fluids with pipes/pumps, never insert/take"
  end
  return "'" .. tostring(name) .. "' is not a valid item name"
end

-- -------------------------------------------------------------------------
-- Inventory resolution
--
-- Maps the slot name from the action ("fuel", "input", "output", "chest",
-- "lab", "ammo") to the correct Factorio 2.0 API call.
-- The LLM picks slot names from the 'slots' field in perception — this
-- function resolves them to actual inventory objects.
-- -------------------------------------------------------------------------

local function get_inventory_by_slot(entity, slot_name)
  local s = (slot_name or ""):lower()

  if s == "fuel" then
    return entity.get_fuel_inventory()

  elseif s == "input" then
    -- Factorio 2.0.32: crafter_input/crafter_output do NOT exist.
    -- Use type-specific defines: furnace_source for furnaces, assembling_machine_input for assemblers.
    if entity.type == "furnace" then
      return entity.get_inventory(defines.inventory.furnace_source)
    else
      return entity.get_inventory(defines.inventory.assembling_machine_input)
    end

  elseif s == "output" then
    return entity.get_output_inventory()

  elseif s == "chest" then
    return entity.get_inventory(defines.inventory.chest)

  elseif s == "lab" then
    return entity.get_inventory(defines.inventory.lab_input)

  elseif s == "ammo" then
    return entity.get_inventory(defines.inventory.turret_ammo)

  else
    -- Unknown slot name: guess based on entity type using type-specific defines.
    -- defines.inventory.crafter_input does NOT exist in Factorio 2.0.32.
    if entity.type == "furnace" then
      local inv = entity.get_inventory(defines.inventory.furnace_source)
      if inv then return inv end
    elseif entity.type == "assembling-machine" then
      local inv = entity.get_inventory(defines.inventory.assembling_machine_input)
      if inv then return inv end
    end
    return entity.get_inventory(defines.inventory.chest)
  end
end

-- -------------------------------------------------------------------------
-- Entity finder
-- -------------------------------------------------------------------------

-- Find the entity a position-based action targets.
-- accept (optional): predicate(entity) → bool. Candidates failing it are
-- discarded. The AI character is ALWAYS excluded — it is never a valid
-- insert/take/mine/set_recipe target. For inventory ops, callers pass an
-- accept that requires the entity to actually have the requested slot, so a
-- nearby resource/ground item/character can't be mistaken for the building
-- (fixes "could not get inventory slot 'fuel' on character" and
-- "'chest' on coal").
local function find_entity(surface, action, character_pos, accept)
  local search_pos = action.position or character_pos
  local radius = action.radius or 4

  -- Filter by name and/or type if given (type lets the model say e.g.
  -- {mine, type="tree"} to chop the nearest tree — trees are named tree-05,
  -- dry-hairy-tree, etc., never literally "tree").
  local filter = {position = search_pos, radius = radius}
  if action.name then filter.name = action.name end
  if action.type then filter.type = action.type end
  local candidates = surface.find_entities_filtered(filter)

  if #candidates == 0 and not action.name and not action.type then
    -- No filter — search all entities near position
    candidates = surface.find_entities_filtered{
      position = search_pos,
      radius   = radius,
    }
  end

  -- Drop the character and anything the caller rejects.
  local filtered = {}
  for _, e in ipairs(candidates) do
    if e.valid and e.type ~= "character" and (not accept or accept(e)) then
      filtered[#filtered + 1] = e
    end
  end
  candidates = filtered

  if #candidates == 0 then return nil end

  -- Closest first, then lowest unit_number for determinism
  table.sort(candidates, function(a, b)
    local dax = a.position.x - search_pos.x
    local day = a.position.y - search_pos.y
    local dbx = b.position.x - search_pos.x
    local dby = b.position.y - search_pos.y
    local da = dax*dax + day*day
    local db = dbx*dbx + dby*dby
    if da ~= db then return da < db end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)

  return candidates[1]
end

-- Visual feedback helpers
local function highlight(surface, pos, color, radius, ttl)
  rendering.draw_circle{
    color    = color or {r=1, g=0.5, b=0},
    radius   = radius or 0.5,
    width    = 2,
    target   = pos,
    surface  = surface,
    time_to_live = ttl or 120,
    forces   = {"player"},
  }
end

-- -------------------------------------------------------------------------
-- Individual action handlers
-- -------------------------------------------------------------------------

local DIRECTION_MAP = {
  north     = defines.direction.north,
  south     = defines.direction.south,
  east      = defines.direction.east,
  west      = defines.direction.west,
  northeast = defines.direction.northeast,
  northwest = defines.direction.northwest,
  southeast = defines.direction.southeast,
  southwest = defines.direction.southwest,
}

local function is_walkable(surface, pos)
  return surface.can_place_entity{name = "character", position = pos}
end

local function action_move(character, action)
  local dir = DIRECTION_MAP[(action.direction or ""):lower()]
  if not dir then
    log_error("move: unknown direction '" .. tostring(action.direction) .. "'")
    return
  end
  -- Cap per-move distance to curb rapid wandering (the home anchor + prompt do
  -- the rest). A single teleport never exceeds 16 tiles.
  local dist = math.max(1, math.min(action.distance or 10, 16))
  local offsets = {
    [defines.direction.north]     = {x=0,        y=-1},
    [defines.direction.south]     = {x=0,        y=1},
    [defines.direction.east]      = {x=1,        y=0},
    [defines.direction.west]      = {x=-1,       y=0},
    [defines.direction.northeast] = {x=0.7,      y=-0.7},
    [defines.direction.northwest] = {x=-0.7,     y=-0.7},
    [defines.direction.southeast] = {x=0.7,      y=0.7},
    [defines.direction.southwest] = {x=-0.7,     y=0.7},
  }
  local unit = offsets[dir]
  local surface = character.surface
  local pos = character.position

  -- Walk up to dist tiles, stopping at the last walkable tile
  local best = nil
  for step = dist, 1, -1 do
    local candidate = {x = pos.x + unit.x * step, y = pos.y + unit.y * step}
    if is_walkable(surface, candidate) then
      best = candidate
      break
    end
  end

  if not best then
    debug_print("move " .. action.direction .. ": all tiles blocked, not moving")
    return
  end

  character.teleport(best)
  debug_print(string.format("Moved %s to {%.1f, %.1f}", action.direction, best.x, best.y))
end

local function action_mine(character, action)
  local surface = character.surface
  local target = find_entity(surface, action, character.position)
  if not target then
    return false, "mine: nothing to mine near the target position"
  end
  if not target.minable then
    return false, "mine: '" .. target.name .. "' is not minable"
  end
  -- Capture identity BEFORE mining — mine_entity(force=true) can fully mine and
  -- invalidate the entity, so reading target.* afterward errors.
  local name = target.name
  local pos  = {x = target.position.x, y = target.position.y}

  -- mine_entity's return value is unreliable for RESOURCES: it returns false
  -- whenever the patch isn't fully depleted, even though it DID mine a unit.
  -- Judge success by whether the inventory actually grew instead.
  local char_inv = character.get_inventory(defines.inventory.character_main)
  local before = char_inv and char_inv.get_item_count() or 0
  local ok = character.mine_entity(target, true)
  local after = char_inv and char_inv.get_item_count() or 0
  local gained = after - before

  if gained > 0 then
    highlight(surface, pos, {r=1, g=0.8, b=0})
    debug_print(string.format("Mined %s (+%d)", name, gained))
    return true, string.format("mined %s (+%d to inventory)", name, gained)
  end
  -- No items gained but the entity is gone (tree/rock fully mined while the
  -- inventory was full → products dropped on the ground): still a success.
  if ok or not target.valid then
    return true, "mined " .. name .. " (items dropped — inventory may be full)"
  end
  return false, "mine: could not mine " .. name .. " (inventory full, or out of reach — move closer)"
end

-- Entities a real player can only place under specific conditions. create_entity
-- (used below) bypasses these rules, so we re-check the common special cases for
-- clear, model-feedable messages. can_place_entity{build_check_type=manual} is the
-- authoritative gate that also covers collisions and everything else.
local MINING_DRILLS = {
  ["burner-mining-drill"]   = true,
  ["electric-mining-drill"] = true,
  ["big-mining-drill"]      = true,
}
local WATER_TILES = {"water", "deepwater", "water-green", "deepwater-green",
                     "water-shallow", "water-mud"}

-- Returns a human-readable reason if a player couldn't legally place this, else nil.
local function placement_problem(surface, item_name, position)
  if item_name == "offshore-pump" then
    local water = surface.count_tiles_filtered{position = position, radius = 1.5, name = WATER_TILES}
    if water == 0 then
      return "offshore-pump must be placed on water (not on land or a resource like crude-oil)"
    end
  elseif MINING_DRILLS[item_name] then
    local res = surface.count_entities_filtered{position = position, radius = 1.5, type = "resource"}
    if res == 0 then
      return "mining drill must be placed on a resource patch"
    end
  end
  return nil
end

local function action_place(character, action)
  if not action.position then
    return false, "place: missing position"
  end
  local item_name = action.item
  local surface = character.surface
  local inv = character.get_inventory(defines.inventory.character_main)
  local px, py = action.position.x, action.position.y

  if not inv or inv.get_item_count(item_name) == 0 then
    return false, "place: no '" .. (item_name or "?") .. "' in your inventory"
  end

  local dir = action.direction and DIRECTION_MAP[action.direction:lower()]
    or defines.direction.north

  -- Reject placements a real player couldn't make. create_entity below bypasses
  -- build rules, so we validate first: a specific message for known special cases,
  -- then the authoritative manual build check (water/resource/collision/alignment).
  local problem = placement_problem(surface, item_name, action.position)
  if problem then
    return false, "place: " .. problem
  end

  if not surface.can_place_entity{
    name      = item_name,
    position  = action.position,
    direction = dir,
    force     = character.force,
    build_check_type = defines.build_check_type.manual,
  } then
    return false, string.format(
      "place: '%s' cannot be legally placed at {%d,%d} (blocked, misaligned, or wrong tile)",
      item_name, px, py)
  end

  local entity = surface.create_entity{
    name      = item_name,
    position  = action.position,
    direction = dir,
    force     = character.force,
    player    = nil,
  }

  if entity then
    inv.remove{name=item_name, count=1}
    -- create_entity does not raise on_built_entity, so register AI placements
    -- with the machine registry directly (no-ops for non-machine items).
    AIRegistry.add(entity)
    highlight(surface, action.position, {r=0, g=1, b=0})
    debug_print("Placed: " .. item_name)
    return true, string.format("placed %s at {%d,%d}", item_name, px, py)
  end
  return false, "place: failed to create " .. (item_name or "?")
end

local function action_set_recipe(character, action)
  if not action.position or not action.recipe then
    return false, "set_recipe: missing position or recipe"
  end
  -- Only crafting machines accept recipes — don't match a nearby resource/chest.
  local entity = find_entity(character.surface, action, character.position, function(e)
    return e.type == "assembling-machine" or e.type == "furnace"
  end)
  if not entity then
    return false, "set_recipe: no assembling machine near the target position"
  end
  if not entity.set_recipe then
    return false, "set_recipe: '" .. entity.name .. "' does not support recipes"
  end
  local ok, err = pcall(function() entity.set_recipe(action.recipe) end)
  if ok then
    debug_print("Set recipe '" .. action.recipe .. "' on " .. entity.name)
    return true, "set recipe " .. action.recipe .. " on " .. entity.name
  end
  return false, "set_recipe: " .. tostring(err)
end

local function action_craft(character, action)
  if not action.recipe then return false, "craft: missing recipe" end
  local count = action.count or 1
  local queued = character.begin_crafting{recipe=action.recipe, count=count}
  if queued > 0 then
    debug_print(string.format("Crafting %d x %s (queued: %d)", count, action.recipe, queued))
    return true, string.format("started hand-crafting %d x %s", queued, action.recipe)
  end
  return false, string.format(
    "craft: cannot hand-craft %s — missing ingredients or recipe not available", action.recipe)
end

local function action_insert(character, action)
  if not action.item or not action.position then
    return false, "insert: missing item or position"
  end
  local iprob = item_problem(action.item)
  if iprob then return false, "insert: " .. iprob end
  local slot = action.inventory or action.slot
  -- Only consider entities that actually have the requested inventory slot.
  local entity = find_entity(character.surface, action, character.position, function(e)
    local ok, inv = pcall(get_inventory_by_slot, e, slot)
    return ok and inv ~= nil
  end)
  if not entity then
    return false, "insert: no building with a '" .. tostring(slot) ..
                  "' slot near the target position"
  end

  local char_inv = character.get_inventory(defines.inventory.character_main)
  local count = action.count or 1
  local available = char_inv and char_inv.get_item_count(action.item) or 0
  if available == 0 then
    return false, "insert: you have no '" .. action.item .. "' to insert"
  end
  count = math.min(count, available)

  local ok, target_inv = pcall(get_inventory_by_slot, entity, slot)
  if not ok or not target_inv then
    return false, "insert: '" .. entity.name .. "' has no '" .. tostring(slot) .. "' slot"
  end

  local inserted = target_inv.insert{name=action.item, count=count}
  if inserted > 0 then
    char_inv.remove{name=action.item, count=inserted}
    highlight(character.surface, entity.position, {r=0, g=0.5, b=1})
    debug_print(string.format("Inserted %d x %s into %s [%s]",
      inserted, action.item, entity.name, action.inventory or "auto"))
    return true, string.format("inserted %d %s into %s [%s]",
      inserted, action.item, entity.name, slot or "auto")
  end
  return false, string.format(
    "insert: %s [%s] is full or won't accept %s (wrong slot? e.g. coal goes in 'fuel', ore in 'input')",
    entity.name, slot or "auto", action.item)
end

local function action_take(character, action)
  if not action.item or not action.position then
    return false, "take: missing item or position"
  end
  local iprob = item_problem(action.item)
  if iprob then return false, "take: " .. iprob end
  local slot = action.inventory or action.slot
  -- Only consider entities that actually have the requested inventory slot.
  local entity = find_entity(character.surface, action, character.position, function(e)
    local ok, inv = pcall(get_inventory_by_slot, e, slot)
    return ok and inv ~= nil
  end)
  if not entity then
    return false, "take: no building with a '" .. tostring(slot) ..
                  "' slot near the target position"
  end

  local ok, source_inv = pcall(get_inventory_by_slot, entity, slot)
  if not ok or not source_inv then
    return false, "take: '" .. entity.name .. "' has no '" .. tostring(slot) .. "' slot"
  end

  local count = action.count or 1
  local available = source_inv.get_item_count(action.item)
  if available == 0 then
    return false, string.format("take: %s [%s] has no %s",
      entity.name, slot or "auto", action.item)
  end
  count = math.min(count, available)

  local char_inv = character.get_inventory(defines.inventory.character_main)
  local taken = char_inv and char_inv.insert{name=action.item, count=count} or 0
  if taken > 0 then
    source_inv.remove{name=action.item, count=taken}
    highlight(character.surface, entity.position, {r=1, g=1, b=0})
    debug_print(string.format("Took %d x %s from %s [%s]",
      taken, action.item, entity.name, action.inventory or "auto"))
    return true, string.format("took %d %s from %s [%s]",
      taken, action.item, entity.name, slot or "auto")
  end
  return false, "take: your inventory is full"
end

local function action_shoot(character, action)
  if not action.position then log_error("shoot: missing position"); return end
  character.shooting_state = {
    state    = defines.shooting.shooting_enemies,
    position = action.position,
  }
  debug_print(string.format("Shooting toward {%.1f, %.1f}", action.position.x, action.position.y))
end

local function action_pickup(character, action)
  local surface = character.surface
  local pos = action.position or character.position
  local radius = action.radius or 3
  local items = surface.find_entities_filtered{
    type     = "item-entity",
    position = pos,
    radius   = radius,
  }
  local picked = 0
  local inv = character.get_inventory(defines.inventory.character_main)
  for _, item_entity in ipairs(items) do
    if item_entity.valid then
      local stack = item_entity.stack
      if inv and inv.can_insert(stack) then
        inv.insert(stack)
        item_entity.destroy()
        picked = picked + 1
      end
    end
  end
  debug_print(string.format("Picked up %d item(s)", picked))
  if picked > 0 then
    return true, string.format("picked up %d ground item(s)", picked)
  end
  return false, "pickup: no loose ground items in range"
end

local function action_chat(character, action)
  if not action.message then return end
  if settings.global["ai-player-enable-chat"] and
     settings.global["ai-player-enable-chat"].value then
    game.print(action.message, {r=0.8, g=1, b=0.8})
  end
end

local function action_summary(character, action)
  if not action.text then return end
  storage.ai_player.memory.previous_summary = action.text
  AIBrain.update_recent_actions(action.text)
  debug_print("Summary: " .. action.text:sub(1, 80))
end

local function action_add_note(character, action)
  if not action.text then return end
  local notes = storage.ai_player.memory.notes
  table.insert(notes, {tick=game.tick, text=action.text})
  debug_print("Note added: " .. action.text:sub(1, 60))
end

local function action_view_notes(character, action)
  local notes = storage.ai_player.memory.notes
  if #notes == 0 then game.print("[AI Notes] (empty)"); return end
  for i, note in ipairs(notes) do
    game.print(string.format("[AI Notes] %d: %s", i, note.text), {r=0.9,g=0.9,b=1})
  end
end

local function action_create_todo(character, action)
  if not action.title or not action.items then return end
  local todos = storage.ai_player.memory.todo_lists
  todos[action.title] = {}
  for _, text in ipairs(action.items) do
    table.insert(todos[action.title], {text=text, completed=false})
  end
  debug_print("Todo list '" .. action.title .. "' created (" .. #action.items .. " items)")
end

local function action_add_todo(character, action)
  if not action.title or not action.text then return end
  local todos = storage.ai_player.memory.todo_lists
  if not todos[action.title] then todos[action.title] = {} end
  table.insert(todos[action.title], {text=action.text, completed=false})
end

local function action_complete_todo(character, action)
  if not action.title or action.index == nil then return end
  local list = storage.ai_player.memory.todo_lists[action.title]
  if not list then return end
  local idx = action.index + 1  -- LLM uses 0-based index
  if list[idx] then
    list[idx].completed = true
    debug_print("Completed todo: " .. (list[idx].text or ""))
  end
end

local function action_view_todo(character, action)
  local todos = storage.ai_player.memory.todo_lists
  for title, items in pairs(todos) do
    game.print("[AI Todo] " .. title, {r=1,g=1,b=0.5})
    for i, item in ipairs(items) do
      local status = item.completed and "[DONE]" or "[ ]"
      game.print(string.format("  %s %d: %s", status, i, item.text), {r=0.9,g=0.9,b=0.7})
    end
  end
end

-- -------------------------------------------------------------------------
-- Dispatch table + executor
-- -------------------------------------------------------------------------

local HANDLERS = {
  move         = action_move,
  mine         = action_mine,
  place        = action_place,
  set_recipe   = action_set_recipe,
  craft        = action_craft,
  insert       = action_insert,
  take         = action_take,
  shoot        = action_shoot,
  pickup       = action_pickup,
  chat         = action_chat,
  summary      = action_summary,
  add_note     = action_add_note,
  view_notes   = action_view_notes,
  create_todo  = action_create_todo,
  add_todo     = action_add_todo,
  complete_todo= action_complete_todo,
  view_todo    = action_view_todo,
  wait         = function() debug_print("Waiting") end,
}

-- Run ONE primitive action → (ok, detail). The unified executor
-- (AISkills.execute) calls this for {action=...} entries and collects the
-- per-action results for the E1 feedback loop. Handlers that return nothing
-- (move/chat/memory) count as ran (ok=true).
function AIActions.run(character, action)
  local handler = HANDLERS[action.action]
  if not handler then
    return false, "unknown action '" .. tostring(action.action) .. "'"
  end
  local call_ok, ok, detail = pcall(handler, character, action)
  if not call_ok then
    log_error(string.format("Action '%s': %s", tostring(action.action), tostring(ok)))
    return false, "error: " .. tostring(ok)
  end
  if ok == nil then ok = true end
  if ok == false and detail then debug_print(detail) end
  return ok, detail
end

return AIActions
