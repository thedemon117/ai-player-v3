"""
Router agent (v3).

Agent.decide() builds the small router prompt from raw perception, calls the
LLM, parses + validates the response into a list of skill/primitive entries,
and returns it. Skills are validated against api.SKILLS, primitives against
api.ACTIONS (see factorio/api.py). Stateless between calls.
"""

import logging
import time

from .config import BridgeConfig
from .factorio.api import parse_response
from .factorio.watcher import PendingRequest
from .prompt import build_messages
from .providers import get_provider
from .transcript import log_exchange

log = logging.getLogger(__name__)


def _fallback(reason: str) -> list[dict]:
    """Safe response so the mod never hangs; the summary states the real reason."""
    return [
        {"action": "wait"},
        {"action": "summary", "text": f"No action this turn — {reason}."},
    ]


class Agent:
    def decide(self, req: PendingRequest, config: BridgeConfig) -> list[dict]:
        provider_cfg = config.to_provider_config()
        complete = get_provider(provider_cfg)

        payload = req.payload
        if "perception" not in payload:
            log.error("Request %s: no 'perception' in payload — fallback", req.req_id)
            return _fallback("internal error: request had no perception")

        messages = build_messages(payload, config.system_prefix)

        log.info("Routing request %s via %s (model=%s)",
                 req.req_id, provider_cfg.provider, provider_cfg.model)
        t0 = time.monotonic()
        content = complete(messages, provider_cfg)
        elapsed = time.monotonic() - t0

        if content is None:
            log.error("Request %s: no response after %.1fs (timeout=%.0fs) — fallback. "
                      "Raise AI_TIMEOUT or use a faster model.",
                      req.req_id, elapsed, provider_cfg.timeout)
            actions = _fallback(f"model did not respond within {provider_cfg.timeout:.0f}s "
                                f"(raise AI_TIMEOUT or use a faster model)")
            log_exchange(config.output_dir, req.req_id, messages, None, elapsed, actions)
            return actions

        log.info("Request %s: response in %.1fs (%d chars)", req.req_id, elapsed, len(content))
        log.debug("Request %s raw: %s", req.req_id, content[:600])

        entries = parse_response(content)
        if entries is None:
            log.warning("Request %s: could not parse skills/actions — fallback. Raw: %s",
                        req.req_id, content[:600])
            log_exchange(config.output_dir, req.req_id, messages, content, elapsed, None)
            return _fallback("could not parse a valid skill/action array from the model's reply")

        entries = self._ensure_chat_ack(req, entries)
        log.info("Request %s: %d entr(ies) [%s]", req.req_id, len(entries),
                 ", ".join(e.get("skill") or e.get("action", "?") for e in entries))
        log_exchange(config.output_dir, req.req_id, messages, content, elapsed, entries)
        return entries

    def _ensure_chat_ack(self, req: PendingRequest, entries: list[dict]) -> list[dict]:
        """Guarantee a chat reply when the player spoke and the model didn't."""
        user_message = req.payload.get("user_message")
        if not user_message:
            return entries
        if any(e.get("action") == "chat" for e in entries):
            return entries
        return [{"action": "chat", "message": f"Got it: {user_message}"}] + entries
