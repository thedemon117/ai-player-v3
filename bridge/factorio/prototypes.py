"""
Entity interaction registry for Factorio 2.0.

Each entry documents how the agent interacts with that entity type:
  - energy_source: "burner" | "electric" | "void" | "fluid"
  - fuel_category: which fuel items are valid (burner entities only)
  - inventories: named slots the agent can insert into or take from
      api: the Lua expression used on a LuaEntity to access this inventory
      accepts: what kind of item goes here (for agent prompt clarity)
  - output_type: "inventory" | "drop_position" | "fluid" | "electric"
  - fluid_connections: fluid input/output (type and fluid name where fixed)
  - status_responses: what the agent should do for each entity status string
  - notes: facts that don't fit elsewhere

Inventory slot names ("fuel", "input", "output") are the values the agent
passes in insert/take actions. The Lua action layer resolves these to the
correct API call using this registry.

Sources:
  - Factorio 2.0 Lua API: https://lua-api.factorio.com/latest/
  - defines.inventory (Factorio 2.0.32): crafter_input/crafter_output do NOT
    exist. Use type-specific defines — furnace_source/furnace_result for
    furnaces, assembling_machine_input/output for assemblers. Resolved by
    entity type in mod/scripts/ai_actions.lua get_inventory_by_slot().
  - Factorio wiki entity pages
"""

# ---------------------------------------------------------------------------
# Inventory slot → Lua API mapping
# Verified against Factorio 2.0.32 runtime API (api_version 6).
#
# IMPORTANT: defines.inventory.crafter_input and crafter_output do NOT exist
# in Factorio 2.0.32. Use type-specific defines instead:
#   furnaces:         furnace_source / furnace_result
#   assemblers:       assembling_machine_input / assembling_machine_output
# Both are resolved by entity type in ai_actions.lua get_inventory_by_slot().
# The "input" / "output" slot names map to different defines depending on entity type.
# ---------------------------------------------------------------------------

SLOT_API = {
    "fuel":    "entity:get_fuel_inventory()",
    # "input" resolves to furnace_source (furnace) or assembling_machine_input (assembler)
    "input":   "entity:get_inventory(defines.inventory.furnace_source)  -- or assembling_machine_input",
    "output":  "entity:get_output_inventory()",
    "chest":   "entity:get_inventory(defines.inventory.chest)",
    "lab":     "entity:get_inventory(defines.inventory.lab_input)",
    "ammo":    "entity:get_inventory(defines.inventory.turret_ammo)",
    # furnace_modules (furnace) or assembling_machine_modules (assembler) — by type
    "modules": "entity:get_inventory(defines.inventory.furnace_modules)",
}

# ---------------------------------------------------------------------------
# Entity prototype registry
# ---------------------------------------------------------------------------

ENTITY_PROTOTYPES = {

    # --- Smelting -----------------------------------------------------------

    "stone-furnace": {
        "type": "furnace",
        "energy_source": "burner",
        "fuel_category": "chemical",          # coal, wood, solid-fuel, rocket-fuel
        "inventories": {
            "fuel":   {
                "api": "get_fuel_inventory()",
                "accepts": "chemical fuel (coal preferred)",
            },
            "input":  {
                "api": "get_inventory(defines.inventory.crafter_input)",
                "accepts": "smeltable ore (iron-ore, copper-ore, stone, iron-plate for steel)",
            },
            "output": {
                "api": "get_output_inventory()",
                "accepts": "smelted plates — TAKE only",
            },
        },
        "output_type": "inventory",
        "status_responses": {
            "no_fuel":         "insert coal into fuel slot",
            "no_ingredients":  "insert ore into input slot",
            "output_full":     "take plates from output slot or clear downstream",
            "working":         "nothing needed",
            "idle":            "insert ore and fuel",
        },
        "notes": (
            "2×2 tiles. Smelting speed 1/s. Insert ore into 'input', coal into 'fuel'. "
            "Take plates from 'output'. Check status before inserting — do not stack actions."
        ),
    },

    "steel-furnace": {
        "type": "furnace",
        "energy_source": "burner",
        "fuel_category": "chemical",
        "inventories": {
            "fuel":   {"api": "get_fuel_inventory()",                                  "accepts": "chemical fuel"},
            "input":  {"api": "get_inventory(defines.inventory.crafter_input)",        "accepts": "smeltable ore"},
            "output": {"api": "get_output_inventory()",                                "accepts": "smelted output — TAKE only"},
        },
        "output_type": "inventory",
        "status_responses": {
            "no_fuel": "insert coal", "no_ingredients": "insert ore",
            "output_full": "take output", "working": "nothing needed",
        },
        "notes": "Smelting speed 2/s. Same slot model as stone-furnace.",
    },

    "electric-furnace": {
        "type": "furnace",
        "energy_source": "electric",
        "inventories": {
            "input":  {"api": "get_inventory(defines.inventory.crafter_input)",  "accepts": "smeltable ore"},
            "output": {"api": "get_output_inventory()",                           "accepts": "smelted output — TAKE only"},
            "modules":{"api": "get_inventory(defines.inventory.crafter_modules)", "accepts": "modules"},
        },
        "output_type": "inventory",
        "status_responses": {
            "no_ingredients": "insert ore", "output_full": "take output",
            "no_power": "check electrical network", "working": "nothing needed",
        },
        "notes": "Smelting speed 2/s. No fuel needed — electric. 2 module slots.",
    },

    # --- Mining -------------------------------------------------------------

    "burner-mining-drill": {
        "type": "mining-drill",
        "energy_source": "burner",
        "fuel_category": "chemical",
        "inventories": {
            "fuel": {
                "api": "get_fuel_inventory()",
                "accepts": "chemical fuel (coal preferred — can self-fuel on coal patch)",
            },
        },
        "output_type": "drop_position",
        "output_notes": (
            "Mined items drop onto entity.drop_position (1 tile in facing direction). "
            "The agent CANNOT take from the drill directly. "
            "Place a chest, belt, or furnace input tile at drop_position to collect output. "
            "Verify drop_position is not blocked before placing drill."
        ),
        "mining_speed": 0.25,
        "status_responses": {
            "no_fuel":           "insert coal into fuel slot",
            "no_resources":      "move drill to a resource patch",
            "output_full":       "clear the entity at drop_position or add belt",
            "mining":            "nothing needed",
        },
        "notes": (
            "2×2 tile footprint. Mining area is 2×2 in front. "
            "Place on iron-ore, copper-ore, coal, or stone patch. "
            "Drop position is always 1 tile past the drill in its facing direction."
        ),
    },

    "electric-mining-drill": {
        "type": "mining-drill",
        "energy_source": "electric",
        "inventories": {
            "modules": {"api": "get_inventory(defines.inventory.mining_drill_modules)", "accepts": "modules"},
        },
        "output_type": "drop_position",
        "output_notes": "Same drop_position model as burner-mining-drill. No fuel needed.",
        "mining_speed": 0.5,
        "status_responses": {
            "no_power":     "check electrical network",
            "no_resources": "move drill to a resource patch",
            "output_full":  "clear drop_position entity",
            "mining":       "nothing needed",
        },
        "notes": "3×3 tile footprint. Requires electricity. 3 module slots.",
    },

    # --- Power --------------------------------------------------------------

    "boiler": {
        "type": "boiler",
        "energy_source": "burner",
        "fuel_category": "chemical",
        "inventories": {
            "fuel": {"api": "get_fuel_inventory()", "accepts": "chemical fuel"},
        },
        "output_type": "fluid",
        "fluid_connections": {
            "input":  {"fluid": "water",  "direction": "input"},
            "output": {"fluid": "steam",  "direction": "output"},
        },
        "status_responses": {
            "no_fuel":    "insert coal into fuel slot",
            "no_fluid_input": "connect pipe from offshore-pump carrying water",
            "working":    "nothing needed",
        },
        "notes": (
            "Converts water → steam using fuel. "
            "Connect offshore-pump → pipe → boiler water-input side. "
            "Connect boiler steam-output → steam-engine. "
            "1×2 tile footprint, directional — orientation matters for pipe connections."
        ),
    },

    "steam-engine": {
        "type": "generator",
        "energy_source": "fluid",
        "inventories": {},
        "output_type": "electric",
        "fluid_connections": {
            "input": {"fluid": "steam", "direction": "input"},
        },
        "status_responses": {
            "no_fluid_input": "connect pipe from boiler steam output",
            "working":        "nothing needed",
        },
        "notes": (
            "Consumes steam, produces 900 kW electricity. "
            "1×3 tile footprint. Connect to boiler steam output via pipe. "
            "Attach electric poles to distribute power."
        ),
    },

    "offshore-pump": {
        "type": "offshore-pump",
        "energy_source": "electric",
        "inventories": {},
        "output_type": "fluid",
        "fluid_connections": {
            "output": {"fluid": "water", "direction": "output"},
        },
        "placement": "must be placed on water tile at shore edge",
        "status_responses": {
            "no_power":   "connect electric pole",
            "working":    "nothing needed",
        },
        "notes": (
            "Produces 1200 water/s. Must be placed directly on a water tile. "
            "Use nearby_water from perception to find valid placement tiles. "
            "Connect output pipe toward boiler."
        ),
    },

    # --- Crafting -----------------------------------------------------------

    "assembling-machine-1": {
        "type": "assembling-machine",
        "energy_source": "electric",
        "inventories": {
            "input":  {"api": "get_inventory(defines.inventory.crafter_input)",  "accepts": "recipe ingredients"},
            "output": {"api": "get_output_inventory()",                           "accepts": "crafted output — TAKE only"},
        },
        "output_type": "inventory",
        "module_slots": 0,
        "crafting_speed": 0.5,
        "liquid_capable": False,
        "status_responses": {
            "no_recipe":      "use set_recipe action: {action:'set_recipe', recipe:'<name>', position:{x,y}}",
            "no_ingredients": "insert recipe inputs into input slot",
            "output_full":    "take output or connect output inserter",
            "no_power":       "connect electric pole",
            "working":        "nothing needed",
        },
        "notes": (
            "3×3 tile footprint. Cannot handle liquid ingredients. No module slots. "
            "MUST set recipe before inserting ingredients: "
            "{action:'set_recipe', recipe:'iron-gear-wheel', position:{x,y}}. "
            "Check status 'no_recipe' — if set, use set_recipe first."
        ),
    },

    "assembling-machine-2": {
        "type": "assembling-machine",
        "energy_source": "electric",
        "inventories": {
            "input":   {"api": "get_inventory(defines.inventory.crafter_input)",  "accepts": "recipe ingredients including liquids"},
            "output":  {"api": "get_output_inventory()",                           "accepts": "crafted output — TAKE only"},
            "modules": {"api": "get_inventory(defines.inventory.crafter_modules)", "accepts": "modules"},
        },
        "output_type": "inventory",
        "module_slots": 2,
        "crafting_speed": 0.75,
        "liquid_capable": True,
        "status_responses": {
            "no_ingredients": "insert recipe inputs",
            "no_recipe":      "set recipe",
            "output_full":    "take output",
            "no_power":       "connect electric pole",
            "working":        "nothing needed",
        },
        "notes": (
            "Handles liquid ingredients, 2 module slots. "
            "MUST set recipe before inserting: {action:'set_recipe', recipe:'...', position:{x,y}}."
        ),
    },

    # --- Logistics & Storage ------------------------------------------------

    "wooden-chest": {
        "type": "container",
        "energy_source": "void",
        "inventories": {
            "chest": {"api": "get_inventory(defines.inventory.chest)", "accepts": "any item"},
        },
        "output_type": "inventory",
        "notes": "16 slots. Use for temporary storage or inserter pickup/dropoff.",
    },

    "iron-chest": {
        "type": "container",
        "energy_source": "void",
        "inventories": {
            "chest": {"api": "get_inventory(defines.inventory.chest)", "accepts": "any item"},
        },
        "output_type": "inventory",
        "notes": "32 slots.",
    },

    "steel-chest": {
        "type": "container",
        "energy_source": "void",
        "inventories": {
            "chest": {"api": "get_inventory(defines.inventory.chest)", "accepts": "any item"},
        },
        "output_type": "inventory",
        "notes": "48 slots.",
    },

    "burner-inserter": {
        "type": "inserter",
        "energy_source": "burner",
        "fuel_category": "chemical",
        "inventories": {
            "fuel": {"api": "get_fuel_inventory()", "accepts": "chemical fuel — self-fuels from coal lane on belt"},
        },
        "output_type": "transfer",
        "notes": (
            "Moves items between buildings/belts. "
            "Can self-fuel if coal is available on the pickup belt lane. "
            "Slower than electric inserter. Useful before electricity is available."
        ),
    },

    "inserter": {
        "type": "inserter",
        "energy_source": "electric",
        "inventories": {},
        "output_type": "transfer",
        "notes": "Electric inserter. Moves items between buildings/belts. Requires power.",
    },

    "transport-belt": {
        "type": "transport-belt",
        "energy_source": "void",
        "inventories": {},
        "output_type": "belt",
        "notes": (
            "Carries items in two lanes. Items placed by inserters or dropped from miners. "
            "Agent cannot directly insert/take — use inserters to load/unload belts. "
            "Belt speed: 15 items/s per lane."
        ),
    },

    # --- Research -----------------------------------------------------------

    "lab": {
        "type": "lab",
        "energy_source": "electric",
        "inventories": {
            "lab": {"api": "get_inventory(defines.inventory.lab_input)", "accepts": "science packs"},
        },
        "output_type": "void",
        "status_responses": {
            "no_ingredients": "insert the required science pack types for current research",
            "no_power":       "connect electric pole",
            "researching":    "nothing needed",
            "idle":           "insert science packs and ensure research is queued",
        },
        "notes": (
            "Consumes science packs to progress research. "
            "Must have correct science pack types for the queued technology. "
            "Red science (automation-science-pack) required for Phase 1 research."
        ),
    },

    # --- Defense ------------------------------------------------------------

    "gun-turret": {
        "type": "turret",
        "energy_source": "void",
        "inventories": {
            "ammo": {"api": "get_inventory(defines.inventory.turret_ammo)", "accepts": "firearm-magazine or piercing-rounds-magazine"},
        },
        "output_type": "void",
        "status_responses": {
            "no_ammo":  "insert firearm-magazine into ammo slot",
            "waiting":  "no enemies in range, nothing needed",
            "attacking":"nothing needed",
        },
        "notes": "Insert firearm-magazine to arm. Range 18 tiles. Targets enemy force automatically.",
    },

    "radar": {
        "type": "radar",
        "energy_source": "electric",
        "inventories": {},
        "output_type": "void",
        "notes": (
            "Charts map automatically. Reveals 7×7 chunk area around it continuously. "
            "Scans distant chunks over time. Place early to reveal resources. "
            "Requires electricity."
        ),
    },

    # --- Electric grid ------------------------------------------------------

    "small-electric-pole": {
        "type": "electric-pole",
        "energy_source": "void",
        "inventories": {},
        "wire_reach": 7.5,
        "supply_area": 5,
        "notes": "Distributes power. Connect poles within wire_reach of each other.",
    },

    "medium-electric-pole": {
        "type": "electric-pole",
        "energy_source": "void",
        "inventories": {},
        "wire_reach": 9,
        "supply_area": 7,
        "notes": "Larger supply area than small pole. Preferred for factory interiors.",
    },

    "big-electric-pole": {
        "type": "electric-pole",
        "energy_source": "void",
        "inventories": {},
        "wire_reach": 30,
        "supply_area": 4,
        "notes": "Long wire reach for spanning distances. Small supply area.",
    },

    # --- Fluid infrastructure -----------------------------------------------

    "pipe": {
        "type": "pipe",
        "energy_source": "void",
        "inventories": {},
        "output_type": "fluid",
        "notes": "Connects fluid producers to consumers. Place contiguously.",
    },

    "pipe-to-ground": {
        "type": "pipe-to-ground",
        "energy_source": "void",
        "inventories": {},
        "output_type": "fluid",
        "notes": "Underground pipe. Allows crossing belt/building paths. Max 10 tiles underground.",
    },

}

# ---------------------------------------------------------------------------
# Helper: look up a slot's Lua API expression for a given entity + slot name
# ---------------------------------------------------------------------------

def get_slot_api(entity_name: str, slot_name: str) -> str | None:
    """Return the Lua API expression string for accessing a named inventory slot."""
    proto = ENTITY_PROTOTYPES.get(entity_name)
    if not proto:
        return None
    inv = proto.get("inventories", {}).get(slot_name)
    if not inv:
        return None
    return inv.get("api")


def get_status_response(entity_name: str, status: str) -> str | None:
    """Return the recommended agent action for a given entity status string."""
    proto = ENTITY_PROTOTYPES.get(entity_name)
    if not proto:
        return None
    return proto.get("status_responses", {}).get(status)


def entity_has_fuel_slot(entity_name: str) -> bool:
    proto = ENTITY_PROTOTYPES.get(entity_name)
    if not proto:
        return False
    return "fuel" in proto.get("inventories", {})


def entity_output_is_drop_position(entity_name: str) -> bool:
    proto = ENTITY_PROTOTYPES.get(entity_name)
    if not proto:
        return False
    return proto.get("output_type") == "drop_position"


def prompt_summary() -> str:
    """
    Return a compact entity interaction summary for injection into agent prompts.
    Covers slot names, key constraints, and set_recipe requirement for assemblers.
    """
    lines = [
        "MOVEMENT: {action:'move', direction:'<dir>'} where direction is one of:",
        "  north, northeast, east, southeast, south, southwest, west, northwest",
        "  Do NOT use numeric directions (0, 1, 2...) — use the string names above.",
        "",
        "ENTITY INTERACTION REFERENCE:",
        "  set_recipe action: {action:'set_recipe', recipe:'<name>', position:{x,y}}",
        "  Assembling machines require set_recipe before inserting ingredients.",
        "  status 'no_recipe' means set_recipe must be called first.",
        "",
    ]
    for name, proto in ENTITY_PROTOTYPES.items():
        slots = list(proto.get("inventories", {}).keys())
        out = proto.get("output_type", "")
        fuel = proto.get("energy_source", "")
        slot_str = ", ".join(f'"{s}"' for s in slots) if slots else "none"
        flags = []
        if out == "drop_position":
            flags.append("DROP_POSITION-cannot-take-directly")
        if proto.get("type") == "assembling-machine":
            flags.append("needs-set_recipe")
        flag_str = f" [{', '.join(flags)}]" if flags else ""
        lines.append(f"  {name}: slots=[{slot_str}] energy={fuel}{flag_str}")
    return "\n".join(lines)
