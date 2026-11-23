"""Build the verified Principal from the Authorization header the runtime forwards.

The AgentCore Runtime has already validated the token signature. This module only
reads the claims. It reads nothing but its argument, defines no default or anonymous
Principal, never logs, and never puts input text into an exception.
"""

import base64
import json
from collections.abc import Mapping

from inspection_core.principal import MissingClaimError, Principal, principal_from_claims


class IdentityError(Exception):
    """Authentication failed. Carries no message text from the input."""


def _authorization_value(headers: Mapping[str, str] | None) -> str:
    if not isinstance(headers, Mapping):
        raise IdentityError
    for key, value in headers.items():
        if isinstance(key, str) and key.lower() == "authorization":
            if isinstance(value, str):
                return value
            raise IdentityError
    raise IdentityError


def _token_from_header(value: str) -> str:
    parts = value.split()
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1]:
        raise IdentityError
    return parts[1]


def _claims_from_token(token: str) -> dict:
    segments = token.split(".")
    if len(segments) != 3:
        raise IdentityError
    payload = segments[1]
    padded = payload + "=" * (-len(payload) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(padded.encode("ascii")))
    except (ValueError, UnicodeError):
        raise IdentityError from None
    if not isinstance(claims, dict):
        raise IdentityError
    return claims


def principal_from_headers(headers: Mapping[str, str] | None) -> Principal:
    """Return the Principal for the forwarded access token, or raise IdentityError."""
    token = _token_from_header(_authorization_value(headers))
    claims = _claims_from_token(token)
    if "token_use" in claims and claims["token_use"] != "access":
        raise IdentityError
    try:
        return principal_from_claims(claims)
    except MissingClaimError:
        raise IdentityError from None
