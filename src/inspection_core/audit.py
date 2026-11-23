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
from typing import Any, Literal, TypedDict

try:  # The span block is optional. A missing package must not break the core.
    from opentelemetry import trace as _otel_trace
except Exception:  # noqa: BLE001
    _otel_trace = None

LOGGER_NAME = "inspection_core.audit"
MAX_STRING_LENGTH = 200
MAX_REPORT_IDS = 20
SPAN_PREFIX = "inspection."


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


def _prepare(event: Mapping[str, Any]) -> dict[str, Any]:
    prepared = dict(event)
    prepared["parameters"] = sanitize_parameters(event.get("parameters") or {})
    prepared["report_ids"] = [str(r) for r in (event.get("report_ids") or [])][:MAX_REPORT_IDS]
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
