"""Verified user identity for the inspection tools.

The Principal is built only from claims of a token the runtime already validated.
The model never supplies it.
"""

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


class MissingClaimError(ValueError):
    """A required claim is missing or empty. The message is the claim name only."""


@dataclass(frozen=True)
class Principal:
    user_id: str  # Cognito "sub"
    username: str  # "username" claim, "" if absent
    groups: tuple[str, ...]  # immutable copy of "cognito:groups"


def principal_from_claims(claims: Mapping[str, Any]) -> Principal:
    """Build a Principal from `sub`, `username`, and `cognito:groups` only."""
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise MissingClaimError("sub")

    username = claims.get("username")
    if not isinstance(username, str):
        username = ""

    raw_groups = claims.get("cognito:groups")
    if isinstance(raw_groups, list) and all(isinstance(g, str) for g in raw_groups):
        groups = tuple(raw_groups)
    else:
        groups = ()

    return Principal(user_id=sub, username=username, groups=groups)
