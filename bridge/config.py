"""
Bridge configuration.

BridgeConfig is the single source of truth for all runtime settings.

Load order (later sources override earlier):
  1. Hardcoded defaults
  2. bridge/.env file  — user-managed secrets and local paths (never committed)
  3. config.json       — written by the Factorio mod when in-game settings change
                         (hot-reloaded on mtime change, no restart required)

The .env file is the right place for:
  - ANTHROPIC_API_KEY / OPENAI_API_KEY
  - FACTORIO_OUTPUT_DIR (path to Factorio's script-output directory)
  - Any setting that differs between machines but shouldn't go through the mod UI

config.json (written by Factorio) covers everything exposed in mod settings:
  provider, model name, LM Studio URL, RCON host/port/password.

factorio-docker is NOT a dependency. The bridge works with any Factorio instance
(local client, Docker server, dedicated server) as long as:
  - RCON is reachable at the configured host:port
  - The script-output directory is readable at FACTORIO_OUTPUT_DIR

For Docker: set FACTORIO_OUTPUT_DIR in bridge/.env to the mounted volume path,
e.g. /Users/<you>/code/virtual/factorio-docker/data/script-output/ai-player
"""

import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

from .providers import ProviderConfig

log = logging.getLogger(__name__)

# .env file sits next to this module (bridge/.env)
_ENV_FILE = Path(__file__).parent / ".env"

# Fallback output dir if not set in .env or config.json.
# For Docker deployments set FACTORIO_OUTPUT_DIR in bridge/.env instead.
_DEFAULT_OUTPUT_DIR = Path.home() / "Library/Application Support/factorio/script-output/ai-player"


def _load_env_file(path: Path) -> dict[str, str]:
    """
    Parse a .env file into a dict. Supports KEY=VALUE and KEY="VALUE".
    Ignores blank lines and lines starting with #.
    Does not export to os.environ — values are kept local to this module.
    """
    if not path.exists():
        return {}
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        result[key] = value
    return result


@dataclass
class RCONConfig:
    host: str = "localhost"
    port: int = 27015
    password: str = ""


@dataclass
class BridgeConfig:
    # File paths
    output_dir: Path = field(default_factory=lambda: _DEFAULT_OUTPUT_DIR)

    # Provider settings (fed into ProviderConfig)
    provider: str = "lmstudio"
    model: str = "local-model"
    lm_studio_url: str = "http://localhost:1234/v1"
    openai_api_key: str = ""
    openai_api_base: str = "https://api.openai.com/v1"
    anthropic_api_key: str = ""
    custom_url: str = ""

    # Request settings.
    # timeout is the SINGLE SOURCE for how long a model is allowed to reply.
    # The mod's pending-request timeout and the watcher's stale timeout are both
    # derived from it (timeout + margin) so neither can ever expire a request
    # before the model has had its full allotted time. Raise AI_TIMEOUT for slow
    # local models; measure real latency with `python -m bridge.benchmark`.
    timeout: float = 240.0
    # Output token budget. Must stay generous: with a large entity-mapping
    # perception, reasoning models need room to think AND emit the full JSON
    # array — too low truncates the response before the array closes (parse
    # fails → fallback wait). The latency lever for reasoning models is
    # AI_SYSTEM_PREFIX="detailed thinking off", NOT a low token cap.
    max_tokens: int = 8192
    temperature: float = 0.7
    # Optional text prepended to the system prompt. Use it to pass model-specific
    # directives without editing code, e.g. "detailed thinking off" disables
    # reasoning on Nemotron models (big latency win). Empty by default.
    system_prefix: str = ""

    # RCON
    rcon: RCONConfig = field(default_factory=RCONConfig)

    # Bridge behaviour
    verbose: bool = True
    poll_interval: float = 0.1     # seconds between directory scans

    def to_provider_config(self) -> ProviderConfig:
        """Build a ProviderConfig from current settings."""
        provider = self.provider.lower()

        if provider == "anthropic":
            url = ""
            api_key = self.anthropic_api_key
        elif provider == "openai":
            url = self.openai_api_base
            api_key = self.openai_api_key
        elif provider == "custom":
            url = self.custom_url or self.lm_studio_url
            api_key = self.openai_api_key or "custom"
        else:
            # lmstudio (default) — any OAI-compatible local server.
            # The OpenAI SDK appends /chat/completions to base_url itself.
            # Strip it if the mod setting included the full path.
            url = self.lm_studio_url.removesuffix("/chat/completions")
            api_key = "lm-studio"

        return ProviderConfig(
            provider=provider,
            model=self.model,
            url=url,
            api_key=api_key,
            timeout=self.timeout,
            max_tokens=self.max_tokens,
            temperature=self.temperature,
        )


class ConfigLoader:
    """
    Loads BridgeConfig from bridge/.env (once at startup) and config.json
    (hot-reloaded whenever the Factorio mod rewrites it on settings change).

    Usage:
        loader = ConfigLoader()
        cfg = loader.get()   # call each loop iteration — cheap if nothing changed
    """

    def __init__(self, env_file: Path | None = None):
        self._env_file = env_file or _ENV_FILE
        self._env = _load_env_file(self._env_file)
        if self._env:
            log.info("Loaded %d setting(s) from %s", len(self._env), self._env_file)
        else:
            log.info("No .env file found at %s — using defaults", self._env_file)

        self._config = self._build_from_env()
        self._config_path = self._config.output_dir / "config.json"
        self._mtime: float = 0.0
        self._prev_rcon = (self._config.rcon.host, self._config.rcon.port, self._config.rcon.password)

    def _e(self, key: str, default: str = "") -> str:
        """Get a value from the .env dict."""
        return self._env.get(key, default)

    def _build_from_env(self) -> BridgeConfig:
        """Build a BridgeConfig seeded from .env values."""
        cfg = BridgeConfig()
        output_dir = self._e("FACTORIO_OUTPUT_DIR")
        if output_dir:
            cfg.output_dir = Path(output_dir)
        cfg.provider          = self._e("AI_PROVIDER", cfg.provider)
        cfg.model             = self._e("AI_MODEL", cfg.model)
        cfg.lm_studio_url     = self._e("LM_STUDIO_URL", cfg.lm_studio_url)
        cfg.openai_api_key    = self._e("OPENAI_API_KEY", cfg.openai_api_key)
        cfg.openai_api_base   = self._e("OPENAI_API_BASE", cfg.openai_api_base)
        cfg.anthropic_api_key = self._e("ANTHROPIC_API_KEY", cfg.anthropic_api_key)
        cfg.custom_url        = self._e("AI_CUSTOM_URL", cfg.custom_url)
        timeout = self._e("AI_TIMEOUT")
        if timeout:
            try:
                cfg.timeout = float(timeout)
            except ValueError:
                pass
        max_tokens = self._e("AI_MAX_TOKENS")
        if max_tokens:
            try:
                cfg.max_tokens = int(max_tokens)
            except ValueError:
                pass
        temperature = self._e("AI_TEMPERATURE")
        if temperature:
            try:
                cfg.temperature = float(temperature)
            except ValueError:
                pass
        cfg.system_prefix = self._e("AI_SYSTEM_PREFIX", cfg.system_prefix)
        cfg.rcon.host     = self._e("FACTORIO_RCON_HOST", cfg.rcon.host)
        port = self._e("FACTORIO_RCON_PORT")
        if port:
            try:
                cfg.rcon.port = int(port)
            except ValueError:
                pass
        cfg.rcon.password = self._e("FACTORIO_RCON_PASSWORD", cfg.rcon.password)
        cfg.verbose       = self._e("BRIDGE_VERBOSE", "1") != "0"
        return cfg

    def get(self) -> BridgeConfig:
        """
        Return current config, reloading from config.json if it changed.
        .env is only read once at startup — restart the bridge to pick up .env changes.
        """
        if not self._config_path.exists():
            return self._config

        try:
            mtime = self._config_path.stat().st_mtime
        except OSError:
            return self._config

        if mtime == self._mtime:
            return self._config

        try:
            with open(self._config_path, encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            log.warning("Failed to reload config.json: %s", e)
            return self._config

        # Start from .env baseline so secrets are always present
        cfg = self._build_from_env()

        # Overlay fields written by the Factorio mod.
        # Exception: an explicit AI_MODEL / AI_PROVIDER in .env WINS over the
        # mod's config.json — so you can switch models from the bridge side
        # (the natural flow for benchmarking) without a stale in-game setting
        # silently clobbering it. Remove AI_MODEL/AI_PROVIDER from .env to hand
        # control back to the in-game mod setting.
        if "AI_PROVIDER" not in self._env:
            cfg.provider = str(raw.get("provider", cfg.provider)).lower()
        if "AI_MODEL" not in self._env:
            cfg.model = raw.get("model_name", cfg.model)
        cfg.lm_studio_url   = raw.get("lm_studio_url", cfg.lm_studio_url)
        cfg.openai_api_key  = raw.get("openai_api_key") or cfg.openai_api_key
        cfg.openai_api_base = raw.get("openai_api_base", cfg.openai_api_base)
        cfg.custom_url      = raw.get("custom_url", cfg.custom_url)

        rcon_host = raw.get("rcon_host", "")
        rcon_port = raw.get("rcon_port")
        rcon_pw   = raw.get("rcon_password", "")
        if rcon_host:
            cfg.rcon.host = rcon_host
        if rcon_port is not None:
            try:
                cfg.rcon.port = int(rcon_port)
            except (TypeError, ValueError):
                pass
        if rcon_pw:
            cfg.rcon.password = rcon_pw

        self._mtime = mtime
        self._config = cfg
        self._config_path = cfg.output_dir / "config.json"

        log.info(
            "Config reloaded from mod: provider=%s model=%s rcon=%s:%d",
            cfg.provider, cfg.model, cfg.rcon.host, cfg.rcon.port,
        )
        return cfg

    def rcon_changed(self, cfg: BridgeConfig) -> bool:
        """
        Returns True if RCON settings changed since last call.
        Call after get() to detect when the gateway needs to reconnect.
        """
        current = (cfg.rcon.host, cfg.rcon.port, cfg.rcon.password)
        if current != self._prev_rcon:
            self._prev_rcon = current
            return True
        return False
