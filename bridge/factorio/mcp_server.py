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
