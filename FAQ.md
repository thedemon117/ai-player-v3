# AI Player v3 — FAQ

## What does this mod actually do?
It spawns an autonomous AI character into your game. The character perceives the
factory (inventory, nearby entities, resources, research, ghosts you've placed)
and decides what to do — gathering, smelting, mining, building, researching, and
replying to chat. The decisions are made by a **Large Language Model of your
choice**; the mod handles all the mechanics (pathfinding, placement, fuelling)
so the model only has to pick *what* to do, not *how*.

## Is this just the mod, or do I need to run something else?
You need both. The mod ships the in-game half; a small **Python "bridge"**
runs alongside Factorio and talks to the LLM. The mod writes what the AI sees to
Factorio's `script-output` folder, the bridge reads it, calls the model, and
sends the chosen actions back over **RCON**. The mod does nothing on its own
until the bridge is running. Setup is in the
[README](https://github.com/thedemon117/ai-player-v3).

## What's the short version of setup?
Three steps:

1. **Install the mod** (mod portal or drop the zip in your `mods/` folder).
2. **Launch Factorio with RCON enabled** so the bridge can reach it:
   ```
   --rcon-port 27015 --rcon-password yourpassword
   ```
3. **Run the bridge** next to your game:
   ```bash
   git clone https://github.com/thedemon117/ai-player-v3.git
   cd ai-player-v3
   pip install -r requirements.txt
   cp bridge/.env.example bridge/.env   # then fill in RCON + provider
   python -m bridge.main
   ```

Make sure the RCON host/port/password in **Mod Settings → Map** (or `bridge/.env`)
match the flags you launched Factorio with. Full step-by-step, including the
`FACTORIO_OUTPUT_DIR` path and provider config, is in the
[README](https://github.com/thedemon117/ai-player-v3#quickstart).

## Does it need an internet connection or a paid API?
No. The default provider is **LM Studio** (a local model on your own machine),
and **Ollama** works too — fully offline, no API key, no cost. If you'd rather
use a hosted model you can point it at **OpenAI**, **Anthropic (Claude)**, or any
OpenAI-compatible endpoint. You pick this in the mod settings.

## Which model should I use?
Any reasonably capable instruction-following model works. Local coder-style
models in the 7B–30B range perform well; the project recommends
`qwen/qwen3-coder-next` as a solid local default. There's a benchmark tool
(`python -m bridge.benchmark --model <id>`) to gauge a model's latency before
committing to it. Smaller/faster models react sooner but plan less well — it's a
trade-off you can tune.

## How do I get the AI to show up?
Open the console (`~`) and run `/spawn-ai-player`. The AI does **not** appear
automatically — this command spawns it with a fresh starter kit and sets its
"home" anchor. `/remove-ai-player` despawns it.

## How do I tell the AI what to do?
Type a chat message prefixed with `ai:` (or `!ai`):

```
ai: smelt some iron
ai: gather coal
ai: build the ghosts I placed
```

It acknowledges instantly and works on the directive for ~30 seconds. You can
also just place **blueprint ghosts** — building your ghosts is the AI's top
priority, so blueprinting is the most reliable way to direct construction.

## Can I run it without an LLM at all?
Yes. `/ai-do <skill> [arg]` runs a single skill deterministically and **bypasses
the LLM entirely** — it works with no bridge and no model running. For example
`/ai-do gather iron-ore`. Useful for testing or scripted play. `/ai-force
<skill>` locks the AI to one skill repeatedly; `/ai-force off` releases it.

## Does it work in multiplayer / co-op?
Yes. Toggle co-op with `/ai-coop on`. In co-op the AI plays on your force and
builds toward a shared base. In solo mode it's on its own force (so you can watch
it play independently), and `/ai-collect` makes it mine back everything it built.
Co-op is a console command, not a setting.

## Will it work on my existing save?
Yes — it can be added to an in-progress game. Note that adding any mod that isn't
flagged for it disables Steam achievements for that save, as with most Factorio
mods.

## Is it safe? Does it send my game data anywhere?
The only data that leaves your machine is the perception snapshot sent to the LLM
provider you choose — and if you run a **local** model (LM Studio/Ollama),
nothing leaves your machine at all. RCON is used locally between the bridge and
your own game. Your API keys and RCON password live in the bridge's `.env` file,
which is never committed. The bridge does expose a `run_lua` escape hatch for
power users — it's documented and optional.

## Does it cheat or spawn items?
No. The AI plays by normal rules — it mines real resources, hand-crafts, places
real entities from its inventory, and runs research on its force. It only acts on
what it actually has and can reach.

## The AI was spawned but isn't doing anything — what's wrong?
Almost always the bridge or RCON. Checklist:
- Is the **bridge** running (`python -m bridge.main`)?
- Is Factorio launched with **RCON enabled** (the bridge connects over RCON)?
- Do the RCON host/port/password in mod settings match what Factorio is using?
- Is your **model** loaded and reachable at the configured URL?

In-game diagnostics: `/ai-pending` shows in-flight requests and their age,
`/ai-clear` aborts a stuck request, and `/ai-memory` prints the AI's notes and
current directive. Turning on the **debug-chat** mod setting prints every action
result so you can see exactly what it's choosing.

## Research never progresses — why?
In Factorio 2.0 a force researches nothing until a technology is queued, and the
very first tech (automation science) is completed by *crafting* red science, not
by a lab. Just tell the AI `ai: research` (or place a lab and let it craft science
packs) and it will handle the queue from there.

## Does it impact UPS / performance?
The AI thinks on an interval, not every tick — the **tick-interval** setting
(default 300 ticks, ~5 s) controls how often it makes a decision. Lower it for a
snappier AI, raise it to reduce overhead. The heavy lifting (the LLM call) runs
in the separate bridge process, not in Factorio's game loop.

## Can other tools drive the AI?
Yes — there's an optional **MCP server** that exposes the AI's skills as tools, so
an external agent (e.g. Claude Code/Desktop) can drive the character directly
instead of the built-in router. This is optional and aimed at developers.

## Where do I report bugs or request features?
On the GitHub repo: <https://github.com/thedemon117/ai-player-v3>.
