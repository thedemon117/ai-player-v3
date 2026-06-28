"""
Prompt/response transcript log (v3).

Writes a human-readable record of every LLM exchange to `chat.log` in the
Factorio script-output dir — the same place bridge.log lives — mirroring the
`chat.log` the original ai-player kept. This is the primary tool for diagnosing
*why* the router picked a given skill: it captures the exact prompt the model
saw (system + assembled game state) and its raw reply, plus what we parsed out.

Deliberately dependency-free and best-effort: any failure here is swallowed so
transcript logging can never break a decision. One file, appended to, newest at
the bottom — `tail -f chat.log` to watch the agent think in real time.
"""

import logging
import time
from pathlib import Path

log = logging.getLogger(__name__)

_SEP = "=" * 80


def log_exchange(
    output_dir: Path,
    req_id: str,
    messages: list[dict],
    content: str | None,
    elapsed: float,
    entries: list[dict] | None,
) -> None:
    """Append one prompt→response exchange to chat.log. Never raises."""
    try:
        lines = [_SEP, f"[{time.strftime('%H:%M:%S')}] request {req_id}"]

        for msg in messages:
            role = str(msg.get("role", "?")).upper()
            lines.append(f"--- PROMPT ({role}) ---")
            lines.append(str(msg.get("content", "")).rstrip())

        if content is None:
            lines.append(f"--- RESPONSE (none after {elapsed:.1f}s) ---")
        else:
            lines.append(f"--- RESPONSE (raw, {elapsed:.1f}s) ---")
            lines.append(content.rstrip())

        if entries is not None:
            summary = ", ".join(
                e.get("skill") or e.get("action", "?") for e in entries
            ) or "(none)"
            lines.append(f"--- PARSED ({len(entries)}): {summary} ---")

        lines.append("")  # trailing blank line between exchanges
        text = "\n".join(lines) + "\n"

        path = Path(output_dir) / "chat.log"
        with path.open("a", encoding="utf-8") as fh:
            fh.write(text)
    except Exception as e:  # noqa: BLE001 — logging must never break a decision
        log.debug("transcript: could not write chat.log: %s", e)
