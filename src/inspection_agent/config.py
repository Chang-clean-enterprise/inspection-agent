"""Agent configuration: constants and environment-based settings."""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

# Constant on purpose: the system prompt promises this number.
TOOL_CALL_LIMIT = 6
MAX_PROMPT_CHARS = 4000
MAX_SESSIONS = 20

DEFAULT_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
DEFAULT_REGION = "us-west-2"
PROMPT_PATH = Path(__file__).resolve().parent / "system_prompt.txt"


@dataclass(frozen=True)
class AgentConfig:
    model_id: str
    region: str
    additional_request_fields: dict | None
    prompt_path: Path


def _parse_additional_fields(raw: str | None) -> dict | None:
    if raw is None or not raw.strip():
        return None
    try:
        value = json.loads(raw)
    except ValueError:
        value = None
    if not isinstance(value, dict):
        raise ValueError("INSPECTION_ADDITIONAL_REQUEST_FIELDS must be a JSON object")
    return value


def load_config(env: Mapping[str, str] = os.environ) -> AgentConfig:
    """Build the agent config from the environment. Reads no identity variable."""
    model_id = (env.get("INSPECTION_MODEL_ID") or "").strip() or DEFAULT_MODEL_ID
    region = (env.get("INSPECTION_MODEL_REGION") or "").strip() or DEFAULT_REGION
    return AgentConfig(
        model_id=model_id,
        region=region,
        additional_request_fields=_parse_additional_fields(
            env.get("INSPECTION_ADDITIONAL_REQUEST_FIELDS")
        ),
        prompt_path=PROMPT_PATH,
    )
