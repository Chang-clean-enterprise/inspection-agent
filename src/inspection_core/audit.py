"""Audit emitter: one structured event per tool call.

``emit`` writes one JSON line through the logger ``inspection_core.audit`` and
then, when a recording OpenTelemetry span is active, sets ``inspection.<field>``
span attributes. Nothing here may change a Tool_Result, so every failure is
swallowed. The event never carries record data such as notes text.
"""

from __future__ import annotations

import json
import logging
import sys
from collections.abc import Mapping
from contextvars import ContextVar, Token
from typing import Any, Literal, TypedDict

try:  # The span block is optional. A missing package must not break the core.
    from opentelemetry import trace as _otel_trace
except Exception:  # noqa: BLE001
    _otel_trace = None

LOGGER_NAME = "inspection_core.audit"
MAX_STRING_LENGTH = 200
MAX_REPORT_IDS = 20
SPAN_PREFIX = "inspection."

# Supplies session_id and actor_id to _prepare without inspection_core importing
# anything from inspection_agent, and without the model ever supplying identity
# as a tool argument. A ContextVar, not a module global: SessionRegistry
# serialises per session, not per process, so a module global would leak one
# session's identity into a concurrent one.
_REQUEST_CONTEXT: ContextVar[tuple[str, str]] = ContextVar(
    "inspection_audit_request", default=("", "")
)


class AuditEvent(TypedDict):
    """Shape of one audit event (design: "Audit emitter")."""

    tool: str
    parameters: dict[str, Any]
    user_id: str
    groups: list[str]
    decision: Literal["allowed", "restricted", "forbidden"] | None
    effective_lines: list[str]
    row_count: int
    report_ids: list[str]
    duration_ms: int
    status: str
    session_id: str
    actor_id: str
    trace_id: str
    span_id: str


def set_request_context(*, session_id: str = "", actor_id: str = "") -> Token:
    """Set the session ID and actor ID that `_prepare` fills in when the caller
    did not supply them. Returns a token for `reset_request_context`.
    """
    return _REQUEST_CONTEXT.set((session_id, actor_id))


def reset_request_context(token: Token) -> None:
    """Undo `set_request_context`, so one request cannot leak its context into
    the next on a reused thread.
    """
    _REQUEST_CONTEXT.reset(token)


def sanitize_parameters(value: Any) -> Any:
    """Return ``value`` with every string cut to 200 characters (recursively)."""
    if isinstance(value, str):
        return value[:MAX_STRING_LENGTH]
    if isinstance(value, Mapping):
        return {str(k)[:MAX_STRING_LENGTH]: sanitize_parameters(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [sanitize_parameters(v) for v in value]
    return value


def _ensure_handler(logger: logging.Logger) -> None:
    """Attach a stdout handler only when nothing else will print the line."""
    if not logger.handlers and not logging.getLogger().handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
    logger.setLevel(logging.INFO)


def _current_trace_and_span_ids() -> tuple[str, str]:
    """Return (trace_id, span_id) as 32 and 16 lowercase hex digits, or ('', '')
    when `_otel_trace` is None or no span is recording.
    """
    if _otel_trace is None:
        return "", ""
    span = _otel_trace.get_current_span()
    if not span.is_recording():
        return "", ""
    context = span.get_span_context()
    return format(context.trace_id, "032x"), format(context.span_id, "016x")


def _prepare(event: Mapping[str, Any]) -> dict[str, Any]:
    prepared = dict(event)
    prepared["parameters"] = sanitize_parameters(event.get("parameters") or {})
    prepared["report_ids"] = [str(r) for r in (event.get("report_ids") or [])][:MAX_REPORT_IDS]

    context_session_id, context_actor_id = _REQUEST_CONTEXT.get()
    prepared["session_id"] = event.get("session_id") or context_session_id
    prepared["actor_id"] = event.get("actor_id") or context_actor_id

    trace_id, span_id = _current_trace_and_span_ids()
    prepared["trace_id"] = trace_id
    prepared["span_id"] = span_id
    return prepared


def _span_value(key: str, value: Any) -> Any:
    if key == "parameters":
        return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    if value is None:
        return "none"
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value]
    if isinstance(value, (str, bool, int, float)):
        return value
    return str(value)


def _set_span_attributes(prepared: Mapping[str, Any]) -> None:
    if _otel_trace is None:
        return
    span = _otel_trace.get_current_span()
    if not span.is_recording():
        return
    for key, value in prepared.items():
        span.set_attribute(SPAN_PREFIX + key, _span_value(key, value))


def emit(event: Mapping[str, Any]) -> None:
    """Emit one audit event. Never raises."""
    try:
        prepared = _prepare(event)
        logger = logging.getLogger(LOGGER_NAME)
        _ensure_handler(logger)
        logger.info(json.dumps(prepared, sort_keys=True, separators=(",", ":"), default=str))
    except Exception:  # noqa: BLE001
        return
    try:
        _set_span_attributes(prepared)
    except Exception:  # noqa: BLE001
        return
