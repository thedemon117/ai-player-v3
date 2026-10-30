"""Sim A world state: pooled item stocks, machine groups, research, power.

Machines run at L1 rates (count x speed / recipe time, the same arithmetic as lpf.rates) when their inputs
and power suffice. Throttling is a fair share of the stock among consumers, stepped in coarse ticks; there
are no belts, tiles or positions.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from .data import MINE, POWER, RESEARCH, GameData


@dataclass
class Spec:
    """What one machine of a group does per craft (times already divided by machine speed)."""
    time: float
    inp: dict[str, float]
    out: dict[str, float]
    kw: float                  # electric draw while crafting (0 for burner machines)
    mining: str = ""           # resource name for drills (counts toward mine-entity triggers)
    fluid_out: bool = False    # fluid or multi-product outputs are never back-pressured (assumes sinks)


@dataclass
class Group:
    recipe: str
    machine: str
    spec: Spec
    count: int = 0
    cap: float = 0.0           # >0: stop crafting while the main output stock is above this (mall items)
    util: float = 0.0          # fraction of nominal output achieved in the last tick
    first_at: float = -1.0


def make_spec(data: GameData, recipe: str, machine: str, oil_yield: float) -> Spec:
    m = data.machines[machine]
    if recipe == RESEARCH:                       # labs are stepped by World._research, not as a recipe
        return Spec(1.0, {}, {}, 0.0)
    if recipe.startswith(MINE):
        res = data.resources[recipe[len(MINE):]]
        mult = oil_yield if res.fluid else 1.0
        time = res.time / m.speed
        spec = Spec(time, {}, {k: v * mult for k, v in res.out.items()}, 0.0, recipe[len(MINE):], res.fluid)
    else:
        r = data.recipes[recipe]
        spec = Spec(r.time / m.speed, dict(r.inp), dict(r.out), 0.0, "", r.fluid and len(r.out) != 1 or len(r.out) > 1)
    if m.burner:
        fuel = m.kw * spec.time / data.coal_kj
        if "coal" in spec.out:                   # a burner drill on coal feeds itself: report the net yield
            spec.out["coal"] -= fuel
        else:
            spec.inp["coal"] = spec.inp.get("coal", 0.0) + fuel
    else:
        spec.kw = m.kw
    return spec


class World:
    def __init__(self, data: GameData, start: dict[str, float] | None = None, oil_yield: float = 2.0,
                 reserve_frac: float = 0.5, buffer_s: float = 600.0, hand_limit_s: float = 90.0):
        self.data = data
        self.t = 0.0
        self.oil_yield = oil_yield
        self.reserve_frac = reserve_frac
        self.buffer_s = buffer_s
        self.hand_limit_s = hand_limit_s
        self.stock: dict[str, float] = defaultdict(float, start or {})
        self.produced: dict[str, float] = defaultdict(float)     # cumulative, any source
        self.mined: dict[str, float] = defaultdict(float)
        self.built: dict[str, float] = defaultdict(float)        # machine item -> entities placed
        self.groups: dict[tuple[str, str], Group] = {}
        self.producers: dict[str, int] = defaultdict(int)         # item -> number of working groups
        self.power: dict[str, int] = defaultdict(int)             # boiler / solar-panel counts
        self.researched: dict[str, float] = {}
        self.queue: list[str] = []
        self.progress = 0.0
        self.current: str | None = None
        self.lab_bonus = 0.0
        self.reserve: dict[str, float] = {}                       # items agents are saving up (set by the dispatcher)
        self.pgen = 0                                             # bumps when a new item gets a producer
        self.epoch = 0                                            # bumps when feasibility of a task may change
        self.starved: dict[tuple[str, str], float] = defaultdict(float)   # (recipe, item) -> machine-seconds lost
        self.power_short_kwh = 0.0
        self.lab_wait: dict[str, float] = defaultdict(float)      # pack -> lab-seconds lost
        self._demand_kw = 0.0
        self._order: list[Group] = []
        self._dirty = True
        self._triggers = [n for n, tc in data.techs.items() if tc.trigger]

    # --- queries -----------------------------------------------------------------------
    def has_producer(self, item: str) -> bool:
        return self.producers.get(item, 0) > 0

    def tech_lock(self, recipe: str) -> str | None:
        """Name of the tech still blocking `recipe`, else None."""
        r = self.data.recipes.get(recipe)
        if r is None or r.enabled:
            return None
        cands = self.data.unlockers.get(recipe)
        if not cands or any(c in self.researched for c in cands):
            return None
        return self.data.cheapest_unlocker(recipe)

    def power_cap_kw(self) -> float:
        return (self.power.get("boiler", 0) * min(self.data.boiler_kw, 2 * self.data.engine_kw)
                + self.power.get("solar-panel", 0) * self.data.solar_kw)

    def power_mw(self) -> tuple[float, float]:
        return self.power_cap_kw() / 1000, self._demand_kw / 1000

    def count(self, recipe: str, machine: str | None = None) -> int:
        return sum(g.count for (r, m), g in self.groups.items() if r == recipe and (machine in (None, m)))

    # --- mutation ----------------------------------------------------------------------
    def add_machines(self, recipe: str, machine: str, n: int, cap: float = 0.0) -> None:
        if recipe == POWER:
            self.power[machine] += n
            self.built[machine] += n
            self.epoch += 1
            return
        key = (recipe, machine)
        g = self.groups.get(key)
        if g is None:
            g = self.groups[key] = Group(recipe, machine, make_spec(self.data, recipe, machine, self.oil_yield),
                                         cap=cap, first_at=self.t)
            self._dirty = True
        if g.count == 0:
            for item in g.spec.out:
                self.producers[item] += 1
            self.pgen += 1
        g.count += n
        self.built[machine] += n
        self.epoch += 1

    def add_stock(self, item: str, n: float) -> None:
        self.stock[item] += n
        self.produced[item] += n
        self.epoch += 1

    def _complete(self, name: str, t: float) -> None:
        if name in self.researched:
            return
        self.researched[name] = t
        self.lab_bonus += self.data.techs[name].lab_speed
        self.epoch += 1

    def queue_research(self, tech: str) -> None:
        for n in self.data.closure(tech, self.researched):
            if n not in self.queue and not self.data.techs[n].trigger:
                self.queue.append(n)

    # --- stepping ----------------------------------------------------------------------
    def _sort(self) -> None:
        """Order groups so producers come before their consumers (cycles broken by insertion order)."""
        gs = [g for g in self.groups.values() if g.count > 0 and g.recipe != RESEARCH]
        by_out: dict[str, list[Group]] = defaultdict(list)
        for g in gs:
            for o in g.spec.out:
                by_out[o].append(g)
        order: list[Group] = []
        state: dict[int, int] = {}

        def visit(g: Group) -> None:
            if state.get(id(g)):
                return
            state[id(g)] = 1
            for i in g.spec.inp:
                for p in by_out.get(i, ()):
                    if p is not g:
                        visit(p)
            order.append(g)
        for g in gs:
            visit(g)
        self._order = order
        self._dirty = False

    def tick(self, dt: float) -> None:
        """Advance production and research by dt seconds."""
        if self._dirty or len(self._order) != sum(1 for g in self.groups.values()
                                                  if g.count > 0 and g.recipe != RESEARCH):
            self._sort()
        stock = self.stock
        data = self.data
        t_end = self.t + dt
        # power
        cap, demand = self.power_cap_kw(), self._demand_kw
        pf = 1.0 if demand <= 1e-9 else min(1.0, cap / demand)
        if cap <= 0 and (self.groups.get((RESEARCH, "lab")) or any(g.spec.kw > 0 for g in self._order)):
            pf = 0.0                                              # electric machines and no generator yet
        if pf < 1.0:
            self.power_short_kwh += (demand - cap) * dt / 3600
        boil = self.power.get("boiler", 0) * min(data.boiler_kw, 2 * data.engine_kw)
        if boil > 0 and demand > 0:
            coal_need = min(demand, boil) * dt / data.coal_kj           # boilers burn what the grid draws
            have = stock["coal"]
            f = 1.0 if have >= coal_need else have / coal_need
            stock["coal"] = have - coal_need * f
            if f < 1.0:
                pf *= f
        # desired crafts and remaining demand per input
        want: dict[int, float] = {}
        rem: dict[str, float] = defaultdict(float)
        for g in self._order:
            sp = g.spec
            d = g.count * dt / sp.time * (pf if sp.kw > 0 else 1.0)
            if sp.out and not sp.fluid_out:                   # back-pressure: full buffers stop the machines
                main = next(iter(sp.out))
                cap = g.cap if g.cap > 0 else self.buffer_s * g.count * sp.out[main] / sp.time
                cap = max(cap, self.reserve.get(main, 0.0))        # builders saving up for it
                d = min(d, max(0.0, (cap - stock[main]) / sp.out[main]))
            want[id(g)] = d
            for i, a in sp.inp.items():
                rem[i] += d * a
        reserve, rf = self.reserve, self.reserve_frac
        kw_used = 0.0
        for g in self._order:
            sp = g.spec
            d = want[id(g)]
            s = 1.0
            lim = ""
            if d > 0:
                for i, a in sp.inp.items():
                    need = rem[i]
                    if need <= 1e-12:
                        continue
                    avail = stock[i]
                    if i in reserve:                       # leave builders their share of what they save up
                        avail = max(avail * (1 - rf), avail - reserve[i])
                    r = avail / need
                    if r < s:
                        s, lim = r, i
                if s < 0:
                    s = 0.0
            crafts = d * s
            for i, a in sp.inp.items():
                stock[i] -= crafts * a
                rem[i] -= d * a
            if crafts > 0:
                for o, a in sp.out.items():
                    stock[o] += crafts * a
                    self.produced[o] += crafts * a
                if sp.mining:
                    self.mined[sp.mining] += crafts * sum(sp.out.values())
            nominal = g.count * dt / sp.time
            g.util = crafts / nominal if nominal > 0 else 0.0
            if lim and s < 0.999:
                self.starved[(g.recipe, lim)] += (d - crafts) * sp.time
            kw_used += sp.kw * g.count * g.util
        lab_kw = self._research(dt, t_end, pf)
        self._demand_kw = kw_used + lab_kw
        self.t = t_end
        self._triggered(t_end)
        self.epoch += 1

    def _triggered(self, t: float) -> None:
        for n in self._triggers:
            if n in self.researched:
                continue
            tc = self.data.techs[n]
            if any(p not in self.researched for p in tc.prereqs):
                continue
            tr = tc.trigger
            kind = tr.get("type")
            ok = False
            if kind == "craft-item":
                ok = self.produced.get(tr["item"], 0) >= tr.get("count", 1)
            elif kind == "mine-entity":
                # 2.0: `entity`; 2.1: `entities` (a list)
                names = tr.get("entities") or [tr["entity"]]
                ok = any(self.mined.get(n, 0) > 0 for n in names)
            elif kind == "build-entity":
                ok = self.built.get(tr["entity"], 0) > 0
            if ok:
                self._complete(n, t)

    def _pick(self) -> str | None:
        """First queued tech whose prerequisites are done and whose packs are in stock."""
        for n in self.queue:
            tc = self.data.techs[n]
            if n in self.researched or any(p not in self.researched for p in tc.prereqs):
                continue
            if all(self.stock[p] >= a for p, a in tc.packs.items()):
                return n
        return None

    def _research(self, dt: float, t_end: float, pf: float) -> float:
        labs = self.groups.get((RESEARCH, "lab"))
        n_labs = labs.count if labs else 0
        if n_labs == 0:
            return 0.0
        self.queue = [n for n in self.queue if n not in self.researched]
        speed = (1.0 + self.lab_bonus) * self.data.machines["lab"].speed * pf
        left = dt
        busy = 0.0
        while left > 1e-9:
            cur = self.current
            if cur is None or cur in self.researched:
                cur = self.current = self._pick()
                self.progress = 0.0
                if cur is None:
                    for n in self.queue:                                   # record which pack blocked the labs
                        tc = self.data.techs[n]
                        if all(p in self.researched for p in tc.prereqs):
                            miss = next((p for p, a in tc.packs.items() if self.stock[p] < a), None)
                            if miss:
                                self.lab_wait[miss] += left * n_labs
                                break
                    break
            tc = self.data.techs[cur]
            rate = n_labs * speed / tc.time                                  # units / s
            if rate <= 0:
                break
            units = min(tc.count - self.progress, rate * left)
            for p, a in tc.packs.items():
                units = min(units, self.stock[p] / a)
            if units <= 1e-12:
                miss = next((p for p, a in tc.packs.items() if self.stock[p] < a), None)
                if miss:
                    self.lab_wait[miss] += left * n_labs
                break
            for p, a in tc.packs.items():
                self.stock[p] -= units * a
            self.progress += units
            used = units / rate
            busy += used
            left -= used
            if self.progress >= tc.count - 1e-9:
                self._complete(cur, t_end - left)
                self.current = None
            else:
                if left > 1e-9:                                              # pack-limited
                    miss = next((p for p, a in tc.packs.items() if self.stock[p] < a * 1e-3 + 1e-9), None)
                    if miss:
                        self.lab_wait[miss] += left * n_labs
                break
        return self.data.machines["lab"].kw * n_labs * busy / dt

    # --- reporting ---------------------------------------------------------------------
    def snapshot(self, items) -> dict:
        cap, dem = self.power_mw()
        return {"t": round(self.t), "produced": {i: round(self.produced.get(i, 0)) for i in items},
                "researched": len(self.researched), "power_mw": [round(cap, 2), round(dem, 2)],
                "machines": {f"{r}@{m}": g.count for (r, m), g in self.groups.items() if g.count}}
