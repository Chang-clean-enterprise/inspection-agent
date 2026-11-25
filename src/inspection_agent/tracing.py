"""Current trace and span identifiers, read from the active OpenTelemetry span.

This module never raises. Every function returns an empty string when no span
is recording, when the `opentelemetry` package is absent, or when the input is
not in the expected shape. There is no logging and no I/O here, and no new
dependency: only `opentelemetry-api`, which the rest of the package already
pins.
"""

from __future__ import annotations

import re

try:  # Optional import, guarded exactly like src/inspection_core/audit.py.
    from opentelemetry import trace as _otel_trace
except Exception:  # noqa: BLE001
    _otel_trace = None

TRACE_ID_HEX_DIGITS = 32
SPAN_ID_HEX_DIGITS = 16
_HEX_TRACE_ID_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def _current_span_context():
    """Return the current recording span context, or None."""
    if _otel_trace is None:
        return None
    try:
        span = _otel_trace.get_current_span()
        if not span.is_recording():
            return None
        return span.get_span_context()
    except Exception:  # noqa: BLE001
        return None


def current_trace_id() -> str:
    """Return the current trace ID as 32 lowercase hex digits, or ''."""
    context = _current_span_context()
    if context is None:
        return ""
    try:
        return format(context.trace_id, "032x")
    except Exception:  # noqa: BLE001
        return ""


def current_span_id() -> str:
    """Return the current span ID as 16 lowercase hex digits, or ''."""
    context = _current_span_context()
    if context is None:
        return ""
    try:
        return format(context.span_id, "016x")
    except Exception:  # noqa: BLE001
        return ""


def xray_trace_id(hex_trace_id: str) -> str:
    """Convert a 32-hex-digit OTel trace ID into the X-Ray trace ID form.

    Returns ``1-<first 8 hex>-<remaining 24 hex>``, or '' when `hex_trace_id`
    is not exactly 32 hex digits. The result is lowercased: `current_trace_id`
    already produces lowercase, but an ID pasted by hand from a console may not,
    and CloudWatch matches the lowercase form.
    """
    if not isinstance(hex_trace_id, str) or not _HEX_TRACE_ID_RE.fullmatch(hex_trace_id):
        return ""
    lowered = hex_trace_id.lower()
    return f"1-{lowered[:8]}-{lowered[8:]}"
