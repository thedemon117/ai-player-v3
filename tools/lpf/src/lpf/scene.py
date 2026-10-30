"""Scene: one normalized entity list, whatever it came from (live snapshot, blueprint, or plan).

All three renderer entry points build a Scene and hand it to render.render():
  - from_snapshot: the mod's `area_snapshot` query JSON (live map, explored ground only)
  - from_blueprint: a decoded blueprint dict (in-run blueprints only; the gate lives in the mod)
  - from_plan: a designer's layout JSON, i.e. factorio-mcp build_plan steps, before anything exists
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from .protos import Proto, Protos, rotate, snap_center, tile_box


@dataclass
class Entity:
    name: str
    cat: str
    x: float
    y: float
    dir: int = 0
    box: tuple[int, int, int, int] = (0, 0, 1, 1)   # tile-aligned [l, t, r, b)
    type: str = ""
    recipe: str | None = None
    ug: str | None = None                            # underground belt: input / output
    pickup: tuple[float, float] | None = None        # inserters, world coords
    drop: tuple[float, float] | None = None
    out: tuple[float, float] | None = None           # mining drills: output point
    status: str | None = None
    ghost: bool = False
    label: str | None = None
    supply: float | None = None                      # poles: supply_area_distance

    @property
    def key(self) -> tuple[str, float, float]:
        return self.name, self.x, self.y


@dataclass
class Scene:
    entities: list[Entity] = field(default_factory=list)
    resources: dict[str, list[tuple[int, int, int]]] = field(default_factory=dict)
    water: list[tuple[int, int]] = field(default_factory=list)
    obstacles: list[tuple[float, float, float, float, str]] = field(default_factory=list)
    unexplored: list[tuple[int, int]] = field(default_factory=list)   # chunk coords
    area: tuple[int, int, int, int] | None = None                     # [x1, y1, x2, y2)
    tick: int | None = None
    title: str = ""
    unknown: list[str] = field(default_factory=list)                  # names with no prototype

    def bounds(self, margin: int = 1) -> tuple[int, int, int, int]:
        if self.area:
            return self.area
        if not self.entities:
            return (-8, -8, 8, 8)
        l = min(e.box[0] for e in self.entities) - margin
        t = min(e.box[1] for e in self.entities) - margin
        r = max(e.box[2] for e in self.entities) + margin
        b = max(e.box[3] for e in self.entities) + margin
        return l, t, r, b


def _entity_from_proto(p: Proto, x: float, y: float, d: int, **kw) -> Entity:
    e = Entity(name=p.name, cat=p.cat, type=p.type, x=x, y=y, dir=d, box=tile_box(p, x, y, d), **kw)
    if p.type == "inserter" and p.pickup and p.insert:
        px, py = rotate(p.pickup, d)
        ix, iy = rotate(p.insert, d)
        e.pickup, e.drop = (x + px, y + py), (x + ix, y + iy)
    if p.type == "mining-drill" and p.out:
        ox, oy = rotate(p.out, d)
        e.out = (x + ox, y + oy)
    if p.type == "electric-pole":
        e.supply = p.supply
    return e


def from_plan(steps: list[dict] | dict, protos: Protos, title: str = "plan") -> Scene:
    """Layout JSON -> Scene. Accepts build_plan steps or {"entities": [...]}; keys item|name, x, y,
    direction|dir, recipe, underground_type|ug. Positions snap like the game snaps placement."""
    if isinstance(steps, dict):
        title = steps.get("label", title)
        steps = steps.get("entities") or steps.get("steps") or []
    sc = Scene(title=title)
    for st in steps:
        if st.get("type") not in (None, "place"):
            continue
        name = st.get("item") or st.get("name")
        p = protos.get(name) if name else None
        if p is None:
            sc.unknown.append(str(name))
            continue
        d = int(st.get("direction", st.get("dir", 0)) or 0)
        x, y = snap_center(p, float(st["x"]), float(st["y"]), d)
        sc.entities.append(_entity_from_proto(p, x, y, d, recipe=st.get("recipe"),
                                              ug=st.get("underground_type") or st.get("ug")))
    return sc


def from_blueprint(bp: dict, protos: Protos, title: str | None = None) -> Scene:
    sc = Scene(title=title or bp.get("label") or "blueprint")
    for ent in bp.get("entities", []):
        p = protos.get(ent["name"])
        if p is None:
            sc.unknown.append(ent["name"])
            continue
        d = int(ent.get("direction", 0))
        x, y = float(ent["position"]["x"]), float(ent["position"]["y"])
        ug = ent.get("type") if p.type == "underground-belt" else None
        if p.type == "underground-belt" and ug is None:
            ug = "input"
        sc.entities.append(_entity_from_proto(p, x, y, d, recipe=ent.get("recipe"), ug=ug))
    return sc


def from_snapshot(snap: dict, protos: Protos, title: str = "map") -> Scene:
    x1, y1, x2, y2 = snap["area"]
    sc = Scene(title=title, tick=snap.get("tick"),
               area=(math.floor(x1), math.floor(y1), math.ceil(x2), math.ceil(y2)))
    for ent in snap.get("entities", []):
        p = protos.get(ent["name"])
        cat = p.cat if p else ("character" if ent.get("type") == "character" else "other")
        l, t, r, b = ent["box"]
        e = Entity(name=ent["name"], cat=cat, type=ent.get("type", ""), x=ent["x"], y=ent["y"],
                   dir=int(ent.get("dir", 0)),
                   box=(math.floor(l + 1e-3), math.floor(t + 1e-3), math.ceil(r - 1e-3), math.ceil(b - 1e-3)),
                   recipe=ent.get("recipe"), ug=ent.get("ug"), status=ent.get("status"),
                   ghost=bool(ent.get("ghost")), label=ent.get("label"),
                   pickup=tuple(ent["pickup"]) if "pickup" in ent else None,
                   drop=tuple(ent["drop"]) if "drop" in ent else None,
                   out=tuple(ent["out"]) if "out" in ent else None,
                   supply=p.supply if p else None)
        if e.box[2] <= e.box[0]:
            e.box = (e.box[0], e.box[1], e.box[0] + 1, e.box[3])
        if e.box[3] <= e.box[1]:
            e.box = (e.box[0], e.box[1], e.box[2], e.box[1] + 1)
        if p is None and cat == "other":
            sc.unknown.append(ent["name"])
        sc.entities.append(e)
    sc.resources = {k: [tuple(v) for v in vs] for k, vs in snap.get("resources", {}).items()}
    sc.water = [tuple(w) for w in snap.get("water", [])]
    sc.obstacles = [tuple(o) for o in snap.get("obstacles", [])]
    sc.unexplored = [tuple(c) for c in snap.get("unexplored_chunks", [])]
    return sc


# --- diff -------------------------------------------------------------------------------

@dataclass
class Diff:
    ok: list[Entity] = field(default_factory=list)
    missing: list[Entity] = field(default_factory=list)          # planned, not on the map
    wrong: list[tuple[Entity, Entity, str]] = field(default_factory=list)  # (plan, actual, what)
    extra: list[Entity] = field(default_factory=list)            # on the map inside the plan's area, not planned


def diff(plan: Scene, actual: Scene, offset: tuple[float, float] = (0, 0)) -> Diff:
    """Compare a plan (shifted by offset) with what stands on the map. Ghosts count as missing."""
    ox, oy = offset
    built = {(e.name, e.x, e.y): e for e in actual.entities if not e.ghost and e.cat not in ("character",)}
    out = Diff()
    seen = set()
    for pe in plan.entities:
        k = (pe.name, pe.x + ox, pe.y + oy)
        ae = built.get(k)
        if ae is None:
            out.missing.append(pe)
            continue
        seen.add(k)
        why = []
        if pe.cat in ("belt", "ubelt", "splitter", "inserter", "drill", "power", "pipe") or not _is_square(pe):
            if pe.dir != ae.dir:
                why.append(f"dir {ae.dir} (plan {pe.dir})")
        if pe.recipe and pe.recipe != ae.recipe:
            why.append(f"recipe {ae.recipe} (plan {pe.recipe})")
        if pe.ug and ae.ug and pe.ug != ae.ug:
            why.append(f"{ae.ug} (plan {pe.ug})")
        if why:
            out.wrong.append((pe, ae, ", ".join(why)))
        else:
            out.ok.append(pe)
    if plan.entities:
        l, t, r, b = plan.bounds(margin=0)
        l, t, r, b = l + ox, t + oy, r + ox, b + oy
        for k, ae in built.items():
            if k in seen or ae.cat in ("other",):
                continue
            if l <= ae.x < r and t <= ae.y < b:
                out.extra.append(ae)
    return out


def _is_square(e: Entity) -> bool:
    l, t, r, b = e.box
    return (r - l) == (b - t)
