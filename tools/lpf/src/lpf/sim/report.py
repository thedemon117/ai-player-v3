"""Text reports for Sim A results and sweeps."""
from __future__ import annotations

from .engine import BUDGET_AGENT_H, BUDGET_WALL_H, Result, SimConfig


def format_result(r: Result, cfg: SimConfig | None = None) -> str:
    lat = f", latency median {cfg.latency_median:g}s sigma {cfg.latency_sigma:g}" if cfg else ""
    head = (f"Sim A: N={r.agents} seed={r.seed}{lat}\n"
            + (f"launch at {r.time_h:.2f} h wall, {r.agent_hours:.1f} agent-h on the clock "
               f"({r.busy_agent_hours:.1f} busy), feasible={r.feasible} "
               f"(T<={BUDGET_WALL_H:g} h, N*T<={BUDGET_AGENT_H:g} agent-h)"
               if r.finished else f"no launch within {r.time_h:.0f} h (stuck or too slow)"))
    lines = [head, "milestones (wall h):"]
    for k, v in sorted(r.milestones.items(), key=lambda kv: kv[1]):
        lines.append(f"  {k:24s} {v:8.2f}")
    lines.append("agents:        busy_h  idle_h  busy%  chunks")
    for a in r.agent_stats:
        lines.append(f"  {a.id:2d} {a.role:8s} {a.busy_h:7.2f} {a.idle_h:7.2f} {a.busy_frac * 100:5.0f}% {a.chunks:6d}")
    if r.blockers:
        lines.append("idle agent-hours by blocker (what the next task was waiting for):")
        for k, v in list(r.blockers.items())[:10]:
            lines.append(f"  {k:32s} {v:8.2f}")
    if r.starvation:
        lines.append("machine-hours lost to input shortage (recipe<-item):")
        for k, v in list(r.starvation.items())[:8]:
            lines.append(f"  {k:40s} {v:8.2f}")
    if r.lab_wait:
        lines.append("lab-hours idle for lack of: " + ", ".join(f"{k} {v:.1f}" for k, v in r.lab_wait.items()))
    if r.power_short_mwh > 0.01:
        lines.append(f"power shortfall: {r.power_short_mwh:.1f} MWh")
    return "\n".join(lines)


def format_sweep(rows: list[dict]) -> str:
    out = [f"{'N':>3} {'T_launch_h':>10} {'agent_h':>8} {'busy%':>6} {'done':>5} {'feasible':>8}  top blocker"]
    for r in rows:
        done = f"{r['finished']}/{r['repeats']}"
        t = f"{r['time_h']:.1f}" if r["finished"] else f">{r['time_h']:.0f}"
        out.append(f"{r['n']:3d} {t:>10} {r['agent_hours']:8.1f} {r['busy_frac'] * 100:5.0f}% {done:>5} "
                   f"{'yes' if r['feasible'] else 'no':>8}  {r['top_blocker']}")
    best = [r for r in rows if r["feasible"]]
    if best:
        b = min(best, key=lambda r: r["time_h"])
        out.append(f"fastest feasible: N={b['n']} at {b['time_h']:.1f} h ({b['agent_hours']:.0f} agent-h)")
    else:
        out.append("no feasible N under T<=168 h and N*T<=1000 agent-h")
    return "\n".join(out)
