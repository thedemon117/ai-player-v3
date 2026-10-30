"""Sim A task DAG: task kinds, what they need from the world, and the build-order container."""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from .world import World

KINDS = ("hand_mine", "hand_craft", "build", "deliver", "research", "wait", "launch")

# build(boiler): one unit is a boiler, its two steam engines and a tenth of an offshore pump
PACKAGE = {"boiler": {"boiler": 1, "steam-engine": 2, "offshore-pump": 0.1}}

# Per-machine glue (inserters, belts, poles, pipes) the build also consumes. Items, not positions.
INFRA_BY_NAME = {
    "burner-mining-drill": {}, "stone-furnace": {},
    "chemical-plant": {"pipe": 8, "inserter": 2, "small-electric-pole": 0.5},
    "oil-refinery": {"pipe": 20, "small-electric-pole": 1},
    "pumpjack": {"pipe": 10, "small-electric-pole": 1},
    "boiler": {"pipe": 4},
    "rocket-silo": {"pipe": 20, "inserter": 4, "small-electric-pole": 4},
    "solar-panel": {"small-electric-pole": 0.1},
}
INFRA_BY_KIND = {
    "assembler": {"inserter": 2, "transport-belt": 6, "small-electric-pole": 0.5},
    "furnace": {"inserter": 2, "transport-belt": 3, "small-electric-pole": 0.3},
    "drill": {"transport-belt": 4, "small-electric-pole": 0.4},
    "lab": {"inserter": 1, "small-electric-pole": 0.5},
}


@dataclass(frozen=True)
class Task:
    id: str
    kind: str
    item: str = ""                 # hand_mine: resource; hand_craft/deliver: item; research: tech
    n: float = 1.0                 # amount (items, machines, or ore)
    recipe: str = ""               # build: what the machines run ("iron-plate", "mine:coal", "research", "power")
    machine: str = ""              # build: machine / entity
    after: tuple[str, ...] = ()
    distance: float = 20.0         # tiles from the base, one way (walking = 2 x distance / running speed)
    calls: int | None = None       # tool calls per chunk (None: default for the kind)
    chunk: float | None = None     # max amount one agent takes at a time (None: not splittable)
    infra: dict | None = None      # build: extra items per machine (None: default for the machine)
    cap: float = 0.0               # build: mall cap on the group's main output
    until: tuple | None = None     # wait: gate condition (see cond_met)
    note: str = ""

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"unknown task kind {self.kind!r}")


@dataclass
class BuildOrder:
    """Tasks in priority order, the stock the run starts with, and named milestones."""
    tasks: list[Task]
    start_items: dict[str, float] = field(default_factory=dict)
    milestones: list[tuple[str, tuple]] = field(default_factory=list)
    track: tuple[str, ...] = ()    # items sampled into the trace timeline

    def validate(self) -> None:
        ids = {t.id for t in self.tasks}
        if len(ids) != len(self.tasks):
            raise ValueError("duplicate task ids")
        for t in self.tasks:
            for a in t.after:
                if a not in ids:
                    raise ValueError(f"{t.id}: unknown dependency {a}")


def cond_met(w: World, cond: tuple, done: dict, since: float = 0.0) -> bool:
    """Gate / milestone conditions: produced, stock, tech, built, power_mw, task, after_s."""
    k = cond[0]
    if k == "produced":
        return w.produced.get(cond[1], 0.0) >= cond[2]
    if k == "stock":
        return w.stock.get(cond[1], 0.0) >= cond[2]
    if k == "tech":
        return cond[1] in w.researched
    if k == "built":
        return w.built.get(cond[1], 0.0) >= cond[2]
    if k == "power_mw":
        return w.power_cap_kw() >= cond[1] * 1000
    if k == "task":
        return cond[1] in done
    if k == "after_s":
        return w.t - since >= cond[1]
    raise ValueError(f"unknown condition {cond!r}")


@dataclass
class Need:
    take: dict[str, float]         # stock to deduct
    hand_s: float                  # hand-crafting time the character spends on intermediates
    levels: dict[str, float]       # blocked items -> stock level that would unblock them
    techs: list[str]               # techs still locking a needed recipe
    crafted: dict[str, float] = field(default_factory=dict)   # intermediates the character hand-crafts

    @property
    def ok(self) -> bool:
        return not self.levels and not self.techs

    def reason(self) -> str:
        if self.techs:
            return f"tech:{self.techs[0]}"
        return f"item:{next(iter(self.levels))}"


def plan_need(w: World, items: dict[str, float]) -> Need:
    """Resolve items against stock. Shortfalls are hand-crafted from their recipe unless the item is not
    hand-craftable (smelted, chemistry, fluids, ...) or a machine group makes it and the shortfall is more than
    a handful (World.hand_limit_s of crafting), in which case the character waits for stock."""
    d = w.data
    used: dict[str, float] = {}
    blocked: dict[str, float] = {}
    crafted: dict[str, float] = {}
    techs: list[str] = []
    hand = 0.0

    def go(item: str, n: float, depth: int = 0) -> None:
        nonlocal hand
        a = w.stock.get(item, 0.0) - used.get(item, 0.0)
        if a > 0:
            u = a if a < n else n
            used[item] = used.get(item, 0.0) + u
            n -= u
        if n <= 1e-9:
            return
        rn = d.hand_recipe.get(item)
        if rn is None or depth > 12:
            blocked[item] = blocked.get(item, 0.0) + n
            return
        r = d.recipes[rn]
        crafts = math.ceil(n / r.out[item] - 1e-9)
        if w.has_producer(item) and crafts * r.time > w.hand_limit_s:
            blocked[item] = blocked.get(item, 0.0) + n          # a machine makes it: wait unless it is a handful
            return
        lock = w.tech_lock(rn)
        if lock:
            if lock not in techs:
                techs.append(lock)
            return
        hand += crafts * r.time
        crafted[item] = crafted.get(item, 0.0) + crafts * r.out[item]
        for ing, amt in r.inp.items():
            go(ing, crafts * amt, depth + 1)

    for item, n in items.items():
        if n > 1e-9:
            go(item, n)
    levels = {i: used.get(i, 0.0) + x for i, x in blocked.items()}
    return Need(used, hand, levels, techs, crafted)


def build_items(w: World, t: Task, c: int) -> dict[str, float]:
    """Items one build chunk of c machines consumes: the machine package plus glue."""
    items: dict[str, float] = {}
    pkg = PACKAGE.get(t.machine, {t.machine: 1})
    for it, per in pkg.items():
        items[it] = items.get(it, 0.0) + math.ceil(per * c - 1e-9)
    infra = t.infra
    if infra is None:
        m = w.data.machines.get(t.machine)
        infra = INFRA_BY_NAME.get(t.machine, INFRA_BY_KIND.get(m.kind if m else "", {}))
    for it, per in infra.items():
        medium = w.has_producer("steel-plate") and w.tech_lock("medium-electric-pole") is None
        if it == "small-electric-pole" and medium:
            it, per = "medium-electric-pole", per * 0.4          # longer reach, no wood
        items[it] = items.get(it, 0.0) + math.ceil(per * c - 1e-9)
    return items
