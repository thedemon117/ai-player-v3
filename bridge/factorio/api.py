"""
Factorio action schema and response parser.

ACTIONS defines what the LLM is allowed to return and what fields are required.
validate() filters an action list down to only well-formed actions, logging
anything dropped so problems are visible without crashing the bridge.

parse_response() extracts a JSON action array from raw LLM output, handling
the common cases: plain JSON array, markdown code fences, and JSON embedded
in prose.
"""

import json
import logging
import re

log = logging.getLogger(__name__)

# Action schema: required fields per action type.
# The LLM must include all required fields; optional fields are passed through as-is.
ACTIONS: dict[str, list[str]] = {
    "move":         ["direction"],
    "mine":         [],
    "place":        ["item", "position"],
    "set_recipe":   ["recipe", "position"],
    "craft":        ["recipe", "count"],
    "pickup":       [],
    "shoot":        ["position"],
    "chat":         ["message"],
    "insert":       ["item", "count", "position"],
    "take":         ["item", "count", "position"],
    "summary":      ["text"],
    "create_todo":  ["title", "items"],
    "add_todo":     ["title", "text"],
    "complete_todo":["title", "index"],
    "view_todo":    [],
    "add_note":     ["text"],
    "view_notes":   [],
    "wait":         [],
}

# Skill schema (Tier-1): required params per skill. Mirrors mod skills.lua REGISTRY.
SKILLS: dict[str, list[str]] = {
    "build_ghosts":  [],
    "deconstruct":   [],
    "gather":        ["item"],
    "build_miner":   [],
    "build_smelter": [],
    "fuel_all":      [],
    "loot_chests":   [],
    "deposit_to_chest": [],
    "return_home":   [],
    "research":      [],
    "goto":          ["position"],
}

# Directions the move action accepts
VALID_DIRECTIONS = {"north", "south", "east", "west",
                    "northeast", "northwest", "southeast", "southwest"}

# Factorio defines.direction numeric values → string names
_NUMERIC_DIRECTIONS = {
    "0": "north", "1": "northeast", "2": "east",    "3": "southeast",
    "4": "south", "5": "southwest", "6": "west",    "7": "northwest",
}


def validate(actions: list) -> list[dict]:
    """
    Filter a parsed action list to only well-formed entries.
    Logs and drops anything that can't be executed by the mod.
    Returns a list (possibly empty) of valid action dicts.
    """
    if not isinstance(actions, list):
        log.warning("validate: expected list, got %s", type(actions).__name__)
        return []

    valid = []
    for i, action in enumerate(actions):
        if not isinstance(action, dict):
            log.warning("Action %d is not a dict (%s) — dropped", i, type(action).__name__)
            continue

        # Skill entry {skill: name, ...params} — validated separately and passed through.
        if "skill" in action and "action" not in action:
            sname = action.get("skill")
            if not isinstance(sname, str) or sname.lower() not in SKILLS:
                log.warning("Unknown skill '%s' at index %d — dropped", sname, i)
                continue
            sname = sname.lower()
            missing = [f for f in SKILLS[sname] if f not in action]
            if missing:
                log.warning("Skill '%s' at index %d missing params %s — dropped", sname, i, missing)
                continue
            entry = dict(action)
            entry["skill"] = sname
            valid.append(entry)
            continue

        name = action.get("action", "")
        if not isinstance(name, str):
            log.warning("Action %d has non-string 'action' field — dropped", i)
            continue

        name = name.lower()
        if name not in ACTIONS:
            log.warning("Unknown action '%s' at index %d — dropped", name, i)
            continue

        required = ACTIONS[name]
        missing = [f for f in required if f not in action]
        if missing:
            log.warning(
                "Action '%s' at index %d missing required fields %s — dropped",
                name, i, missing,
            )
            continue

        # Normalise action name to lowercase in output
        action = dict(action)
        action["action"] = name

        # Validate direction for move actions
        if name == "move":
            direction = str(action.get("direction", "")).lower()
            direction = _NUMERIC_DIRECTIONS.get(direction, direction)
            if direction not in VALID_DIRECTIONS:
                log.warning(
                    "move action has invalid direction '%s' — dropped "
                    "(valid: %s)", direction, ", ".join(sorted(VALID_DIRECTIONS))
                )
                continue
            action["direction"] = direction

        valid.append(action)

    if len(valid) < len(actions):
        log.info("validate: kept %d/%d actions", len(valid), len(actions))

    return valid


def parse_response(content: str) -> list[dict] | None:
    """
    Extract a validated JSON action list from raw LLM output.

    Robust to the ways local models wrap their answers:
      - Plain JSON array:                 [{...}, ...]
      - Markdown fenced:                  ```json\\n[...]\\n```
      - Array embedded in prose:          "Here are my actions: [{...}]"
      - A stray bracket before the array: "Step [1]: ... [{...}]"
      - A single action object:           {"action": "wait"}
      - Object-wrapped array:             {"actions": [{...}]}
      - Reasoning model output:           <think>...</think>[{...}]

    Strategy: gather every plausible JSON snippet (fenced blocks, then every
    balanced [...] and {...} span, then the whole string) and return the first
    that validates to at least one well-formed action. Returns None only if
    nothing parses — the caller then sends a fallback.
    """
    if not content or not content.strip():
        log.warning("parse_response: empty content")
        return None

    # Strip reasoning/thinking tags produced by local reasoning models
    cleaned = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()

    candidates: list[str] = []
    # Fenced code blocks first (highest signal)
    for m in re.finditer(r"```(?:json)?\s*(.*?)\s*```", cleaned, re.DOTALL):
        candidates.append(m.group(1))
    # Every balanced array, then every balanced object (handles wrong-bracket
    # and wrapper cases), then the whole string as a last resort.
    candidates.extend(_balanced_spans(cleaned, "[", "]"))
    candidates.extend(_balanced_spans(cleaned, "{", "}"))
    candidates.append(cleaned)

    for snippet in candidates:
        result = _try_parse(snippet)
        if result:
            return result

    log.warning("parse_response: no valid action array found. Raw content: %s", content[:600])
    return None


def _balanced_spans(text: str, open_ch: str, close_ch: str) -> list[str]:
    """Return every top-level balanced open_ch..close_ch substring, in order."""
    spans: list[str] = []
    depth = 0
    start = -1
    for i, ch in enumerate(text):
        if ch == open_ch:
            if depth == 0:
                start = i
            depth += 1
        elif ch == close_ch and depth > 0:
            depth -= 1
            if depth == 0 and start != -1:
                spans.append(text[start : i + 1])
                start = -1
    return spans


def _try_parse(text: str) -> list[dict] | None:
    """Parse one snippet into a validated action list, or None if it doesn't yield any."""
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None

    # Accept a bare list, a single action object, or an {"actions": [...]} wrapper.
    if isinstance(parsed, dict):
        if isinstance(parsed.get("actions"), list):
            parsed = parsed["actions"]
        elif "action" in parsed or "skill" in parsed:
            parsed = [parsed]
        else:
            return None

    if not isinstance(parsed, list):
        return None

    result = validate(parsed)
    return result or None
