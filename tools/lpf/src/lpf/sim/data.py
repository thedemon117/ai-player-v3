"""Game numbers for Sim A, all read from the game's own dump (data/game/data-raw-dump.json).

Only a few unit conversions are written here (steam is 150 C x 0.2 kJ per unit; solar averages 70% of peak).
Everything else (recipe times, machine speeds and power, tech costs, character speeds, silo part count) is data.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from functools import lru_cache

from .. import rates

FLUID_FREE = {"water"}          # unlimited, never tracked as stock
MINE = "mine:"                  # pseudo-recipe prefix for drills / pumpjacks: "mine:iron-ore"
RESEARCH = "research"           # pseudo-recipe of the lab group
POWER = "power"                 # pseudo-recipe of boilers / solar panels


def power_kw(s) -> float:
    """'90kW' / '1.8MW' / '3990kW' -> kW."""
    if s is None:
        return 0.0
    if isinstance(s, (int, float)):
        return float(s)
    m = re.fullmatch(r"\s*([0-9.eE+-]+)\s*([kMG]?)(W|J)\s*", s)
    if not m:
        return 0.0
    return float(m.group(1)) * {"": 1e-3, "k": 1.0, "M": 1e3, "G": 1e6}[m.group(2)]


def _amt(x) -> float:
    if "amount" in x:
        return float(x["amount"]) * float(x.get("probability", 1))
    return (float(x["amount_min"]) + float(x["amount_max"])) / 2 * float(x.get("probability", 1))


@dataclass(frozen=True)
class Recipe:
    name: str
    category: str
    time: float                      # energy_required (s at crafting speed 1)
    inp: dict[str, float]            # fluids included, water dropped
    out: dict[str, float]
    enabled: bool
    fluid: bool                      # touches a fluid -> cannot be hand-crafted


@dataclass(frozen=True)
class Machine:
    name: str
    kind: str                        # assembler | furnace | drill | lab | silo
    speed: float                     # crafting / mining / research speed
    kw: float                        # electric draw at full load, or burner fuel burn (kW)
    burner: bool
    categories: tuple[str, ...] = ()


@dataclass(frozen=True)
class Tech:
    name: str
    prereqs: tuple[str, ...]
    count: float                     # units (0 for trigger techs)
    packs: dict[str, float]          # pack -> per unit
    time: float                      # s per unit at lab speed 1
    trigger: dict | None
    unlocks: tuple[str, ...]
    lab_speed: float = 0.0           # +x lab speed when researched


@dataclass(frozen=True)
class Resource:
    time: float                      # mining_time
    out: dict[str, float]
    fluid: bool = False


@dataclass
class GameData:
    recipes: dict[str, Recipe]
    machines: dict[str, Machine]
    techs: dict[str, Tech]
    resources: dict[str, Resource]
    unlockers: dict[str, list[str]]                  # recipe -> techs that unlock it (any one suffices)
    hand_recipe: dict[str, str]                      # item -> recipe the character can craft by hand
    stack: dict[str, int]
    char_speed: float                                # tiles / s
    char_mining: float                               # mining speed
    char_inventory: int
    coal_kj: float
    parts_required: int
    boiler_kw: float
    engine_kw: float
    solar_kw: float
    tech_order: dict[str, int] = field(default_factory=dict)

    def cheapest_unlocker(self, recipe: str) -> str | None:
        """The unlocking tech with the fewest techs to research first."""
        c = self.unlockers.get(recipe)
        return min(c, key=lambda n: (len(self.closure(n)), self.tech_order[n])) if c else None

    def closure(self, tech: str, done=()) -> list[str]:
        """Prerequisite-first list of techs needed for `tech` (excluding `done`)."""
        out: list[str] = []
        seen: dict[str, bool] = {}

        def go(n: str) -> None:
            if n in seen or n in done:
                return
            seen[n] = True
            for p in self.techs[n].prereqs:
                go(p)
            out.append(n)
        go(tech)
        return out


def _recipes(d: dict, char_cats: set[str]) -> tuple[dict[str, Recipe], dict[str, str]]:
    recs: dict[str, Recipe] = {}
    for name, r in d["recipe"].items():
        cat = r.get("category", "crafting")
        if cat == "recycling" or name.endswith("-recycling") or "parameter" in name:
            continue
        fluid = any(x.get("type") == "fluid" for x in (r.get("ingredients") or []) + (r.get("results") or []))
        inp = {x["name"]: _amt(x) for x in r.get("ingredients") or [] if x["name"] not in FLUID_FREE}
        out = {x["name"]: _amt(x) for x in r.get("results") or [] if x["name"] not in FLUID_FREE}
        recs[name] = Recipe(name, cat, float(r.get("energy_required", 0.5)), inp, out,
                            bool(r.get("enabled", True)), fluid)
    hand: dict[str, str] = {}
    for name, r in recs.items():
        if r.category in char_cats and not r.fluid and not name.endswith("-barrel"):
            for item in r.out:
                if item == name or item not in hand:
                    hand[item] = name
    return recs, hand


def _machines(d: dict) -> dict[str, Machine]:
    ms: dict[str, Machine] = {}
    kinds = {"assembling-machine": "assembler", "furnace": "furnace", "mining-drill": "drill",
             "lab": "lab", "rocket-silo": "silo"}
    for typ, kind in kinds.items():
        for n, p in d.get(typ, {}).items():
            if "hidden" in p.get("flags", []):
                continue
            speed = p.get("crafting_speed") or p.get("mining_speed") or p.get("researching_speed") or 1.0
            kw = power_kw(p.get("active_energy_usage") or p.get("energy_usage"))
            burner = (p.get("energy_source") or {}).get("type") == "burner"
            ms[n] = Machine(n, kind, float(speed), kw, burner, tuple(p.get("crafting_categories") or ()))
    return ms


def _techs(d: dict) -> dict[str, Tech]:
    ts: dict[str, Tech] = {}
    for name, t in d["technology"].items():
        u = t.get("unit") or {}
        if t.get("research_trigger") is None and "count" not in u:
            continue                                   # infinite (formula) techs are never needed
        unl, lab = [], 0.0
        for e in t.get("effects") or []:
            if e.get("type") == "unlock-recipe":
                unl.append(e["recipe"])
            elif e.get("type") == "laboratory-speed":
                lab += float(e.get("modifier", 0))
        packs = {ing[0]: float(ing[1]) for ing in u.get("ingredients", [])} if u else {}
        ts[name] = Tech(name, tuple(t.get("prerequisites") or ()), float(u.get("count", 0)), packs,
                        float(u.get("time", 0)), t.get("research_trigger"), tuple(unl), lab)
    return ts


def _resources(d: dict) -> dict[str, Resource]:
    rs: dict[str, Resource] = {}
    for name, r in d["resource"].items():
        m = r.get("minable") or {}
        if "results" in m:
            out = {x["name"]: _amt(x) for x in m["results"]}
        elif "result" in m:
            out = {m["result"]: float(m.get("count", 1))}
        else:
            continue
        fluid = any(x.get("type") == "fluid" for x in m.get("results", []))
        rs[name] = Resource(float(m.get("mining_time", 1)), out, fluid)
    # trees: the character hand-mines wood from them
    for t in d.get("tree", {}).values():
        m = t.get("minable") or {}
        if m.get("result") == "wood":
            rs.setdefault("wood", Resource(float(m["mining_time"]) / float(m.get("count", 1)), {"wood": 1.0}))
            break
    return rs


@lru_cache(maxsize=1)
def load() -> GameData:
    d = rates.raw_dump()
    ch = d["character"]["character"]
    recs, hand = _recipes(d, set(ch["crafting_categories"]))
    techs = _techs(d)
    unlock: dict[str, list[str]] = {}
    for n, t in techs.items():
        for r in t.unlocks:
            unlock.setdefault(r, []).append(n)
    stack: dict[str, int] = {}
    for typ in ("item", "tool", "module", "ammo", "capsule", "item-with-entity-data", "rail-planner"):
        for n, p in d.get(typ, {}).items():
            stack[n] = int(p.get("stack_size", 50))
    silo = d["rocket-silo"]["rocket-silo"]
    steam_dt = 165 - 15
    eng = d["generator"]["steam-engine"]
    # steam heat capacity is 0.2 kJ/unit/C; the engine burns fluid_usage_per_tick steam per tick
    engine_kw = float(eng.get("fluid_usage_per_tick", 0.5)) * 60 * steam_dt * 0.2
    boiler_kw = power_kw(d["boiler"]["boiler"]["energy_consumption"])
    solar_kw = power_kw(d["solar-panel"]["solar-panel"]["production"]) * 0.7      # day/night average
    data = GameData(
        recipes=recs, machines=_machines(d), techs=techs, resources=_resources(d), unlockers=unlock,
        hand_recipe=hand, stack=stack, char_speed=float(ch["running_speed"]) * 60,
        char_mining=float(ch["mining_speed"]), char_inventory=int(ch["inventory_size"]),
        coal_kj=power_kw(d["item"]["coal"]["fuel_value"]),
        parts_required=int(silo["rocket_parts_required"]),
        boiler_kw=boiler_kw, engine_kw=engine_kw, solar_kw=solar_kw)
    data.tech_order = {n: i for i, n in enumerate(techs)}
    rates._data()                          # fill rates' own tables from the same parse ...
    rates.raw_dump.cache_clear()           # ... then release the 13 MB dump
    return data


def ceil_div(a: float, b: float) -> int:
    return int(math.ceil(a / b - 1e-9))
