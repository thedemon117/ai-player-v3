# lpf — offline plan simulator and layout tools

Ported from [llm-play-factorio](https://github.com/StevenLi-phoenix/llm-play-factorio) (`lpf/`). Standalone
Python package; it needs nothing from the Lua mod and does not talk to a running game.

- `lpf.sim` — **Sim A**: a discrete-event model of a whole run at the level of tasks, not tiles. N characters,
  task durations from the game's own data (walk speed, mining/crafting time) plus a sampled LLM decision-latency
  term; output is time to each milestone (power, science tiers, oil, silo…), per-agent idle ratio and the
  bottleneck item. Use it to pick the number of agents, compare build orders, and calibrate against a real run's
  tool-call gaps (`lpf.sim.calibrate`). It never produces positions or blueprints.
- `lpf.render` / `lpf.scene` — schematic PNG of a map area or of a layout written as `build_plan` steps.
- `lpf.rates` — machines-per-recipe arithmetic for a target item rate.
- `lpf.blueprint` — blueprint string codec.

## Game data

All numbers come from the game's own prototype dump, which is not committed (29 MB, derived from the game):

```bash
factorio --dump-data        # writes script-output/data-raw-dump.json
mkdir -p data/game && cp <write-data>/script-output/data-raw-dump.json data/game/
# or point LPF_GAME_DATA at a directory containing it
```

## Run

```bash
uv sync
uv run lpf sim --agents 4 --seed 1        # one rollout
uv run pytest                             # tests skip without the dump
```

Tests that pin rollout numbers were calibrated on Factorio 2.0.77 data; on a 2.1 dump (rocket-part now takes one
of each ingredient) they are skipped, the other 8 pass. `lpf render-area` asks the running game for the mod's `area_snapshot` query through the repo's `bridge/` (same
`bridge/.env` as the MCP servers; run it from the repo's venv), or reads a saved snapshot with `--snapshot`.
