"""Default rocket build order for Factorio 2.0 base, as data plus a small expander.

STAGES lists, for each phase of the run, the cumulative production targets (items per minute at scale 1), the
techs the agents queue, and what must have happened before the phase starts. The expander turns each stage into
build tasks using the L1 rate model (lpf.rates): machine counts per recipe, ore/coal drills, pumpjacks and
refineries for the fluids, boilers for the electric load, minus what earlier stages already built. Recipe times,
machine speeds and power, tech costs and the 100 rocket parts all come from the game dump. The result is a task
DAG (sizes and durations, not layouts).
"""
from __future__ import annotations

import math

from .. import rates
from .data import MINE, POWER, RESEARCH, GameData, load
from .tasks import BuildOrder, Task

ASM1 = {"crafting": "assembling-machine-1", "advanced-crafting": "assembling-machine-1",
        "basic-crafting": "assembling-machine-1"}
MALL_CAP = 120.0
BASE_CAPS = {"stone-brick": 600.0}          # furnaces must not turn all stone into bricks
DRILL = "electric-mining-drill"
PUMPJACK = "pumpjack"
REFINERY = "oil-refinery"
MARGIN = 1.15                      # headroom on electric load when sizing boilers

# `targets` are cumulative (a stage overrides earlier values for the same item), items per minute at scale 1.
# The "iron-plate"/"copper-plate"/"steel-plate"/"stone-brick" targets are the construction allowance: plates the
# builders themselves draw from stock. `mall` items are produced into capped stock for builds to take.
STAGES: list[dict] = [
    dict(name="red", gate=("tech", "automation"), asm="assembling-machine-1", furnace="stone-furnace", labs=4,
         targets={"automation-science-pack": 30, "iron-plate": 120, "copper-plate": 50, "stone-brick": 10},
         mall={"transport-belt": 12, "inserter": 8, "iron-gear-wheel": 12},
         research=["electric-mining-drill", "logistic-science-pack", "steel-processing"]),
    dict(name="green", gate=("produced", "automation-science-pack", 60), asm="assembling-machine-1",
         furnace="stone-furnace", labs=8,
         targets={"automation-science-pack": 45, "logistic-science-pack": 45, "iron-plate": 240,
                  "copper-plate": 100, "stone-brick": 20},
         mall={"small-electric-pole": 8, "pipe": 12},
         research=["automation-2", "engine", "electric-energy-distribution-1", "advanced-material-processing",
                   "fluid-handling", "oil-gathering"]),
    dict(name="steel", gate=("produced", "logistic-science-pack", 60), asm="assembling-machine-2",
         furnace="steel-furnace", labs=10,
         machine_for={"steel-plate": "stone-furnace"},          # steel furnaces need steel to build
         targets={"steel-plate": 40, "iron-plate": 360, "copper-plate": 150, "stone-brick": 40},
         mall={"assembling-machine-2": 2, "steel-furnace": 3},
         research=["plastics", "sulfur-processing", "advanced-circuit"]),
    dict(name="oil", gate=("produced", "steel-plate", 100), asm="assembling-machine-2",
         furnace="steel-furnace", labs=10,
         targets={"plastic-bar": 60, "sulfur": 30},
         mall={"chemical-plant": 1, "oil-refinery": 0.3},
         research=["chemical-science-pack"]),
    dict(name="blue", gate=("produced", "plastic-bar", 200), asm="assembling-machine-2",
         furnace="steel-furnace", labs=16,
         targets={"advanced-circuit": 60, "chemical-science-pack": 30, "iron-plate": 480, "copper-plate": 200,
                  "steel-plate": 60},
         mall={"engine-unit": 2},
         research=["advanced-oil-processing", "flammables", "productivity-module", "speed-module"]),
    dict(name="purple", gate=("produced", "chemical-science-pack", 100), asm="assembling-machine-2",
         furnace="steel-furnace", labs=20,
         targets={"production-science-pack": 24, "iron-plate": 600, "copper-plate": 250, "stone-brick": 60},
         mall={"electric-furnace": 1},
         research=["advanced-material-processing-2", "railway", "production-science-pack"]),
    dict(name="yellow", gate=("produced", "chemical-science-pack", 100), asm="assembling-machine-2",
         furnace="steel-furnace", labs=24,
         targets={"utility-science-pack": 24, "processing-unit": 10},
         mall={"battery": 2},
         research=["processing-unit", "low-density-structure", "robotics", "utility-science-pack"]),
    dict(name="final", gate=("produced", "chemical-science-pack", 100), asm="assembling-machine-2",
         furnace="steel-furnace", labs=28,
         targets={"processing-unit": 24, "low-density-structure": 18, "rocket-fuel": 18, "concrete": 20,
                  "electric-engine-unit": 6, "steel-plate": 120, "iron-plate": 700, "copper-plate": 400},
         mall={}, caps={"concrete": 1100.0, "electric-engine-unit": 220.0}, silo=True,
         research=["rocket-fuel", "rocket-silo"]),
]

START_ITEMS = {"iron-plate": 8, "wood": 1, "burner-mining-drill": 1, "stone-furnace": 1}   # freeplay crash-site start

TRACK = ("iron-plate", "copper-plate", "steel-plate", "coal", "stone-brick", "automation-science-pack",
         "logistic-science-pack", "chemical-science-pack", "production-science-pack", "utility-science-pack",
         "plastic-bar", "advanced-circuit", "processing-unit", "low-density-structure", "rocket-fuel", "rocket-part")

MILESTONES: list[tuple[str, tuple]] = [
    ("burner_mining", ("built", "burner-mining-drill", 1)),
    ("steam_power", ("power_mw", 1.5)),
    ("automation_researched", ("tech", "automation")),
    ("red_science_auto", ("produced", "automation-science-pack", 60)),
    ("green_science", ("produced", "logistic-science-pack", 60)),
    ("steel", ("produced", "steel-plate", 100)),
    ("oil", ("tech", "oil-processing")),
    ("plastics", ("produced", "plastic-bar", 200)),
    ("red_circuits", ("produced", "advanced-circuit", 100)),
    ("blue_science", ("produced", "chemical-science-pack", 100)),
    ("modules", ("tech", "productivity-module")),
    ("purple_science", ("produced", "production-science-pack", 30)),
    ("yellow_science", ("produced", "utility-science-pack", 30)),
    ("LDS", ("produced", "low-density-structure", 200)),
    ("rocket_fuel", ("produced", "rocket-fuel", 200)),
    ("processing_units", ("produced", "processing-unit", 200)),
    ("silo_researched", ("tech", "rocket-silo")),
    ("silo_built", ("built", "rocket-silo", 1)),
    ("rocket_parts_100", ("produced", "rocket-part", 100)),
]


def _burner() -> list[Task]:
    """Hand-mining, burner drills and furnaces, steam power, the first labs and 10 hand-made red packs."""
    T = Task
    return [
        T("b.mine_stone", "hand_mine", item="stone", n=100, chunk=25, distance=8),
        T("b.mine_coal", "hand_mine", item="coal", n=40, chunk=20, distance=8),
        T("b.mine_iron", "hand_mine", item="iron-ore", n=60, chunk=30, distance=8),
        T("b.drill_iron1", "build", recipe=MINE + "iron-ore", machine="burner-mining-drill", n=1, distance=8),
        T("b.furnace_iron1", "build", recipe="iron-plate", machine="stone-furnace", n=1, distance=8),
        T("b.drills_stone", "build", recipe=MINE + "stone", machine="burner-mining-drill", n=2, distance=10),
        T("b.drills_coal", "build", recipe=MINE + "coal", machine="burner-mining-drill", n=4, chunk=2, distance=8),
        T("b.drills_iron", "build", recipe=MINE + "iron-ore", machine="burner-mining-drill", n=5, chunk=3,
          distance=8),
        T("b.furnaces_iron", "build", recipe="iron-plate", machine="stone-furnace", n=5, chunk=3, distance=8),
        T("b.mine_copper", "hand_mine", item="copper-ore", n=30, chunk=30, distance=40),
        T("b.drills_copper", "build", recipe=MINE + "copper-ore", machine="burner-mining-drill", n=3, chunk=3,
          distance=40),
        T("b.furnaces_copper", "build", recipe="copper-plate", machine="stone-furnace", n=3, chunk=3, distance=40),
        T("b.wood", "hand_mine", item="wood", n=200, chunk=100, distance=30),
        T("p.steam", "build", recipe=POWER, machine="boiler", n=1, distance=25, calls=12),
        T("p.fuel_boilers", "deliver", item="coal", n=50, distance=25, after=("p.steam",), calls=2),
        T("p.lab", "build", recipe=RESEARCH, machine="lab", n=2, distance=15, calls=6),
        T("p.red_by_hand", "hand_craft", item="automation-science-pack", n=10, chunk=10, distance=5),
        T("p.research_automation", "research", item="automation", calls=1),
    ]


class _Expander:
    """Turns STAGES into tasks. `built` tracks (recipe, machine) -> planned count across stages."""

    def __init__(self, d: GameData, scale: float, oil_yield: float):
        self.d, self.scale, self.oil_yield = d, scale, oil_yield
        self.tasks: list[Task] = _burner()
        self.built: dict[tuple[str, str], int] = {
            ("iron-plate", "stone-furnace"): 6, ("copper-plate", "stone-furnace"): 3,
            (MINE + "iron-ore", "burner-mining-drill"): 6,
            (MINE + "copper-ore", "burner-mining-drill"): 3, (MINE + "coal", "burner-mining-drill"): 4,
            (MINE + "stone", "burner-mining-drill"): 2}
        self.labs, self.boilers = 2, 1
        self.caps: dict[str, float] = dict(BASE_CAPS)
        self.stage_tasks: list[Task] = []
        self.sname = self.gid = ""

    # --- capacities (crafts per second) --------------------------------------------------
    def time_of(self, recipe: str, machine: str) -> float:
        m = self.d.machines[machine]
        if recipe.startswith(MINE):
            return self.d.resources[recipe[len(MINE):]].time / m.speed
        return self.d.recipes[recipe].time / m.speed

    def capacity(self, recipe: str) -> float:
        return sum(n / self.time_of(r, m) for (r, m), n in self.built.items() if r == recipe)

    def kw(self, built: dict, burner: bool) -> float:
        total = 0.0 if burner else self.labs * self.d.machines["lab"].kw
        for (r, m), n in built.items():
            if self.d.machines[m].burner == burner:
                total += n * self.d.machines[m].kw
        return total

    def emit(self, recipe: str, machine: str, k: int, **kw) -> None:
        if k <= 0:
            return
        self.built[(recipe, machine)] = self.built.get((recipe, machine), 0) + k
        m = self.d.machines.get(machine)
        chunk = {"furnace": 8, "drill": 8, "assembler": 6, "lab": 4, "silo": 1}.get(m.kind if m else "", 4)
        if machine in (REFINERY, PUMPJACK):
            chunk = 2
        self.stage_tasks.append(Task(f"{self.sname}.{recipe}@{machine}", "build", recipe=recipe, machine=machine,
                                     n=k, after=(self.gid,), chunk=kw.pop("chunk", chunk),
                                     cap=self.caps.get(recipe, 0.0), **kw))

    # --- one stage -----------------------------------------------------------------------
    def stage(self, st: dict, cum: dict, mall: dict) -> None:
        d = self.d
        self.sname, self.gid, self.stage_tasks = st["name"], f"{st['name']}.gate", []
        gate = Task(self.gid, "wait", until=tuple(st["gate"]), note=f"start of stage {st['name']}")
        cum.update(st["targets"])
        mall.update(st.get("mall", {}))
        self.caps.update(st.get("caps", {}))
        for it in mall:
            self.caps.setdefault(it, MALL_CAP)
        mo = {**(ASM1 if st["asm"] == "assembling-machine-1" else {}), "smelting": st["furnace"]}
        plan = rates.rates({k: v * self.scale / 60 for k, v in {**cum, **mall}.items()}, mo)
        for rname, (mach, _n) in plan.machines.items():
            if d.recipes[rname].category not in d.machines[mach].categories:
                raise ValueError(f"{mach} cannot run {rname} ({d.recipes[rname].category})")
        research = [Task(f"{st['name']}.research:{t}", "research", item=t, calls=1, after=(self.gid,))
                    for t in st.get("research", ())]
        # recipe machine groups (the plan lists consumers first; build upstream first)
        for rname, (mach, n) in reversed(list(plan.machines.items())):
            need = n * d.machines[mach].speed / d.recipes[rname].time
            mach = st.get("machine_for", {}).get(rname, mach)
            k = math.ceil((need - self.capacity(rname)) * self.time_of(rname, mach) - 1e-6)
            self.emit(rname, mach, k, distance=20.0, calls=self._calls(mach))
        self._oil(plan)
        n_labs = math.ceil(st["labs"] * self.scale - 1e-6)
        if n_labs > self.labs:
            self.stage_tasks.append(Task(f"{self.sname}.labs", "build", recipe=RESEARCH, machine="lab",
                                         n=n_labs - self.labs, after=(self.gid,), chunk=4, distance=15.0, calls=9))
            self.labs = n_labs
        if st.get("silo"):
            self.built[("rocket-part", "rocket-silo")] = 1                  # counts its power in the sizing
        self._support(plan)
        if st.get("silo"):
            self.stage_tasks.append(Task("final.haul", "deliver", item="concrete", n=1000, distance=300.0,
                                         after=(self.gid,), calls=3, note="stage the silo materials on site"))
            self.stage_tasks.append(Task("final.silo", "build", recipe="rocket-part", machine="rocket-silo", n=1,
                                         after=(self.gid, "final.haul"), distance=40.0, calls=30,
                                         note="needs the silo tech, 1000 concrete, 200 PU, 200 electric engines"))
            self.stage_tasks.append(Task("launch", "launch", after=("final.silo",), calls=3,
                                         note=f"{d.parts_required} rocket parts, then launch"))
            del self.built[("rocket-part", "rocket-silo")]
        self.tasks.append(gate)
        self.tasks.extend(research)
        self.tasks.extend(sorted(self.stage_tasks, key=self._rank))       # stable: plan order within a rank

    def _calls(self, machine: str) -> int | None:
        """Tool calls per build chunk: lay out, place, wire, verify. Furnace columns are simpler than assembly."""
        kind = self.d.machines[machine].kind
        return {"furnace": 8, "drill": 8, "assembler": 12}.get(kind, 12) if machine != "chemical-plant" else 14

    @staticmethod
    def _rank(t: Task) -> int:
        """Coal and power first, then ore, smelting, assembly, oil; the silo and launch stay last."""
        if t.id in ("final.silo", "launch"):
            return 9
        if t.recipe == MINE + "coal" or t.recipe == POWER:
            return 0
        if t.recipe.startswith(MINE) and t.machine != PUMPJACK:
            return 1
        if t.machine in ("stone-furnace", "steel-furnace", "electric-furnace"):
            return 2
        return 5 if t.machine in (REFINERY, PUMPJACK) else 3

    def _oil(self, plan) -> None:
        d = self.d
        pg, lo, ho = (plan.raw.get(f, 0.0) for f in ("petroleum-gas", "light-oil", "heavy-oil"))
        if pg + lo + ho <= 0:
            return
        supply = {"petroleum-gas": 0.0, "light-oil": 0.0, "heavy-oil": 0.0}
        for (r, m), n in self.built.items():
            if r in ("basic-oil-processing", "advanced-oil-processing"):
                rec = d.recipes[r]
                for f in supply:
                    supply[f] += n * rec.out.get(f, 0.0) / self.time_of(r, m)
        rn = "advanced-oil-processing" if (lo > 0 or ho > 0) else "basic-oil-processing"
        rec = d.recipes[rn]
        crafts = max((need - supply[f]) / rec.out[f]
                     for f, need in (("petroleum-gas", pg), ("light-oil", lo), ("heavy-oil", ho)) if f in rec.out)
        self.emit(rn, REFINERY, math.ceil(max(0.0, crafts) * self.time_of(rn, REFINERY) - 1e-6),
                  distance=150.0, calls=16)
        crude = sum(n / self.time_of(r, m) * d.recipes[r].inp["crude-oil"]
                    for (r, m), n in self.built.items() if r in ("basic-oil-processing", "advanced-oil-processing"))
        per_jack = d.resources["crude-oil"].out["crude-oil"] * self.oil_yield / self.time_of(
            MINE + "crude-oil", PUMPJACK)
        self.emit(MINE + "crude-oil", PUMPJACK,
                  math.ceil(crude / per_jack - 1e-6) - self.built.get((MINE + "crude-oil", PUMPJACK), 0),
                  distance=150.0, calls=12, chunk=3)

    def _support(self, plan) -> None:
        """Ore and coal drills plus boilers; coal feeds burners and boilers, drills and boilers draw power."""
        d = self.d
        drills = {ore: self.built.get((MINE + ore, DRILL), 0) for ore in ("iron-ore", "copper-ore", "coal", "stone")}
        boilers = self.boilers
        for _ in range(8):
            trial = dict(self.built)
            for ore, n in drills.items():
                trial[(MINE + ore, DRILL)] = n
            kw_e = self.kw(trial, burner=False)
            coal_s = (self.kw(trial, burner=True) + kw_e * 0.9) / d.coal_kj
            new = {}
            for ore in drills:
                res = d.resources[ore]
                per_drill = d.machines[DRILL].speed / res.time * res.out[ore]
                other = sum(n / self.time_of(r, m) * res.out[ore] for (r, m), n in self.built.items()
                            if r == MINE + ore and m != DRILL)
                raw = plan.raw.get(ore, 0.0) + (coal_s if ore == "coal" else 0.0)
                new[ore] = max(drills[ore], math.ceil((raw - other) / per_drill - 1e-6))
            nb = max(boilers, math.ceil(kw_e * MARGIN / min(d.boiler_kw, 2 * d.engine_kw) - 1e-6))
            if new == drills and nb == boilers:
                break
            drills, boilers = new, nb
        for ore, n in drills.items():
            self.emit(MINE + ore, DRILL, n - self.built.get((MINE + ore, DRILL), 0),
                      distance=100.0 if ore == "copper-ore" else 80.0, calls=8)
        if boilers > self.boilers:
            self.stage_tasks.append(Task(f"{self.sname}.power", "build", recipe=POWER, machine="boiler",
                                         n=boilers - self.boilers, after=(self.gid,), chunk=2, distance=30.0,
                                         calls=12))
            self.boilers = boilers


def default_build_order(scale: float = 1.0, oil_yield: float = 2.0, data: GameData | None = None,
                        stages: list[dict] | None = None) -> BuildOrder:
    """Expand STAGES into a BuildOrder. `scale` multiplies every production target (and the lab count)."""
    ex = _Expander(data or load(), scale, oil_yield)
    cum: dict[str, float] = {}
    mall: dict[str, float] = {}
    for st in STAGES if stages is None else stages:
        ex.stage(st, cum, mall)
    return BuildOrder(ex.tasks, dict(START_ITEMS), list(MILESTONES), TRACK)
