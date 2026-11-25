"""AgentCore Runtime entrypoint.

Identity enters only here, from the Authorization header the runtime forwards
after it validates the token. The Principal goes to the tools through the Strands
invocation state. The model never sees it, and no error payload, log line, or
span attribute holds the token, the claims, the prompt, or an exception message.
"""

from __future__ import annotations

import logging
import os
import threading
import uuid

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from opentelemetry import trace

from . import memory
from .agent_factory import build_agent
from .budget import RequestRecorder
from .config import MAX_PROMPT_CHARS, AgentConfig, load_config
from .identity import IdentityError, principal_from_headers
from .prompt import load_system_prompt
from .sessions import SessionOwnerMismatch, SessionRegistry

logger = logging.getLogger("inspection_agent.entrypoint")

MAX_SESSION_ID_CHARS = 128

_ALLOWED_LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR")


def _configure_logging() -> None:
    """Set the level on the project loggers only. The root logger is not touched.

    Reads INSPECTION_LOG_LEVEL. Any value outside the allowed set falls back to INFO.
    """
    level = os.environ.get("INSPECTION_LOG_LEVEL", "INFO").strip().upper()
    if level not in _ALLOWED_LOG_LEVELS:
        level = "INFO"
    for name in ("inspection_agent", "inspection_core"):
        logging.getLogger(name).setLevel(level)


_configure_logging()

# Fixed error payloads. Defined once. Never built from input or from an exception.
ERROR_UNAUTHENTICATED = {
    "error": {"code": "unauthenticated", "message": "Authentication is required."}
}
ERROR_INVALID_REQUEST = {
    "error": {
        "code": "invalid_request",
        "message": "The request is not valid. Send a prompt of 1 to 4000 characters.",
    }
}
ERROR_FORBIDDEN_SESSION = {
    "error": {
        "code": "forbidden_session",
        "message": "This session belongs to another user.",
    }
}
ERROR_INTERNAL = {
    "error": {
        "code": "internal_error",
        "message": "The request could not be completed. Try again later.",
    }
}

app = BedrockAgentCoreApp()

_registry = SessionRegistry()
_load_lock = threading.Lock()
_loaded: tuple[AgentConfig, str, str] | None = None  # config, prompt version, prompt text


def _settings() -> tuple[AgentConfig, str, str]:
    """Load the config and the prompt on first use. Called inside the handler's try."""
    global _loaded
    with _load_lock:
        if _loaded is None:
            config = load_config()
            version, text = load_system_prompt(config.prompt_path)
            _loaded = (config, version, text)
        return _loaded


def _parse_payload(payload: object) -> tuple[str, str | None] | None:
    """Return (prompt, session_id or None), or None when the payload is not valid.

    Every other key, including any identity-looking one, is ignored.
    """
    if not isinstance(payload, dict):
        return None
    prompt = payload.get("prompt")
    if not isinstance(prompt, str):
        return None
    prompt = prompt.strip()
    if not 1 <= len(prompt) <= MAX_PROMPT_CHARS:
        return None
    session_id = payload.get("session_id")
    if session_id is not None:
        if not isinstance(session_id, str) or not 1 <= len(session_id) <= MAX_SESSION_ID_CHARS:
            return None
    return prompt, session_id


def _set_span_attributes(prompt_version: str, model_id: str) -> None:
    """Set the attributes known before the model call.

    Called before the agent runs, so a failed invocation still carries the
    prompt version and the model ID in its trace.
    """
    try:
        span = trace.get_current_span()
        if span.is_recording():
            span.set_attribute("inspection.prompt_version", prompt_version)
            span.set_attribute("inspection.model_id", model_id)
    except Exception:  # noqa: BLE001, S110
        pass


def _set_memory_span_attributes(
    memory_enabled: bool,
    background_records: int,
    write_status: str,
) -> None:
    """Set the memory attributes, which are known only after the write.

    The record count is a count. No record text, prompt text, or answer text
    reaches a span attribute.
    """
    try:
        span = trace.get_current_span()
        if span.is_recording():
            span.set_attribute("inspection.memory.enabled", memory_enabled)
            span.set_attribute("inspection.memory.background_records", background_records)
            span.set_attribute("inspection.memory.write_status", write_status)
    except Exception:  # noqa: BLE001, S110
        pass


@app.entrypoint
def handler(payload, context):
    try:
        try:
            principal = principal_from_headers(getattr(context, "request_headers", None))
        except IdentityError:
            return ERROR_UNAUTHENTICATED

        parsed = _parse_payload(payload)
        if parsed is None:
            return ERROR_INVALID_REQUEST
        prompt, requested_session_id = parsed

        session_id = (
            requested_session_id or getattr(context, "session_id", None) or uuid.uuid4().hex
        )
        if not isinstance(session_id, str) or not session_id:
            session_id = uuid.uuid4().hex

        config, prompt_version, prompt_text = _settings()

        try:
            entry = _registry.acquire(
                session_id,
                principal.user_id,
                lambda: build_agent(config, prompt_text, prompt_version),
            )
        except SessionOwnerMismatch:
            return ERROR_FORBIDDEN_SESSION

        _set_span_attributes(prompt_version, config.model_id)

        memory_id = config.memory_id
        background = ""
        record_count = 0

        recorder = RequestRecorder()
        with entry.lock:
            if memory_id and not entry.background_loaded:
                background, record_count = memory.read_background(
                    memory_id, principal.user_id, prompt
                )
                entry.background_loaded = True

            model_input = [{"text": background}, {"text": prompt}] if background else prompt
            result = entry.agent(
                model_input,
                invocation_state={"principal": principal, "recorder": recorder},
            )
        answer = str(result).strip()
        if not answer:
            return ERROR_INTERNAL

        write_status = "disabled"
        if memory_id:
            ok = memory.write_turn(memory_id, principal.user_id, session_id, prompt, answer)
            write_status = "ok" if ok else "failed"
            if not ok:
                logger.warning("memory write failed")

        _set_memory_span_attributes(
            memory_enabled=bool(memory_id),
            background_records=record_count,
            write_status=write_status,
        )
        return {"answer": answer, "actions": recorder.actions, "session_id": session_id}
    except Exception as exc:  # noqa: BLE001
        logger.error("invocation failed class=%s", type(exc).__name__)
        return ERROR_INTERNAL


if __name__ == "__main__":
    app.run()
