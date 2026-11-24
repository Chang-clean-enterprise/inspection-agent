"""Database access for the inspection tools.

Reads only the ``agent_ro`` secret, opens a TLS connection, and runs each tool
call in one read-only transaction with a 5 second statement timeout. Secret
values are never logged.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

import boto3
import psycopg
from psycopg.rows import dict_row

_ENV_PATTERN = re.compile(r"^[a-z][a-z0-9]{0,9}$")
_HOST_PATTERN = re.compile(r"^[A-Za-z0-9.-]{1,253}$")
_DEFAULT_ENV = "demo"
_DEFAULT_REGION = "us-west-2"
_SECRET_TTL_SECONDS = 300.0
_STATEMENT_TIMEOUT_SQL = "SET LOCAL statement_timeout = '5s'"
# SQLSTATE 28P01 invalid_password, 28000 invalid_authorization_specification.
_AUTH_FAILURE_SQLSTATES = frozenset({"28P01", "28000"})

_cache_lock = threading.Lock()
_cached_secret: dict[str, Any] | None = None
_cached_at = 0.0


def _env() -> str:
    env = os.environ.get("INSPECTION_ENV", _DEFAULT_ENV)
    if not _ENV_PATTERN.fullmatch(env):
        raise ValueError("INSPECTION_ENV is not a valid environment name")
    return env


def _region() -> str:
    return os.environ.get("AWS_REGION") or _DEFAULT_REGION


def _secret_id() -> str:
    # The only secret this module reads. Owner and master secrets are never read.
    env = _env()
    name = f"inspection-agent/{env}/database/agent-ro"
    arn = os.environ.get("INSPECTION_DB_SECRET_ARN")
    if not arn:
        return name
    pattern = (
        r"^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:"
        + re.escape(name)
        + r"-.+$"
    )
    if not re.fullmatch(pattern, arn):
        raise ValueError("INSPECTION_DB_SECRET_ARN is not a valid agent-ro secret ARN")
    return arn


def _host(secret: dict[str, Any]) -> str:
    override = os.environ.get("INSPECTION_DB_HOST")
    if not override:
        return secret["host"]
    if not _HOST_PATTERN.fullmatch(override):
        raise ValueError("INSPECTION_DB_HOST is not a valid host name")
    return override


def clear_secret_cache() -> None:
    """Drop the cached secret so the next connection reloads it."""
    global _cached_secret, _cached_at
    with _cache_lock:
        _cached_secret = None
        _cached_at = 0.0


def _load_secret() -> dict[str, Any]:
    """Return the agent_ro secret, cached in memory for 5 minutes."""
    global _cached_secret, _cached_at
    with _cache_lock:
        now = time.monotonic()
        if _cached_secret is not None and now - _cached_at < _SECRET_TTL_SECONDS:
            return _cached_secret
        client = boto3.client("secretsmanager", region_name=_region())
        response = client.get_secret_value(SecretId=_secret_id())
        secret = json.loads(response["SecretString"])
        _cached_secret = secret
        _cached_at = now
        return secret


def connect() -> psycopg.Connection:
    """Open a TLS connection as agent_ro. The caller closes it."""
    secret = _load_secret()
    try:
        return psycopg.connect(
            host=_host(secret),
            port=int(secret["port"]),
            dbname=secret["dbname"],
            user=secret["username"],
            password=secret["password"],
            sslmode="require",
            connect_timeout=5,
            application_name="inspection-core",
            row_factory=dict_row,
        )
    except psycopg.OperationalError as exc:
        # A rotated password shows up as an authentication failure. Reload next time.
        if getattr(exc, "sqlstate", None) in _AUTH_FAILURE_SQLSTATES:
            clear_secret_cache()
        raise


@contextmanager
def read_only_session() -> Iterator[psycopg.Cursor]:
    """Yield a dict-row cursor inside one read-only transaction.

    The first statement sets a 5 second statement timeout. The transaction is
    always rolled back and the connection is always closed.
    """
    conn = connect()
    try:
        conn.read_only = True
        with conn.cursor() as cur:
            cur.execute(_STATEMENT_TIMEOUT_SQL)
            yield cur
    finally:
        try:
            conn.rollback()
        finally:
            conn.close()
