"""Result envelopes, fixed reason strings, and serialization helpers.

Every tool returns a plain ``dict`` built here. Non-``ok`` results carry only
constant text and already validated request values. They never carry an ID,
count, or value read from a record.
"""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any

SCHEMA_VERSION = "1.0"

# Fixed reason strings (design: "Fixed reason strings").
REASON_FORBIDDEN_NO_LINES = "This user has no access to any inspection line."
REASON_FORBIDDEN_RECORD = "Access to this record is not permitted for this user."
REASON_NOT_FOUND_REPORT = "No report with this report_id."
REASON_NOT_FOUND_LOT = "No lot with this lot_id."
REASON_NOT_FOUND_PART = "Unknown part_number."
REASON_NOT_FOUND_CHARACTERISTIC = "Unknown characteristic for this part."
REASON_ERROR = "The request could not be completed. Try again later."


def reason_forbidden_line(line: str) -> str:
    """Reason for a denied line filter. ``line`` must be a validated ``A`` or ``B``."""
    return f"Access to line {line} is not permitted for this user."


# Serialization helpers.


def to_date_str(value: date | datetime | str) -> str:
    """Return a ``YYYY-MM-DD`` string for a date, datetime, or ISO date string."""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return date.fromisoformat(value).isoformat()


def to_float(value: Decimal | float | int) -> float:
    """Return a JSON-native float for a ``Decimal`` or number."""
    return float(value)


def to_int(value: int | Decimal | float) -> int:
    """Return an ``int`` count."""
    return int(value)


def to_json_value(value: Any) -> Any:
    """Convert database values to JSON-native types, recursively.

    ``None`` stays ``None``. ``bool`` and ``int`` stay as they are. ``Decimal``
    becomes ``float``. Dates become ``YYYY-MM-DD`` strings.
    """
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, Decimal):
        return to_float(value)
    if isinstance(value, (date, datetime)):
        return to_date_str(value)
    if isinstance(value, dict):
        return {k: to_json_value(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_json_value(v) for v in value]
    return value


# Envelope builders.


def _meta(tool: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    meta: dict[str, Any] = {"tool": tool, "schema_version": SCHEMA_VERSION}
    if extra:
        meta.update(to_json_value(extra))
    return meta


def ok(
    tool: str,
    scope: list[str] | tuple[str, ...],
    meta: dict[str, Any] | None = None,
    **payload: Any,
) -> dict[str, Any]:
    """Build an ``ok`` envelope.

    ``meta`` holds the extra fields (``truncated``, ``row_count``, and so on).
    ``scope`` is the sorted list of effective lines. ``payload`` holds the
    tool-specific top-level fields.
    """
    full_meta = _meta(tool)
    full_meta["scope"] = sorted(scope)
    if meta:
        full_meta.update(to_json_value(meta))
    result: dict[str, Any] = {"status": "ok", "meta": full_meta}
    result.update(to_json_value(payload))
    return result


def _failure(status: str, tool: str, reason: str) -> dict[str, Any]:
    return {"status": status, "reason": reason, "meta": _meta(tool)}


def forbidden(tool: str, reason: str) -> dict[str, Any]:
    return _failure("forbidden", tool, reason)


def not_found(tool: str, reason: str) -> dict[str, Any]:
    return _failure("not_found", tool, reason)


def invalid_request(tool: str, reason: str) -> dict[str, Any]:
    return _failure("invalid_request", tool, reason)


def error(tool: str) -> dict[str, Any]:
    return _failure("error", tool, REASON_ERROR)


def forbidden_no_principal(tool: str) -> dict[str, Any]:
    """Standard ``forbidden`` envelope for a call with no principal.

    The adapter returns this when the invocation state holds no principal.
    No query runs.
    """
    return forbidden(tool, REASON_FORBIDDEN_NO_LINES)
