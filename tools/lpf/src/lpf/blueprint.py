"""Blueprint string codec: "0" + base64(zlib(json)). No game data, no layouts."""
from __future__ import annotations

import base64
import json
import zlib

GAME_VERSION = (2, 0, 77, 0)


def version_number(v: tuple[int, int, int, int] = GAME_VERSION) -> int:
    return (v[0] << 48) | (v[1] << 32) | (v[2] << 16) | v[3]


def decode(s: str) -> dict:
    s = s.strip()
    if s.startswith("{"):
        return json.loads(s)  # 2.0 also imports raw JSON
    if not s or s[0] != "0":
        raise ValueError("not a Factorio blueprint string (expected version byte '0')")
    return json.loads(zlib.decompress(base64.b64decode(s[1:])))


def encode(obj: dict) -> str:
    raw = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    return "0" + base64.b64encode(zlib.compress(raw, 9)).decode("ascii")


def blueprints(obj: dict, path: str = "") -> list[tuple[str, dict]]:
    """Flatten a blueprint or book into (path, blueprint) pairs; path is like '2/0' inside books."""
    if "blueprint" in obj:
        return [(path, obj["blueprint"])]
    if "blueprint_book" in obj:
        out = []
        for child in obj["blueprint_book"].get("blueprints", []):
            out.extend(blueprints(child, f"{path}/{child.get('index', 0)}".lstrip("/")))
        return out
    return []
