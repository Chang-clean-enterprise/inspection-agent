"""Strands adapter for the inspection tools.

Thin wrappers around ``inspection_core``. Each wrapper takes the verified
``Principal`` from the Strands invocation state, never from a model argument.
Authorization, SQL, and formatting live in ``inspection_core``.
"""

from __future__ import annotations

from typing import Any

from strands import ToolContext, tool

import inspection_core
from inspection_core import Principal, results


def _principal(tool_context: ToolContext) -> Principal | None:
    """Return the verified principal from the invocation state, or None."""
    value = tool_context.invocation_state.get("principal")
    return value if isinstance(value, Principal) else None


@tool(context=True)
def list_reports(
    tool_context: ToolContext,
    line: str | None = None,
    part_number: str | None = None,
    lot_id: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    status: str | None = None,
    limit: int | None = None,
) -> dict[str, Any]:
    """List inspection reports the current user may see, newest first.

    All filters are optional and combine with AND. Results are limited to the
    inspection lines the user is allowed to read.

    Args:
        line: Inspection line, "A" or "B".
        part_number: Exact part number, for example "DEMO-SHAFT-3001".
        lot_id: Exact lot ID.
        date_from: First report date to include, as YYYY-MM-DD.
        date_to: Last report date to include, as YYYY-MM-DD.
        status: Report status: "draft", "submitted", or "closed".
        limit: Maximum number of reports to return, 1 to 50. Default 50.
    """
    principal = _principal(tool_context)
    if principal is None:
        return results.forbidden_no_principal("list_reports")
    return inspection_core.list_reports(
        principal,
        line=line,
        part_number=part_number,
        lot_id=lot_id,
        date_from=date_from,
        date_to=date_to,
        status=status,
        limit=limit,
    )


@tool(context=True)
def get_report(tool_context: ToolContext, report_id: str) -> dict[str, Any]:
    """Get one inspection report with its measurements and notes.

    Returns a denial if the report belongs to a line the user may not read.

    Args:
        report_id: The report ID, for example "IR-2025-0031".
    """
    principal = _principal(tool_context)
    if principal is None:
        return results.forbidden_no_principal("get_report")
    return inspection_core.get_report(principal, report_id=report_id)


@tool(context=True)
def get_lot(tool_context: ToolContext, lot_id: str) -> dict[str, Any]:
    """Get one lot with its reports, measurements, and notes.

    Use it to summarize the findings of a lot. Returns a denial if the lot
    belongs to a line the user may not read.

    Args:
        lot_id: The lot ID, for example "LOT-20250604-01".
    """
    principal = _principal(tool_context)
    if principal is None:
        return results.forbidden_no_principal("get_lot")
    return inspection_core.get_lot(principal, lot_id=lot_id)


@tool(context=True)
def characteristic_trend(
    tool_context: ToolContext,
    part_number: str,
    characteristic: str,
    line: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
) -> dict[str, Any]:
    """Get per-lot statistics and the trend direction for one characteristic.

    Returns, for the most recent lots, the mean, minimum, maximum, and
    out-of-tolerance count, plus a rising, falling, or flat trend indicator.

    Args:
        part_number: Exact part number, for example "DEMO-BRACKET-4001".
        characteristic: Exact characteristic name, for example "bore_diameter".
        line: Inspection line, "A" or "B".
        date_from: First lot production date to include, as YYYY-MM-DD.
        date_to: Last lot production date to include, as YYYY-MM-DD.
    """
    principal = _principal(tool_context)
    if principal is None:
        return results.forbidden_no_principal("characteristic_trend")
    return inspection_core.characteristic_trend(
        principal,
        part_number=part_number,
        characteristic=characteristic,
        line=line,
        date_from=date_from,
        date_to=date_to,
    )


TOOLS = [list_reports, get_report, get_lot, characteristic_trend]
