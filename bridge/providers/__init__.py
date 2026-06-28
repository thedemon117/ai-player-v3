"""
LLM provider interface.

All providers implement the same complete() signature so agent.py
is provider-agnostic. ProviderConfig carries everything provider-specific.

Supported providers:
  "lmstudio"  — openai_compat.py  (LM Studio, Ollama, vLLM, llama.cpp server)
  "openai"    — openai_compat.py  (api.openai.com with real key)
  "custom"    — openai_compat.py  (any OpenAI-compatible endpoint)
  "anthropic" — anthropic.py      (Claude via api.anthropic.com)
"""

from dataclasses import dataclass, field


@dataclass
class ProviderConfig:
    provider: str = "lmstudio"
    model: str = "local-model"
    url: str = "http://localhost:1234/v1"
    api_key: str = "lm-studio"
    timeout: float = 120.0
    max_tokens: int = 8192
    temperature: float = 0.7


def get_provider(config: ProviderConfig):
    """Return the complete() callable for the given provider."""
    if config.provider == "anthropic":
        from .anthropic import complete
    else:
        from .openai_compat import complete
    return complete
