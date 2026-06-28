# AI Player v3

A Factorio 2.0 mod that spawns an autonomous AI character in your game. The AI perceives the factory, decides what to do, and acts — building, mining, smelting, researching, and responding to chat — all driven by an LLM of your choice.

**Providers supported:** LM Studio (local), Ollama, OpenAI, Anthropic Claude, or any OpenAI-compatible endpoint.

---

## How it works

```
Factorio mod  ──────────►  bridge/  ──────────►  LLM provider
(perception)    script-output    (agent.py)      (local or cloud)
                   files
      ◄──────────────────────────────────────────
            RCON (skill/action response)
```

1. The **mod** spawns an AI character, gathers a perception snapshot (inventory, nearby entities, factory state, research progress, ghost list), and writes a request file to Factorio's `script-output` directory.
2. The **bridge** (`python -m bridge.main`) polls that directory, assembles a compact prompt, calls the LLM, parses the response into skill/action objects, and sends them back via RCON.
3. The mod executes the actions, collects results, and queues the next request after a configurable tick interval.

The skill layer keeps the LLM's job small: it picks *what* to do (gather iron, build ghosts, research) and the mod handles *how* (pathfinding, placement offsets, fuelling). Primitive actions exist as a fallback for one-off operations no skill covers.

---

## Repository layout

```
mod/                    Factorio mod (install this)
  info.json
  control.lua           Mod entry point, event hooks
  settings.lua          In-game mod settings (provider, RCON, tick rate, …)
  scripts/
    perception.lua      Snapshot builder — what the AI can "see"
    skills.lua          Skill layer — parameterized multi-step loops
    primitives.lua      Primitive action handlers (place, mine, craft, chat, …)
    brain.lua           Request/response loop, JSON parsing, action dispatch
    character.lua       AI character lifecycle (spawn, respawn, home anchor)
    registry.lua        Machine registry (tracks placed machines by ID)

bridge/                 Python bridge — run this alongside Factorio
  main.py               Entry point: poll loop wiring config → RCON → agent
  agent.py              Router: builds prompt, calls LLM, parses response
  prompt.py             System prompt + per-turn user message assembly
  config.py             Config loader (.env → config.json hot-reload)
  transcript.py         Per-request JSON transcript logging
  benchmark.py          Latency benchmark for local models
  factorio/
    rcon.py             RCON gateway (send actions, clear queues)
    watcher.py          File watcher (detect new request files)
    api.py              Skill/action schema validation
    mcp_server.py       Optional MCP server (expose Factorio to Claude Code)
    prototypes.py       Factorio prototype helpers
  providers/
    __init__.py         ProviderConfig dataclass + get_provider()
    anthropic.py        Anthropic (Claude) provider
    openai_compat.py    OpenAI-compatible provider (LM Studio, Ollama, OpenAI, custom)

.github/workflows/
  release.yml           Workflow-dispatch release: zips mod/ → ai-player-v3.zip
```

---

## Quickstart

### 1. Install the mod

Download `ai-player-v3.zip` from [Releases](../../releases) and place it in your Factorio mods directory, or install directly from the [Factorio mod portal](https://mods.factorio.com/).

The mod directory is:
- **macOS:** `~/Library/Application Support/factorio/mods/`
- **Windows:** `%APPDATA%\Factorio\mods\`
- **Linux:** `~/.factorio/mods/`

### 2. Enable RCON on your Factorio server

The bridge communicates back to Factorio via RCON. Add these flags when starting Factorio (or to your server config):

```
--rcon-port 27015 --rcon-password yourpassword
```

For Docker, set `RCON_PORT` and `RCON_PASSWORD` in your compose environment and expose the port.

### 3. Set up the bridge

```bash
git clone https://github.com/thedemon117/ai-player-v3.git
cd ai-player-v3
pip install -r requirements.txt
```

Copy and edit the environment template:

```bash
cp bridge/.env.example bridge/.env
```

Fill in `bridge/.env`:

```env
# Path where Factorio writes script-output (must be readable by the bridge)
FACTORIO_OUTPUT_DIR=/path/to/factorio/script-output/ai-player

# RCON credentials (must match Factorio server config)
FACTORIO_RCON_HOST=localhost
FACTORIO_RCON_PORT=27015
FACTORIO_RCON_PASSWORD=yourpassword

# LLM provider: lmstudio | openai | anthropic | custom
AI_PROVIDER=lmstudio

# Model name as reported by your provider
AI_MODEL=local-model

# LM Studio / Ollama / local server base URL
LM_STUDIO_URL=http://localhost:1234/v1

# API keys (only needed for the matching provider)
OPENAI_API_KEY=
ANTHROPIC_API_KEY=

# How long to wait for a model response (seconds). Measure with:
#   python -m bridge.benchmark
# then set at or above the recommendation. Slow local models may need 240+.
AI_TIMEOUT=240
```

`bridge/.env` is gitignored and never committed.

### 4. Run the bridge

```bash
python -m bridge.main
```

### 5. Configure and start a game

Load Factorio, start or load a save, then open **Settings → Mod settings → Map** to configure:
- Provider, model name, LM Studio URL (`ai-player-provider`, `ai-player-model-name`, `ai-player-lm-studio-url`)
- OpenAI/custom endpoint keys and base URLs
- RCON host/port/password (alternative to bridge/.env — values here hot-reload without restarting the bridge)
- Tick interval (how often the AI acts, in ticks; default 300 = ~5 seconds)
- Vision radius, chat enable/disable, auto-respawn, debug-chat logging

### 6. Spawn the AI character

In the in-game console (`~` key), run:

```
/spawn-ai-player
```

The character spawns on the `nauvis` surface. With the bridge running, it begins acting on the next tick interval. Use `/ai-coop on` if you want it to join your force and help expand your base (see [Console commands](#console-commands)).

---

## Console commands

Run these from the in-game console (press `~`). The AI does **not** spawn automatically — start it with `/spawn-ai-player`.

| Command | Description |
|---|---|
| `/spawn-ai-player` | Spawn or reset the AI character. Run this first. |
| `/remove-ai-player` | Destroy the AI character. |
| `/goto-ai-player` | Teleport yourself to the AI. |
| `/ai-come` | Bring the AI character to you. |
| `/ai-coop on\|off` | Switch between co-op (AI shares your force, sees and expands your base) and solo (AI on its own force). Default is co-op. |
| `/ai-do <skill> [arg] [count\|output]` | Run a skill **deterministically, bypassing the LLM** — e.g. `/ai-do build_miner iron-ore`. Useful for testing skills with no bridge running. |
| `/ai-force <skill> [args]` \| `/ai-force off` | Lock the LLM router to a single skill until cleared. |
| `/ai-collect` | (Solo only) AI mines back every building it placed, then returns to you. Refused in co-op mode to avoid mining the shared base. |

> **Run without an LLM:** `/ai-do` executes any skill directly through the mod, so you can drive the AI character entirely from the console without the bridge or a model. The bridge is only required for autonomous LLM-driven play.

---

## Providers

| Provider | `AI_PROVIDER` value | Notes |
|---|---|---|
| LM Studio | `lmstudio` | Default. Any model loaded in LM Studio at `LM_STUDIO_URL`. |
| Ollama | `lmstudio` | Point `LM_STUDIO_URL` at `http://localhost:11434/v1`. |
| OpenAI | `openai` | Set `OPENAI_API_KEY`. |
| Anthropic Claude | `anthropic` | Set `ANTHROPIC_API_KEY`. |
| Custom endpoint | `custom` | Any OpenAI-compatible API; set `AI_CUSTOM_URL`. |

### Choosing a model

The prompt is compact by design, but the model must reliably emit valid JSON arrays. Recommendations:
- **Local:** `qwen2.5-7b-instruct` or `mistral-7b-instruct` work well in LM Studio. Larger is better for complex factory states.
- **Cloud:** Claude Sonnet or GPT-4o. Set `AI_TIMEOUT` lower (30–60s) for cloud models.
- Run `python -m bridge.benchmark` to measure your model's actual latency and get a recommended `AI_TIMEOUT`.

---

## Skills

Skills are the primary interface between the LLM and the game. The LLM picks a skill and its parameters; the mod handles the mechanics.

| Skill | Params | What it does |
|---|---|---|
| `build_ghosts` | _(none)_ | Builds all entity ghosts on the surface. Teleports to distant ghost clusters automatically. Highest priority — always triggered before anything else when ghosts exist. |
| `deconstruct` | _(none)_ | Mines everything marked for deconstruction. Second priority after ghosts. |
| `gather` | `item`, `count` | Mines the nearest sources of an item (wood, ores, stone) until `count` is reached. |
| `build_miner` | `resource`, `output` | Places a burner-mining-drill on the nearest patch of `resource`, fuels it, and puts a `chest`/`furnace`/`belt` at its output. |
| `build_smelter` | `ore`, `count` | Places and loads stone-furnaces to smelt ore into plates. |
| `fuel_all` | _(none)_ | Tops up every nearby burner machine low on fuel. |
| `research` | `tech` _(optional)_ | Queues a technology; auto-picks the next logical tech if `tech` is omitted. |
| `loot_chests` | _(none)_ | Pulls items from nearby chests into the AI's inventory. |
| `deposit_to_chest` | _(none)_ | Deposits excess inventory items into nearby chests. |
| `return_home` | _(none)_ | Teleports back to the AI's base anchor point. |
| `goto` | `position` | Teleports to `{"x": N, "y": N}` for manual positioning. |

Primitive actions (`place`, `mine`, `craft`, `insert`, `take`, `chat`, `wait`, …) are available as a fallback for operations no skill covers.

---

## MCP server (optional)

The bridge includes an MCP server that exposes Factorio to any MCP client (Claude Code, Claude Desktop, etc.) over stdio. Instead of the mod pushing requests to an LLM, the client *pulls* — reading game state and driving the AI character through the same skill layer on demand.

```bash
pip install "mcp[cli]"
python -m bridge.factorio.mcp_server
```

It uses the same `bridge/.env` credentials as the bridge — no extra configuration. Register it with your MCP client as a stdio server, e.g. in `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "factorio": {
      "command": "python",
      "args": ["-m", "bridge.factorio.mcp_server"],
      "cwd": "/path/to/ai-player-v3"
    }
  }
}
```

**Tools exposed:** read state (`get_factory_state`, `get_research`, `get_players`, `entities_near`, …), lifecycle (`spawn_ai_player`, `remove_ai_player`), the full skill set (`gather`, `build_miner`, `build_smelter`, `build_ghosts`, `deconstruct`, `loot_chests`, `deposit_to_chest`, `research`, `return_home`, `fuel_all`), and mode switches (`set_coop`, `set_autonomy`).

> When driving the character externally through these tools, call `set_autonomy(false)` first so the mod's built-in LLM loop doesn't issue competing actions. Re-enable with `set_autonomy(true)` to hand control back. `run_lua` is a raw escape hatch — see [Security notes](#security-notes).

---

## Configuration reference

All settings can be provided via `bridge/.env` (secrets, paths) or the in-game **Mod Settings → Map** panel (which writes `config.json` and hot-reloads without restarting the bridge). `.env` values take precedence over in-game settings for `AI_PROVIDER` and `AI_MODEL`, so you can benchmark models from the bridge side without stale in-game settings overriding them.

| `.env` key | In-game setting | Default | Description |
|---|---|---|---|
| `FACTORIO_OUTPUT_DIR` | — | macOS default path | Path to Factorio's `script-output/ai-player` directory |
| `FACTORIO_RCON_HOST` | RCON Host | `localhost` | RCON server host |
| `FACTORIO_RCON_PORT` | RCON Port | `27015` | RCON server port |
| `FACTORIO_RCON_PASSWORD` | RCON Password | _(empty)_ | RCON password |
| `AI_PROVIDER` | Provider | `lmstudio` | `lmstudio` / `openai` / `anthropic` / `custom` |
| `AI_MODEL` | Model Name | `local-model` | Model identifier as reported by the provider |
| `LM_STUDIO_URL` | LM Studio URL | `http://localhost:1234/v1` | Base URL for local/compatible server |
| `OPENAI_API_KEY` | OpenAI API Key | _(empty)_ | OpenAI or compatible API key |
| `ANTHROPIC_API_KEY` | — | _(empty)_ | Anthropic API key |
| `AI_TIMEOUT` | — | `240` | Seconds to wait for a model response |
| `AI_MAX_TOKENS` | — | `8192` | Max output tokens per turn |
| `AI_TEMPERATURE` | — | `0.7` | Sampling temperature |
| `AI_SYSTEM_PREFIX` | — | _(empty)_ | Text prepended to system prompt (e.g. `detailed thinking off` for Nemotron) |

---

## Security notes

- `bridge/.env` contains your RCON password and API keys — it is gitignored and must never be committed.
- The MCP server's `run_lua` tool executes arbitrary Lua in your Factorio game. Only expose it to trusted clients on a local network.
- RCON has no TLS. Use it on localhost or a trusted LAN only.

---

## Requirements

- Factorio 2.0+
- Python 3.10+ (uses `X | None` type-hint syntax)
- `factorio-rcon-py`, `openai`, `anthropic` (see `requirements.txt`)
- LM Studio, Ollama, or API keys for a cloud provider
- Optional: `mcp[cli]` for the MCP server

---

## License

MIT
