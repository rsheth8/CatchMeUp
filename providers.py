"""LLM providers CatchMeUp can recap with.

Bring your own key from any of these companies (or a custom OpenAI-compatible
endpoint / local Ollama). Transcription stays on-device via whisperkit-cli;
only the text transcript is sent to the provider you pick.
"""
from __future__ import annotations

import json
import os
import re
import time

PROVIDERS = {
    "anthropic": {
        "label": "Anthropic (Claude)",
        "kind": "anthropic",
        "default_model": "claude-haiku-4-5-20251001",
        "signup": "https://console.anthropic.com/settings/keys",
        "key_env": ("ANTHROPIC_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "openai": {
        "label": "OpenAI (GPT)",
        "kind": "openai",
        "base_url": "https://api.openai.com/v1",
        "default_model": "gpt-4.1-mini",
        "signup": "https://platform.openai.com/api-keys",
        "key_env": ("OPENAI_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "gemini": {
        "label": "Google (Gemini)",
        "kind": "openai",
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai/",
        "default_model": "gemini-2.5-flash",
        "signup": "https://aistudio.google.com/apikey",
        "key_env": ("GEMINI_API_KEY", "GOOGLE_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "groq": {
        "label": "Groq",
        "kind": "openai",
        "base_url": "https://api.groq.com/openai/v1",
        "default_model": "llama-3.3-70b-versatile",
        "signup": "https://console.groq.com/keys",
        "key_env": ("GROQ_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "openrouter": {
        "label": "OpenRouter (one key, many models)",
        "kind": "openai",
        "base_url": "https://openrouter.ai/api/v1",
        "default_model": "openai/gpt-4o-mini",
        "signup": "https://openrouter.ai/keys",
        "key_env": ("OPENROUTER_API_KEY", "CATCHMEUP_API_KEY"),
        "headers": {
            "HTTP-Referer": "https://github.com/rsheth8/CatchMeUp",
            "X-Title": "CatchMeUp",
        },
    },
    "deepseek": {
        "label": "DeepSeek",
        "kind": "openai",
        "base_url": "https://api.deepseek.com",
        "default_model": "deepseek-chat",
        "signup": "https://platform.deepseek.com/api_keys",
        "key_env": ("DEEPSEEK_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "mistral": {
        "label": "Mistral",
        "kind": "openai",
        "base_url": "https://api.mistral.ai/v1",
        "default_model": "mistral-small-latest",
        "signup": "https://console.mistral.ai/api-keys",
        "key_env": ("MISTRAL_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "together": {
        "label": "Together AI",
        "kind": "openai",
        "base_url": "https://api.together.xyz/v1",
        "default_model": "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        "signup": "https://api.together.ai/settings/api-keys",
        "key_env": ("TOGETHER_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "xai": {
        "label": "xAI (Grok)",
        "kind": "openai",
        "base_url": "https://api.x.ai/v1",
        "default_model": "grok-3-mini",
        "signup": "https://console.x.ai/",
        "key_env": ("XAI_API_KEY", "CATCHMEUP_API_KEY"),
    },
    "ollama": {
        "label": "Ollama (local, no cloud key)",
        "kind": "openai",
        "base_url": "http://127.0.0.1:11434/v1",
        "default_model": "llama3.1",
        "signup": "https://ollama.com",
        "key_env": ("CATCHMEUP_API_KEY",),
        "dummy_key": "ollama",
    },
    "custom": {
        "label": "Custom OpenAI-compatible API",
        "kind": "openai",
        "base_url": None,
        "default_model": "gpt-4o-mini",
        "signup": None,
        "key_env": ("CATCHMEUP_API_KEY",),
    },
}

ALIASES = {
    "claude": "anthropic",
    "gpt": "openai",
    "chatgpt": "openai",
    "google": "gemini",
    "google-ai": "gemini",
    "llama": "groq",
    "grok": "xai",
    "local": "ollama",
}

PLACEHOLDER_KEYS = {
    "",
    "sk-ant-your-key-here",
    "your-key-here",
    "changeme",
}


def normalize_provider(name: str | None) -> str:
    raw = (name or "").strip().lower()
    raw = ALIASES.get(raw, raw)
    if raw in PROVIDERS:
        return raw
    return ""


def active_provider() -> str:
    name = normalize_provider(os.environ.get("CATCHMEUP_PROVIDER"))
    if name:
        return name
    # Existing installs that only have an Anthropic key.
    if _looks_like_key(os.environ.get("ANTHROPIC_API_KEY")):
        return "anthropic"
    return "anthropic"


def _looks_like_key(value: str | None) -> bool:
    v = (value or "").strip()
    return bool(v) and v not in PLACEHOLDER_KEYS


def resolve_api_key(provider: str) -> str:
    spec = PROVIDERS[provider]
    if spec.get("dummy_key") and not any(_looks_like_key(os.environ.get(k)) for k in spec["key_env"]):
        return spec["dummy_key"]
    for env_name in spec["key_env"]:
        if _looks_like_key(os.environ.get(env_name)):
            return os.environ[env_name].strip()
    return ""


def resolve_model(provider: str) -> str:
    override = (os.environ.get("CATCHMEUP_MODEL") or "").strip()
    if override:
        return override
    return PROVIDERS[provider]["default_model"]


def resolve_base_url(provider: str) -> str | None:
    override = (os.environ.get("CATCHMEUP_BASE_URL") or "").strip()
    if override:
        return override.rstrip("/")
    return PROVIDERS[provider].get("base_url")


def parse_json_payload(raw: str) -> dict:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if "\n" in text:
            text = text.split("\n", 1)[1]
        text = text.strip()
        if text.endswith("```"):
            text = text[: -3].strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", text, flags=re.DOTALL)
        if match:
            return json.loads(match.group(0))
        raise


def _complete_anthropic(prompt: str, model: str, api_key: str) -> str:
    import anthropic

    client = anthropic.Anthropic(api_key=api_key)
    resp = client.messages.create(
        model=model,
        max_tokens=8000,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.content[0].text


def _complete_openai(prompt: str, model: str, api_key: str, base_url: str | None, headers: dict | None, json_mode: bool = False) -> str:
    from openai import OpenAI

    kwargs = {"api_key": api_key}
    if base_url:
        kwargs["base_url"] = base_url
    if headers:
        kwargs["default_headers"] = headers
    client = OpenAI(**kwargs)
    create_kwargs = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 8000,
    }
    if json_mode:
        try:
            resp = client.chat.completions.create(
                **create_kwargs,
                response_format={"type": "json_object"},
            )
            return resp.choices[0].message.content or ""
        except Exception:
            pass
    resp = client.chat.completions.create(**create_kwargs)
    return resp.choices[0].message.content or ""


def _complete_raw(prompt: str, json_mode: bool, log, retries: int) -> str:
    provider = active_provider()
    if provider not in PROVIDERS:
        raise RuntimeError(f"Unknown CATCHMEUP_PROVIDER={provider!r}. Run ./catchup providers")

    spec = PROVIDERS[provider]
    api_key = resolve_api_key(provider)
    if not api_key:
        raise RuntimeError(
            f"No API key for {spec['label']}. Run: ./catchup config {provider}"
        )
    model = resolve_model(provider)
    base_url = resolve_base_url(provider)
    if provider == "custom" and not base_url:
        raise RuntimeError("CATCHMEUP_BASE_URL is required for provider=custom")

    log(f"LLM {provider} / {model}")
    delay = 5
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            if spec["kind"] == "anthropic":
                return _complete_anthropic(prompt, model, api_key)
            return _complete_openai(prompt, model, api_key, base_url, spec.get("headers"), json_mode=json_mode)
        except Exception as e:
            last_err = e
            name = type(e).__name__
            status = getattr(e, "status_code", None)
            retryable = name in {"RateLimitError", "APIStatusError", "APIConnectionError", "InternalServerError"} or (
                isinstance(status, int) and status >= 500
            )
            if retryable and attempt < retries:
                log(f"{name} (attempt {attempt}/{retries}), backing off {delay}s")
                time.sleep(delay)
                delay = min(delay * 2, 60)
                continue
            raise
    raise RuntimeError(f"LLM call failed after {retries} attempts: {last_err}")


def complete_text(prompt: str, log=print, retries: int = 5) -> str:
    """Free-form answer (ask, quiz generation)."""
    return _complete_raw(prompt, json_mode=False, log=log, retries=retries).strip()


def complete_json(prompt: str, log=print, retries: int = 5) -> dict:
    """Send prompt to the configured provider and parse a JSON object."""
    delay = 5
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            raw = _complete_raw(prompt, json_mode=True, log=log, retries=1)
            return parse_json_payload(raw)
        except json.JSONDecodeError as e:
            last_err = e
            log(f"Model returned non-JSON (attempt {attempt}/{retries}), retrying")
            time.sleep(delay)
            delay = min(delay * 2, 60)
        except Exception:
            raise
    raise RuntimeError(f"LLM call failed after {retries} attempts: {last_err}")


def format_provider_list() -> str:
    lines = ["id            company"]
    for key, spec in PROVIDERS.items():
        lines.append(f"{key:<13} {spec['label']}")
    lines.append("")
    lines.append("Set one with:  ./catchup config openai")
    lines.append("Then paste that company's API key. Optional: ./catchup model gpt-4.1-mini")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] in {"list", "--list"}:
        print(format_provider_list())
    else:
        print(format_provider_list())
