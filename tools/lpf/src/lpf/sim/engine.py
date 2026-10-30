"""Sim A engine: agents pull tasks from the DAG, the world produces, results come out.

Time is wall seconds from the start of the run. Agents are the only thing that costs LLM latency; the world
is stepped in coarse ticks (SimConfig.step) and agents re-check blocked work at each tick.
"""
from __future__ import annotations

import bisect
import json
import math
import statistics
from collections import defaultdict
from dataclasses import asdict, dataclass, field

from .core import EventLoop
from .data import MINE, POWER, RESEARCH, GameData, load
from .tasks import BuildOrder, Need, Task, build_items, cond_met, plan_need
from .world import World

BUDGET_WALL_H = 168.0           # run rules: T <= 168 h wall
BUDGET_AGENT_H = 1000.0         # and N * T <= 1000 agent-hours
DEFAULT_CALLS = {"hand_mine": 3, "hand_craft": 3, "build": 10, "deliver": 3, "research": 2, "launch": 4}


@dataclass
class SimConfig:
    agents: int = 4                       # N, including the planner (agent 0)
    seed: int = 0
    latency_median: float = 25.0          # s per LLM tool call (lognormal median)
    latency_sigma: float = 0.6
    mistake_p: float = 0.15               # chance a task chunk needs a retry
    step: float = 120.0                   # world tick (s)
    max_hours: float = 336.0              # give up after this much wall time
    plan_period: float = 1800.0           # planner replans this often ...
    plan_calls: int = 4                   # ... costing this many calls + coord_calls per extra agent
    coord_calls: float = 0.5
    place_s: float = 1.5                  # game seconds to place one machine with its glue
    entities_per_call: float = 2.0        # machines laid out per build tool call
    call_scale: float = 1.0               # multiplies every task's base tool-call count
    oil_yield: float = 2.0                # crude-oil patch yield (x100%) per pumpjack
    buffer_s: float = 600.0               # machines stop when their output stock exceeds this many seconds of it
    hand_limit_s: float = 90.0            # shortfalls of machine-made items up to this much hand-crafting are crafted
    reserve_frac: float = 0.5             # share of a saved-for item that machines leave to waiting builders
    launch_s: float = 120.0               # rocket rising and launch sequence
    stagger_s: float = 0.0                # agent i joins at i * stagger_s
    trace_every: float = 900.0
    keep_spans: bool = True


@dataclass
class AgentStat:
    id: int
    role: str
    busy_h: float
    idle_h: float
    busy_frac: float
    chunks: int


@dataclass
class Result:
    agents: int
    seed: int
    finished: bool
    time_h: float
    milestones: dict[str, float]
    agent_stats: list[AgentStat]
    agent_hours: float                    # sum over agents of time on the clock (N * T)
    busy_agent_hours: float
    blockers: dict[str, float]            # idle agent-hours by what blocked the next task
    starvation: dict[str, float]          # machine-hours lost, "recipe<-item"
    lab_wait: dict[str, float]            # lab-hours lost per science pack
    power_short_mwh: float
    spans: list[list] = field(default_factory=list)       # [agent, task, kind, chunk, t0_h, t1_h]
    timeline: list[dict] = field(default_factory=list)

    @property
    def feasible(self) -> bool:
        return self.finished and self.time_h <= BUDGET_WALL_H and self.agent_hours <= BUDGET_AGENT_H

    def to_dict(self) -> dict:
        d = asdict(self)
        d["feasible"] = self.feasible
        return d

    def to_json(self, indent: int | None = 1) -> str:
        return json.dumps(self.to_dict(), indent=indent)


class _St:
    __slots__ = ("task", "idx", "remaining", "inflight", "deps", "ready_t", "done")

    def __init__(self, task: Task, idx: int):
        self.task, self.idx = task, idx
        self.remaining = task.n
        self.inflight = 0
        self.deps = len(task.after)
        self.ready_t = 0.0
        self.done = False


class _Agent:
    def __init__(self, idx: int, rng, join: float):
        self.idx, self.rng, self.join = idx, rng, join
        self.busy = False
        self.busy_s = 0.0
        self.work_t = 0.0
        self.work_dur = 0.0
        self.idle_since = join
        self.reason = "start"
        self.chunks = 0
        self.joined = False


class Simulation:
    def __init__(self, order: BuildOrder, cfg: SimConfig, data: GameData | None = None):
        order.validate()
        self.cfg, self.order = cfg, order
        self.data = data or load()
        self.loop = EventLoop(cfg.seed)
        self.w = World(self.data, order.start_items, cfg.oil_yield, cfg.reserve_frac, cfg.buffer_s, cfg.hand_limit_s)
        self.st = {t.id: _St(t, i) for i, t in enumerate(order.tasks)}
        self.succ: dict[str, list[str]] = defaultdict(list)
        for t in order.tasks:
            for a in t.after:
                self.succ[a].append(t.id)
            if t.kind == "research" and t.item not in self.data.techs:
                raise ValueError(f"{t.id}: unknown tech {t.item}")
        self.ready: list[_St] = []
        self.done: dict[str, float] = {}
        for s in self.st.values():
            if s.deps == 0:
                self.ready.append(s)
        self.agents = [_Agent(i, self.loop.rng(i), i * cfg.stagger_s) for i in range(cfg.agents)]
        self.milestones: dict[str, float] = {}
        self.pending_ms = list(order.milestones)
        self.blockers: dict[str, float] = defaultdict(float)
        self.spans: list[list] = []
        self.timeline: list[dict] = []
        self.next_plan = cfg.plan_period
        self.fail_epoch = -1
        self.fail_reason = "deps"
        self.blocked: dict[str, tuple] = {}
        self.blocked_pgen = -1
        self.finished_at: float | None = None
        self._next_trace = 0.0

    # --- sampling -----------------------------------------------------------------------
    def _lat(self, ag: _Agent) -> float:
        c = self.cfg
        if c.latency_sigma <= 0:
            return c.latency_median
        return ag.rng.lognormvariate(math.log(c.latency_median), c.latency_sigma)

    def _calls_time(self, ag: _Agent, calls: int) -> float:
        return sum(self._lat(ag) for _ in range(calls))

    # --- task quoting -------------------------------------------------------------------
    def _walk(self, task: Task) -> float:
        return 2 * task.distance / self.data.char_speed

    def _quote(self, st: _St, c: float):
        """-> (Need, game seconds, calls, outputs) for doing c units of the task now."""
        t, d, w, cfg = st.task, self.data, self.w, self.cfg
        k = t.kind
        base = t.calls if t.calls is not None else DEFAULT_CALLS.get(k, 1)
        calls = max(1, round(base * cfg.call_scale))
        if k == "hand_mine":
            res = d.resources[t.item]
            return Need({}, 0.0, {}, []), self._walk(t) + c * res.time / d.char_mining, calls, \
                {i: a * c for i, a in res.out.items()}
        if k == "hand_craft":
            rn = d.hand_recipe.get(t.item)
            if rn is None:
                return Need({}, 0.0, {t.item: c}, []), 0.0, calls, {}
            r = d.recipes[rn]
            lock = w.tech_lock(rn)
            if lock:
                return Need({}, 0.0, {}, [lock]), 0.0, calls, {}
            crafts = math.ceil(c / r.out[t.item] - 1e-9)
            need = plan_need(w, {i: a * crafts for i, a in r.inp.items()})
            return need, self._walk(t) + crafts * r.time + need.hand_s, calls, {t.item: crafts * r.out[t.item]}
        if k == "build":
            lock = w.tech_lock(t.recipe) if not t.recipe.startswith(MINE) and t.recipe not in (RESEARCH, POWER) \
                else None
            if lock:
                return Need({}, 0.0, {}, [lock]), 0.0, calls, {}
            need = plan_need(w, build_items(w, t, int(c)))
            return need, self._walk(t) + c * cfg.place_s + need.hand_s, \
                calls + math.ceil(c / cfg.entities_per_call), {}
        if k == "deliver":
            have = w.stock.get(t.item, 0.0)
            levels = {t.item: c} if have < c else {}
            trips = max(1, math.ceil(c / (d.char_inventory * d.stack.get(t.item, 50))))
            return Need({}, 0.0, levels, []), trips * self._walk(t), calls + trips - 1, {}
        if k == "launch":
            need = plan_need(w, {"rocket-part": float(d.parts_required)})
            return need, cfg.launch_s, calls, {}
        return Need({}, 0.0, {}, []), 0.0, calls, {}             # research: queueing is just tool calls

    def _try_task(self, st: _St):
        """-> ('start', c, need, game_s, calls, out) or ('blocked', Need)."""
        t = st.task
        c0 = min(st.remaining, t.chunk if t.chunk else st.remaining)
        c = c0
        whole = t.kind in ("hand_mine", "deliver", "launch", "research")
        last = None
        while True:
            need, game_s, calls, out = self._quote(st, c)
            if need.ok:
                return "start", c, need, game_s, calls, out
            last = need
            if whole or c <= 1:
                break
            c = float(max(1, int(c) // 2))
        return "blocked", last

    # --- agent actions ------------------------------------------------------------------
    def _flush_idle(self, ag: _Agent, t: float) -> None:
        if t > ag.idle_since:
            self.blockers[ag.reason] += t - ag.idle_since
        ag.idle_since = t

    def _scan(self, ag: _Agent):
        """Find the first startable ready task. Returns (task state, quote) or (None, reason)."""
        w = self.w
        if self.blocked_pgen != w.pgen:
            self.blocked.clear()
            self.blocked_pgen = w.pgen
        first_reason, first_levels = None, None
        for st in self.ready:
            task = st.task
            if task.kind == "wait" or st.remaining <= 1e-9:
                continue
            ent = self.blocked.get(task.id)
            if ent is not None:
                levels, techs, reason = ent
                short = any(w.stock.get(i, 0.0) < lv for i, lv in levels.items())
                if short or any(x not in w.researched for x in techs):
                    if first_reason is None:                       # still short of something: skip the re-quote
                        first_reason, first_levels = reason, levels
                    continue
            res = self._try_task(st)
            if res[0] == "start":
                w.reserve = first_levels or {}
                return st, res
            need = res[1]
            for x in need.techs:                     # an agent that needs a recipe queues its tech
                w.queue_research(x)
            self.blocked[task.id] = (need.levels, need.techs, need.reason())
            if first_reason is None:
                first_reason, first_levels = need.reason(), need.levels
        w.reserve = first_levels or {}
        return None, first_reason or "deps"

    def _begin(self, ag: _Agent, st: _St, q) -> None:
        _, c, need, game_s, calls, out = q
        w, t = self.w, self.loop.now
        task = st.task
        for i, a in need.take.items():
            w.stock[i] -= a
        for i, a in need.crafted.items():
            w.produced[i] += a
        st.remaining -= c
        st.inflight += 1
        lat = self._calls_time(ag, calls)
        dur = lat + game_s
        tries = 0
        while ag.rng.random() < self.cfg.mistake_p and tries < 3:
            tries += 1
            dur += self._calls_time(ag, calls // 2 + 1) + 0.5 * self._walk(task)
        self._flush_idle(ag, t)
        ag.busy, ag.work_t, ag.work_dur = True, t, dur
        ag.chunks += 1
        if self.cfg.keep_spans:
            self.spans.append([ag.idx, task.id, task.kind, c, round(t / 3600, 4), round((t + dur) / 3600, 4)])
        self.loop.at(t + dur, self._finish_chunk, ag, st, c, out)

    def _begin_plan(self, ag: _Agent) -> None:
        cfg, t = self.cfg, self.loop.now
        calls = cfg.plan_calls + math.ceil(cfg.coord_calls * (cfg.agents - 1))
        dur = self._calls_time(ag, calls)
        self.next_plan = t + dur + cfg.plan_period
        self._flush_idle(ag, t)
        ag.busy, ag.work_t, ag.work_dur = True, t, dur
        if cfg.keep_spans:
            self.spans.append([ag.idx, "plan", "plan", 1, round(t / 3600, 4), round((t + dur) / 3600, 4)])
        self.loop.at(t + dur, self._free, ag)

    def _free(self, ag: _Agent) -> None:
        if ag.busy:
            ag.busy_s += ag.work_dur
        ag.busy = False
        ag.idle_since = self.loop.now
        if not self._start_for(ag):
            ag.reason = self.fail_reason

    def _start_for(self, ag: _Agent) -> bool:
        t = self.loop.now
        if ag.idx == 0 and t >= self.next_plan:
            self._begin_plan(ag)
            return True
        if self.fail_epoch == self.w.epoch:
            return False
        st, res = self._scan(ag)
        if st is None:
            self.fail_epoch, self.fail_reason = self.w.epoch, res
            return False
        self._begin(ag, st, res)
        return True

    def _finish_chunk(self, ag: _Agent, st: _St, c: float, out: dict) -> None:
        t, w = self.loop.now, self.w
        task = st.task
        k = task.kind
        if k == "hand_mine":
            for i, a in out.items():
                w.add_stock(i, a)
            w.mined[task.item] += c
        elif k == "hand_craft":
            for i, a in out.items():
                w.add_stock(i, a)
        elif k == "build":
            self._sync(t)                          # machines count from the moment they are placed
            w.add_machines(task.recipe, task.machine, int(c), task.cap)
        elif k == "research":
            self._sync(t)
            w.queue_research(task.item)
        elif k == "launch":
            self.milestones.setdefault("launch", t / 3600)
        st.inflight -= 1
        self.fail_epoch = -1
        if st.remaining <= 1e-9 and st.inflight == 0:
            self._complete(st, t)
        self._check(t)
        if self.finished_at is not None:
            self.loop.stop()
            return
        self._free(ag)

    def _complete(self, st: _St, t: float) -> None:
        if st.done:
            return
        st.done = True
        self.done[st.task.id] = t
        if len(self.done) == len(self.st):
            self.finished_at = t
        i = bisect.bisect_left([s.idx for s in self.ready], st.idx)
        if i < len(self.ready) and self.ready[i] is st:
            self.ready.pop(i)
        for sid in self.succ.get(st.task.id, ()):
            s = self.st[sid]
            s.deps -= 1
            if s.deps == 0:
                s.ready_t = t
                bisect.insort(self.ready, s, key=lambda x: x.idx)
        self.fail_epoch = -1

    def _check(self, t: float) -> None:
        """Gates and milestones."""
        progress = True
        while progress:
            progress = False
            for st in self.ready:
                task = st.task
                if task.kind == "wait" and not st.done and task.until and \
                        cond_met(self.w, task.until, self.done, st.ready_t):
                    self._complete(st, t)
                    progress = True
                    break
        if self.pending_ms:
            keep = []
            for name, cond in self.pending_ms:
                if cond_met(self.w, cond, self.done):
                    self.milestones.setdefault(name, t / 3600)
                else:
                    keep.append((name, cond))
            self.pending_ms = keep

    # --- world tick ---------------------------------------------------------------------
    def _sync(self, t: float) -> None:
        if t - self.w.t > 1e-9:
            self.w.tick(t - self.w.t)

    def _tick(self) -> None:
        t, w, cfg = self.loop.now, self.w, self.cfg
        self._sync(t)
        self._check(t)
        if self.finished_at is not None:
            self.loop.stop()
            return
        self.fail_epoch = -1
        for ag in self.agents:
            if ag.busy:
                continue
            if t < ag.join:
                continue
            self._flush_idle(ag, t)
            if not self._start_for(ag):
                ag.reason = self.fail_reason
        if t >= self._next_trace:
            self.timeline.append(w.snapshot(self.order.track))
            self._next_trace = t + cfg.trace_every
        if t / 3600 < cfg.max_hours:
            self.loop.at(t + cfg.step, self._tick)
        else:
            self.loop.stop()

    def run(self) -> Result:
        cfg = self.cfg
        for ag in self.agents:
            if ag.join > 0:
                ag.reason = "not_started"
        self.loop.at(0.0, self._tick)
        end = self.loop.run(cfg.max_hours * 3600 + cfg.step)
        t_end = self.finished_at if self.finished_at is not None else end
        for ag in self.agents:
            if ag.busy:
                ag.busy_s += max(0.0, min(t_end - ag.work_t, ag.work_dur))
            elif t_end > ag.idle_since:
                self.blockers[ag.reason] += t_end - ag.idle_since
        total_h = t_end / 3600
        stats, busy_total, clock_total = [], 0.0, 0.0
        for ag in self.agents:
            on = max(0.0, t_end - ag.join)
            busy = min(ag.busy_s, on)
            clock_total += on
            busy_total += busy
            stats.append(AgentStat(ag.idx, "planner" if ag.idx == 0 else "worker", round(busy / 3600, 3),
                                   round((on - busy) / 3600, 3), round(busy / on, 3) if on else 0.0, ag.chunks))
        blockers = {k: round(v / 3600, 3) for k, v in sorted(self.blockers.items(), key=lambda kv: -kv[1])
                    if k != "not_started" and v > 0}
        starv = {f"{r}<-{i}": round(v / 3600, 3)
                 for (r, i), v in sorted(self.w.starved.items(), key=lambda kv: -kv[1])[:12]}
        lab = {p: round(v / 3600, 3) for p, v in sorted(self.w.lab_wait.items(), key=lambda kv: -kv[1])}
        return Result(
            agents=cfg.agents, seed=cfg.seed, finished=self.finished_at is not None, time_h=round(total_h, 5),
            milestones={k: round(v, 4) for k, v in self.milestones.items()}, agent_stats=stats,
            agent_hours=round(clock_total / 3600, 2), busy_agent_hours=round(busy_total / 3600, 2),
            blockers=blockers, starvation=starv, lab_wait=lab,
            power_short_mwh=round(self.w.power_short_kwh / 1000, 2), spans=self.spans, timeline=self.timeline)


def simulate(order: BuildOrder | None = None, cfg: SimConfig | None = None, **kw) -> Result:
    """One rollout. simulate(agents=8, seed=1, latency_median=20) uses the default rocket build order."""
    cfg = cfg or SimConfig(**kw)
    if order is None:
        from .buildorder import default_build_order
        order = default_build_order()
    return Simulation(order, cfg).run()


def sweep(agents: range | list[int], repeats: int = 1, seed: int = 0, order: BuildOrder | None = None,
          **kw) -> list[dict]:
    """Rollouts for each N (mean over `repeats` seeds). Rows: n, time_h, agent_hours, busy_frac, feasible."""
    if order is None:
        from .buildorder import default_build_order
        order = default_build_order()
    rows = []
    for n in agents:
        rs = [Simulation(order, SimConfig(agents=n, seed=seed + k, keep_spans=False, **kw)).run()
              for k in range(repeats)]
        ok = [r for r in rs if r.finished]
        T = statistics.mean(r.time_h for r in rs)
        rows.append({
            "n": n, "time_h": round(T, 2), "finished": len(ok), "repeats": repeats,
            "agent_hours": round(n * T, 1),
            "busy_frac": round(statistics.mean(sum(a.busy_h for a in r.agent_stats)
                                               / max(1e-9, sum(a.busy_h + a.idle_h for a in r.agent_stats))
                                               for r in rs), 3),
            "feasible": all(r.feasible for r in rs),
            "top_blocker": max(rs[0].blockers.items(), key=lambda kv: kv[1])[0] if rs[0].blockers else "",
        })
    return rows
