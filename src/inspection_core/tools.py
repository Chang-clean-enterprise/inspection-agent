"""The read-only inspection tool functions and the shared runner.

Every public tool takes a verified ``Principal`` first and typed keyword-only
arguments after it. Each tool follows the same order: validate, authorize,
query. All tools run through ``_run``, which times the call, turns unexpected
failures into a generic ``error`` result, and emits exactly one audit event.
"""

from __future__ import annotations

import logging
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from typing import Any, Literal

from . import audit, db, queries, results
from .authorizer import allowed_lines, decide
from .principal import Principal
from .trend import trend_indicator

ROW_CAP = 50
DEFAULT_LIMIT = 50
SCHEMA_VERSION = results.SCHEMA_VERSION

MAX_STRING_LENGTH = 100
VALID_LINES = ("A", "B")
VALID_STATUSES = ("draft", "submitted", "closed")

_DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_error_logger = logging.getLogger("inspection_core.errors")

Decision = Literal["allowed", "restricted", "forbidden"]


class ValidationError(Exception):
    """A request value failed validation. The message is the public reason."""


@dataclass
class CallState:
    """Mutable record of one call. Handlers fill it, the runner audits it."""

    decision: Decision | None = None
    scope: tuple[str, ...] = ()
    row_count: int = 0
    report_ids: list[str] = field(default_factory=list)
    status: str = "error"


Handler = Callable[[CallState], dict[str, Any]]


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def _log_failure(exc: BaseException) -> None:
    """Log the class name and SQLSTATE only. Never the message."""
    try:
        sqlstate = getattr(exc, "sqlstate", None)
        _error_logger.error(
            "tool failure class=%s sqlstate=%s", type(exc).__name__, sqlstate or "none"
        )
    except Exception:  # noqa: BLE001
        return


def _set_decision(result: Any, state: CallState) -> None:
    """Add ``meta.decision`` to a result. ``None`` when not yet computed."""
    if isinstance(result, dict) and isinstance(result.get("meta"), dict):
        result["meta"]["decision"] = state.decision


def _run(
    tool: str,
    principal: Principal,
    params: dict[str, Any],
    handler: Handler,
) -> dict[str, Any]:
    """Run ``handler`` and emit exactly one audit event, whatever the outcome."""
    started = time.perf_counter()
    state = CallState()
    try:
        result = handler(state)
        state.status = str(result.get("status", "error"))
        _set_decision(result, state)
        return result
    except Exception as exc:  # noqa: BLE001
        _log_failure(exc)
        state.status = "error"
        state.row_count = 0
        state.report_ids = []
        error_result = results.error(tool)
        _set_decision(error_result, state)
        return error_result
    finally:
        duration_ms = int((time.perf_counter() - started) * 1000)
        audit.emit(
            {
                "tool": tool,
                "parameters": params,
                "user_id": principal.user_id,
                "groups": list(principal.groups),
                "decision": state.decision,
                "effective_lines": list(state.scope),
                "row_count": state.row_count,
                "report_ids": list(state.report_ids),
                "duration_ms": duration_ms,
                "status": state.status,
            }
        )


# ---------------------------------------------------------------------------
# Shared validation. Each helper raises ValidationError with the public reason.
# ---------------------------------------------------------------------------


def _check_string(name: str, value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_STRING_LENGTH:
        raise ValidationError(f"{name} must be a string of 1 to {MAX_STRING_LENGTH} characters.")
    return value


def _check_choice(name: str, value: Any, allowed: tuple[str, ...]) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or value not in allowed:
        raise ValidationError(f"{name} must be one of: {', '.join(allowed)}.")
    return value


def _check_date(name: str, value: Any) -> date | None:
    if value is None:
        return None
    if not isinstance(value, str) or not _DATE_PATTERN.fullmatch(value):
        raise ValidationError(f"{name} must be a date in YYYY-MM-DD format.")
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ValidationError(f"{name} must be a date in YYYY-MM-DD format.") from None


def _check_date_order(date_from: date | None, date_to: date | None) -> None:
    if date_from is not None and date_to is not None and date_from > date_to:
        raise ValidationError("date_from must not be later than date_to.")


def _resolve_limit(value: Any) -> int:
    """Absent gives the default, above the cap is clamped, below 1 is invalid."""
    if value is None:
        return DEFAULT_LIMIT
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError("limit must be an integer.")
    if value < 1:
        raise ValidationError("limit must be at least 1.")
    return min(value, ROW_CAP)


# ---------------------------------------------------------------------------
# Shared authorization step
# ---------------------------------------------------------------------------


def _authorize(
    tool: str, principal: Principal, state: CallState, line: str | None
) -> dict[str, Any] | None:
    """Decide the call and record it in ``state``.

    Returns a ``forbidden`` result when denied, otherwise ``None``.
    """
    auth = decide(principal, line)
    state.decision = auth.decision
    state.scope = auth.scope
    if auth.decision != "forbidden":
        return None
    state.scope = ()
    state.status = "forbidden"
    if line is not None and allowed_lines(principal):
        return results.forbidden(tool, results.reason_forbidden_line(line))
    return results.forbidden(tool, results.REASON_FORBIDDEN_NO_LINES)


# ---------------------------------------------------------------------------
# list_reports
# ---------------------------------------------------------------------------


def list_reports(
    principal: Principal,
    *,
    line: str | None = None,
    part_number: str | None = None,
    lot_id: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    status: str | None = None,
    limit: int | None = None,
) -> dict[str, Any]:
    """List inspection report summaries within the user's allowed lines."""
    tool = "list_reports"
    params = {
        "line": line,
        "part_number": part_number,
        "lot_id": lot_id,
        "date_from": date_from,
        "date_to": date_to,
        "status": status,
        "limit": limit,
    }

    def handler(state: CallState) -> dict[str, Any]:
        # 1. Validate. Failure carries decision None.
        try:
            v_line = _check_choice("line", line, VALID_LINES)
            v_status = _check_choice("status", status, VALID_STATUSES)
            v_part = _check_string("part_number", part_number)
            v_lot = _check_string("lot_id", lot_id)
            v_from = _check_date("date_from", date_from)
            v_to = _check_date("date_to", date_to)
            _check_date_order(v_from, v_to)
            limit_applied = _resolve_limit(limit)
        except ValidationError as exc:
            state.status = "invalid_request"
            return results.invalid_request(tool, str(exc))

        # 2. Authorize.
        denied = _authorize(tool, principal, state, v_line)
        if denied is not None:
            return denied

        # 3. Query.
        query_params = {
            "lines": list(state.scope),
            "part": v_part,
            "lot": v_lot,
            "date_from": v_from,
            "date_to": v_to,
            "status": v_status,
            "limit": limit_applied,
        }
        with db.read_only_session() as cur:
            cur.execute(queries.LIST_REPORTS, query_params)
            rows = cur.fetchall()

        total_matches = int(rows[0]["total_matches"]) if rows else 0
        reports = [
            {
                "report_id": r["report_id"],
                "report_date": r["report_date"],
                "line": r["line"],
                "part_number": r["part_number"],
                "lot_id": r["lot_id"],
                "status": r["status"],
                "disposition": r["disposition"],
                "overall_result": r["overall_result"],
            }
            for r in rows
        ]
        state.row_count = len(reports)
        state.report_ids = [r["report_id"] for r in reports]
        state.status = "ok"
        return results.ok(
            tool,
            state.scope,
            meta={
                "truncated": total_matches > limit_applied,
                "row_count": len(reports),
                "total_matches": total_matches,
                "limit_applied": limit_applied,
            },
            reports=reports,
        )

    return _run(tool, principal, params, handler)


# ---------------------------------------------------------------------------
# get_report and get_lot (ID lookups)
# ---------------------------------------------------------------------------


def _deny_record(tool: str, state: CallState) -> dict[str, Any]:
    """Uniform ``forbidden`` for ID lookups. Nothing about the record leaks."""
    state.decision = "forbidden"
    state.scope = ()
    state.row_count = 0
    state.report_ids = []
    state.status = "forbidden"
    return results.forbidden(tool, results.REASON_FORBIDDEN_RECORD)


def _authorize_lookup(principal: Principal, state: CallState) -> bool:
    """Authorize with no line filter. Returns False when the user has no lines."""
    auth = decide(principal, None)
    if auth.decision == "forbidden":
        return False
    state.decision = auth.decision
    state.scope = auth.scope
    return True


def _measurement(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "characteristic_id": row["characteristic_id"],
        "characteristic_name": row["characteristic_name"],
        "unit": row["unit"],
        "measured_value": row["measured_value"],
        "lower_limit": row["lower_limit"],
        "upper_limit": row["upper_limit"],
        "result": row["result"],
    }


def _overall_result(measurements: list[dict[str, Any]]) -> str:
    if any(m["result"] == "fail" for m in measurements):
        return "fail"
    return "pass" if measurements else "none"


def _report_record(row: dict[str, Any], measurements: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "report_id": row["report_id"],
        "report_date": row["report_date"],
        "line": row["line"],
        "part_number": row["part_number"],
        "lot_id": row["lot_id"],
        "inspector_id": row["inspector_id"],
        "status": row["status"],
        "disposition": row["disposition"],
        "notes": row["notes"],
        "overall_result": _overall_result(measurements),
        "measurements": measurements,
    }


def get_report(principal: Principal, *, report_id: str) -> dict[str, Any]:
    """Return one inspection report with its measurements, if the user may read it."""
    tool = "get_report"
    params = {"report_id": report_id}

    def handler(state: CallState) -> dict[str, Any]:
        try:
            v_id = _check_string("report_id", report_id)
            if v_id is None:
                raise ValidationError("report_id is required.")
        except ValidationError as exc:
            state.status = "invalid_request"
            return results.invalid_request(tool, str(exc))

        if not _authorize_lookup(principal, state):
            return _deny_record(tool, state)

        allowed = sorted(allowed_lines(principal))
        with db.read_only_session() as cur:
            cur.execute(queries.REPORT_HEADER, {"report_id": v_id})
            header = cur.fetchone()
            if header is None:
                state.status = "not_found"
                return results.not_found(tool, results.REASON_NOT_FOUND_REPORT)
            if header["line_id"] not in allowed:
                return _deny_record(tool, state)
            cur.execute(queries.GET_REPORT, {"report_id": v_id, "lines": allowed})
            rows = cur.fetchall()

        if not rows:
            state.status = "not_found"
            return results.not_found(tool, results.REASON_NOT_FOUND_REPORT)

        measurements = [_measurement(r) for r in rows if r["characteristic_id"] is not None]
        report = _report_record(rows[0], measurements)
        state.row_count = 1
        state.report_ids = [report["report_id"]]
        state.status = "ok"
        return results.ok(
            tool,
            state.scope,
            meta={"truncated": False, "row_count": 1},
            report=report,
        )

    return _run(tool, principal, params, handler)


def get_lot(principal: Principal, *, lot_id: str) -> dict[str, Any]:
    """Return one lot with its first 50 reports, if the user may read it."""
    tool = "get_lot"
    params = {"lot_id": lot_id}

    def handler(state: CallState) -> dict[str, Any]:
        try:
            v_id = _check_string("lot_id", lot_id)
            if v_id is None:
                raise ValidationError("lot_id is required.")
        except ValidationError as exc:
            state.status = "invalid_request"
            return results.invalid_request(tool, str(exc))

        if not _authorize_lookup(principal, state):
            return _deny_record(tool, state)

        allowed = sorted(allowed_lines(principal))
        with db.read_only_session() as cur:
            cur.execute(queries.LOT_HEADER, {"lot_id": v_id})
            header = cur.fetchone()
            if header is None:
                state.status = "not_found"
                return results.not_found(tool, results.REASON_NOT_FOUND_LOT)
            if header["line_id"] not in allowed:
                return _deny_record(tool, state)
            cur.execute(queries.GET_LOT, {"lot_id": v_id, "lines": allowed})
            lot_row = cur.fetchone()
            if lot_row is None:
                state.status = "not_found"
                return results.not_found(tool, results.REASON_NOT_FOUND_LOT)
            cur.execute(
                queries.GET_LOT_REPORTS,
                {"lot_id": v_id, "lines": allowed, "limit": ROW_CAP},
            )
            report_rows = cur.fetchall()
            by_report: dict[str, list[dict[str, Any]]] = {}
            if report_rows:
                ids = [r["report_id"] for r in report_rows]
                cur.execute(queries.GET_LOT_MEASUREMENTS, {"ids": ids, "lines": allowed})
                for m in cur.fetchall():
                    by_report.setdefault(m["report_id"], []).append(_measurement(m))

        total_reports = int(report_rows[0]["total_reports"]) if report_rows else 0
        reports = [_report_record(r, by_report.get(r["report_id"], [])) for r in report_rows]
        lot = {
            "lot_id": lot_row["lot_id"],
            "part_number": lot_row["part_number"],
            "line": lot_row["line"],
            "produced_on": lot_row["produced_on"],
            "quantity": lot_row["quantity"],
            "reports": reports,
        }
        state.row_count = len(reports)
        state.report_ids = [r["report_id"] for r in reports][:20]
        state.status = "ok"
        return results.ok(
            tool,
            state.scope,
            meta={
                "truncated": total_reports > ROW_CAP,
                "row_count": len(reports),
                "total_reports": total_reports,
            },
            lot=lot,
        )

    return _run(tool, principal, params, handler)


# ---------------------------------------------------------------------------
# characteristic_trend
# ---------------------------------------------------------------------------

_MEAN_QUANTUM = Decimal("0.0001")


def _round_mean(value: Any) -> Decimal:
    """Round a per-lot mean to 4 decimals, half up."""
    return Decimal(str(value)).quantize(_MEAN_QUANTUM, rounding=ROUND_HALF_UP)


def characteristic_trend(
    principal: Principal,
    *,
    part_number: str,
    characteristic: str,
    line: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
) -> dict[str, Any]:
    """Return per-lot aggregates and a trend indicator for one characteristic."""
    tool = "characteristic_trend"
    params = {
        "part_number": part_number,
        "characteristic": characteristic,
        "line": line,
        "date_from": date_from,
        "date_to": date_to,
    }

    def handler(state: CallState) -> dict[str, Any]:
        # 1. Validate. Failure carries decision None.
        try:
            v_part = _check_string("part_number", part_number)
            if v_part is None:
                raise ValidationError("part_number is required.")
            v_char = _check_string("characteristic", characteristic)
            if v_char is None:
                raise ValidationError("characteristic is required.")
            v_line = _check_choice("line", line, VALID_LINES)
            v_from = _check_date("date_from", date_from)
            v_to = _check_date("date_to", date_to)
            _check_date_order(v_from, v_to)
        except ValidationError as exc:
            state.status = "invalid_request"
            return results.invalid_request(tool, str(exc))

        # 2. Authorize with the line filter.
        denied = _authorize(tool, principal, state, v_line)
        if denied is not None:
            return denied

        with db.read_only_session() as cur:
            # 3. Catalog existence checks (not line-restricted data).
            cur.execute(queries.PART_EXISTS, {"part": v_part})
            if cur.fetchone() is None:
                state.status = "not_found"
                return results.not_found(tool, results.REASON_NOT_FOUND_PART)
            cur.execute(
                queries.CHARACTERISTIC_LOOKUP,
                {"part": v_part, "characteristic": v_char},
            )
            char_row = cur.fetchone()
            if char_row is None:
                state.status = "not_found"
                return results.not_found(tool, results.REASON_NOT_FOUND_CHARACTERISTIC)

            # 4. Scoped aggregate query (newest first, at most 50 lots).
            cur.execute(
                queries.CHARACTERISTIC_TREND,
                {
                    "characteristic_id": char_row["characteristic_id"],
                    "lines": list(state.scope),
                    "date_from": v_from,
                    "date_to": v_to,
                },
            )
            rows = cur.fetchall()

        total_lots = int(rows[0]["total_lots"]) if rows else 0
        lots = [
            {
                "lot_id": r["lot_id"],
                "produced_on": r["produced_on"],
                "count": int(r["count"]),
                "mean": _round_mean(r["mean"]),
                "min": r["min"],
                "max": r["max"],
                "out_of_tolerance_count": int(r["out_of_tolerance_count"]),
            }
            for r in reversed(rows)
        ]
        trend = trend_indicator([lot["mean"] for lot in lots])

        state.row_count = len(lots)
        state.status = "ok"
        return results.ok(
            tool,
            state.scope,
            meta={
                "truncated": total_lots > ROW_CAP,
                "row_count": len(lots),
                "total_matches": total_lots,
            },
            characteristic={
                "characteristic_id": char_row["characteristic_id"],
                "name": char_row["name"],
                "unit": char_row["unit"],
                "nominal": char_row["nominal"],
                "lower_limit": char_row["lower_limit"],
                "upper_limit": char_row["upper_limit"],
            },
            lots=lots,
            trend=trend,
        )

    return _run(tool, principal, params, handler)
