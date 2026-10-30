"""lpf CLI: render blueprints, plans and live map areas; timelapse frames.

  lpf render-area X1 Y1 X2 Y2 [-o out.png] [--snapshot snap.json] [--plan plan.json --dx N --dy N]
  lpf render-plan plan.json [-o out.png]
  lpf render-blueprint (STRING | @file) [--index PATH] [-o out.png]
  lpf plan-to-blueprint plan.json            prints the blueprint string (register it in-game before use)
  lpf rates ITEM=PER_MIN [ITEM=PER_MIN ...]   machines and raw inputs (L1 rate model)
  lpf sim --agents N [--seed S] [--latency-median 25] [--json out.json]   plan-model rollout (Sim A, L2)
  lpf sim-sweep --agents 1-16                 N vs time-to-launch and agent-hours
  lpf protos --rebuild

render-area fetches the snapshot with `factorio-mcp snapshot` against the server in FACTORIO_RCON_*.
Every render prints the text legend to stdout; the PNG goes to -o (default out/<kind>.png).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import blueprint as bpc
from .protos import REPO_ROOT, Protos
from .render import render
from .scene import diff, from_blueprint, from_plan, from_snapshot
from .sim.cli import add_sim_args, run_sim

def fetch_snapshot(x1: float, y1: float, x2: float, y2: float) -> dict:
    """Ask the running game for the `area_snapshot` query (mod/scripts/queries.lua) over RCON,
    through the repo's bridge, so it uses the same bridge/.env settings as the MCP servers."""
    repo = Path(__file__).resolve().parents[4]   # the factorio-ai-player root, home of bridge/
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))
    try:
        from bridge.config import ConfigLoader
        from bridge.factorio.rcon import RCONGateway
    except ImportError as e:
        raise RuntimeError(f"bridge dependencies missing ({e}); run from the repo's own venv "
                           "or pass --snapshot with a saved snapshot JSON") from e
    cfg = ConfigLoader().get()
    # LPF_RCON_* point at another server (e.g. a test instance) without touching bridge/.env.
    host = os.environ.get("LPF_RCON_HOST", cfg.rcon.host)
    port = int(os.environ.get("LPF_RCON_PORT", cfg.rcon.port))
    password = os.environ.get("LPF_RCON_PASSWORD", cfg.rcon.password)
    r = RCONGateway(host, port, password).run_query(
        "area_snapshot", {"x1": x1, "y1": y1, "x2": x2, "y2": y2})
    if not isinstance(r, dict) or "error" in r:
        raise RuntimeError(f"area_snapshot failed: {r}")
    return r


def _load_json_arg(s: str):
    p = Path(s)
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else json.loads(s)


def plan_to_blueprint(plan: dict | list, protos: Protos, label: str = "plan") -> dict:
    """Layout JSON -> blueprint dict. Positions are kept as planned (the game re-anchors on build)."""
    sc = from_plan(plan, protos, title=label)
    ents = []
    for i, e in enumerate(sc.entities, 1):
        ent = {"entity_number": i, "name": e.name, "position": {"x": e.x, "y": e.y}}
        if e.dir:
            ent["direction"] = e.dir
        if e.recipe:
            ent["recipe"] = e.recipe
        if e.ug:
            ent["type"] = e.ug
        ents.append(ent)
    if sc.unknown:
        raise ValueError(f"unknown entities: {sorted(set(sc.unknown))}")
    return {"blueprint": {"item": "blueprint", "label": sc.title, "entities": ents,
                          "version": bpc.version_number()}}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="lpf")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("render-area")
    for n in ("x1", "y1", "x2", "y2"):
        a.add_argument(n, type=float)
    a.add_argument("--snapshot", help="use a saved snapshot JSON instead of querying the server")
    a.add_argument("--plan", help="overlay a plan (layout JSON) and diff it against the map")
    a.add_argument("--dx", type=float, default=0)
    a.add_argument("--dy", type=float, default=0)
    a.add_argument("--power", action="store_true", help="draw pole supply areas")
    p = sub.add_parser("render-plan")
    p.add_argument("plan")
    p.add_argument("--power", action="store_true")
    b = sub.add_parser("render-blueprint")
    b.add_argument("string", help="blueprint string, or @path to a file holding one")
    b.add_argument("--index", default=None, help="book path like 2 or 2/0 (default: first)")
    c = sub.add_parser("plan-to-blueprint")
    c.add_argument("plan")
    c.add_argument("--label", default="plan")
    rt = sub.add_parser("rates")
    rt.add_argument("targets", nargs="+", help="item=per_minute")
    add_sim_args(sub.add_parser("sim"))
    add_sim_args(sub.add_parser("sim-sweep"), sweep_mode=True)
    r = sub.add_parser("protos")
    r.add_argument("--rebuild", action="store_true")
    for s in (a, p, b):
        s.add_argument("-o", "--out", default=None)
        s.add_argument("--max-px", type=int, default=1024)
    args = ap.parse_args(argv)

    if args.cmd == "rates":
        from .rates import format_plan, rates
        targets = {t.split("=")[0]: float(t.split("=")[1]) / 60 for t in args.targets}
        print(format_plan(rates(targets)))
        return 0
    if args.cmd in ("sim", "sim-sweep"):
        return run_sim(args)
    if args.cmd == "protos":
        pr = Protos.load(rebuild=args.rebuild)
        print(f"{len(pr._table['entities'])} entity prototypes cached")
        return 0
    protos = Protos.load()
    layers = {"terrain", "entities", "status", "grid", "labels"} | ({"power"} if getattr(args, "power", False) else set())

    if args.cmd == "plan-to-blueprint":
        print(bpc.encode(plan_to_blueprint(_load_json_arg(args.plan), protos, args.label)))
        return 0
    if args.cmd == "render-area":
        snap = (json.loads(Path(args.snapshot).read_text(encoding="utf-8")) if args.snapshot
                else fetch_snapshot(args.x1, args.y1, args.x2, args.y2))
        sc = from_snapshot(snap, protos)
        plan = pd = None
        if args.plan:
            plan = from_plan(_load_json_arg(args.plan), protos)
            pd = diff(plan, sc, (args.dx, args.dy))
        out = render(sc, max_px=args.max_px, layers=layers, plan=plan, plan_diff=pd, plan_offset=(args.dx, args.dy))
        kind = "area"
    elif args.cmd == "render-plan":
        sc = from_plan(_load_json_arg(args.plan), protos)
        out = render(sc, max_px=args.max_px, layers=layers)
        kind = "plan"
    else:
        s = Path(args.string[1:]).read_text(encoding="utf-8") if args.string.startswith("@") else args.string
        books = bpc.blueprints(bpc.decode(s))
        if not books:
            raise SystemExit("no blueprint in string")
        chosen = next((bp for path, bp in books if path == args.index), books[0][1]) if args.index else books[0][1]
        sc = from_blueprint(chosen, protos)
        out = render(sc, max_px=args.max_px, layers=layers)
        kind = "blueprint"
    path = Path(args.out or REPO_ROOT / "out" / f"{kind}.png")
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path)
    print(f"image: {path} ({out.image.size[0]}x{out.image.size[1]})")
    print(out.legend)
    return 0


if __name__ == "__main__":
    sys.exit(main())
