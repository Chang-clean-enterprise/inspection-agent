"""Shared core: authorized, read-only inspection tools.

This package has no Strands or model imports. The agent adapter wraps these functions.
"""

from .principal import Principal, principal_from_claims
from .tools import characteristic_trend, get_lot, get_report, list_reports

__all__ = [
    "Principal",
    "characteristic_trend",
    "get_lot",
    "get_report",
    "list_reports",
    "principal_from_claims",
]
