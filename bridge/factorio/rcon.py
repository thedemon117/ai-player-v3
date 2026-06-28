"""
RCON gateway — the only place in the codebase that holds a socket to Factorio.

RCONGateway wraps factorio-rcon with:
  - Automatic reconnect on connection drop
  - Typed methods per command (no raw string building outside this file)
  - JSON serialisation of action lists before sending

Factorio RCON commands used:
  /ai-response <id>|<json>   — deliver LLM response to the mod
  /sc <lua>                  — run arbitrary Lua; use rcon.print() to return values
  /spawn-ai-player           — spawn or reset the AI character
  /remove-ai-player          — destroy the AI character
  /ai-pending                — list pending requests (debug)
"""

import json
import logging
import time
from typing import Optional

log = logging.getLogger(__name__)

_RECONNECT_DELAY = 2.0   # seconds between reconnect attempts
_MAX_COMMAND_LEN = 65535 # Factorio RCON hard limit


def _lua_value(v) -> str:
    """Serialise a Python scalar to a Lua literal (for run_skill params)."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    # String: single-quote and escape backslashes/quotes so it survives /sc.
    s = str(v).replace("\\", "\\\\").replace("'", "\\'")
    return f"'{s}'"


def _lua_table(params: dict) -> str:
    """Serialise a flat dict to a Lua table literal, e.g. {item='coal',count=50}.
    Keys are skill param names (item/count/ore/resource/output/radius/tech) —
    valid bare Lua identifiers, so they need no quoting."""
    return "{" + ",".join(f"{k}={_lua_value(v)}" for k, v in params.items()) + "}"


class RCONGateway:
    def __init__(self, host: str, port: int, password: str):
        self._host = host
        self._port = port
        self._password = password
        self._client = None

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------

    def connect(self) -> bool:
        """Attempt to connect. Returns True on success."""
        try:
            from factorio_rcon import RCONClient
        except ImportError:
            log.error("factorio-rcon not installed — run: pip install factorio-rcon")
            return False

        try:
            self._client = RCONClient(self._host, self._port, self._password)
            log.info("RCON connected to %s:%d", self._host, self._port)
            return True
        except Exception as e:
            log.warning("RCON connect failed (%s:%d): %s", self._host, self._port, e)
            self._client = None
            return False

    def disconnect(self):
        self._client = None

    def reconnect(self, settings: Optional[tuple[str, int, str]] = None) -> bool:
        """
        Reconnect, optionally updating host/port/password first.
        settings: (host, port, password) tuple, or None to reuse current values.
        """
        if settings:
            self._host, self._port, self._password = settings
        self._client = None
        time.sleep(_RECONNECT_DELAY)
        return self.connect()

    @property
    def connected(self) -> bool:
        return self._client is not None

    # ------------------------------------------------------------------
    # Internal send with one auto-reconnect retry
    # ------------------------------------------------------------------

    def _send(self, command: str) -> str | None:
        if len(command) > _MAX_COMMAND_LEN:
            log.error("Command exceeds RCON limit (%d chars), dropping", len(command))
            return None

        for attempt in range(2):
            if not self._client:
                if not self.connect():
                    log.error("RCON not connected — cannot send command")
                    return None
            try:
                result = self._client.send_command(command)
                # Library returns None when command succeeds but produces no output.
                # Convert to "" so callers can use `None` to mean "send failed".
                return result if result is not None else ""
            except Exception as e:
                log.warning("RCON send failed (attempt %d): %s", attempt + 1, e)
                self._client = None

        log.error("RCON send failed after retry — command dropped")
        return None

    # ------------------------------------------------------------------
    # Typed command methods
    # ------------------------------------------------------------------

    def send_ai_response(self, req_id: str, actions: list[dict]) -> bool:
        """
        Deliver an action list to the Factorio mod.
        Actions are serialised to JSON and sent via /ai-response.
        Returns True if the command was sent (not necessarily processed).
        """
        try:
            actions_json = json.dumps(actions, separators=(",", ":"))
        except (TypeError, ValueError) as e:
            log.error("Failed to serialise actions: %s", e)
            return False

        command = f"/ai-response {req_id}|{actions_json}"
        result = self._send(command)
        if result is None:
            log.error("Failed to send ai-response for request %s", req_id)
            return False

        log.debug("ai-response sent: req=%s actions=%d", req_id, len(actions))
        return True

    def query_lua(self, lua_code: str) -> str | None:
        """
        Run arbitrary Lua in Factorio and return printed output.

        The Lua code must use rcon.print() to return a value:
            query_lua('rcon.print(game.tick)')

        Returns the printed string, or None on failure.
        """
        result = self._send(f"/sc {lua_code}")
        return result

    def spawn_ai_player(self) -> bool:
        """Spawn or reset the AI character."""
        result = self._send("/spawn-ai-player")
        return result is not None

    def remove_ai_player(self) -> bool:
        """Destroy the AI character."""
        result = self._send("/remove-ai-player")
        return result is not None

    def list_pending(self) -> str | None:
        """Return pending request info (debug)."""
        return self._send("/ai-pending")

    def clear_pending_requests(self) -> bool:
        """
        Clear all pending requests from the mod's queue.

        The mod does this automatically on on_configuration_changed (F5 / mod reload)
        and on_load (save loaded). Call this when the bridge restarts while Factorio
        keeps running — old request IDs are stale and the mod would block indefinitely
        waiting for responses that will never arrive.
        """
        lua = (
            "if storage.ai_player then "
            "local n=0 "
            "for _ in pairs(storage.ai_player.pending_requests) do n=n+1 end "
            "storage.ai_player.pending_requests={} "
            "game.print('[AI Bridge] Cleared '..n..' pending request(s)') "
            "else game.print('[AI Bridge] No AI state to clear') end"
        )
        result = self.query_lua(lua)
        if result is not None:
            log.info("clear_pending_requests: %s", result.strip())
            return True
        return False

    def set_request_timeout(self, seconds: float) -> bool:
        """
        Tell the mod how long to wait for a bridge response before discarding a
        pending request. Derived from the bridge SDK timeout (AI_TIMEOUT + margin)
        so the mod never expires a request before the model's allotted reply time.
        Single source of truth = AI_TIMEOUT in the bridge.
        """
        ticks = int(seconds * 60)
        lua = (
            "if storage.ai_player then "
            f"storage.ai_player.request_timeout_ticks={ticks} "
            f"game.print('[AI Bridge] Request timeout set to {int(seconds)}s') "
            "else game.print('[AI Bridge] No AI state to configure') end"
        )
        result = self.query_lua(lua)
        if result is not None:
            log.info("set_request_timeout: %ds (%d ticks)", int(seconds), ticks)
            return True
        return False

    def clear_memory(self) -> bool:
        """
        Reset the AI's in-game memory: notes, todo lists, and previous summary.

        Does NOT touch the character, pending requests, or chat log.
        Useful at the start of a new play session when old notes/todos are stale.
        """
        lua = (
            "if storage.ai_player and storage.ai_player.memory then "
            "storage.ai_player.memory.notes={} "
            "storage.ai_player.memory.todo_lists={} "
            "storage.ai_player.memory.previous_summary=nil "
            "storage.ai_player.memory.user_directive=nil "
            "storage.ai_player.memory.directive_expire_tick=nil "
            "game.print('[AI Bridge] Memory cleared (notes, todos, summary, directive)') "
            "else game.print('[AI Bridge] No AI memory to clear') end"
        )
        result = self.query_lua(lua)
        if result is not None:
            log.info("clear_memory: %s", result.strip())
            return True
        return False

    # ------------------------------------------------------------------
    # Skill invocation (used by the MCP server to drive the AI character)
    # ------------------------------------------------------------------

    def run_skill(self, skill: str, params: Optional[dict] = None) -> dict:
        """
        Invoke an ai-player skill against the AI character via the mod's
        "ai_player" remote interface. Reuses the same dispatch path the bridge
        uses (AISkills.run -> REGISTRY), so mechanics stay in one place.

        Returns {'ok': bool, 'detail': str}. 'detail' is the skill's own
        actionable status string (e.g. "gathered 50 coal (now have 73)") or an
        error explaining why the call could not be made.
        """
        params = params or {}
        lua = (
            "rcon.print(helpers.table_to_json(remote.call("
            f"'ai_player','run_skill',{_lua_value(skill)},{_lua_table(params)})))"
        )
        result = self.query_lua(lua)
        if result is None:
            return {"ok": False, "detail": "ERROR: RCON send failed (is Factorio running?)"}
        result = result.strip()
        try:
            data = json.loads(result)
        except (ValueError, TypeError):
            # Old mod without the remote interface, or a Lua error — surface it.
            return {"ok": False, "detail": f"no skill result (is the mod loaded?): {result[:200]}"}
        return {"ok": bool(data.get("ok")), "detail": str(data.get("detail", ""))}

    def list_skills(self) -> list[str]:
        """Return the AI's valid skill names via the remote interface."""
        lua = (
            "rcon.print(helpers.table_to_json("
            "remote.call('ai_player','list_skills')))"
        )
        result = self.query_lua(lua)
        if not result:
            return []
        try:
            data = json.loads(result.strip())
            return list(data) if isinstance(data, list) else []
        except (ValueError, TypeError):
            return []

    def get_factory_state(self) -> dict:
        """
        Compact, registry-backed situation snapshot via the remote interface
        (perception.lua factory_state): character, inventory, research, game
        phase, scale-aware factory view, maintenance-need counts, autonomy.
        Returns the parsed dict, or {'error': ...} on failure.
        """
        lua = (
            "rcon.print(helpers.table_to_json("
            "remote.call('ai_player','get_state')))"
        )
        result = self.query_lua(lua)
        if result is None:
            return {"error": "RCON send failed (is Factorio running?)"}
        try:
            return json.loads(result.strip())
        except (ValueError, TypeError):
            return {"error": f"no state (is the mod loaded?): {result.strip()[:200]}"}

    def set_autonomy(self, enabled: bool) -> dict:
        """
        Enable/disable the mod's autonomous on_tick decision loop via the remote
        interface. Returns {'autonomy': bool} (the new state), or {'error': ...}.
        """
        lua = (
            "rcon.print(helpers.table_to_json(remote.call("
            f"'ai_player','set_autonomy',{_lua_value(enabled)})))"
        )
        result = self.query_lua(lua)
        if result is None:
            return {"error": "RCON send failed (is Factorio running?)"}
        try:
            return json.loads(result.strip())
        except (ValueError, TypeError):
            return {"error": f"no result (is the mod loaded?): {result.strip()[:200]}"}

    def set_coop(self, enabled: bool) -> dict:
        """
        Switch the AI between co-op (rides the player force — shared base view,
        power, research) and solo (own force) via the remote interface. Returns
        {'coop': bool, 'force': str} (the new mode), or {'error': ...}.
        """
        lua = (
            "rcon.print(helpers.table_to_json(remote.call("
            f"'ai_player','set_coop',{_lua_value(enabled)})))"
        )
        result = self.query_lua(lua)
        if result is None:
            return {"error": "RCON send failed (is Factorio running?)"}
        try:
            return json.loads(result.strip())
        except (ValueError, TypeError):
            return {"error": f"no result (is the mod loaded?): {result.strip()[:200]}"}

    # ------------------------------------------------------------------
    # Convenience Lua queries (used by verification loop)
    # ------------------------------------------------------------------

    def count_entities(self, surface: str, entity_name: str, x: float, y: float, radius: float = 2.0) -> int:
        """
        Count entities of a given name near a position.
        Used to verify place/mine actions actually took effect.
        """
        lua = (
            f"local s=game.surfaces['{surface}'] "
            f"local n=s.count_entities_filtered{{name='{entity_name}',"
            f"position={{x={x},y={y}}},radius={radius}}} "
            f"rcon.print(n)"
        )
        result = self.query_lua(lua)
        try:
            return int(result or "0")
        except ValueError:
            return 0

    def get_entity_status(self, surface: str, entity_name: str, x: float, y: float, radius: float = 2.0) -> str | None:
        """
        Return the status string of the nearest named entity at a position.
        Used to verify insert/fuel actions.
        """
        lua = (
            f"local s=game.surfaces['{surface}'] "
            f"local e=s.find_entity('{entity_name}',{{x={x},y={y}}}) "
            f"if e then rcon.print(e.status and defines.entity_status[e.status] or 'unknown') "
            f"else rcon.print('not_found') end"
        )
        return self.query_lua(lua)

    def get_inventory_count(self, surface: str, entity_name: str, x: float, y: float,
                            slot_lua: str, item_name: str) -> int:
        """
        Return item count in a specific inventory slot of a nearby entity.
        slot_lua: e.g. 'e:get_fuel_inventory()' or 'e:get_output_inventory()'
        """
        lua = (
            f"local s=game.surfaces['{surface}'] "
            f"local e=s.find_entity('{entity_name}',{{x={x},y={y}}}) "
            f"if e then local inv={slot_lua} "
            f"rcon.print(inv and inv.get_item_count('{item_name}') or 0) "
            f"else rcon.print(0) end"
        )
        result = self.query_lua(lua)
        try:
            return int(result or "0")
        except ValueError:
            return 0
