"""Entity prototype table extracted from the game's own `--dump-data` output.

Nothing here is hand-written game data: footprints, inserter vectors, drill output
offsets and pole ranges all come from data/game/data-raw-dump.json, which
scripts/dump_prototypes.sh produces from the pinned server image. The compact table
is cached next to the dump as protos.json.
"""
from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]  # tools/lpf
DUMP_NAME = "data-raw-dump.json"
CACHE_NAME = "protos.json"
CACHE_VERSION = 1

# data.raw types that are placeable buildings we care about, mapped to a render category.
TYPE_CATEGORY = {
    "transport-belt": "belt",
    "underground-belt": "ubelt",
    "splitter": "splitter",
    "loader": "belt",
    "loader-1x1": "belt",
    "inserter": "inserter",
    "mining-drill": "drill",
    "furnace": "furnace",
    "assembling-machine": "assembler",
    "rocket-silo": "silo",
    "lab": "lab",
    "electric-pole": "pole",
    "pipe": "pipe",
    "pipe-to-ground": "pipe",
    "pump": "pipe",
    "storage-tank": "tank",
    "offshore-pump": "power",
    "boiler": "power",
    "generator": "power",
    "solar-panel": "power",
    "accumulator": "power",
    "reactor": "power",
    "heat-pipe": "power",
    "container": "chest",
    "logistic-container": "chest",
    "roboport": "logistics",
    "radar": "misc",
    "beacon": "misc",
    "lamp": "misc",
    "wall": "wall",
    "gate": "wall",
    "turret": "misc",
    "ammo-turret": "misc",
    "electric-turret": "misc",
    "fluid-turret": "misc",
    "constant-combinator": "circuit",
    "arithmetic-combinator": "circuit",
    "decider-combinator": "circuit",
    "selector-combinator": "circuit",
    "power-switch": "circuit",
    "programmable-speaker": "circuit",
    "straight-rail": "rail",
    "half-diagonal-rail": "rail",
    "curved-rail-a": "rail",
    "curved-rail-b": "rail",
    "rail-signal": "rail",
    "rail-chain-signal": "rail",
    "train-stop": "rail",
    "locomotive": "vehicle",
    "cargo-wagon": "vehicle",
    "fluid-wagon": "vehicle",
    "car": "vehicle",
    "character": "character",
}


@dataclass(frozen=True)
class Proto:
    name: str
    type: str
    cat: str
    w: int                      # tiles, facing north
    h: int
    pickup: tuple[float, float] | None = None   # inserters, facing north, relative to centre
    insert: tuple[float, float] | None = None
    out: tuple[float, float] | None = None      # mining drills: vector_to_place_result
    supply: float | None = None                 # electric poles: supply_area_distance
    wire: float | None = None                   # electric poles: maximum_wire_distance
    ug_max: int | None = None                   # underground belts: max_distance
    speed: float | None = None                  # crafting_speed / mining_speed / belt speed

    @property
    def square(self) -> bool:
        return self.w == self.h


def game_data_dir() -> Path:
    return Path(os.environ.get("LPF_GAME_DATA", REPO_ROOT / "data" / "game"))


def _footprint(p: dict) -> tuple[int, int]:
    if "tile_width" in p or "tile_height" in p:
        return int(p.get("tile_width", 1)), int(p.get("tile_height", 1))
    box = p.get("collision_box")
    if not box:
        return 1, 1
    (x1, y1), (x2, y2) = box
    return max(1, math.ceil(x2 - x1 - 1e-6)), max(1, math.ceil(y2 - y1 - 1e-6))


def _vec(v) -> tuple[float, float] | None:
    if v is None:
        return None
    if isinstance(v, dict):
        return float(v["x"]), float(v["y"])
    return float(v[0]), float(v[1])


def build_table(dump: dict) -> dict:
    entities: dict[str, dict] = {}
    for typ, cat in TYPE_CATEGORY.items():
        for name, p in dump.get(typ, {}).items():
            if not isinstance(p, dict) or "hidden" in p.get("flags", []) and typ != "character":
                continue
            w, h = _footprint(p)
            e = {"type": typ, "cat": cat, "w": w, "h": h}
            if typ == "inserter":
                e["pickup"] = _vec(p.get("pickup_position"))
                e["insert"] = _vec(p.get("insert_position"))
            elif typ == "mining-drill":
                e["out"] = _vec(p.get("vector_to_place_result"))
                e["speed"] = p.get("mining_speed")
            elif typ == "electric-pole":
                e["supply"] = p.get("supply_area_distance")
                e["wire"] = p.get("maximum_wire_distance")
            elif typ == "underground-belt":
                e["ug_max"] = p.get("max_distance")
            if typ in ("transport-belt", "underground-belt", "splitter"):
                e["speed"] = p.get("speed")
            if typ in ("assembling-machine", "furnace", "rocket-silo"):
                e["speed"] = p.get("crafting_speed")
            entities[name] = {k: v for k, v in e.items() if v is not None}
    items = {}
    for typ in ("item", "item-with-entity-data", "rail-planner"):
        for name, p in dump.get(typ, {}).items():
            pr = p.get("place_result")
            if typ == "rail-planner":
                pr = (p.get("rails") or [None])[0]
            if pr and pr in entities:
                items[name] = pr
    return {"version": CACHE_VERSION, "entities": entities, "items": items}


class Protos:
    def __init__(self, table: dict):
        self._table = table
        self._cache: dict[str, Proto] = {}

    @classmethod
    def load(cls, data_dir: Path | None = None, rebuild: bool = False) -> "Protos":
        d = data_dir or game_data_dir()
        cache = d / CACHE_NAME
        if not rebuild and cache.exists():
            table = json.loads(cache.read_text(encoding="utf-8"))
            if table.get("version") == CACHE_VERSION:
                return cls(table)
        dump_path = d / DUMP_NAME
        if not dump_path.exists():
            raise FileNotFoundError(f"{dump_path} missing; run scripts/dump_prototypes.sh first")
        table = build_table(json.loads(dump_path.read_text(encoding="utf-8")))
        cache.write_text(json.dumps(table, indent=1), encoding="utf-8")
        return cls(table)

    def entity_name(self, name_or_item: str) -> str:
        """Entity name for an entity or item name (base game: identical except rails)."""
        n = name_or_item.split("@", 1)[0]
        if n in self._table["entities"]:
            return n
        return self._table["items"].get(n, n)

    def get(self, name: str) -> Proto | None:
        name = self.entity_name(name)
        if name in self._cache:
            return self._cache[name]
        e = self._table["entities"].get(name)
        if e is None:
            return None
        p = Proto(name=name, type=e["type"], cat=e["cat"], w=e["w"], h=e["h"],
                  pickup=_vec(e.get("pickup")), insert=_vec(e.get("insert")), out=_vec(e.get("out")),
                  supply=e.get("supply"), wire=e.get("wire"), ug_max=e.get("ug_max"), speed=e.get("speed"))
        self._cache[name] = p
        return p

    def __contains__(self, name: str) -> bool:
        return self.get(name) is not None


@lru_cache(maxsize=1)
def default() -> Protos:
    return Protos.load()


# --- geometry -------------------------------------------------------------------------

def rotate(v: tuple[float, float], direction: int) -> tuple[float, float]:
    """Rotate a north-facing offset to a 16-way direction (0=N, 4=E, 8=S, 12=W; y grows south)."""
    a = math.radians(direction * 22.5)
    x, y = v
    rx, ry = x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
    return round(rx, 6), round(ry, 6)


def footprint(p: Proto, direction: int) -> tuple[int, int]:
    return (p.h, p.w) if direction % 8 == 4 else (p.w, p.h)


def snap_center(p: Proto, x: float, y: float, direction: int) -> tuple[float, float]:
    """Snap a requested position to where the game would put the entity's centre."""
    w, h = footprint(p, direction)
    sx = math.floor(x) + 0.5 if w % 2 else math.floor(x + 0.5)
    sy = math.floor(y) + 0.5 if h % 2 else math.floor(y + 0.5)
    return float(sx), float(sy)


def tile_box(p: Proto, x: float, y: float, direction: int) -> tuple[int, int, int, int]:
    """Tile-aligned [left, top, right, bottom) box of an entity centred at (x, y)."""
    w, h = footprint(p, direction)
    left, top = math.floor(x - w / 2 + 1e-6), math.floor(y - h / 2 + 1e-6)
    return left, top, left + w, top + h
