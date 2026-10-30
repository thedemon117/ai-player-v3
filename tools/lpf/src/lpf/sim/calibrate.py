"""Calibration hook: compare a Sim A rollout with the run's own KPI log (runtime/run/kpi.jsonl).

Each KPI line is one snapshot from scripts/kpi.py: {"tick", "wall", "produced": {item: n}, "researched": [...],
"counts": {entity: n}, ...}. Observed time is game time (tick / 60), which equals wall time at speed 1.
Milestones are matched by the same conditions the simulator uses; the first snapshot satisfying one is an
upper bound on when it happened (snapshots are minutes apart).
"""
from __future__ import annotations

import bisect
import json
import math
from pathlib import Path

from ..protos import REPO_ROOT
from .buildorder import MILESTONES, TRACK
from .data import load
from .engine import Result

KPI_PATH = REPO_ROOT / "runtime" / "run" / "kpi.jsonl"


def read_kpi(path: Path | str = KPI_PATH) -> list[dict]:
    p = Path(path)
    if not p.exists():
        return []
    snaps = [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]
    return sorted(snaps, key=lambda s: s["tick"])


def _met(cond: tuple, snap: dict) -> bool | None:
    """Does this KPI snapshot satisfy a milestone condition? None when the KPI cannot tell."""
    k = cond[0]
    if k == "produced":
        return snap.get("produced", {}).get(cond[1], 0) >= cond[2]
    if k == "tech":
        return cond[1] in snap.get("researched", [])
    if k == "built":
        return snap.get("counts", {}).get(cond[1], 0) >= cond[2]
    if k == "power_mw":
        return snap.get("counts", {}).get("steam-engine", 0) * load().engine_kw >= cond[1] * 1000
    return None


def observed_milestones(snaps: list[dict]) -> dict[str, float]:
    """Milestone -> hours of the first snapshot that satisfies it."""
    out: dict[str, float] = {}
    for name, cond in MILESTONES:
        for s in snaps:
            if _met(cond, s):
                out[name] = round(s["tick"] / 60 / 3600, 3)
                break
    return out


def _interp(timeline: list[dict], t_s: float, item: str) -> float:
    ts = [p["t"] for p in timeline]
    i = bisect.bisect_right(ts, t_s)
    if i == 0:
        return 0.0
    a = timeline[i - 1]
    if i == len(timeline):
        return float(a["produced"].get(item, 0))
    b = timeline[i]
    f = (t_s - a["t"]) / max(1, b["t"] - a["t"])
    return a["produced"].get(item, 0) * (1 - f) + b["produced"].get(item, 0) * f


def calibrate(result: Result, path: Path | str = KPI_PATH) -> dict:
    """Sim vs observed: milestone times and production counts at each KPI snapshot."""
    snaps = read_kpi(path)
    obs = observed_milestones(snaps)
    rows = []
    for name, _ in MILESTONES:
        if name in obs or name in result.milestones:
            sim_h = result.milestones.get(name)
            rows.append({"milestone": name, "observed_h": obs.get(name), "sim_h": sim_h,
                         "ratio": round(obs[name] / sim_h, 2) if name in obs and sim_h else None})
    prod = []
    for s in snaps:
        t = s["tick"] / 60
        prod.append({"t_h": round(t / 3600, 3), "researched": {"observed": len(s.get("researched", [])),
                                                              "sim": _sim_techs(result, t)},
                     "produced": {i: {"observed": n, "sim": round(_interp(result.timeline, t, i))}
                                  for i, n in s.get("produced", {}).items() if i in TRACK}})
    return {"snapshots": len(snaps), "milestones": rows, "production": prod}


def _sim_techs(result: Result, t_s: float) -> int:
    ts = [p["t"] for p in result.timeline]
    i = bisect.bisect_right(ts, t_s)
    return result.timeline[i - 1]["researched"] if i else 0


def format_calibration(c: dict) -> str:
    if not c["snapshots"]:
        return "calibration: no KPI snapshots yet (run scripts/kpi.py to append to runtime/run/kpi.jsonl)"
    lines = [f"calibration vs {c['snapshots']} KPI snapshot(s); observed = first snapshot meeting the milestone",
             f"  {'milestone':24s} {'observed_h':>10} {'sim_h':>8} {'obs/sim':>8}"]
    for r in c["milestones"]:
        o = f"{r['observed_h']:.2f}" if r["observed_h"] is not None else "-"
        s = f"{r['sim_h']:.2f}" if r["sim_h"] is not None else "-"
        q = f"{r['ratio']:.2f}" if r["ratio"] else "-"
        lines.append(f"  {r['milestone']:24s} {o:>10} {s:>8} {q:>8}")
    last = c["production"][-1]
    lines.append(f"production at t={last['t_h']:.2f} h (observed vs sim), techs "
                 f"{last['researched']['observed']} vs {last['researched']['sim']}:")
    for item, v in last["produced"].items():
        lines.append(f"  {item:24s} {v['observed']:>9} {v['sim']:>9}")
    return "\n".join(lines)


def fit_latency(gaps_s: list[float]) -> tuple[float, float]:
    """Lognormal fit (median, sigma) to measured tool-call gaps in seconds, for SimConfig.latency_*."""
    xs = [math.log(g) for g in gaps_s if g > 0]
    if len(xs) < 2:
        raise ValueError("need at least two positive gaps")
    mu = sum(xs) / len(xs)
    var = sum((x - mu) ** 2 for x in xs) / (len(xs) - 1)
    return math.exp(mu), math.sqrt(var)
