"""
Factorio MCP server.

Exposes a running Factorio instance to any MCP client (Claude Desktop, Claude
Code, etc.) over stdio, by wrapping the existing RCONGateway. This is the *pull*
counterpart to the autonomous ai-player bridge: instead of the mod queueing a
request and the bridge pushing actions back, here an MCP client decides when to
read game state or run a command.

Run it:
    pip install "mcp[cli]"            # one-time
    python -m bridge.factorio.mcp_server

RCON connection settings come from the same place the bridge uses
(bridge/.env -> FACTORIO_RCON_HOST/PORT/PASSWORD, optionally overlaid by the
mod's config.json). No new configuration to maintain.

Design notes:
  - RCONGateway holds a single, non-thread-safe socket. FastMCP runs sync tool
    functions in a worker-thread pool, so every gateway call is serialised
    behind _LOCK to avoid interleaved reads/writes on the wire.
  - run_lua() is a raw escape hatch (arbitrary code execution in the game).
    Prefer the curated read tools; keep run_lua for ad-hoc inspection only and
    never expose this server on an untrusted network.
  - The "/sc scenario-env gotcha": /sc (silent-command) runs in the game's
    command context. Reads of plain game state (surfaces, players, forces,
    research) are reliable. Reads of the ai-player mod's own `storage` table
    only work when the mod owns the Lua state (freeplay), not in scenario mode.
"""

import json
import logging
import threading

from ..config import ConfigLoader
from .rcon import RCONGateway

try:
    from mcp.server.fastmcp import FastMCP
except ImportError as e:  # pragma: no cover - import-time guard
    raise SystemExit(
        "mcp is not installed. Run:  pip install \"mcp[cli]\"\n"
        f"(original error: {e})"
    )

log = logging.getLogger(__name__)

# Single gateway + lock shared by all tools (see module docstring).
_cfg = ConfigLoader().get()
_GW = RCONGateway(_cfg.rcon.host, _cfg.rcon.port, _cfg.rcon.password)
_LOCK = threading.Lock()

mcp = FastMCP("factorio")


def _q(lua: str) -> str:
    """Run a Lua snippet under the lock and return its rcon.print output.

    Returns the printed string, or an "ERROR: ..." marker the model can read
    so a failed RCON send never looks like an empty-but-successful result.
    """
    with _LOCK:
        result = _GW.query_lua(lua)
    if result is None:
        return "ERROR: RCON send failed (is Factorio running with RCON enabled?)"
    return result.strip()


# ----------------------------------------------------------------------
# Read tools — plain game state, reliable in any mode
# ----------------------------------------------------------------------

@mcp.tool()
def run_lua(code: str) -> str:
    """Run arbitrary Lua in Factorio and return its output.

    The code MUST call rcon.print(...) to return a value, e.g.
        run_lua("rcon.print(game.tick)")
    Escape hatch for ad-hoc inspection; prefer the specific tools below.
    """
    return _q(code)


@mcp.tool()
def get_tick() -> str:
    """Current game tick and elapsed in-game time (60 ticks = 1 second)."""
    return _q(
        "local t=game.tick "
        "rcon.print(t..' ticks ('..string.format('%.1f',t/60)..'s, '"
        "..string.format('%.1f',t/3600)..' min)')"
    )


@mcp.tool()
def get_players() -> str:
    """List all players with surface, position, and online status."""
    return _q(
        "local t={} "
        "for _,p in pairs(game.players) do "
        "t[#t+1]=p.name..' @('..math.floor(p.position.x)..','"
        "..math.floor(p.position.y)..') on '..p.surface.name"
        "..(p.connected and ' [online]' or ' [offline]') end "
        "rcon.print(#t>0 and table.concat(t,'\\n') or 'no players')"
    )


@mcp.tool()
def get_research() -> str:
    """Current research and its progress for the player force."""
    return _q(
        "local f=game.forces.player local r=f.current_research "
        "if r then rcon.print(r.name..' — '"
        "..string.format('%.1f',f.research_progress*100)..'%') "
        "else rcon.print('no active research') end"
    )


@mcp.tool()
def get_player_inventory(player: str) -> str:
    """Contents of a player's main inventory. `player` is the player name."""
    return _q(
        f"local p=game.players['{player}'] "
        "if not p then rcon.print('no such player') return end "
        "local inv=p.get_main_inventory() "
        "if not inv then rcon.print('player has no main inventory') return end "
        "local parts={} "
        "for k,v in pairs(inv.get_contents()) do "
        # Handle both Factorio 2.0 (array of {name,count}) and 1.1 ({name=count}).
        "if type(v)=='table' then parts[#parts+1]=v.name..'='..v.count "
        "else parts[#parts+1]=k..'='..v end end "
        "table.sort(parts) "
        "rcon.print(#parts>0 and table.concat(parts,', ') or 'empty')"
    )


@mcp.tool()
def entities_near(surface: str, x: float, y: float, radius: float = 20.0) -> str:
    """Summarise entities near a point as 'Nx name' counts.

    surface: surface name (usually 'nauvis'). radius in tiles (default 20).
    """
    return _q(
        f"local s=game.surfaces['{surface}'] "
        "if not s then rcon.print('no such surface') return end "
        f"local ents=s.find_entities_filtered{{position={{x={x},y={y}}},radius={radius}}} "
        "local c={} for _,e in pairs(ents) do c[e.name]=(c[e.name] or 0)+1 end "
        "local parts={} for k,v in pairs(c) do parts[#parts+1]=v..'x '..k end "
        "table.sort(parts) "
        "rcon.print(#parts>0 and table.concat(parts,', ') or 'nothing nearby')"
    )


@mcp.tool()
def count_entities(surface: str, name: str, x: float, y: float, radius: float = 2.0) -> int:
    """Count entities of a given prototype name near a position."""
    with _LOCK:
        return _GW.count_entities(surface, name, x, y, radius)


@mcp.tool()
def list_surfaces() -> str:
    """List all surface names in the game (nauvis, platforms, etc.)."""
    return _q(
        "local t={} for _,s in pairs(game.surfaces) do t[#t+1]=s.name end "
        "table.sort(t) rcon.print(table.concat(t,', '))"
    )


# ----------------------------------------------------------------------
# Control tools — mutate the game / ai-player mod state
# ----------------------------------------------------------------------

@mcp.tool()
def spawn_ai_player() -> str:
    """Spawn or reset the ai-player character (requires the ai-player mod)."""
    with _LOCK:
        ok = _GW.spawn_ai_player()
    return "spawned" if ok else "ERROR: command failed"


@mcp.tool()
def remove_ai_player() -> str:
    """Destroy the ai-player character (requires the ai-player mod)."""
    with _LOCK:
        ok = _GW.remove_ai_player()
    return "removed" if ok else "ERROR: command failed"


@mcp.tool()
def server_status() -> str:
    """Whether the RCON socket is currently connected, plus configured target."""
    return (
        f"connected={_GW.connected} "
        f"target={_cfg.rcon.host}:{_cfg.rcon.port}"
    )


# ----------------------------------------------------------------------
# Skill tools — drive the AI character at the skill (Tier-1) altitude.
# Each call runs one bounded skill via the mod's "ai_player" remote interface
# and returns the skill's own actionable status. The mod owns all mechanics
# (placement legality, slot resolution, fuelling, patch-finding); the client
# only picks the skill + params. Requires the ai-player mod and a spawned
# character (use spawn_ai_player first).
# ----------------------------------------------------------------------

def _skill(name: str, **params) -> str:
    """Run a skill and format its ok/detail. Drops None params (use defaults)."""
    params = {k: v for k, v in params.items() if v is not None}
    with _LOCK:
        r = _GW.run_skill(name, params)
    return ("OK: " if r.get("ok") else "FAILED: ") + (r.get("detail") or "(no detail)")


@mcp.tool()
def gather(item: str, count: int = 50) -> str:
    """Mine the nearest sources of `item` until ~`count` are held (capped at 300).
    Handles wood (chops trees) and ores/rocks (mines by name). Bounded per call;
    returns what was gathered or why it couldn't (e.g. no source in range)."""
    return _skill("gather", item=item, count=count)


@mcp.tool()
def build_smelter(ore: str = "iron-ore", count: int = 2) -> str:
    """Place up to `count` stone furnaces (capped at 6), each set to smelt `ore`.
    Hand-crafts a furnace if none in inventory (retry next turn if it does)."""
    return _skill("build_smelter", ore=ore, count=count)


@mcp.tool()
def build_miner(resource: str = "iron-ore", output: str = "chest") -> str:
    """Place a burner mining drill on the nearest `resource` patch, dropping into
    'chest' or onto a 'belt'. Reports if no patch in range or placement blocked."""
    return _skill("build_miner", resource=resource, output=output)


@mcp.tool()
def fuel_all() -> str:
    """Distribute coal from the AI's inventory into all nearby burners that need
    fuel. Requires coal on hand; reports how many burners were fuelled."""
    return _skill("fuel_all")


@mcp.tool()
def build_ghosts() -> str:
    """Build any buildable ghost entities within range from the AI's inventory."""
    return _skill("build_ghosts")


@mcp.tool()
def deconstruct(radius: int = 96) -> str:
    """Mine everything marked for deconstruction within `radius` tiles (cap 200)."""
    return _skill("deconstruct", radius=radius)


@mcp.tool()
def loot_chests(radius: int = 32, items: str = "") -> str:
    """Pull items from nearby chests (any force) into the AI's inventory.
    Human→AI sharing: put coal/materials in a chest, then call this.
    AI restocking: call before build_ghosts when items are reported missing.
    items: comma-separated item names to restrict looting, e.g. 'coal,iron-plate'
           (empty = take everything from all reachable chests).
    radius: search radius in tiles (max 128)."""
    return _skill("loot_chests", radius=radius, items=items if items else None)


@mcp.tool()
def deposit_to_chest(radius: int = 32, keep: int = 50) -> str:
    """Deposit excess items from the AI's inventory into a nearby chest.
    Keeps `keep` of each item type; deposits the rest.
    Use for inventory management (clearing clutter) or AI→human resource sharing.
    radius: search radius in tiles (max 128)."""
    return _skill("deposit_to_chest", radius=radius, keep=keep)


@mcp.tool()
def build_plan(steps: list[dict], stop_on_error: bool = False) -> str:
    """Place many entities in one call. Each step: {item, position:{x,y},
    direction? ("north"/"east"/...), recipe?, insert? {"coal": 5}}, up to 100.
    Uses the same place/set_recipe/insert rules as the single actions, builds
    what is within build reach, then walks toward the first step that is not
    and returns; call again with the same steps to continue (steps already
    built are skipped, so repeating is safe). Items must be in the inventory."""
    return _skill("build_plan", steps=steps, stop_on_error=stop_on_error or None)


@mcp.tool()
def return_home() -> str:
    """Walk the AI character back to its home anchor (set on first spawn)."""
    return _skill("return_home")


@mcp.tool()
def research(tech: str = "") -> str:
    """Queue research for `tech` (or the next sensible tech if empty). Techs
    unlocked by crafting rather than labs are rejected with guidance."""
    return _skill("research", tech=tech or None)


@mcp.tool()
def list_skills() -> str:
    """List the AI character's available skill names (for discovery)."""
    with _LOCK:
        names = _GW.list_skills()
    return ", ".join(names) if names else "no skills (is the ai-player mod loaded?)"


@mcp.tool()
def get_factory_state() -> str:
    """Structured, registry-backed snapshot of the AI's situation — the same
    machine view the autonomous router sees, without the heavy local scan.
    Includes: character position/health/home-distance, full inventory, current
    research + progress, game phase (0-5), a scale-aware factory view (total,
    counts by_type and by_status, problem machines nearest-first in 'attention',
    plus a per-machine roster while the base is small), maintenance-need counts,
    ghost/deconstruction counts, and whether autonomy is on. Returned as JSON."""
    with _LOCK:
        state = _GW.get_factory_state()
    return json.dumps(state, indent=2, sort_keys=True)


@mcp.tool()
def set_autonomy(enabled: bool) -> str:
    """Enable or disable the mod's autonomous on-tick decision loop. Disable it
    while an external agent/harness drives the character through the skill tools
    so the built-in LLM router doesn't issue competing actions; re-enable to hand
    control back. Chat directives keep working either way. Returns the new state."""
    with _LOCK:
        r = _GW.set_autonomy(enabled)
    if "error" in r:
        return "ERROR: " + str(r["error"])
    return "autonomy " + ("ENABLED" if r.get("autonomy") else "DISABLED")


@mcp.tool()
def set_coop(enabled: bool) -> str:
    """Switch the AI between co-op and solo mode (reversible).
    Co-op (enabled=true): the AI joins the player force — it sees the human's
    whole base as its factory view, shares the power grid and all research, and
    its builds contribute to the shared base. Use this so the AI helps EXPAND
    the human's factory instead of bootstrapping a separate one. Fixes the
    "stuck bootstrapping" loop caused by force isolation.
    Solo (enabled=false): the AI runs on its own force and builds independently
    (use to task it on a self-contained outpost). Returns the new mode."""
    with _LOCK:
        r = _GW.set_coop(enabled)
    if "error" in r:
        return "ERROR: " + str(r["error"])
    return ("CO-OP (shares the player force — sees the base, shared power/research)"
            if r.get("coop") else "SOLO (own force)")


# ----------------------------------------------------------------------
# Query tools — read-only world/prototype lookups via the mod's query
# registry (mod/scripts/queries.lua). Unlike the generic reads above, these
# run inside the mod (remote interface), so they can reuse the same
# perception code the autonomous router uses. All return JSON.
# ----------------------------------------------------------------------

def _query(name: str, **params) -> str:
    """Run a mod query and return its result as JSON. Drops None params."""
    params = {k: v for k, v in params.items() if v is not None}
    with _LOCK:
        r = _GW.run_query(name, params)
    return json.dumps(r, indent=2, sort_keys=True)


@mcp.tool()
def get_recipe(name: str) -> str:
    """Recipe details: ingredients, products, craft time (energy, in seconds at
    speed 1), category, whether the force has it unlocked (enabled), and whether
    a character can hand-craft it (hand_craftable — false means it needs a
    machine, e.g. smelting needs a furnace). Use to plan multi-step crafts."""
    return _query("get_recipe", name=name)


@mcp.tool()
def get_resource_patch(resource: str, x: float | None = None, y: float | None = None,
                       radius: int = 48) -> str:
    """Bounding box, tile count, and total amount of a resource patch around a
    point (defaults to the AI character's position). resource: prototype name
    (iron-ore, copper-ore, coal, stone, crude-oil). Use the bbox to plan drill
    rows along the patch instead of guessing from the nearest tile."""
    return _query("get_resource_patch", resource=resource, x=x, y=y, radius=radius)


@mcp.tool()
def can_place(entity: str, x: float, y: float, direction: str = "north") -> str:
    """Check whether a manual build of `entity` at {x,y} would succeed, WITHOUT
    placing anything. Runs the same checks as place_entity (special rules like
    drill-on-resource and pump-on-water, then the engine's manual build check),
    so can_place=true means a subsequent place_entity will not be rejected.
    direction: north/south/east/west."""
    return _query("can_place", entity=entity, x=x, y=y, direction=direction)


@mcp.tool()
def nearest_buildable(entity: str, x: float | None = None, y: float | None = None,
                      radius: int = 32) -> str:
    """Nearest clear position where `entity` fits, spiralling out from a point
    (defaults to the AI character's position). Collision-only: for entities with
    placement rules beyond collision (mining drills need a resource patch,
    offshore pumps need water) plan with get_resource_patch/can_place instead."""
    return _query("nearest_buildable", entity=entity, x=x, y=y, radius=radius)


@mcp.tool()
def inspect_entity(x: float, y: float, name: str = "", radius: int = 4) -> str:
    """Full perception-grade detail of the entity nearest {x,y}: status, recipe,
    fuel/input/output contents, chest/lab/turret contents, fluid connection
    points, health, direction, and which inventory slots it has — the same view
    the autonomous router sees. name: optionally restrict to one prototype."""
    return _query("inspect_entity", x=x, y=y, name=name if name else None, radius=radius)


@mcp.tool()
def get_enemies(radius: int = 50, x: float | None = None, y: float | None = None) -> str:
    """Enemies around a point (defaults to the AI character's position),
    nearest-first with health and distance, plus a composition summary
    (units/spawners/worms) and a threat_level (safe/caution/danger)."""
    return _query("get_enemies", radius=radius, x=x, y=y)


@mcp.tool()
def analyze_factory(radius: int = 40, x: float | None = None, y: float | None = None) -> str:
    """One-call diagnosis of what is stuck around a point (defaults to the AI
    character's position): machines grouped by (name, problem) with the nearest
    sample position and, for starved crafters, the missing ingredient. Idle but
    healthy states (inserters waiting for items) are counted separately, so
    totals always add up. radius is capped at 150."""
    return _query("analyze_factory", radius=radius, x=x, y=y)


@mcp.tool()
def map_warnings(charted_only: bool = False) -> str:
    """The map screen's warning icons as one punch list: every machine of the
    force with a problem status across the whole surface, grouped by problem
    (most frequent first), nearest-first with positions. Idle-but-healthy
    inserters are listed last, separately. charted_only=true limits it to
    chunks the force has charted."""
    return _query("map_warnings", charted_only=charted_only)


@mcp.tool()
def production_stats(window: str = "1m", names: list[str] | None = None,
                     kind: str = "both", top: int = 20) -> str:
    """Item/fluid production and consumption of the force on the AI's surface,
    like the in-game production statistics window. Rates are per minute over
    window (5s, 1m, 10m, 1h, 10h, 50h, 250h, 1000h); also all-time totals.
    names restricts to specific items/fluids; kind is item, fluid or both;
    rows are sorted by the larger of produced/consumed rate, capped at top."""
    return _query("production_stats", window=window, names=names, kind=kind, top=top)


@mcp.tool()
def map_view(x: float | None = None, y: float | None = None, radius: int = 20,
             to_x: float | None = None, to_y: float | None = None) -> str:
    """Character-grid map of the area around (x, y) (default: the AI character),
    one glyph per tile, radius 4-40: water ~, trees T, rocks R, cliffs C, ore
    f/c/k/s/u/O, belts as arrows, buildings by letter, ghosts g, the character @,
    unexplored ? (fog). Give to_x/to_y to trace the DIRECT line (*) and learn
    what lies on it (water, a tree, a building); goto routes around such things
    by pathfinding, so this shows how much of a detour to expect, and whether the
    target is even on the same side of a lake. The legend is in the result."""
    r = json.loads(_query("map_view", x=x, y=y, radius=radius, to_x=to_x, to_y=to_y))
    if "text" not in r:
        return json.dumps(r, indent=2)
    meta = {k: r[k] for k in ("character", "path", "note") if r.get(k) is not None}
    return r["text"] + "\n\nlegend: " + json.dumps(r["legend"], sort_keys=True) + "\n" + json.dumps(meta)


@mcp.tool()
def belt_line(at: float, start: float, end: float, horizontal: bool = True) -> str:
    """Walk a belt row tile by tile and report gaps/obstructions, each belt's
    direction and per-lane contents. horizontal=True scans tile row y=at from tile x=start to
    x=end; False scans tile column x=at from y=start to y=end (tile
    coordinates = floor of the position; span capped at 300). A gap
    or an unexpected direction cuts a line in half (often a pole dropped on the
    row); one packed lane next to an empty one means a bad side-load."""
    return _query("belt_line", at=at, **{"from": start}, to=end, horizontal=horizontal)


@mcp.tool()
def inserter_at(x: float, y: float) -> str:
    """Resolved pickup and drop positions of the inserter at (x, y) and what
    stands on each. An inserter's direction names the side it PICKS UP from;
    it drops on the opposite side, so this is the reliable wiring check."""
    return _query("inserter_at", x=x, y=y)


@mcp.tool()
def power_report() -> str:
    """Generation vs capacity (MW) and every electric-pole network on the
    surface with pole count and bounding box. More than one network means
    something is islanded, the usual cause of a built block sitting at no_power."""
    return _query("power_report")


@mcp.tool()
def silo_status() -> str:
    """Rocket silos of the force on the AI's surface: rocket parts built, phase,
    whether the rocket is ready to launch, status and cargo, plus the launches
    recorded so far (tick, silo, cargo)."""
    return _query("silo_status")


@mcp.tool()
def platforms() -> str:
    """Space Age: every space platform of the force: state, paused, speed,
    location (at a planet or between two), schedule stops and hub items."""
    return _query("platforms")


@mcp.tool()
def launch_rocket(x: float | None = None, y: float | None = None) -> str:
    """Walk to the nearest rocket silo (or the one nearest {x,y}) and launch its
    rocket. Fails with the parts count until the silo has built the rocket; a
    rocket still rising says so (call again). Cargo is whatever was inserted
    into the silo."""
    return _skill("launch_rocket", position={"x": x, "y": y} if x is not None and y is not None else None)


@mcp.tool()
def layout_context(area: list[float] | None = None, points: list[dict] | None = None) -> str:
    """What a build check needs about ground a plan will join: belts in
    area = [x1, y1, x2, y2] (direction, underground type), mining drills with the
    one tile each outputs onto and what stands there, and the entity standing at
    each of points = [{x, y}]. Respects fog of war."""
    return _query("layout_context", area=area, points=points)


@mcp.tool()
def order_platform(name: str) -> str:
    """Space Age: order a new space platform above the planet the AI stands on.
    Needs rocket-silo research; the platform waits for a starter pack that a
    silo launches."""
    return _skill("order_platform", name=name)


@mcp.tool()
def equip(gun: str | None = None, ammo: str | None = None, armor: str | None = None) -> str:
    """Put items from the AI's inventory into its gun / ammo / armor slots (a new
    gun takes an empty slot, ammo tops up the paired slot to one stack, armor
    swaps; the old item returns to the inventory). Nothing is created."""
    return _skill("equip", gun=gun, ammo=ammo, armor=armor)


@mcp.tool()
def supply_turrets(ammo: str, per_turret: int = 10, radius: int = 40) -> str:
    """Load ammo from the AI's inventory into its gun turrets within radius that
    hold fewer than per_turret rounds; walks to the nearest turret out of reach
    (call again to continue)."""
    return _skill("supply_turrets", ammo=ammo, per_turret=per_turret, radius=radius)


@mcp.tool()
def queue_jobs(steps: list[dict], on_fail: str = "stop") -> str:
    """Queue skills to run one after another in the background. steps = [{"skill":
    "gather","item":"coal","count":20}, {"skill":"goto","position":{"x":0,"y":0}},
    {"wait": 5}]. While a walk or drive is running it waits; a skill that answers
    "out of reach — call me again" is re-run after the walk (up to 25 attempts).
    on_fail "stop" (default) drops the rest after a failed step, "continue" skips
    it. At most 50 steps; see job_status."""
    return _skill("queue_jobs", steps=steps, on_fail=on_fail)


@mcp.tool()
def cancel_jobs() -> str:
    """Clear the background job queue (the current step and everything waiting) and
    stop a walk in progress."""
    return _skill("cancel_jobs")


@mcp.tool()
def job_status() -> str:
    """The background job queue: current step (and how many attempts it has used),
    waiting steps, the last 20 results and the on_fail mode."""
    return _query("job_status")


@mcp.tool()
def platform_build(platform: str, steps: list[dict]) -> str:
    """Space Age: place ghosts on a platform (the hub builds them from its own
    inventory). steps = [{name, x, y, direction?, recipe?}]; name is an item or
    entity, space-platform-foundation places a floor tile ghost. Floor must grow
    outward from existing floor, in order. Up to 400 steps; rejects are listed."""
    return _skill("platform_build", platform=platform, steps=steps)


@mcp.tool()
def platform_deconstruct(platform: str, x1: float, y1: float, x2: float, y2: float,
                         names: list[str] | None = None) -> str:
    """Space Age: mark buildings of the force in an area of a platform for
    deconstruction (the hub takes them back); ghosts in the area are removed. The
    hub itself is never touched. names optionally filters."""
    return _skill("platform_deconstruct", platform=platform, x1=x1, y1=y1, x2=x2, y2=y2, names=names)


@mcp.tool()
def platform_configure(platform: str, x: float, y: float, recipe: str | None = None,
                       filters: list[str] | None = None, direction: int | None = None) -> str:
    """Space Age: set the recipe, filters (inserters; asteroid chunk names for
    asteroid collectors) and/or direction of the building or ghost at (x, y) on a
    platform, like clicking it in remote view."""
    return _skill("platform_configure", platform=platform, x=x, y=y, recipe=recipe, filters=filters, direction=direction)


@mcp.tool()
def platform_requests(platform: str, items: dict, import_from: str | None = None) -> str:
    """Space Age: set what the platform hub requests (rockets bring it up),
    replacing the first manual request section. items = {name: count}; {} clears.
    import_from is the planet to import from (default the one it is parked at)."""
    return _skill("platform_requests", platform=platform, items=items, import_from=import_from)


@mcp.tool()
def landing_pad_requests(x: float, y: float, items: dict) -> str:
    """Space Age: set what a cargo landing pad at (x, y) asks for; platforms
    parked above the planet holding those items drop them down in cargo pods.
    items = {name: count}; {} clears."""
    return _skill("landing_pad_requests", x=x, y=y, items=items)


@mcp.tool()
def chest_requests(x: float, y: float, items: dict) -> str:
    """Set what the requester or buffer chest at (x, y) asks the logistic network
    for. items = {name: count}; {} clears."""
    return _skill("chest_requests", x=x, y=y, items=items)


@mcp.tool()
def platform_schedule(platform: str, stops: list[dict] | None = None, paused: bool | None = None) -> str:
    """Space Age: set a platform's schedule, stops = [{planet, wait}] with wait a
    number of seconds or "requests" (all hub requests satisfied), and/or pause or
    resume its thrust with paused."""
    return _skill("platform_schedule", platform=platform, stops=stops, paused=paused)


@mcp.tool()
def drop_to_planet(x: float | None = None, y: float | None = None) -> str:
    """Space Age: from a platform parked at a planet, ride a cargo pod down to that
    planet's surface (near x, y when given)."""
    position = {"x": x, "y": y} if x is not None and y is not None else None
    return _skill("drop_to_planet", position=position)


@mcp.tool()
def map_overview(center_x: float | None = None, center_y: float | None = None, radius: int = 320) -> str:
    """What the map screen would show, at chunk resolution, over known ground
    (radius 32-640 around the AI or a center): resource patches per ore, rocks,
    forests, water and enemy bases, each grouped into connected chunk areas
    with a centre, a bounding box, a size, an `at` tile on the patch to goto/scan
    and the distance from the AI. Nearest first, at most 60 groups."""
    center = {"x": center_x, "y": center_y} if center_x is not None and center_y is not None else None
    return _query("map_overview", center=center, radius=radius)


@mcp.tool()
def alerts() -> str:
    """The in-game alert panel (turret out of ammo, entity destroyed, no power,
    ...) grouped by type, oldest first. Needs a connected human player on the
    force; headless it says so — battle_report is the headless equivalent."""
    return _query("alerts")


@mcp.tool()
def find_buildable_area(width: int, height: int, near_x: float, near_y: float, max_distance: int = 50) -> str:
    """Nearest clear width x height rectangle of explored ground to (near_x,
    near_y): no water and nothing standing in it (trees are allowed and counted
    in trees_in_area, ore tiles count as occupied). Searches outward in rings up
    to max_distance (max 100). Use it to site a build before build_plan."""
    return _query("find_buildable_area", width=width, height=height, near={"x": near_x, "y": near_y},
                  max_distance=max_distance)


@mcp.tool()
def describe_prototype(names: list[str]) -> str:
    """Facts about up to 10 names at once: for each, the item (stack size, fuel
    value), the entity it places (tile size, energy source, power kW, crafting
    speed, mining area, inserter pickup/drop offsets, drill output offset, fluid
    connections as pipe offsets), the recipe that makes it and the fluid.
    Geometry offsets are for the entity facing north."""
    return _query("describe_prototype", names=names)


@mcp.tool()
def route_belt(start: dict, end: dict, belt: str | None = None, underground: str | None = None,
               allow_underground: bool | None = None, clear_obstacles: bool = False,
               margin: int = 12, through_inserters: bool = False) -> str:
    """Plan a belt between two endpoints on the real map with weighted A* (turns
    and undergrounds cost extra, existing belts/machines/water are avoided) and
    return build steps for build_plan. Endpoints are {x, y} plus optional
    port: tile (default), drop (a drill/inserter output), pickup (an inserter's
    pickup tile), belt (join an existing belt: from continues it, to feeds or
    side-loads it) and optional direction. clear_obstacles lets the route go
    through trees/rocks (listed in mine_first). The result has steps, bill vs
    inventory, notes on how it joins other belts, and the detour taken to avoid
    inserter tiles. Read-only: nothing is built."""
    return _query("route_belt", **{"from": start}, to=end, belt=belt, underground=underground,
                  allow_underground=allow_underground, clear_obstacles=clear_obstacles,
                  margin=margin, through_inserters=through_inserters)


@mcp.tool()
def route_pipe(start: dict, end: dict, pipe: str | None = None, underground: str | None = None,
               allow_underground: bool | None = None, clear_obstacles: bool = False, margin: int = 12) -> str:
    """Like route_belt for pipes (pipe-to-ground for crossings). Endpoints may use
    port "fluid": the first unconnected fluid connection of the entity at x,y.
    Returns build steps for build_plan; nothing is built."""
    return _query("route_pipe", **{"from": start}, to=end, pipe=pipe, underground=underground,
                  allow_underground=allow_underground, clear_obstacles=clear_obstacles, margin=margin)


@mcp.tool()
def list_registered_blueprints() -> str:
    """Blueprint provenance registry: layouts made during this run (exported
    from the map or compiled from the agent's own layout), oldest first, and
    whether import_blueprint enforces it (mod setting
    ai-player-enforce-blueprint-provenance)."""
    return _query("list_registered_blueprints")


@mcp.tool()
def trace_belt(x: float, y: float) -> str:
    """Follow the belt line through the tile at (x, y) both ways: legs (runs of
    one direction, with lane fill %), how it starts and ends (dead end, what it
    faces, unpaired underground), what feeds it and takes from it, lane capacity.
    Use it when items stop flowing; complements belt_line."""
    return _query("trace_belt", x=x, y=y)


@mcp.tool()
def list_trains() -> str:
    """Trains on the AI's surface (state, locomotives/wagons, position, station,
    schedule, cargo) and the names of the force's train stops — the only valid
    targets for set_train_schedule."""
    return _query("list_trains")


@mcp.tool()
def set_train_schedule(train_id: int, stops: list[dict]) -> str:
    """Give a train a schedule: stops = [{"station": "Name", "wait": "full" |
    "empty" | seconds}] (default wait 5 s). Station names must be existing train
    stops. Sets the train to automatic and warns if no locomotive has fuel."""
    return _skill("set_train_schedule", train_id=train_id, stops=stops)


@mcp.tool()
def list_technologies(status: str = "available", search: str | None = None, limit: int = 60) -> str:
    """The tech tree with the exact names `research` takes. status: researched,
    in-progress, queued, available, trigger (completes by doing something, the
    action is listed), locked or all. Each row has prerequisites (and which are
    missing), the total science bill and seconds per unit. Also the live queue
    and per-status counts. search filters by name substring."""
    return _query("list_technologies", status=status, search=search, limit=limit)


@mcp.tool()
def cancel_research(tech: str) -> str:
    """Remove a queued technology that has not started. The research in progress
    cannot be cancelled (its progress would be lost)."""
    return _skill("cancel_research", tech=tech)


@mcp.tool()
def drive_to(x: float, y: float, arrive_within: float = 3) -> str:
    """Walk to the nearest free car of the AI's force (within 30 tiles), fuel it
    from the AI's inventory, and drive it to (x, y). Asynchronous: the result
    (parked/failed) shows up in the next action results. Cars do not path around
    lakes or forests; on "stuck" use goto, which pathfinds."""
    return _skill("drive_to", position={"x": x, "y": y}, arrive_within=arrive_within)


@mcp.tool()
def exit_vehicle() -> str:
    """Get the AI out of the vehicle it is driving."""
    return _skill("exit_vehicle")


@mcp.tool()
def battle_report() -> str:
    """Defence picture in one call: own entities below max health, turrets with
    no ammo, and enemy clusters (size, top names, centre) with the distance to
    the nearest own entity, nearest first."""
    return _query("battle_report")


@mcp.tool()
def get_character_state() -> str:
    """Live embodiment state of the AI character: position, health, walking and
    mining flags, home anchor distance, and the HAND-CRAFTING QUEUE with
    progress — the only surface that shows what is mid-craft. Check this when a
    craft was queued but the item never appeared."""
    return _query("get_character_state")


# ----------------------------------------------------------------------
# Primitive tools — surgical Tier-0 actions via the mod's AIActions dispatch
# (the same handlers the bridge LLM uses). Use these for one-off operations
# no skill covers; prefer the skill tools for multi-step work. All require a
# spawned character (spawn_ai_player first).
# ----------------------------------------------------------------------

def _primitive(action: str, **fields) -> str:
    """Run one primitive action and format its ok/detail. Drops None fields."""
    fields = {k: v for k, v in fields.items() if v is not None}
    fields["action"] = action
    with _LOCK:
        r = _GW.run_primitive(fields)
    return ("OK: " if r.get("ok") else "FAILED: ") + (r.get("detail") or "(no detail)")


@mcp.tool()
def place_entity(item: str, x: float, y: float, direction: str = "north") -> str:
    """Place one `item` from the AI's inventory at {x,y} (validated as a legal
    manual build first — use can_place to pre-check). direction: north/south/
    east/west. Fails with the reason if the item is missing or the spot is
    blocked/misaligned/on the wrong tile."""
    return _primitive("place", item=item, position={"x": x, "y": y}, direction=direction)


@mcp.tool()
def mine_entity(x: float, y: float, name: str = "", type: str = "", radius: int = 4) -> str:
    """Mine the nearest minable entity within `radius` of {x,y} into the AI's
    inventory. Optionally filter by prototype `name` (e.g. 'stone-furnace') or
    `type` (e.g. 'tree' — tree prototypes are never literally named 'tree').
    One entity/resource unit per call; use the gather skill for bulk mining."""
    return _primitive("mine", position={"x": x, "y": y},
                      name=name if name else None, type=type if type else None,
                      radius=radius)


@mcp.tool()
def craft_item(recipe: str, count: int = 1) -> str:
    """Start hand-crafting `count` x `recipe` on the AI character. Only works
    for hand-craftable recipes (get_recipe: hand_craftable) with ingredients on
    hand. Crafting takes in-game time — poll get_character_state to see the
    queue drain."""
    return _primitive("craft", recipe=recipe, count=count)


@mcp.tool()
def set_recipe(recipe: str, x: float, y: float) -> str:
    """Set the recipe on the assembling machine / furnace nearest {x,y}. Needed
    before an assembler will accept ingredients."""
    return _primitive("set_recipe", recipe=recipe, position={"x": x, "y": y})


@mcp.tool()
def insert_items(item: str, count: int, x: float, y: float, slot: str = "") -> str:
    """Move `count` x `item` from the AI's inventory into the building nearest
    {x,y}. slot: fuel / input / output / chest / lab / ammo (empty = guess from
    the entity type). E.g. coal goes in 'fuel', ore in 'input'. Fails with the
    reason if the AI lacks the item or the target slot won't accept it."""
    return _primitive("insert", item=item, count=count, position={"x": x, "y": y},
                      inventory=slot if slot else None)


@mcp.tool()
def take_items(item: str, count: int, x: float, y: float, slot: str = "") -> str:
    """Take `count` x `item` from the building nearest {x,y} into the AI's
    inventory. slot: fuel / input / output / chest / lab / ammo (empty = guess).
    E.g. take smelted plates from a furnace's 'output'."""
    return _primitive("take", item=item, count=count, position={"x": x, "y": y},
                      inventory=slot if slot else None)


@mcp.tool()
def say(message: str) -> str:
    """Send a chat message to the game as the AI player (visible to everyone).
    Respects the mod's 'enable chat' setting — if disabled, nothing is printed."""
    return _primitive("chat", message=message)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    # Best-effort eager connect so the first tool call isn't slow; _send()
    # auto-reconnects anyway if this fails or the socket drops later.
    if _GW.connect():
        log.info("RCON connected to %s:%d", _cfg.rcon.host, _cfg.rcon.port)
    else:
        log.warning(
            "RCON not reachable at %s:%d yet — tools will retry on first call",
            _cfg.rcon.host, _cfg.rcon.port,
        )
    mcp.run()  # stdio transport


if __name__ == "__main__":
    main()
