"""`lpf sim` and `lpf sim-sweep` (wired into lpf.cli)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from .buildorder import default_build_order
from .calibrate import KPI_PATH, calibrate, format_calibration
from .engine import SimConfig, simulate, sweep
from .report import format_result, format_sweep


def parse_agents(s: str) -> list[int]:
    """'8', '1-16' or '1,2,4,8' -> list of agent counts."""
    out: list[int] = []
    for part in s.split(","):
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    if not out or min(out) < 1 or max(out) > 64:
        raise argparse.ArgumentTypeError(f"bad agent count {s!r}")
    return out


def add_sim_args(p: argparse.ArgumentParser, sweep_mode: bool = False) -> None:
    p.add_argument("--agents", default="1-16" if sweep_mode else "8",
                   help="number of agents incl. the planner" + (" (N, A-B or A,B,C)" if sweep_mode else ""))
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--latency-median", type=float, default=25.0, help="median LLM tool-call latency (s)")
    p.add_argument("--latency-sigma", type=float, default=0.6, help="lognormal sigma of the latency")
    p.add_argument("--mistake-p", type=float, default=0.15, help="chance a task chunk needs a retry")
    p.add_argument("--call-scale", type=float, default=1.0, help="multiplier on every task's tool-call count")
    p.add_argument("--scale", type=float, default=1.0, help="multiplier on the build order's production targets")
    p.add_argument("--stagger-min", type=float, default=0.0, help="agent i joins at i * this many minutes")
    p.add_argument("--max-hours", type=float, default=336.0)
    p.add_argument("--json", default=None, help="write the full result (with trace) to this file")
    if sweep_mode:
        p.add_argument("--repeats", type=int, default=3, help="seeds averaged per N")
    else:
        p.add_argument("--kpi", nargs="?", const=str(KPI_PATH), default=None,
                       help="also compare with a KPI log (default runtime/run/kpi.jsonl)")


def _cfg(args, agents: int) -> SimConfig:
    return SimConfig(agents=agents, seed=args.seed, latency_median=args.latency_median,
                     latency_sigma=args.latency_sigma, mistake_p=args.mistake_p, call_scale=args.call_scale,
                     stagger_s=args.stagger_min * 60, max_hours=args.max_hours)


def run_sim(args) -> int:
    order = default_build_order(scale=args.scale)
    if args.cmd == "sim":
        n = parse_agents(args.agents)[0]
        cfg = _cfg(args, n)
        r = simulate(order, cfg)
        print(format_result(r, cfg))
        if args.kpi:
            print(format_calibration(calibrate(r, args.kpi)))
        if args.json:
            Path(args.json).write_text(r.to_json(), encoding="utf-8")
            print(f"trace: {args.json}")
        return 0
    base = _cfg(args, 1)
    kw = {k: getattr(base, k) for k in ("latency_median", "latency_sigma", "mistake_p", "call_scale", "stagger_s",
                                        "max_hours")}
    rows = sweep(parse_agents(args.agents), repeats=args.repeats, seed=args.seed, order=order, **kw)
    print(format_sweep(rows))
    if args.json:
        Path(args.json).write_text(json.dumps(rows, indent=1), encoding="utf-8")
        print(f"rows: {args.json}")
    return 0
