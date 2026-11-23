"""Line authorization for the inspection tools.

Pure functions, no I/O. The decision depends only on the Principal's groups and
the line filter. No parameter text or database field reaches it.
"""

from dataclasses import dataclass
from typing import Literal

from .principal import Principal

ALL_LINES = frozenset({"A", "B"})
GROUP_LINES: dict[str, frozenset[str]] = {
    "line-a": frozenset({"A"}),
    "line-b": frozenset({"B"}),
    "supervisors": frozenset({"A", "B"}),
}


def allowed_lines(principal: Principal) -> frozenset[str]:
    """Union of the lines of the known groups, matched with exact case."""
    lines: set[str] = set()
    for group in principal.groups:
        lines |= GROUP_LINES.get(group, frozenset())
    return frozenset(lines)


@dataclass(frozen=True)
class Authorization:
    decision: Literal["allowed", "restricted", "forbidden"]
    scope: tuple[str, ...]  # sorted effective lines, () when forbidden


_FORBIDDEN = Authorization(decision="forbidden", scope=())


def decide(principal: Principal, line: str | None) -> Authorization:
    """Decide a call from the Principal's allowed lines and an optional line filter."""
    allowed = allowed_lines(principal)
    if not allowed:
        return _FORBIDDEN
    if line is not None:
        if line not in allowed:
            return _FORBIDDEN
        return Authorization(decision="allowed", scope=(line,))
    scope = tuple(sorted(allowed))
    if allowed == ALL_LINES:
        return Authorization(decision="allowed", scope=scope)
    return Authorization(decision="restricted", scope=scope)
