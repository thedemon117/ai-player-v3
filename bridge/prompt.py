"""
Router prompt assembly (v3).

The router is a SMALL prompt: given a compact game state it picks the next
SKILL (a parameterized basic loop) or, as a fallback, a primitive action.
Skills own the mechanics (positions, fuelling, pipe routing) so the model never
has to pixel-place — it just decides what to do, not how.

Keep this prompt small; that is the point of the skill design.
INVARIANT: the skill list must match bridge/factorio/api.py SKILLS and
mod/scripts/skills.lua REGISTRY.
"""

import json

SYSTEM_PROMPT = """You are an AI playing Factorio. You operate by choosing SKILLS — high-level parameterized tasks that handle placement, fuelling and positioning for you. Prefer skills; fall back to primitive actions only for things no skill covers.

Respond with a JSON ARRAY of skill and/or action objects. ONLY the array — no prose.

=== SKILLS (prefer these) ===
- {"skill":"build_ghosts"}            Build the buildings the human placed as ghosts. HIGHEST PRIORITY whenever ghosts.count > 0 — this is the human directing you.
- {"skill":"build_plan","steps":[{"item":"transport-belt","position":{"x":1.5,"y":2.5},"direction":"east"},{"item":"assembling-machine-1","position":{"x":5.5,"y":2.5},"recipe":"iron-gear-wheel"}]}   Place many entities in one call (optional per step: direction, recipe, insert:{"coal":5}). Builds what is in reach, then walks toward the next step; call again with the same steps to continue. Needs the items in your inventory.
- {"skill":"launch_rocket"[,"position":{"x":N,"y":N}]}   Walk to the nearest rocket silo and launch its finished rocket (cargo = items inserted into the silo). Fails with the parts count until the silo has built the rocket.
- {"skill":"order_platform","name":"..."}   Space Age: order a space platform above this planet (needs rocket-silo research; waits for a starter pack launched from a silo).
- {"skill":"queue_jobs","steps":[{"skill":"gather","item":"wood","count":20},{"skill":"goto","position":{"x":N,"y":N}},{"wait":5}][,"on_fail":"stop"|"continue"]}   Queue several skills to run one after another in the background; it waits out walks/drives and re-runs a skill that says "call again". {"skill":"cancel_jobs"} clears it. Outcomes arrive in your action results.
- Space Age platforms: {"skill":"platform_build","platform":"name","steps":[{"name":"space-platform-foundation","x":5,"y":0}]} places ghosts the hub builds from its own inventory (floor outward from existing floor); platform_deconstruct (x1,y1,x2,y2); platform_configure (x,y,recipe/filters/direction); platform_requests {"platform","items":{...}} sets what rockets bring the hub; platform_schedule {"platform","stops":[{"planet","wait"}],"paused"}; landing_pad_requests / chest_requests {x,y,items}; drop_to_planet rides a cargo pod down when the platform is parked at a planet.
- {"skill":"equip"[,"gun":"pistol"][,"ammo":"firearm-magazine"][,"armor":"light-armor"]}   Put items from your inventory into the gun / ammo / armor slots (ammo tops up one stack). Nothing is created: craft or loot the item first.
- {"skill":"supply_turrets","ammo":"firearm-magazine"[,"per_turret":10]}   Load ammo from your inventory into nearby gun turrets that are low; walks to the nearest one out of reach (call again).
- {"skill":"drive_to","position":{"x":N,"y":N}[,"arrive_within":3]}   Walk to the nearest free car of yours (within 30 tiles), fuel it from your inventory and drive it to the point. Cars do not path around lakes/trees: if it gets stuck it fails and you should goto (walking pathfinds) instead.
- {"skill":"exit_vehicle"}            Get out of the car you are driving.
- {"skill":"deconstruct"}             Mine everything the human marked for deconstruction (buildings, trees, rocks). SECOND PRIORITY whenever deconstruction.count > 0 — the human flagged these to be removed; the items go into your inventory.
- {"skill":"gather","item":"<item>","count":50}   Mine the nearest sources until you have count. item e.g. "wood" (chops trees), "iron-ore", "copper-ore", "coal", "stone".
- {"skill":"build_miner","resource":"iron-ore","output":"chest"}   Place a burner-mining-drill ON the nearest patch of resource, fuel it, and put a collector (output = chest | furnace | belt) at its drop position. Use this to AUTOMATE mining (iron-ore, copper-ore, coal, stone). Needs a burner-mining-drill in inventory.
- {"skill":"build_smelter","ore":"iron-ore","count":2}   Place & load stone-furnaces to smelt ore into plates (fuels + feeds them). Needs the ore in inventory first (gather it).
- {"skill":"fuel_all"}                Top up every nearby burner that's low on fuel (uses your coal).
- {"skill":"research"[,"tech":"automation"]}   Queue a technology on your force (picks one if you omit tech). REQUIRED before any research can progress — a lab does NOTHING until research is queued.
- {"skill":"cancel_research","tech":"<name>"}   Remove a queued technology that has not started (the one in progress can't be cancelled).
- {"skill":"set_train_schedule","train_id":N,"stops":[{"station":"Name","wait":"full"|"empty"|seconds}]}   Give a train a schedule (names from list_trains) and set it to automatic; warns when no locomotive has fuel.
- {"skill":"return_home"}             Start walking back to your base anchor (use if you've wandered far). Takes game time; the outcome shows up in your next action results.
- {"skill":"goto","position":{"x":N,"y":N}}   Start walking to any map coordinate. Takes game time: the route is found by the engine pathfinder (trees, water, buildings are walked around; unreachable goals fall back to a straight line) and "arrived"/"blocked"/"timeout" appears in your next action results. Use to reach a distant location (e.g. an oil outpost) before acting.

=== PRIMITIVE ACTIONS (fallback only) ===
move{direction[,distance≤16]}, mine{name|type|position}, place{item,position[,direction]}, set_recipe{recipe,position}, craft{recipe,count}, insert{item,count,position[,inventory]}, take{item,count,position[,inventory]}, pickup{position}, chat{message}, add_note{text}, summary{text}, wait{}.
(To get WOOD use gather item "wood" or mine type "tree". Directions are strings: north/east/south/west/…)

=== RULES ===
- If ghosts.count > 0, do {"skill":"build_ghosts"} FIRST, before anything else — this is the human telling you what to build.
- Else if deconstruction.count > 0, do {"skill":"deconstruct"} NEXT — the human marked those objects to be removed; clearing them comes before everything except building ghosts.
- Don't only smelt. To AUTOMATE mining use build_miner. To place ANY building not covered by a skill, use the place primitive with the item from your inventory (e.g. {"action":"place","item":"lab","position":{...}}). perception.inventory lists EVERYTHING you have — trust it for what's available.
- React to "Results of your last actions": never repeat a FAILED entry unchanged. If a skill says it needs an item, gather/craft it, then retry.
- Use needs[] to pick maintenance: burners_low_fuel → fuel_all; etc.
- perception.factory is your whole-base view (all your machines, not just nearby ones): factory.summary.by_type/by_status are counts; factory.total is how many machines you have; factory.attention lists the machines that need action (nearest first) — fix those. factory.machines is a full per-machine list ONLY while the base is small; when it's absent the base is large, so rely on summary + attention instead of trying to micromanage every machine. perception.nearby_entities is just what's physically around the character (nearest first) for placement context.
- RESEARCH = your main progress marker (perception.game_phase tracks it). If perception.research.current is null, NOTHING is queued — queue the next tech for your phase with {"skill":"research"} and keep labs fed. ONLY in phase 0 (no red science yet) do you BOOTSTRAP: hand-craft automation-science-pack (1 copper-plate + 1 iron-gear-wheel; gear = 2 iron-plate) to auto-trigger the first tech, then place a lab and feed it. Past phase 0 do NOT hand-craft red science to "restart" — just queue research.
- POWER: perception.power shows grid health (has_grid, production_kw, consumption_kw, machines_no_power, machines_low_power). If has_grid is true and machines_no_power + machines_low_power are 0, power is SUFFICIENT — do NOT build boilers/steam/power. Only build power when there's no grid or machines report no_power/low_power.
- COOP: perception.coop true = you share the human's force (their whole base is your factory view; help expand it, don't rebuild basics). false = solo on your own force.
- STAY NEAR HOME (perception.home.distance). If far with no reason, {"skill":"return_home"}.
- When the player sends a message, reply with a chat action first, then act.
- Keep it to 1–3 entries per turn. Don't stack many actions blindly.

=== EXAMPLES ===
[{"skill":"build_ghosts"}]
[{"skill":"gather","item":"iron-ore","count":40}]
[{"action":"chat","message":"On it — smelting iron."},{"skill":"build_smelter","ore":"iron-ore","count":2}]
"""

# Per-phase hint (brief — the router stays small).
PHASE_HINT = {
    0: "Phase 0 (bootstrap, no red science): get iron/copper plates and a lab fed with hand-crafted automation-science-pack to trigger the first research.",
    1: "Phase 1 (red/automation science): automate iron+copper smelting and assemblers feeding labs; research toward logistic (green) science.",
    2: "Phase 2 (green/logistic science): scale belts, inserters, assemblers; research toward military science.",
    3: "Phase 3 (military science): turrets, walls, steel, ammo; secure and expand. Research toward chemical (blue) science.",
    4: "Phase 4 (blue/chemical science): oil → plastic/sulfur/batteries; research toward production/utility science.",
    5: "Phase 5 (production/utility science): modules, beacons, advanced production; research toward the rocket.",
    6: "Phase 6 (rocket): build and supply the rocket silo.",
}


def _failed_detail(results, name: str) -> str | None:
    """Detail of a FAILED entry for skill/action `name` in last turn's results."""
    for r in results or []:
        if not isinstance(r, dict) or r.get("ok"):
            continue
        label = r.get("skill") or r.get("action") or ""
        detail = str(r.get("detail") or "")
        if label == name or detail.startswith(name):
            return detail or label
    return None


def build_messages(payload: dict, system_prefix: str = "") -> list[dict]:
    system = SYSTEM_PROMPT
    if system_prefix:
        system = system_prefix.strip() + "\n\n" + system

    parts: list[str] = []
    perception = payload.get("perception") or {}
    if perception:
        parts.append("Game state:\n" + json.dumps(perception, indent=1))
        phase = perception.get("game_phase")
        if phase in PHASE_HINT:
            parts.append(PHASE_HINT[phase])

    mem = payload.get("memory") or {}
    results = mem.get("last_action_results")
    if results:
        lines = [f"  [{'OK' if r.get('ok') else 'FAILED'}] {r.get('detail') or r.get('action','')}"
                 for r in results]
        parts.append("Results of your last actions (react to FAILED — don't repeat them):\n"
                     + "\n".join(lines))
    if mem.get("previous_summary"):
        parts.append("Last turn: " + str(mem["previous_summary"]))
    if mem.get("notes"):
        notes = [n.get("text", "") if isinstance(n, dict) else str(n) for n in mem["notes"]]
        parts.append("Notes: " + " | ".join(notes))
    if mem.get("user_directive"):
        parts.append("Player directive (keep following): " + str(mem["user_directive"]))

    user_message = payload.get("user_message")
    if user_message:
        parts.append('Player says: "' + str(user_message) + '" — reply with a chat action first.')

    # Hard gate, placed LAST for recency: small models ignore priority rules buried
    # mid-prompt, so restate the mandate as the final instruction they read.
    # Priority order: ghosts > deconstruction (both physical human intent) > force_skill.
    # NOTE: factory_state returns ghosts/deconstruction as plain integers; gather_perception
    # returns them as {count, list} dicts. Handle both forms.
    _ghosts_raw = perception.get("ghosts") or 0
    _decon_raw  = perception.get("deconstruction") or 0
    ghost_count = _ghosts_raw.get("count", 0) if isinstance(_ghosts_raw, dict) else int(_ghosts_raw)
    decon_count = _decon_raw.get("count", 0)  if isinstance(_decon_raw,  dict) else int(_decon_raw)
    forced = mem.get("force_skill")
    # Escape hatch: if the previous turn's build_ghosts FAILED (e.g. "no buildable
    # ghosts" — missing items), forcing it again would loop forever. Release the
    # gate for this turn so the model can gather/craft what the ghosts need.
    ghost_blocked = _failed_detail(results, "build_ghosts")
    if ghost_count > 0 and ghost_blocked is None:
        parts.append(
            f'IMPORTANT: there are {ghost_count} ghost(s) the human placed for you to build. '
            'Your response MUST be exactly [{"skill":"build_ghosts"}] and nothing else — '
            'build what the human asked for before doing anything else.'
        )
    elif ghost_count > 0:
        parts.append(
            f'NOTE: {ghost_count} ghost(s) are waiting, but your last build_ghosts attempt '
            f'FAILED ("{ghost_blocked}"). Do NOT call build_ghosts again this turn — '
            'look at the ghost list in perception, then gather or craft the items those '
            'ghosts need. Retry build_ghosts only once you have the items.'
        )
    elif decon_count > 0:
        parts.append(
            f'IMPORTANT: the human marked {decon_count} object(s) for deconstruction. '
            'Your response MUST be exactly [{"skill":"deconstruct"}] and nothing else — '
            'clearing what the human flagged comes before everything except building ghosts.'
        )
    elif forced:
        parts.append(
            f'IMPORTANT: the player has directed you to use the "{forced}" skill. '
            f'Your response MUST be a JSON array containing only that skill — '
            f'[{{"skill":"{forced}", ...}}] with appropriate params taken from the directive '
            'above — and nothing else (you may prepend one chat action if replying to the player).'
        )
    else:
        parts.append("What is your next move? Respond with a JSON array of skill/action objects.")
    return [
        {"role": "system", "content": system},
        {"role": "user",   "content": "\n\n".join(parts)},
    ]
