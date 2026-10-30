"""L1 rate model: machines and raw inputs needed for a target item rate, from the game's own recipes.

Arithmetic only (no layouts). Oil fractions are treated as raw fluids and reported for refinery sizing.
"""
from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass, field
from functools import lru_cache

from .protos import game_data_dir

RAW = {"iron-ore", "copper-ore", "coal", "stone", "water", "crude-oil", "petroleum-gas", "light-oil",
       "heavy-oil", "wood", "raw-fish", "uranium-ore"}
# machine per recipe category; speed comes from the dump
DEFAULT_MACHINE = {
    "crafting": "assembling-machine-2", "advanced-crafting": "assembling-machine-2",
    "crafting-with-fluid": "assembling-machine-2", "basic-crafting": "assembling-machine-2",
    "smelting": "stone-furnace", "chemistry": "chemical-plant", "oil-processing": "oil-refinery",
    "rocket-building": "rocket-silo", "centrifuging": "centrifuge",
}


def _amount(x) -> float:
    if "amount" in x:
        return float(x["amount"]) * float(x.get("probability", 1))
    return (float(x["amount_min"]) + float(x["amount_max"])) / 2 * float(x.get("probability", 1))


@lru_cache(maxsize=1)
def raw_dump() -> dict:
    """The parsed dump (shared with lpf.sim; call raw_dump.cache_clear() to release the memory)."""
    return json.loads((game_data_dir() / "data-raw-dump.json").read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def _data():
    d = raw_dump()
    speeds = {}
    for t in ("assembling-machine", "furnace", "rocket-silo"):
        for n, p in d.get(t, {}).items():
            speeds[n] = float(p.get("crafting_speed", 1))
    by_product: dict[str, str] = {}
    for name, r in d["recipe"].items():
        for res in r.get("results", []) or []:
            # prefer the recipe named after the product; never pick recycling/void recipes
            if res["name"] == name or res["name"] not in by_product:
                if not name.endswith(("-recycling", "-barrel", "empty-barrel")) and "parameter" not in name:
                    by_product.setdefault(res["name"], name)
                    if res["name"] == name:
                        by_product[res["name"]] = name
    return d["recipe"], speeds, by_product


@dataclass
class Plan:
    machines: dict[str, tuple[str, float]] = field(default_factory=dict)   # recipe -> (machine, count)
    raw: dict[str, float] = field(default_factory=lambda: defaultdict(float))  # per second
    items: dict[str, float] = field(default_factory=lambda: defaultdict(float))  # intermediate per second


def rates(targets: dict[str, float], machine_override: dict[str, str] | None = None) -> Plan:
    """targets: item -> items per second. Returns machines per recipe and raw inputs per second."""
    recipes, speeds, by_product = _data()
    mo = {**DEFAULT_MACHINE, **(machine_override or {})}
    plan = Plan()
    need: dict[str, float] = defaultdict(float)

    def add(item: str, per_s: float, depth: int = 0) -> None:
        if depth > 40:
            raise RecursionError(item)
        if item in RAW or item not in by_product:
            plan.raw[item] += per_s
            return
        rname = by_product[item]
        r = recipes[rname]
        out = sum(_amount(x) for x in r["results"] if x["name"] == item)
        crafts_per_s = per_s / out
        cat = r.get("category", "crafting")
        machine = mo.get(cat, "assembling-machine-2")
        speed = speeds.get(machine, 1.0)
        count = crafts_per_s * float(r.get("energy_required", 0.5)) / speed
        prev = plan.machines.get(rname, (machine, 0.0))[1]
        plan.machines[rname] = (machine, prev + count)
        plan.items[item] += per_s
        for ing in r.get("ingredients", []):
            add(ing["name"], crafts_per_s * _amount(ing), depth + 1)

    for item, per_s in targets.items():
        add(item, per_s)
    return plan


def format_plan(plan: Plan, per: str = "min") -> str:
    k = 60 if per == "min" else 1
    lines = ["machines (fractional = utilisation):"]
    for rname, (machine, n) in sorted(plan.machines.items(), key=lambda kv: -kv[1][1]):
        lines.append(f"  {rname:32s} {n:8.2f} x {machine}")
    lines.append(f"raw inputs per {per}:")
    for item, v in sorted(plan.raw.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {item:32s} {v * k:10.1f}")
    return "\n".join(lines)
