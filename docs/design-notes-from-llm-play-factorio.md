# Design notes from llm-play-factorio

Ideas from [`llm-play-factorio`](https://github.com/StevenLi-phoenix/llm-play-factorio) that this repo does not
implement as code. That project is a fork of Agentic-Factorio + `linsyking/factorio-mcp` with a different
architecture (per-character job queue instead of synchronous skills), so these are design notes, not patches.
Written for whoever decides how far to take the skill model; each section says what problem it solves.

## 1. Asynchronous jobs instead of synchronous skills

`AISkills.execute` runs a skill to completion inside one tick, so nothing that takes time (walking, mining a rock,
hand-crafting 20 gears) can be expressed. lpf (`scripts/tasks.lua`) keeps a **lane per character**: RCON calls
enqueue a job, `on_tick` advances the head of each lane, and a finished job is logged as a `job_done`/`job_failed`
event. Rules that made it workable with LLM agents:

- Job tools return immediately; a `job_wait` / `wait_until` tool blocks (up to ~60 s) so an agent does not poll.
- **If a job fails, everything queued behind it is cancelled**, and the next result says so. Otherwise a failed
  `walk_to` is followed by a `place` that happens in the wrong spot.
- A character can only see and cancel its own jobs.
- Finished-job records are pruned after 5 minutes.

This PR adds only the smallest piece of that idea: `AIMovement`, one walk per character. A general queue would
build on it.

## 2. "Walk within reach first" as a shared phase

Every action with a map target (mine, place, insert, deconstruct) goes through one `approach.ensure(task, c,
target, reach)` step: already in reach → proceed; otherwise start a walk and report "still walking"; walk failed →
fail the task with "couldn't get in range". Placement also has a `step_aside` helper for when the character stands
inside the footprint about to be built on (the mod's `build_ghosts` hits exactly this: a ghost has no collision, so
the character blocks the revive). One approach function avoids every skill growing its own teleport/walk logic.

## 3. Fog of war for a player-less character

The engine never charts the map for a character without a player, and `force.chart()` does nothing while the force
has no players. Without a filter `find_entities_filtered` sees every generated chunk, so an agent could "find" ore
it has never been near. lpf keeps its own per-force set of explored chunks (`scripts/vision.lua`):

- **KNOWN**: explored by one of the force's characters or charted by the force → terrain, resources and own
  buildings are reported.
- **VISIBLE**: within a view radius of a character or radar-visible → live details of other forces (enemies).
- Walk goals must be known or within the exploration radius.

Every perception query goes through the filter. If this repo ever wants a "no-cheat" mode, this is the missing
piece; it should be an opt-in setting (default off) so existing behaviour is unchanged.

## 4. Ambient alerts

Warnings that need polling (`map_warnings`) are seen late. lpf attaches a one-line digest of the force's warning
counts to every response, **delta-based per character** (steady state is silent; a reconnecting agent is told what
changed since it last called), cached for 30 ticks. The `waiting_for_space_in_destination` class never triggers the
line — belts backing up is the normal state while building, and alert fatigue defeats the feature.

## 5. Rules for a multi-agent run

From the run-4 playbook (several workers, one planner, one shared task board):
no self-written blueprint strings (only strings exported from this map during the run), a single CLI as the only
interface to the game, no touching other workers' buildings unless assigned, and items move between characters
only through containers or machines — never directly. These constraints are what make multi-agent results
comparable.

## 6. What "no cheating" meant in practice

Banned: killing enemies with `entity.destroy()`, spawning items/entities from nothing, `researched = true`,
`enable_all_recipes`, changing `game.speed` to fake throughput. The first three also matter for this repo:
teleporting (`character.teleport`) and force-level `revive{}` skip the cost of distance, which is why the walking
PR exists.

## 7. Not included, and why

- **calc MCP** (recipe/ratio calculator): licensed AGPL-3.0, which cannot be shipped inside an MIT project.
- **Offline simulator** (`lpf/sim`, render, scene, calibrate): independent Python tooling with its own tests; a
  separate repo or `tools/` directory decision for the maintainers.
- **Space / rocket / vehicles / combat / trains**: large, and need Space Age content or an enemy setup to test.
  Not ported here rather than shipped untested.
