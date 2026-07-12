"""
Run evaluation report (v3).

Reads the metrics.jsonl written by bridge/metrics.py and answers "is the
AI player succeeding" with numbers instead of vibes:

  * Outcomes   — milestone splits (when each game phase / factory size /
                 first tech was reached), production rates, factory growth
  * Decisions  — action OK/FAILED rates, top failures, worst failure streak
  * Loop health— model response rate, timeouts, parse failures, latency

Rows are grouped by provider+model: run the bridge with one model, switch
models in bridge/.env, run again, and the report prints the runs side by
side from the same file.

Usage:
    python -m bridge.report                  # metrics.jsonl from configured output dir
    python -m bridge.report FILE [FILE ...]  # explicit file(s), merged then grouped
"""

import json
import sys
from pathlib import Path

# Milestone thresholds: (label, predicate over a row)
PHASE_NAMES = {
    1: "phase 1 (automation/red)",
    2: "phase 2 (logistic/green)",
    3: "phase 3 (military)",
    4: "phase 4 (chemical/blue)",
    5: "phase 5 (production/utility)",
    6: "phase 6 (rocket)",
}
FACTORY_SIZES = [1, 5, 15, 30]
KEY_ITEMS = [
    "iron-plate", "copper-plate", "steel-plate",
    "electronic-circuit", "automation-science-pack", "logistic-science-pack",
]


def _load(paths: list[Path]) -> list[dict]:
    rows = []
    for path in paths:
        with path.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue  # tolerate a torn write
    return rows


def _fmt_ticks(ticks) -> str:
    """Game ticks → wall-ish time (60 ticks/s), with explicit units."""
    if ticks is None:
        return "—"
    seconds = int(ticks // 60)
    h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    return f"{m}m {s:02d}s"


def _pct(part: int, whole: int) -> str:
    return f"{100.0 * part / whole:.0f}%" if whole else "—"


def _p95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))]


def summarize(rows: list[dict]) -> dict:
    """Compute one run's summary from its (tick-sorted) metric rows."""
    rows = sorted(rows, key=lambda r: (r.get("tick") or 0))
    first, last = rows[0], rows[-1]

    ticks = [r["tick"] for r in rows if r.get("tick") is not None]
    tick_span = (ticks[-1] - ticks[0]) if len(ticks) > 1 else 0
    t0 = ticks[0] if ticks else 0

    def since_start(tick) -> str:
        return _fmt_ticks(tick - t0 if tick is not None else None)

    # --- loop health ---
    statuses = [r.get("status") for r in rows]
    n_ok = statuses.count("ok")
    n_timeout = statuses.count("timeout")
    n_parse = statuses.count("parse_error")
    latencies = [r["elapsed_s"] for r in rows
                 if r.get("status") in ("ok", "parse_error") and r.get("elapsed_s") is not None]

    # --- decision quality ---
    results_ok = sum(r.get("results_ok") or 0 for r in rows)
    results_failed = sum(r.get("results_failed") or 0 for r in rows)
    fail_counts: dict[str, int] = {}
    streak = best_streak = 0
    prev_failed: list[str] = []
    for r in rows:
        failed = r.get("failed_detail") or []
        for detail in failed:
            fail_counts[detail] = fail_counts.get(detail, 0) + 1
        # identical nonempty failure set repeating across turns = thrashing
        if failed and failed == prev_failed:
            streak += 1
        else:
            streak = 1 if failed else 0
        best_streak = max(best_streak, streak)
        prev_failed = failed
    top_failures = sorted(fail_counts.items(), key=lambda kv: -kv[1])[:3]

    # --- outcome milestones ---
    milestones: list[tuple[str, str]] = []
    for phase, name in PHASE_NAMES.items():
        hit = next((r for r in rows if (r.get("phase") or 0) >= phase), None)
        if hit:
            milestones.append((name, since_start(hit.get("tick"))))
    for size in FACTORY_SIZES:
        hit = next((r for r in rows if (r.get("factory_total") or 0) >= size), None)
        if hit:
            milestones.append((f"{size} machine{'s' if size > 1 else ''} placed",
                               since_start(hit.get("tick"))))
    base_techs = first.get("techs_researched") or 0
    hit = next((r for r in rows if (r.get("techs_researched") or 0) > base_techs), None)
    if hit:
        milestones.append(("first tech researched", since_start(hit.get("tick"))))

    production_end = {
        item: stats for item, stats in (last.get("production") or {}).items()
        if item in KEY_ITEMS
    }

    return {
        "provider": last.get("provider") or "?",
        "model": last.get("model") or "?",
        "turns": len(rows),
        "tick_span": tick_span,
        "loop": {
            "ok": n_ok, "timeout": n_timeout, "parse_error": n_parse,
            "response_rate": _pct(n_ok, len(rows)),
            "latency_avg": sum(latencies) / len(latencies) if latencies else None,
            "latency_p95": _p95(latencies),
        },
        "decisions": {
            "ok": results_ok, "failed": results_failed,
            "fail_rate": _pct(results_failed, results_ok + results_failed),
            "top_failures": top_failures,
            "worst_streak": best_streak,
        },
        "milestones": milestones,
        "factory_first": first.get("factory_total") or 0,
        "factory_last": last.get("factory_total") or 0,
        "working_last": last.get("machines_working") or 0,
        "techs_last": last.get("techs_researched") or 0,
        "production_end": production_end,
    }


def _render(summary: dict) -> list[str]:
    loop, decisions = summary["loop"], summary["decisions"]
    lat_avg = f"{loop['latency_avg']:.1f}s" if loop["latency_avg"] is not None else "—"
    lat_p95 = f"{loop['latency_p95']:.1f}s" if loop["latency_p95"] is not None else "—"

    lines = [
        f"run          : {summary['provider']} / {summary['model']}",
        f"turns        : {summary['turns']}  over {_fmt_ticks(summary['tick_span'])} game time",
        "",
        "loop health",
        f"  responded  : {loop['ok']}/{summary['turns']} ({loop['response_rate']})"
        f"   timeouts: {loop['timeout']}   parse errors: {loop['parse_error']}",
        f"  latency    : avg {lat_avg}   p95 {lat_p95}",
        "",
        "decision quality",
        f"  actions    : {decisions['ok']} OK / {decisions['failed']} FAILED"
        f" (fail rate {decisions['fail_rate']})",
        f"  worst thrash streak: {decisions['worst_streak']} turn(s) repeating the same failure",
    ]
    for detail, count in decisions["top_failures"]:
        lines.append(f"  repeated failure ×{count}: {detail[:70]}")

    lines += ["", "outcomes"]
    lines.append(f"  factory    : {summary['factory_first']} → {summary['factory_last']} machines"
                 f" ({summary['working_last']} working at end)")
    lines.append(f"  research   : {summary['techs_last']} tech(s) researched")
    if summary["production_end"]:
        for item, stats in summary["production_end"].items():
            lines.append(f"  {item:<28}: {stats.get('total', 0)} total,"
                         f" {stats.get('per_min', 0)}/min at end")
    else:
        lines.append("  production : none of the key items produced yet")
    if summary["milestones"]:
        lines.append("  milestones (time from run start):")
        for name, when in summary["milestones"]:
            lines.append(f"    {name:<30} {when}")
    else:
        lines.append("  milestones : none reached")
    return lines


def main() -> None:
    if len(sys.argv) > 1:
        paths = [Path(a) for a in sys.argv[1:]]
    else:
        from .config import ConfigLoader
        from .metrics import FILENAME
        paths = [ConfigLoader().get().output_dir / FILENAME]

    missing = [p for p in paths if not p.exists()]
    if missing:
        print("metrics file not found: " + ", ".join(str(p) for p in missing))
        print("Run the bridge first — it writes metrics.jsonl next to bridge.log.")
        sys.exit(1)

    rows = _load(paths)
    if not rows:
        print("no metric rows found")
        sys.exit(1)

    # Group into runs by provider+model, preserving first-seen order
    groups: dict[tuple, list[dict]] = {}
    for row in rows:
        groups.setdefault((row.get("provider"), row.get("model")), []).append(row)

    sep = "=" * 64
    for group_rows in groups.values():
        print(sep)
        print("\n".join(_render(summarize(group_rows))))
    print(sep)
    if len(groups) > 1:
        print(f"{len(groups)} runs compared — models listed in first-seen order.")


if __name__ == "__main__":
    main()
