"""Sim A (plan model): determinism, scaling with N, hand-checkable scenarios, calibration hook."""
from __future__ import annotations

import json
import math
import statistics
import tempfile
from pathlib import Path

import pytest

from lpf import rates
from lpf.protos import game_data_dir

pytestmark = pytest.mark.skipif(not (game_data_dir() / "data-raw-dump.json").exists(),
                                reason="needs data/game/data-raw-dump.json")

from lpf.sim import BuildOrder, SimConfig, Simulation, Task, default_build_order, simulate  # noqa: E402
from lpf.sim.calibrate import calibrate, fit_latency, observed_milestones  # noqa: E402
from lpf.sim.cli import parse_agents  # noqa: E402
from lpf.sim.data import MINE, load  # noqa: E402
from lpf.sim.world import World  # noqa: E402


def _dump_is_2_0() -> bool:
    """These assertions were calibrated on Factorio 2.0.77 data. 2.1 changed recipes
    (rocket-part now takes 1 of each ingredient instead of 10), so the rollout numbers
    differ; the tests that pin them are skipped there rather than silently re-baselined."""
    try:
        rp = load().recipes["rocket-part"]
        return all(v == 10 for v in rp.inp.values())
    except Exception:
        return False


needs_2_0_data = pytest.mark.skipif(not _dump_is_2_0(), reason="pinned to Factorio 2.0.77 recipe data")

QUIET = dict(latency_sigma=0.0, mistake_p=0.0, latency_median=10.0, plan_period=1e9)


@pytest.fixture(scope="module")
def order():
    return default_build_order()


@needs_2_0_data
def test_game_numbers_come_from_the_dump():
    d = load()
    rp = d.recipes["rocket-part"]
    assert rp.inp == {"processing-unit": 10, "low-density-structure": 10, "rocket-fuel": 10}
    assert d.parts_required == 100
    assert d.char_mining == 0.5 and d.char_speed == pytest.approx(9.0)
    assert d.techs["rocket-silo"].count == 1000 and len(d.techs["rocket-silo"].packs) == 5
    assert d.techs["steam-power"].trigger["type"] == "craft-item"


def test_world_matches_l1_rates():
    """A furnace group makes 1/3.2 plates/s and burns coal; 4 gear assemblers match lpf.rates."""
    d = load()
    w = World(d, {"iron-ore": 100, "coal": 10})
    w.add_machines("iron-plate", "stone-furnace", 1)
    w.tick(64.0)
    assert w.produced["iron-plate"] == pytest.approx(20.0)                    # 64 s / 3.2 s
    assert w.stock["coal"] == pytest.approx(10 - 20 * 90 * 3.2 / 4000)        # 90 kW furnace, 4 MJ coal
    plan = rates.rates({"iron-gear-wheel": 1.0}, {"crafting": "assembling-machine-2"})
    machine, n = plan.machines["iron-gear-wheel"]
    w2 = World(d, {"iron-plate": 1e6}, buffer_s=1e9)
    w2.add_machines("power", "boiler", 10)                                    # plenty of power
    w2.add_machines("iron-gear-wheel", machine, 1)
    w2.tick(100.0)
    assert w2.produced["iron-gear-wheel"] == pytest.approx(100.0 / n, rel=1e-6)   # one machine = 1/n of 1 gear/s


def test_hand_mining_task_duration_is_hand_checkable():
    # 2 calls x 10 s + 20 ore x (1 s mining time / 0.5 mining speed) = 60 s
    bo = BuildOrder([Task("m", "hand_mine", item="iron-ore", n=20, distance=0, calls=2)])
    r = simulate(bo, SimConfig(agents=1, **QUIET))
    assert r.finished and r.time_h * 3600 == pytest.approx(60.0, abs=0.5)
    assert r.agent_stats[0].busy_frac == pytest.approx(1.0, abs=0.01)


def test_build_then_production_scenario():
    """Mine ore, place a furnace (start stock), wait until 10 plates exist."""
    bo = BuildOrder(
        [Task("ore", "hand_mine", item="iron-ore", n=50, distance=0, calls=1),
         Task("coal", "hand_mine", item="coal", n=10, distance=0, calls=1),
         Task("furn", "build", recipe="iron-plate", machine="stone-furnace", n=1, distance=0, calls=1, infra={}),
         Task("gate", "wait", after=("furn",), until=("produced", "iron-plate", 10))],
        start_items={"stone-furnace": 1})
    sim = Simulation(bo, SimConfig(agents=2, step=10.0, **QUIET))
    r = sim.run()
    assert r.finished
    # coal (10 s call + 10 x 2 s) is mined by agent 1 first; it then places the furnace:
    # 2 calls (plan + place) x 10 s + 1.5 s per machine
    assert sim.done["coal"] == pytest.approx(30.0)
    assert sim.done["furn"] == pytest.approx(30.0 + 20.0 + 1.5)
    assert sim.w.count("iron-plate", "stone-furnace") == 1
    # ore (10 s call + 50 x 2 s = 110 s) is the last input; 10 crafts of 3.2 s follow, resolved to one 10 s tick
    assert 110 + 10 * 3.2 - 10.0 <= sim.done["gate"] <= 110 + 10 * 3.2 + 10.0


@needs_2_0_data
def test_blocked_task_reports_missing_item():
    bo = BuildOrder([Task("t", "build", recipe=MINE + "iron-ore", machine="burner-mining-drill", n=1,
                          distance=0, calls=1, infra={})])          # no start items: drill needs plates and stone
    r = simulate(bo, SimConfig(agents=1, max_hours=1.0, **QUIET))
    assert not r.finished
    assert list(r.blockers)[0].startswith("item:")


def test_deterministic_with_seed(order):
    a = simulate(order, SimConfig(agents=4, seed=7))
    b = simulate(order, SimConfig(agents=4, seed=7))
    c = simulate(order, SimConfig(agents=4, seed=8))
    assert a.to_json() == b.to_json()
    assert a.time_h != c.time_h


@needs_2_0_data
def test_more_agents_never_slower_in_the_parallel_phase(order):
    """Mean over seeds: N=1 > N=2 > N=4, and N=8 is not slower than N=4 beyond noise."""
    def mean(n):
        return statistics.mean(simulate(order, SimConfig(agents=n, seed=s, keep_spans=False)).time_h
                               for s in range(3))
    t1, t2, t4, t8 = mean(1), mean(2), mean(4), mean(8)
    assert t1 > t2 > t4
    assert t8 <= t4 * 1.05


@needs_2_0_data
def test_default_rollout_is_complete_and_fast(order):
    import time
    t0 = time.perf_counter()
    r = simulate(order, SimConfig(agents=8, seed=1))
    assert time.perf_counter() - t0 < 2.0
    assert r.finished and r.feasible
    ms = r.milestones
    chain = ["burner_mining", "steam_power", "automation_researched", "green_science", "blue_science",
             "silo_researched", "silo_built", "rocket_parts_100", "launch"]
    assert all(c in ms for c in chain)
    assert [ms[c] for c in chain] == sorted(ms[c] for c in chain)
    assert r.agent_hours == pytest.approx(8 * r.time_h, rel=0.02)
    assert 0 < r.busy_agent_hours <= r.agent_hours
    assert r.blockers and r.starvation
    json.loads(r.to_json())                                           # the trace serialises
    assert all(len(s) == 6 for s in r.spans)                          # [agent, task, kind, chunk, t0_h, t1_h]


@needs_2_0_data
def test_slower_llm_means_slower_run(order):
    fast = simulate(order, SimConfig(agents=4, seed=1, latency_median=10))
    slow = simulate(order, SimConfig(agents=4, seed=1, latency_median=60))
    assert slow.time_h > fast.time_h


@needs_2_0_data
def test_rocket_part_numbers_drive_the_end_of_the_run(order):
    sim = Simulation(order, SimConfig(agents=8, seed=2))
    sim.run()
    assert sim.w.produced["rocket-part"] >= 100
    # 100 parts x (10 PU + 10 LDS + 10 RF) were really consumed from stock
    assert sim.w.produced["processing-unit"] >= 1000
    assert sim.w.produced["low-density-structure"] >= 1000
    assert sim.w.produced["rocket-fuel"] >= 1000


def test_parse_agents():
    assert parse_agents("1-4") == [1, 2, 3, 4]
    assert parse_agents("1,2,8") == [1, 2, 8]
    assert parse_agents("5") == [5]


def test_calibration_reads_kpi_lines(order):
    tmp = tempfile.TemporaryDirectory()
    tmp_path = Path(tmp.name)
    kpi = tmp_path / "kpi.jsonl"
    kpi.write_text("\n".join(json.dumps(s) for s in [
        {"tick": 36000, "wall": "2026-01-01T00:10:00Z", "produced": {"iron-plate": 400}, "researched": ["steam-power"],
         "counts": {"burner-mining-drill": 5}},
        {"tick": 216000, "wall": "2026-01-01T01:00:00Z",
         "produced": {"iron-plate": 3000, "automation-science-pack": 80},
         "researched": ["steam-power", "electronics", "automation"], "counts": {"burner-mining-drill": 9}},
    ]) + "\n", encoding="utf-8")
    obs = observed_milestones([json.loads(x) for x in kpi.read_text().splitlines()])
    assert obs["burner_mining"] == pytest.approx(10 / 60, abs=1e-3)
    assert obs["automation_researched"] == pytest.approx(1.0, abs=1e-3)
    r = simulate(order, SimConfig(agents=4, seed=1))
    c = calibrate(r, kpi)
    assert c["snapshots"] == 2
    row = next(x for x in c["milestones"] if x["milestone"] == "automation_researched")
    assert row["observed_h"] == pytest.approx(1.0, abs=1e-3) and row["sim_h"] > 0
    assert c["production"][-1]["produced"]["iron-plate"]["sim"] > 0
    assert calibrate(r, tmp_path / "missing.jsonl")["snapshots"] == 0
    tmp.cleanup()


def test_fit_latency_recovers_lognormal():
    import random
    rng = random.Random(1)
    xs = [rng.lognormvariate(math.log(25), 0.6) for _ in range(4000)]
    med, sig = fit_latency(xs)
    assert med == pytest.approx(25, rel=0.05) and sig == pytest.approx(0.6, rel=0.05)


def test_cli_sim_and_sweep(capsys):
    from lpf.cli import main
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "t.json"
        assert main(["sim", "--agents", "4", "--seed", "1", "--json", str(out)]) == 0
        text = capsys.readouterr().out
        assert "launch at" in text and "milestones" in text
        assert json.loads(out.read_text())["agents"] == 4
    assert main(["sim-sweep", "--agents", "2-3", "--repeats", "1"]) == 0
    text = capsys.readouterr().out
    assert "T_launch_h" in text and "fastest feasible" in text
