"""
Per-turn run metrics (v3).

Appends one compact JSON line per LLM exchange to `metrics.jsonl` in the
Factorio script-output dir — alongside bridge.log and chat.log. Where chat.log
answers "why did the router pick that skill", metrics.jsonl answers "is the
AI actually succeeding": each row snapshots the factory KPIs the perception
already carries (game phase, research, factory size/health, production rates)
plus decision quality (action OK/FAILED counts) and loop health (latency,
timeout/parse failures).

Rows carry provider+model, so one file can hold several runs and
`python -m bridge.report` groups them for side-by-side comparison.

Deliberately dependency-free and best-effort, mirroring transcript.py: any
failure here is swallowed so metrics can never break a decision.
"""

import json
import logging
import time
from pathlib import Path

log = logging.getLogger(__name__)

FILENAME = "metrics.jsonl"

# status values recorded per exchange
STATUS_OK = "ok"                    # model replied, actions parsed
STATUS_TIMEOUT = "timeout"          # provider returned nothing in time
STATUS_PARSE_ERROR = "parse_error"  # model replied, reply wasn't a valid action array


def record_exchange(
    output_dir: Path,
    req_id: str,
    payload: dict,
    entries: list[dict] | None,
    status: str,
    elapsed: float,
    provider: str,
    model: str,
) -> None:
    """Append one exchange's metrics row to metrics.jsonl. Never raises."""
    try:
        perception = payload.get("perception") or {}
        memory = payload.get("memory") or {}

        environment = perception.get("environment") or {}
        factory = perception.get("factory") or {}
        by_status = factory.get("by_status") or {}
        research = perception.get("research") or {}
        production = perception.get("production") or {}
        character = perception.get("character") or {}

        results = memory.get("last_action_results") or []
        results_ok = sum(1 for r in results if isinstance(r, dict) and r.get("ok"))
        failed = [
            str(r.get("detail") or r.get("action") or "?")
            for r in results
            if isinstance(r, dict) and not r.get("ok")
        ]

        row = {
            "ts": round(time.time(), 1),
            "req_id": req_id,
            "tick": environment.get("ticks_played"),
            "provider": provider,
            "model": model,
            # --- factory outcomes (ground truth) ---
            "phase": perception.get("game_phase"),
            "techs_researched": production.get("techs_researched"),
            "research_current": research.get("current"),
            "factory_total": factory.get("total"),
            "machines_working": by_status.get("working", 0) + by_status.get("normal", 0),
            "machines_attention": len(factory.get("attention") or []),
            "ghosts": (perception.get("ghosts") or {}).get("count"),
            "production": production.get("items") or {},
            "health_pct": character.get("health_pct"),
            # --- decision quality (previous turn's outcomes) ---
            "results_ok": results_ok,
            "results_failed": len(failed),
            "failed_detail": failed[:5],
            # --- loop health (this turn) ---
            "status": status,
            "elapsed_s": round(elapsed, 1),
            "actions": [e.get("skill") or e.get("action") or "?" for e in entries]
                       if entries else None,
        }

        path = Path(output_dir) / FILENAME
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    except Exception as e:  # noqa: BLE001 — metrics must never break a decision
        log.debug("metrics: could not record row: %s", e)
