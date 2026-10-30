-- Blueprint provenance registry (optional, setting ai-player-enforce-blueprint-provenance,
-- default off). With it on, only blueprints made DURING the run are accepted:
-- exported from the live map (export_blueprint registers its output) or compiled
-- from a layout the agent wrote (register_blueprint remote). Any other export
-- string — pasted, remembered, read from a file — is refused by import_blueprint.
-- Ported from llm-play-factorio (scripts/bp_registry.lua).
--
-- The registry is keyed by CONTENT, not by the string: two strings that
-- describe the same layout share one key however they were encoded, wherever
-- the area sat on the map, and whatever label or icons they carry. The key is
-- a 128-bit hash of a canonical JSON form (see M.canonical):
--
--   [1, [entity lines...], [tile lines...]]      all lines sorted as strings
--   entity line  name|x|y|dir|recipe|type|input_priority|output_priority|filter|quality
--   tile line    name|x|y
--
-- Positions are shifted so the top-left entity (min x, min y over all entities;
-- over the tiles when there are none) sits at 0,0 and written with two
-- decimals. `type` is the underground belt / loader direction ("input" or
-- "output"); empty fields stay empty.
--
-- Audit trail: the record keeps the source, character, tick, entity count and
-- an optional note. The first registration of a layout wins.
AIBPRegistry = {}
local M = AIBPRegistry

local SETTING = "ai-player-enforce-blueprint-provenance"

local MAX_SOURCE = 64
local MAX_NOTE = 300

local function store()
  storage.bp_registry = storage.bp_registry or { by_hash = {} }
  return storage.bp_registry
end

-- Runtime-global mod setting, default OFF here (the source project ran with it ON).
function M.enforced()
  local s = settings and settings.global and settings.global[SETTING]
  return s ~= nil and s.value == true
end

local function try(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

-- Two-decimal fixed text; never "-0.00" (a shifted position of 0 minus noise).
local function fixed(v)
  local r = math.floor(v * 100 + 0.5) / 100
  if r == 0 then r = 0 end
  return string.format("%.2f", r)
end

-- Priorities, filters and the like: strings stay as they are, small tables
-- are flattened with sorted keys so the text never depends on hash order.
local function flat(v)
  if v == nil then return "" end
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local val = v[k]
    if val == nil then val = v[tonumber(k)] end
    parts[#parts + 1] = k .. "=" .. flat(val)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function quality_of(e)
  local q = e.quality
  if type(q) == "table" then q = q.name end
  if q == nil or q == "normal" then return "" end
  return tostring(q)
end

-- The canonical text of a blueprint holder (LuaItemStack or LuaRecord:
-- get_blueprint_entities / get_blueprint_tiles) and its entity count.
function M.canonical(holder)
  local ents = try(function() return holder.get_blueprint_entities() end) or {}
  local tiles = try(function() return holder.get_blueprint_tiles() end) or {}

  local min_x, min_y = math.huge, math.huge
  for _, e in ipairs(ents) do
    min_x = math.min(min_x, e.position.x)
    min_y = math.min(min_y, e.position.y)
  end
  if #ents == 0 then
    for _, t in ipairs(tiles) do
      min_x = math.min(min_x, t.position.x)
      min_y = math.min(min_y, t.position.y)
    end
  end
  if min_x == math.huge then min_x, min_y = 0, 0 end

  local ent_lines, tile_lines = {}, {}
  for _, e in ipairs(ents) do
    ent_lines[#ent_lines + 1] = table.concat({
      e.name,
      fixed(e.position.x - min_x),
      fixed(e.position.y - min_y),
      tostring(e.direction or 0),
      flat(e.recipe),
      flat(e.type),
      flat(e.input_priority),
      flat(e.output_priority),
      flat(e.filter),
      quality_of(e),
    }, "|")
  end
  for _, t in ipairs(tiles) do
    tile_lines[#tile_lines + 1] = table.concat({
      t.name, fixed(t.position.x - min_x), fixed(t.position.y - min_y),
    }, "|")
  end
  table.sort(ent_lines)
  table.sort(tile_lines)
  return helpers.table_to_json({ 1, ent_lines, tile_lines }), #ents
end

-- 128-bit hash of a string as 32 hex digits: four independent
-- multiply-and-add lanes, each modulo a prime just under 2^32 (so every
-- product stays exact in a double). Plain arithmetic only: no bit ops.
local LANES = {
  { p = 4294967291, m = 1000003, seed = 2166136261 },
  { p = 4294967279, m = 999983, seed = 1540483477 },
  { p = 4294967231, m = 1000033, seed = 3266489917 },
  { p = 4294967197, m = 999979, seed = 668265263 },
}

function M.hash(text)
  local h = {}
  for i, lane in ipairs(LANES) do h[i] = lane.seed % lane.p end
  for i = 1, #text do
    local b = string.byte(text, i) + 1
    for j = 1, 4 do
      local lane = LANES[j]
      h[j] = (h[j] * lane.m + b) % lane.p
    end
  end
  local out = {}
  for j = 1, 4 do out[j] = string.format("%08x", math.floor(h[j])) end
  return table.concat(out)
end

-- Canonical key hash and entity count of a holder.
function M.key_of(holder)
  local text, count = M.canonical(holder)
  return M.hash(text), count
end

function M.is_registered(key_hash)
  return store().by_hash[key_hash] ~= nil
end

-- Register a holder's layout. meta = {source, character?, note?}. Returns
-- {key_hash, entity_count, already_registered}; an existing record is kept.
function M.register(holder, meta)
  meta = meta or {}
  local key_hash, count = M.key_of(holder)
  local tile_count = #(try(function() return holder.get_blueprint_tiles() end) or {})
  if count == 0 and tile_count == 0 then
    error("that blueprint is empty — nothing to register")
  end
  local by_hash = store().by_hash
  local already = by_hash[key_hash] ~= nil
  if not already then
    local note = type(meta.note) == "string" and meta.note ~= "" and meta.note:sub(1, MAX_NOTE) or nil
    by_hash[key_hash] = {
      source = tostring(meta.source or "?"):sub(1, MAX_SOURCE),
      character = meta.character,
      tick = game.tick,
      entity_count = count,
      note = note,
    }
  end
  return { key_hash = key_hash, entity_count = count, already_registered = already }
end

M.REFUSAL = "this blueprint string is not allowed: the provenance rule only allows blueprints exported from the map "
  .. "(export_blueprint) or compiled from a layout made in this run, and this string is neither"

-- The gate: refuse a decoded blueprint that was not registered. No-op when the
-- mod setting is off.
function M.require_registered(holder)
  if not M.enforced() then return end
  if not M.is_registered((M.key_of(holder))) then error(M.REFUSAL, 0) end
end

-- Registered layouts for auditing, oldest first.
function M.list()
  local out = {}
  for key_hash, r in pairs(store().by_hash) do
    out[#out + 1] = {
      key_hash = key_hash,
      source = r.source,
      character = r.character,
      tick = r.tick,
      entity_count = r.entity_count,
      note = r.note,
    }
  end
  table.sort(out, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    return a.key_hash < b.key_hash
  end)
  return out
end

return M
