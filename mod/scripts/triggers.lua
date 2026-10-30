-- -------------------------------------------------------------------------
-- Trigger technologies for a player-less AI character.
--
-- Factorio 2.0 replaced the first few science-pack techs with "trigger"
-- technologies: instead of consuming science in a lab, they complete when the
-- player performs an action (craft N of an item, mine an entity, build an
-- entity). The engine credits those triggers from PLAYER activity.
--
-- The AI character is a bare `character` entity with no associated LuaPlayer.
-- Measured on a live server (see the table below), the engine credits some of
-- the AI's activity and silently drops the rest:
--
--   AI action                         | in production statistics?
--   ----------------------------------|--------------------------
--   mine_entity (hand-mining)         | YES  — copper-ore 60 after gathering 60
--   furnace / assembler output        | YES  — copper-plate 48
--   begin_crafting (hand-crafting)    | NO   — lab/gear/circuit all stayed 0
--                                     |        even with the lab in inventory
--
-- So `steam-power` (craft 50 iron-plate) and `electronics` (craft 10
-- copper-plate) complete on their own — furnaces cover them. But
-- `automation-science-pack` (craft 1 lab) never fires: a lab can only be
-- hand-crafted at that stage, and hand-crafting is invisible to the engine.
-- That single gap stalls the whole tech tree — without it the red-science
-- recipe stays locked, so nothing downstream is researchable either.
--
-- This module closes the gap WITHOUT handing out free technologies. It never
-- marks a tech researched just because it is a trigger tech; it re-derives each
-- condition from evidence that the force really did the work:
--   craft-item   -> production statistics PLUS a hand-craft ledger the mod keeps
--                   (AITriggers.on_crafted, called from every begin_crafting site)
--   mine-entity  -> production statistics of that entity's mining products
--   build-entity -> a matching entity actually exists on a force surface
-- Triggers the AI genuinely cannot satisfy on Nauvis (capture-spawner,
-- create-space-platform) are deliberately left alone.
-- -------------------------------------------------------------------------

AITriggers = {}

local CHECK_INTERVAL = 120     -- ticks between scans (~2s); the scan is cheap
local MAX_CASCADE    = 8       -- completing one trigger can unlock the next

-- ---------------------------------------------------------------------------
-- Production-statistics helpers
-- ---------------------------------------------------------------------------

-- Total amount of `name` the force has ever produced on `surface`.
-- pcall-wrapped: statistics APIs vary between versions and a bad item name
-- must not take down on_tick.
local function produced(force, surface, kind, name)
  if not name then return 0 end
  local ok, n = pcall(function()
    local stats = (kind == "fluid")
      and force.get_fluid_production_statistics(surface)
      or  force.get_item_production_statistics(surface)
    return stats.get_input_count(name)
  end)
  return (ok and type(n) == "number") and n or 0
end

-- research_trigger fields are sometimes a bare name, sometimes {name=...}.
local function proto_name(v)
  if type(v) == "table" then return v.name end
  return v
end

-- mine-entity triggers name one entity in 2.0 (`entity`) and a list in 2.1
-- (`entities`); return the names either way.
local function trigger_entities(trigger)
  local out = {}
  if trigger.entities then
    for _, e in pairs(trigger.entities) do out[#out + 1] = proto_name(e) end
  elseif trigger.entity then
    out[1] = proto_name(trigger.entity)
  end
  return out
end

-- Sum of everything mining `entity_name` yields that the force has produced.
-- Covers ore (item products) and crude-oil (fluid product) alike.
local function mining_yield(force, surface, entity_name)
  local proto = prototypes.entity[entity_name]
  if not proto then return 0 end
  local mp = proto.mineable_properties
  if not (mp and mp.minable and mp.products) then return 0 end
  local total = 0
  for _, p in pairs(mp.products) do
    total = total + produced(force, surface, p.type, p.name)
  end
  return total
end

-- ---------------------------------------------------------------------------
-- Hand-craft ledger
--
-- begin_crafting by a player-less character never reaches production
-- statistics, so the mod keeps its own tally. Ingredients are consumed at queue
-- time and the mod never cancels a queue, so crediting on a successful queue
-- matches what the character actually ends up holding.
-- ---------------------------------------------------------------------------

local function ledger()
  local s = storage.ai_player
  if not s then return nil end
  s.hand_crafted = s.hand_crafted or {}
  return s.hand_crafted
end

-- Record `crafts` completed hand-crafts of `recipe_name`. Call this from every
-- begin_crafting site with the count the API actually queued.
function AITriggers.on_crafted(recipe_name, crafts)
  if not recipe_name or not crafts or crafts <= 0 then return end
  local book = ledger()
  if not book then return end
  local recipe = prototypes.recipe[recipe_name]
  if not recipe then return end
  for _, p in pairs(recipe.products) do
    if p.type == "item" then
      -- amount may be a range (amount_min/amount_max); the low end is the
      -- guaranteed yield, which keeps the ledger conservative.
      local per = p.amount or p.amount_min or 0
      if per > 0 then
        book[p.name] = (book[p.name] or 0) + per * crafts
      end
    end
  end
end

local function hand_crafted(item)
  local book = ledger()
  return (book and item and book[item]) or 0
end

local function force_has_entity(force, entity_name)
  for _, surface in pairs(game.surfaces) do
    if surface.count_entities_filtered{name = entity_name, force = force, limit = 1} > 0 then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Trigger evaluation
-- ---------------------------------------------------------------------------

-- Returns true only when the force has demonstrably done what the trigger asks.
-- Unknown/unreachable trigger types return false so they stay untouched.
local function satisfied(force, surface, trigger)
  local t = trigger.type

  if t == "craft-item" then
    local item = proto_name(trigger.item)
    local need = trigger.count or 1
    -- Machine output shows up in statistics; the AI's hand-crafting does not,
    -- so both sources count toward the same threshold.
    return produced(force, surface, "item", item) + hand_crafted(item) >= need

  elseif t == "craft-fluid" then
    local fluid = proto_name(trigger.fluid)
    local need  = trigger.amount or 1
    return produced(force, surface, "fluid", fluid) >= need

  elseif t == "mine-entity" then
    -- The trigger asks for one mining action; any yield proves it happened.
    for _, name in ipairs(trigger_entities(trigger)) do
      if mining_yield(force, surface, name) > 0 then return true end
    end
    return false

  elseif t == "build-entity" then
    for _, name in ipairs(trigger_entities(trigger)) do
      if force_has_entity(force, name) then return true end
    end
    return false
  end

  -- capture-spawner / create-space-platform / anything new: not our business.
  return false
end

local function prereqs_met(tech)
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then return false end
  end
  return true
end

-- One pass over the force's trigger technologies. Returns the list of names
-- completed this pass (empty when nothing was earned).
local function scan_once(force, surface)
  local completed = {}
  for name, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched then
      local trigger = tech.prototype.research_trigger
      if trigger and prereqs_met(tech) and satisfied(force, surface, trigger) then
        tech.researched = true
        completed[#completed + 1] = name
      end
    end
  end
  return completed
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Evaluate every pending trigger tech for `force`, cascading so that a tech
-- unlocked by this pass is itself considered. Returns the completed names.
function AITriggers.check(force, surface)
  surface = surface or game.surfaces["nauvis"]
  if not (force and surface) then return {} end

  local all = {}
  for _ = 1, MAX_CASCADE do
    local done = scan_once(force, surface)
    if #done == 0 then break end
    for _, n in ipairs(done) do all[#all + 1] = n end
  end

  if #all > 0 then
    game.print("[AI] Trigger tech earned: " .. table.concat(all, ", "), {r = 0.4, g = 0.9, b = 1})
  end
  return all
end

-- Human/model-readable statement of what a trigger asks for, so the research
-- skill can tell the model exactly which action completes the tech.
function AITriggers.describe(trigger)
  if not trigger then return "" end
  local t = trigger.type
  if t == "craft-item" then
    return string.format("Craft %d x %s.", trigger.count or 1, tostring(proto_name(trigger.item)))
  elseif t == "craft-fluid" then
    return string.format("Produce %d %s.", trigger.amount or 1, tostring(proto_name(trigger.fluid)))
  elseif t == "mine-entity" then
    return string.format("Mine a %s.", table.concat(trigger_entities(trigger), " or "))
  elseif t == "build-entity" then
    return string.format("Build a %s.", tostring(proto_name(trigger.entity)))
  elseif t == "capture-spawner" then
    return "Capture a biter spawner (needs capture bots)."
  end
  return "Trigger type '" .. tostring(t) .. "' is not reachable from Nauvis ground play."
end

-- on_tick entry point: throttled so the scan runs ~every 2 seconds.
function AITriggers.on_tick(tick, force)
  if tick % CHECK_INTERVAL ~= 0 then return end
  AITriggers.check(force, game.surfaces["nauvis"])
end

return AITriggers
