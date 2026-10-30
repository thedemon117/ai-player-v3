"""Schematic renderer: Scene -> PNG + text legend, sized for an LLM to read.

Colour blocks per category, belt arrows, inserter pickup->drop arrows, drill output marks, status
outlines, coordinate grid with labelled major lines, optional plan/actual diff overlay. No game sprites.
"""
from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass

from PIL import Image, ImageDraw, ImageFont

from .scene import Diff, Entity, Scene

MAX_SIDE_TILES = 200
LAND = (244, 241, 234)
WATER = (143, 184, 222)
UNEXPLORED = (150, 150, 150)
GRID_MINOR = (226, 221, 210)
GRID_MAJOR = (170, 163, 150)
INK = (40, 40, 40)

RESOURCE = {
    "iron-ore": (125, 147, 178), "copper-ore": (217, 146, 91), "coal": (70, 70, 70),
    "stone": (200, 180, 138), "uranium-ore": (122, 201, 67), "crude-oil": (155, 89, 182),
}
OBSTACLE = {"tree": (63, 125, 58), "rock": (138, 129, 120), "cliff": (107, 79, 58)}
CATEGORY = {
    "assembler": (91, 139, 208), "furnace": (181, 101, 29), "drill": (108, 122, 137), "lab": (232, 120, 180),
    "silo": (120, 60, 160), "pole": (120, 80, 40), "pipe": (106, 160, 200), "tank": (80, 130, 170),
    "power": (200, 70, 60), "chest": (160, 120, 70), "logistics": (230, 140, 40), "misc": (130, 130, 160),
    "wall": (110, 110, 110), "circuit": (60, 170, 120), "rail": (100, 90, 80), "vehicle": (90, 90, 90),
    "character": (255, 255, 255), "other": (190, 190, 190),
}
TIER = {"": (230, 184, 0), "fast-": (217, 83, 79), "express-": (59, 125, 216)}
INSERTER = {"burner-inserter": (139, 90, 43), "inserter": (224, 160, 32), "long-handed-inserter": (208, 64, 64),
            "fast-inserter": (59, 125, 216), "bulk-inserter": (46, 139, 87)}
STATUS = {  # outline colour for problem statuses; "working" and friends get none
    "no_power": (220, 0, 0), "low_power": (230, 90, 0), "not_plugged_in_electric_network": (220, 0, 0),
    "no_fuel": (240, 140, 0), "no_ingredients": (240, 190, 0), "no_input_fluid": (240, 190, 0),
    "no_recipe": (240, 190, 0), "fluid_ingredient_shortage": (240, 190, 0), "item_ingredient_shortage": (240, 190, 0),
    "waiting_for_space_in_destination": (150, 0, 200), "full_output": (150, 0, 200), "full_burnt_result_output": (150, 0, 200),
    "no_minable_resources": (0, 0, 0), "missing_required_fluid": (240, 190, 0), "disabled": (120, 120, 120),
    "marked_for_deconstruction": (120, 120, 120),
}
DIFF_COLORS = {"missing": (230, 0, 0), "wrong": (255, 140, 0), "extra": (200, 0, 200), "ok": (0, 160, 0)}
DIR8 = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}


@dataclass
class Rendered:
    image: Image.Image
    legend: str
    cell: int
    bounds: tuple[int, int, int, int]

    def save(self, path) -> None:
        self.image.save(path)


def code_for(name: str) -> str:
    """Short label: initials of hyphen parts plus trailing tier digit (assembling-machine-2 -> AM2)."""
    parts = name.split("-")
    digit = parts[-1] if parts[-1].isdigit() else ""
    words = [p for p in parts if not p.isdigit()]
    if len(words) == 1:
        return (words[0][:3] + digit).upper()
    return ("".join(w[0] for w in words) + digit).upper()


def _font(size: int):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow < 10.1
        return ImageFont.load_default()


def _tier_color(name: str) -> tuple[int, int, int]:
    for prefix in ("express-", "fast-"):
        if name.startswith(prefix):
            return TIER[prefix]
    return TIER[""]


def _darker(c, f=0.55):
    return tuple(int(v * f) for v in c)


def _lighter(c, f=0.55):
    return tuple(int(v + (255 - v) * f) for v in c)


class _Canvas:
    def __init__(self, bounds, cell, margin_l, margin_t):
        self.l, self.t, self.r, self.b = bounds
        self.cell, self.ml, self.mt = cell, margin_l, margin_t
        w, h = (self.r - self.l) * cell + margin_l + 2, (self.b - self.t) * cell + margin_t + 2
        self.img = Image.new("RGB", (w, h), (255, 255, 255))
        self.d = ImageDraw.Draw(self.img, "RGBA")

    def px(self, x: float, y: float) -> tuple[float, float]:
        return self.ml + (x - self.l) * self.cell, self.mt + (y - self.t) * self.cell

    def rect(self, l, t, r, b, fill=None, outline=None, width=1):
        x0, y0 = self.px(l, t)
        x1, y1 = self.px(r, b)
        self.d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=fill, outline=outline, width=width)

    def dashed_rect(self, l, t, r, b, color, width=2):
        x0, y0 = self.px(l, t)
        x1, y1 = self.px(r, b)
        dash = max(3, self.cell // 3)
        for (ax, ay, bx, by) in ((x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)):
            length = math.hypot(bx - ax, by - ay)
            n = max(1, int(length // dash))
            for i in range(0, n, 2):
                s, e = i / n, min(1, (i + 1) / n)
                self.d.line([ax + (bx - ax) * s, ay + (by - ay) * s, ax + (bx - ax) * e, ay + (by - ay) * e],
                            fill=color, width=width)

    def arrow(self, x0, y0, x1, y1, color, width=1, head=None):
        a, b = self.px(x0, y0), self.px(x1, y1)
        self.d.line([a, b], fill=color, width=width)
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        hl = head or max(3, self.cell * 0.35)
        for da in (2.6, -2.6):
            self.d.line([b, (b[0] + hl * math.cos(ang + da), b[1] + hl * math.sin(ang + da))], fill=color, width=width)

    def triangle(self, cx, cy, direction, color, size=0.38):
        dx, dy = DIR8.get(direction - direction % 4, (0, -1))
        px_, py_ = -dy, dx
        pts = [(cx + dx * size, cy + dy * size), (cx - dx * size + px_ * size, cy - dy * size + py_ * size),
               (cx - dx * size - px_ * size, cy - dy * size - py_ * size)]
        self.d.polygon([self.px(*p) for p in pts], fill=color)


def _auto_cell(bounds, max_px):
    l, t, r, b = bounds
    side = max(r - l, b - t, 1)
    return max(4, min(24, max_px // side))


def render(scene: Scene, bounds: tuple[int, int, int, int] | None = None, max_px: int = 1024,
           layers: set[str] | None = None, plan: Scene | None = None, plan_diff: Diff | None = None,
           plan_offset: tuple[float, float] = (0, 0)) -> Rendered:
    """Draw a scene. layers: terrain, entities, status, grid, labels, power (default all but power)."""
    layers = layers or {"terrain", "entities", "status", "grid", "labels"}
    l, t, r, b = bounds or scene.bounds()
    if r - l > MAX_SIDE_TILES or b - t > MAX_SIDE_TILES:
        raise ValueError(f"area {r - l}x{b - t} exceeds {MAX_SIDE_TILES} tiles per side")
    cell = _auto_cell((l, t, r, b), max_px)
    font = _font(max(9, min(14, cell)))
    small = _font(max(7, min(11, int(cell * 0.6))))
    cv = _Canvas((l, t, r, b), cell, margin_l=40, margin_t=18)
    d = cv.d

    # background + terrain
    cv.rect(l, t, r, b, fill=LAND)
    if "terrain" in layers:
        for (wx, wy) in scene.water:
            if l <= wx < r and t <= wy < b:
                cv.rect(wx, wy, wx + 1, wy + 1, fill=WATER)
        for res, tiles in scene.resources.items():
            col = RESOURCE.get(res, (180, 180, 120))
            for (rx, ry, *_amt) in tiles:
                if l <= rx < r and t <= ry < b:
                    if res == "crude-oil":
                        cv.rect(rx - 1, ry - 1, rx + 2, ry + 2, outline=col + (255,), width=2)
                    else:
                        cv.rect(rx, ry, rx + 1, ry + 1, fill=col + (120,))
        for (ol, ot, orr, ob, kind) in scene.obstacles:
            col = OBSTACLE.get(kind, (100, 100, 100))
            if kind == "tree":
                cx, cy = cv.px((ol + orr) / 2, (ot + ob) / 2)
                rad = max(1.5, cell * 0.3)
                d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=col)
            else:
                cv.rect(math.floor(ol), math.floor(ot), math.ceil(orr), math.ceil(ob), fill=col + (200,))
        for (chx, chy) in scene.unexplored:
            cl, ct = max(l, chx * 32), max(t, chy * 32)
            cr, cb = min(r, chx * 32 + 32), min(b, chy * 32 + 32)
            if cl < cr and ct < cb:
                cv.rect(cl, ct, cr, cb, fill=UNEXPLORED + (235,))

    # grid
    if "grid" in layers:
        for gx in range(l, r + 1):
            major = gx % 10 == 0
            if major or cell >= 8:
                x0, _ = cv.px(gx, t)
                d.line([x0, cv.mt, x0, cv.px(gx, b)[1]], fill=GRID_MAJOR if major else GRID_MINOR, width=1)
                if major:
                    d.text((x0 + 2, 2), str(gx), fill=INK, font=small)
        for gy in range(t, b + 1):
            major = gy % 10 == 0
            if major or cell >= 8:
                _, y0 = cv.px(l, gy)
                d.line([cv.ml, y0, cv.px(r, gy)[0], y0], fill=GRID_MAJOR if major else GRID_MINOR, width=1)
                if major:
                    d.text((2, y0 + 1), str(gy), fill=INK, font=small)

    if "power" in layers:
        for e in scene.entities:
            if e.cat == "pole" and e.supply:
                cv.rect(e.x - e.supply, e.y - e.supply, e.x + e.supply, e.y + e.supply, fill=(255, 220, 0, 40))

    codes: Counter = Counter()
    problems: dict[str, list[Entity]] = {}
    if "entities" in layers:
        for e in sorted(scene.entities, key=lambda e: (e.cat == "character", e.cat == "inserter")):
            _draw_entity(cv, e, font, layers, codes)
            if e.status in STATUS and "status" in layers:
                cv.rect(*e.box, outline=STATUS[e.status], width=max(2, cell // 6))
                problems.setdefault(e.status, []).append(e)

    if plan is not None:
        _draw_plan(cv, plan, plan_diff, plan_offset, font)

    img = cv.img
    legend = _legend(scene, (l, t, r, b), cell, codes, problems, plan, plan_diff)
    return Rendered(img, legend, cell, (l, t, r, b))


def _draw_entity(cv: _Canvas, e: Entity, font, layers, codes: Counter) -> None:
    c, cell = cv.cell, cv.cell
    l, t, r, b = e.box
    if e.cat in ("belt", "ubelt", "splitter"):
        col = _tier_color(e.name)
        fill = _lighter(col, 0.35) if not e.ghost else None
        cv.rect(l, t, r, b, fill=fill, outline=_darker(col), width=1)
        if e.cat == "ubelt":  # dark half on the side that goes underground
            dx, dy = DIR8.get(e.dir - e.dir % 4, (0, -1))
            sgn = 1 if e.ug != "output" else -1
            cx, cy = (l + r) / 2, (b + t) / 2
            hx, hy = cx + dx * 0.25 * sgn, cy + dy * 0.25 * sgn
            cv.rect(hx - (0.5 if dx == 0 else 0.25), hy - (0.5 if dy == 0 else 0.25),
                    hx + (0.5 if dx == 0 else 0.25), hy + (0.5 if dy == 0 else 0.25), fill=_darker(col, 0.4))
        if e.cat == "splitter":
            for (cx, cy) in _splitter_lanes(e):
                cv.triangle(cx, cy, e.dir, _darker(col))
        else:
            cv.triangle((l + r) / 2, (t + b) / 2, e.dir, _darker(col))
        codes[e.name] += 1
        if e.ghost:
            cv.dashed_rect(l, t, r, b, _darker(col))
        return
    if e.cat == "inserter":
        col = INSERTER.get(e.name, (224, 160, 32))
        inset = 0.2
        cv.rect(l + inset, t + inset, r - inset, b - inset, fill=None if e.ghost else col, outline=_darker(col))
        if e.pickup and e.drop:
            cv.d.ellipse([*(v - 2 for v in cv.px(*e.pickup)), *(v + 2 for v in cv.px(*e.pickup))], fill=_darker(col))
            cv.arrow(*e.pickup, *e.drop, _darker(col), width=max(1, c // 10))
        codes[e.name] += 1
        return
    if e.cat == "character":
        cx, cy = cv.px(e.x, e.y)
        rad = max(3, c * 0.45)
        cv.d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(255, 255, 255), outline=(0, 0, 0), width=2)
        if e.label:
            cv.d.text((cx + rad + 1, cy - rad), e.label, fill=(0, 0, 0), font=font)
        return
    col = CATEGORY.get(e.cat, CATEGORY["other"])
    if e.cat == "pole":
        cx, cy = cv.px(e.x, e.y)
        rad = max(2, c * 0.3 * (r - l))
        cv.d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=None if e.ghost else col, outline=_darker(col))
    elif e.cat == "pipe":
        inset = 0.25
        cv.rect(l + inset, t + inset, r - inset, b - inset, fill=None if e.ghost else col, outline=_darker(col))
    else:
        cv.rect(l, t, r, b, fill=None if e.ghost else _lighter(col, 0.25), outline=_darker(col), width=max(1, c // 12))
    if e.ghost:
        cv.dashed_rect(l, t, r, b, _darker(col))
    if e.out:
        ox, oy = e.out
        cv.rect(math.floor(ox) + 0.3, math.floor(oy) + 0.3, math.floor(ox) + 0.7, math.floor(oy) + 0.7,
                fill=_darker(col, 0.3))
        dx, dy = DIR8.get(e.dir - e.dir % 4, (0, -1))
        cv.arrow(e.x + dx * ((r - l) / 2 - 0.4), e.y + dy * ((b - t) / 2 - 0.4), math.floor(ox) + 0.5,
                 math.floor(oy) + 0.5, _darker(col, 0.3), width=max(1, c // 10))
    elif e.cat in ("power",) and (r - l) * (b - t) <= 2:
        cv.triangle((l + r) / 2, (t + b) / 2, e.dir, _darker(col))
    codes[e.name] += 1
    if "labels" in layers and (r - l) * c >= 16:
        label = code_for(e.name)
        if e.recipe and (b - t) * c >= 30:
            label += "\n" + e.recipe[:max(3, int((r - l) * c / 6))]
        x0, y0 = cv.px(l, t)
        cv.d.multiline_text((x0 + 2, y0 + 1), label, fill=INK, font=font, spacing=0)


def _splitter_lanes(e: Entity):
    l, t, r, b = e.box
    cx, cy = (l + r) / 2, (t + b) / 2
    if (r - l) > (b - t):
        return [(cx - 0.5, cy), (cx + 0.5, cy)]
    return [(cx, cy - 0.5), (cx, cy + 0.5)]


def _draw_plan(cv: _Canvas, plan: Scene, pd: Diff | None, offset, font) -> None:
    ox, oy = offset
    if pd is None:
        for e in plan.entities:
            l, t, r, b = e.box
            cv.dashed_rect(l + ox, t + oy, r + ox, b + oy, DIFF_COLORS["missing"])
        return
    for e in pd.missing:
        l, t, r, b = e.box
        cv.rect(l + ox, t + oy, r + ox, b + oy, fill=DIFF_COLORS["missing"] + (50,))
        cv.dashed_rect(l + ox, t + oy, r + ox, b + oy, DIFF_COLORS["missing"])
    for pe, _ae, _why in pd.wrong:
        l, t, r, b = pe.box
        cv.rect(l + ox, t + oy, r + ox, b + oy, outline=DIFF_COLORS["wrong"], width=max(2, cv.cell // 5))
    for e in pd.extra:
        cv.rect(*e.box, outline=DIFF_COLORS["extra"], width=max(2, cv.cell // 6))


def _fmt_pos(e: Entity) -> str:
    return f"({e.x:g},{e.y:g})"


def _legend(scene, bounds, cell, codes, problems, plan, pd) -> str:
    l, t, r, b = bounds
    lines = [f"{scene.title}: x {l}..{r} (east), y {t}..{b} (south), {r - l}x{b - t} tiles, {cell}px per tile"
             + (f", tick {scene.tick}" if scene.tick is not None else "")]
    lines.append("grid: thin line every tile, thick labelled line every 10 tiles; labels are map coordinates")
    if codes:
        lines.append("entities: " + ", ".join(f"{code_for(n)}={n} x{k}" if not n.endswith(("belt", "inserter", "splitter"))
                                              else f"{n} x{k}" for n, k in codes.most_common()))
    lines.append("belts: tier colour (yellow/red/blue), triangle = flow; underground: dark half = side going underground."
                 " inserters: dot = pickup, arrow = drop. drills: arrow to output tile.")
    if problems:
        lines.append("status outlines: " + "; ".join(
            f"{s} ({len(es)}): " + " ".join(f"{code_for(e.name)}{_fmt_pos(e)}" for e in es[:12])
            + (" ..." if len(es) > 12 else "") for s, es in problems.items()))
    recipes = [e for e in scene.entities if e.recipe]
    if recipes:
        lines.append("recipes: " + "; ".join(f"{code_for(e.name)}{_fmt_pos(e)}={e.recipe}" for e in recipes[:40])
                     + (" ..." if len(recipes) > 40 else ""))
    chars = [e for e in scene.entities if e.cat == "character"]
    if chars:
        lines.append("characters: " + ", ".join(f"{e.label or e.name}{_fmt_pos(e)}" for e in chars))
    if scene.unexplored:
        lines.append(f"grey: {len(scene.unexplored)} unexplored chunk(s), contents unknown")
    if scene.unknown:
        lines.append("not drawn (no prototype): " + ", ".join(sorted(set(scene.unknown))))
    if plan is not None and pd is not None:
        lines.append(f"diff vs plan '{plan.title}': ok {len(pd.ok)}, missing {len(pd.missing)} (red fill),"
                     f" wrong {len(pd.wrong)} (orange), extra {len(pd.extra)} (magenta)")
        for e in pd.missing[:20]:
            lines.append(f"  missing {e.name}{_fmt_pos(e)} dir {e.dir}")
        for pe, _ae, why in pd.wrong[:20]:
            lines.append(f"  wrong {pe.name}{_fmt_pos(pe)}: {why}")
        for e in pd.extra[:10]:
            lines.append(f"  extra {e.name}{_fmt_pos(e)}")
    return "\n".join(lines)
