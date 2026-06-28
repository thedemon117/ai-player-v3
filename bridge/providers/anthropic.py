"""
Anthropic provider (Claude models).

Anthropic's API is not OpenAI-compatible — it uses a separate system parameter,
different auth header, and different tool call schema. Requires the anthropic SDK.

Converts from OpenAI message format (the canonical internal format) to Anthropic's
format before sending, so agent.py stays provider-agnostic.

Models: claude-opus-4-8, claude-sonnet-4-6, claude-haiku-4-5-20251001
"""

import logging
from . import ProviderConfig

log = logging.getLogger(__name__)

# Anthropic requires url to be their endpoint; config.url is ignored for this provider.
ANTHROPIC_API_URL = "https://api.anthropic.com"


def _split_system(messages: list[dict]) -> tuple[str, list[dict]]:
    """
    Extract the system message from an OpenAI-format message list.
    Anthropic passes system as a top-level parameter, not a message role.
    Returns (system_text, remaining_messages).
    """
    system_parts = []
    remaining = []
    for msg in messages:
        if msg["role"] == "system":
            system_parts.append(msg["content"])
        else:
            remaining.append(msg)
    return "\n\n".join(system_parts), remaining


def complete(messages: list[dict], config: ProviderConfig) -> str | None:
    """
    Send a chat completion request to Anthropic's API.

    messages: standard OpenAI format — system role is extracted automatically.
    Returns the assistant content string, or None on failure.
    """
    try:
        import anthropic
        from anthropic import APIError, APITimeoutError, APIConnectionError
    except ImportError:
        log.error("anthropic package not installed — run: pip install anthropic")
        return None

    if not config.api_key or config.api_key in ("lm-studio", ""):
        log.error("Anthropic provider requires a valid ANTHROPIC_API_KEY")
        return None

    system_text, conversation = _split_system(messages)

    client = anthropic.Anthropic(
        api_key=config.api_key,
        timeout=config.timeout,
    )

    try:
        kwargs = dict(
            model=config.model,
            max_tokens=config.max_tokens,
            messages=conversation,
        )
        if system_text:
            kwargs["system"] = system_text

        response = client.messages.create(**kwargs)
        content = response.content[0].text
        log.debug(
            "provider=anthropic model=%s input_tokens=%s output_tokens=%s",
            config.model,
            response.usage.input_tokens,
            response.usage.output_tokens,
        )
        return content

    except APITimeoutError:
        log.error("Request timed out after %.0fs (model=%s)", config.timeout, config.model)
    except APIConnectionError as e:
        log.error("Cannot reach Anthropic API: %s", e)
    except APIError as e:
        log.error("Anthropic API error %s: %s", e.status_code, e.message)

    return None
