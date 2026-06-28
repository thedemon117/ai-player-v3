"""
Model latency benchmark — gauge how a local model performs before committing.

Sends one representative game-state prompt (the real B1 system prompt + a
moderately large perception) through whatever provider/model is configured in
bridge/.env + config.json, and reports:
  - wall-clock response time (what the timeouts must accommodate)
  - approximate output size and tokens/sec
  - whether the response parsed into valid actions
  - a recommended AI_TIMEOUT for this model

Run from the ai-player-v2 root:
    python -m bridge.benchmark
    python -m bridge.benchmark --runs 3        # average over N runs
    python -m bridge.benchmark --max-tokens 4096

This is the answer to "how do we gauge LMStudio response time so we're not
timing out faster than the model can reply": measure it here, then set AI_TIMEOUT
at or above the recommendation. The mod + watcher timeouts derive from AI_TIMEOUT
automatically.
"""

import argparse
import logging
import math
import sys
import time

from .config import ConfigLoader
from .factorio.api import parse_response
from .prompt import build_messages
from .providers import get_provider

log = logging.getLogger("bridge.benchmark")

# A representative perception: moderate entity mapping, early-game state.
_SAMPLE_PAYLOAD = {
    "perception": {
        "character": {"position": {"x": 0, "y": 0}, "health": 250, "health_pct": 100},
        "game_phase": 0,
        "inventory": [
            {"name": "stone-furnace", "count": 4}, {"name": "coal", "count": 100},
            {"name": "burner-mining-drill", "count": 4}, {"name": "iron-plate", "count": 50},
            {"name": "transport-belt", "count": 50}, {"name": "small-electric-pole", "count": 20},
        ],
        "craftable": ["iron-gear-wheel", "stone-furnace", "transport-belt", "pipe", "iron-chest"],
        "nearby_resources": [
            {"name": "iron-ore", "patch_count": 38, "total_amount": 4200,
             "nearest": {"x": 6, "y": -3}, "nearest_distance": 6},
            {"name": "copper-ore", "patch_count": 25, "total_amount": 2900,
             "nearest": {"x": -12, "y": 5}, "nearest_distance": 13},
            {"name": "coal", "patch_count": 30, "total_amount": 3100,
             "nearest": {"x": -8, "y": 4}, "nearest_distance": 9},
            {"name": "stone", "patch_count": 14, "total_amount": 900,
             "nearest": {"x": 10, "y": 10}, "nearest_distance": 14},
        ],
        "nearby_entities": [
            {"name": "rock-huge", "type": "simple-entity", "position": {"x": 3, "y": 1}},
            {"name": "tree-01", "type": "tree", "position": {"x": -2, "y": -4}},
        ],
        "enemies": [],
        "nearby_water": [{"x": 18, "y": -6}, {"x": 19, "y": -6}],
        "environment": {"surface": "nauvis", "ticks_played": 3600, "pollution": 0},
    },
    "memory": {"previous_summary": "Spawned and surveyed the area."},
    "user_message": "what's your plan?",
}


def _approx_tokens(text: str) -> int:
    # Rough heuristic (~4 chars/token) — good enough to estimate throughput.
    return max(1, len(text) // 4)


def run(runs: int, max_tokens_override: int | None, model_override: str | None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    cfg = ConfigLoader().get()
    if max_tokens_override:
        cfg.max_tokens = max_tokens_override
    if model_override:
        cfg.model = model_override
    provider_cfg = cfg.to_provider_config()
    complete = get_provider(provider_cfg)

    messages = build_messages(_SAMPLE_PAYLOAD, cfg.system_prefix)
    prompt_chars = sum(len(m["content"]) for m in messages)

    print("=" * 64)
    print("ai-player-v2 model benchmark")
    print("=" * 64)
    print(f"provider     : {provider_cfg.provider}")
    print(f"model        : {provider_cfg.model}")
    print(f"url          : {provider_cfg.url or '(default)'}")
    print(f"max_tokens   : {cfg.max_tokens}")
    print(f"temperature  : {cfg.temperature}")
    print(f"system_prefix: {cfg.system_prefix or '(none)'}")
    print(f"prompt size  : ~{_approx_tokens(str(prompt_chars))} (~{prompt_chars} chars in)")
    print("-" * 64)

    times: list[float] = []
    for i in range(1, runs + 1):
        t0 = time.monotonic()
        content = complete(messages, provider_cfg)
        dt = time.monotonic() - t0

        if content is None:
            print(f"run {i}: FAILED — provider returned no content after {dt:.1f}s")
            print("       (timed out, server down, or model not loaded — see logs above)")
            continue

        out_tokens = _approx_tokens(content)
        tps = out_tokens / dt if dt > 0 else 0
        actions = parse_response(content)
        n_actions = len(actions) if actions else 0
        has_think = "<think>" in content

        times.append(dt)
        print(f"run {i}: {dt:6.1f}s  ~{out_tokens:5d} out tok  ~{tps:5.1f} tok/s  "
              f"actions={n_actions:2d}  think={'yes' if has_think else 'no'}  "
              f"parse={'OK' if actions else 'FAIL'}")

    print("-" * 64)
    if not times:
        print("No successful runs. Raise AI_TIMEOUT, check the model is loaded, "
              "and confirm the provider/url in bridge/.env.")
        return 1

    avg = sum(times) / len(times)
    worst = max(times)
    # Recommend a timeout above the worst observed, with headroom for variance.
    recommended = int(math.ceil(worst * 1.5 / 10) * 10)
    print(f"avg {avg:.1f}s | worst {worst:.1f}s over {len(times)} run(s)")
    print(f"\nRecommended:  AI_TIMEOUT={recommended}   (in bridge/.env)")
    print("The mod + watcher timeouts derive from AI_TIMEOUT automatically.")
    if avg > 30:
        print("\nNote: turns over ~30s make the loop sluggish. Consider a smaller/"
              "faster model for development (e.g. a *-nano variant).")
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(description="Benchmark the configured model's latency.")
    ap.add_argument("--runs", type=int, default=1, help="number of runs to average (default 1)")
    ap.add_argument("--max-tokens", type=int, default=None, help="override max_tokens for the test")
    ap.add_argument("--model", type=str, default=None,
                    help="override model id to benchmark (e.g. nvidia/nemotron-3-nano)")
    args = ap.parse_args()
    sys.exit(run(args.runs, args.max_tokens, args.model))


if __name__ == "__main__":
    main()
