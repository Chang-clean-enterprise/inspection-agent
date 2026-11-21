"""Seed Lambda handler: roles, schema, data load, and grants for the inspection database.

Runs inside the VPC. It ignores the invocation payload completely. All input comes from the
environment (secret ARNs, database name) and from files in the deployment package.

Connections use sslmode=require. That encrypts traffic but does not verify the server
certificate. Upgrade to verify-full (with the RDS CA bundle in the package) if the demo
leaves a private, single-account setup.
"""

from __future__ import annotations

import csv
import json
import logging
import os
from pathlib import Path
from typing import Any

import boto3
import psycopg
from psycopg import sql

logger = logging.getLogger()
logger.setLevel(logging.INFO)

OWNER_ROLE = "inspection_owner"
READONLY_ROLE = "agent_ro"

# Fixed, in foreign-key order. Never taken from input.
TABLES = (
    "lines",
    "parts",
    "characteristics",
    "inspectors",
    "lots",
    "inspection_reports",
    "measurements",
)

# Steps whose database messages describe synthetic data only and are safe to return.
_MESSAGE_STEPS = ("schema", "load")

_ROOT = Path(os.environ.get("LAMBDA_TASK_ROOT") or Path(__file__).parent)
_SCHEMA_FILE = _ROOT / "data" / "schema.sql"
_SEED_DIR = _ROOT / "data" / "seed"


class StepError(Exception):
    """Failure of a named step, optionally tied to a table."""

    def __init__(self, step: str, table: str | None, error: str) -> None:
        super().__init__(error)
        self.step = step
        self.table = table
        self.error = error


def _describe(exc: BaseException, step: str) -> str:
    """Build an error text from the class name and SQLSTATE, never from secret-bearing text."""
    text = type(exc).__name__
    sqlstate = getattr(exc, "sqlstate", None)
    if sqlstate:
        text += f" SQLSTATE {sqlstate}"
    if step in _MESSAGE_STEPS:
        diag = getattr(exc, "diag", None)
        message = getattr(diag, "message_primary", None)
        if message:
            text += f": {message}"
    return text


def _get_secret(arn: str) -> dict[str, Any]:
    client = boto3.client("secretsmanager")
    return json.loads(client.get_secret_value(SecretId=arn)["SecretString"])


def _connect(secret: dict[str, Any], db_name: str) -> psycopg.Connection:
    return psycopg.connect(
        host=secret["host"],
        port=int(secret["port"]),
        dbname=db_name,
        user=secret["username"],
        password=secret["password"],
        sslmode="require",
        connect_timeout=10,
        autocommit=True,
    )


def _validate_metadata() -> None:
    try:
        metadata = json.loads((_SEED_DIR / "METADATA.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        error = f"{type(exc).__name__} reading METADATA.json"
        raise StepError("validate-metadata", None, error) from exc
    if not isinstance(metadata, dict) or metadata.get("synthetic") is not True:
        raise StepError("validate-metadata", None, "METADATA.json key 'synthetic' is not true")


def _roles_exec(conn: psycopg.Connection, label: str, query: sql.Composable | str) -> Any:
    """Run one statement of the roles step. A failure is reported with the fixed label only."""
    try:
        return conn.execute(query)
    except Exception as exc:
        raise StepError("roles", None, f"substep={label} {_describe(exc, 'roles')}") from exc


def _set_password(conn: psycopg.Connection, role: str, password: str, label: str) -> None:
    """Set a role password using a client-side SCRAM-SHA-256 verifier.

    Only the PASSWORD clause is used. On PG16 a CREATEROLE user that is not a real superuser
    cannot name SUPERUSER, CREATEDB, or CREATEROLE attributes in ALTER ROLE, even to turn them off.
    New roles already default to NOSUPERUSER NOCREATEDB NOCREATEROLE, and the step verifies it.
    """
    try:
        verifier = conn.pgconn.encrypt_password(password.encode(), role.encode(), b"scram-sha-256")
    except Exception as exc:
        raise StepError("roles", None, f"substep={label} {_describe(exc, 'roles')}") from exc
    _roles_exec(
        conn,
        label,
        sql.SQL("ALTER ROLE {} PASSWORD {}").format(
            sql.Identifier(role), sql.Literal(verifier.decode())
        ),
    )


def _step_roles(master: dict, owner: dict, agent_ro: dict, db_name: str) -> None:
    """Create and configure the two roles as the RDS master (rds_superuser, not a superuser).

    The master never touches objects owned by inspection_owner, so no membership grant to the
    owner role is needed. On PG15+ it changes grants on schema public as a member of
    pg_database_owner, which holds only while the master owns the database (checked first).
    """
    db = sql.Identifier(db_name)
    owner_id = sql.Identifier(OWNER_ROLE)
    ro_id = sql.Identifier(READONLY_ROLE)
    with _connect(master, db_name) as conn:
        row = _roles_exec(
            conn,
            "check-database-owner",
            "SELECT datdba = (SELECT oid FROM pg_roles WHERE "
            "rolname = current_user) FROM pg_database WHERE datname = current_database()",
        ).fetchone()
        if not row or row[0] is not True:
            raise StepError("roles", None, "substep=check-database-owner master is not the owner")

        for role, secret, tag in (
            (OWNER_ROLE, owner, "owner"),
            (READONLY_ROLE, agent_ro, "agent-ro"),
        ):
            exists = _roles_exec(
                conn,
                f"lookup-role-{tag}",
                sql.SQL("SELECT 1 FROM pg_roles WHERE rolname = {}").format(sql.Literal(role)),
            ).fetchone()
            if not exists:
                _roles_exec(
                    conn,
                    f"create-role-{tag}",
                    sql.SQL("CREATE ROLE {} LOGIN").format(sql.Identifier(role)),
                )
            _set_password(conn, role, secret["password"], f"set-password-{tag}")

        flags = _roles_exec(
            conn,
            "verify-role-attributes",
            sql.SQL(
                "SELECT count(*) FROM pg_roles WHERE rolname IN ({}, {}) AND "
                "(rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)"
            ).format(sql.Literal(OWNER_ROLE), sql.Literal(READONLY_ROLE)),
        ).fetchone()
        if not flags or flags[0] != 0:
            raise StepError("roles", None, "substep=verify-role-attributes unexpected privileges")

        statements = (
            ("agent-ro-connection-limit", "ALTER ROLE {ro} CONNECTION LIMIT 10"),
            ("agent-ro-statement-timeout", "ALTER ROLE {ro} SET statement_timeout = '10s'"),
            (
                "agent-ro-read-only-default",
                "ALTER ROLE {ro} SET default_transaction_read_only = 'on'",
            ),
            ("revoke-db-agent-ro", "REVOKE ALL ON DATABASE {db} FROM {ro}"),
            ("revoke-db-temp-public", "REVOKE TEMPORARY ON DATABASE {db} FROM PUBLIC"),
            ("grant-db-connect", "GRANT CONNECT ON DATABASE {db} TO {ro}, {owner}"),
            ("revoke-schema-create", "REVOKE CREATE ON SCHEMA public FROM PUBLIC, {ro}"),
            ("grant-schema-usage", "GRANT USAGE ON SCHEMA public TO {ro}, {owner}"),
            ("grant-schema-create-owner", "GRANT CREATE ON SCHEMA public TO {owner}"),
        )
        for label, template in statements:
            _roles_exec(conn, label, sql.SQL(template).format(db=db, ro=ro_id, owner=owner_id))


def _step_schema(owner: dict, db_name: str) -> None:
    text = _SCHEMA_FILE.read_text(encoding="utf-8")
    with _connect(owner, db_name) as conn:
        # No parameters: simple query protocol, so the file's own BEGIN/COMMIT apply.
        conn.execute(text)


def _csv_columns(path: Path) -> list[str]:
    with path.open(newline="", encoding="utf-8") as handle:
        return next(csv.reader(handle))


def _step_load(owner: dict, db_name: str) -> None:
    current: str | None = None
    try:
        with _connect(owner, db_name) as conn, conn.transaction():
            current = None
            conn.execute(
                sql.SQL("TRUNCATE {}").format(sql.SQL(", ").join(map(sql.Identifier, TABLES)))
            )
            for table in TABLES:
                current = table
                path = _SEED_DIR / f"{table}.csv"
                columns = sql.SQL(", ").join(map(sql.Identifier, _csv_columns(path)))
                copy_sql = sql.SQL("COPY {} ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
                    sql.Identifier(table), columns
                )
                with conn.cursor() as cur, cur.copy(copy_sql) as copy, path.open("rb") as handle:
                    while chunk := handle.read(65536):
                        copy.write(chunk)
                logger.info("loaded table=%s", table)
    except Exception as exc:
        raise StepError("load", current, _describe(exc, "load")) from exc


def _step_grants(owner: dict, db_name: str) -> None:
    ro_id = sql.Identifier(READONLY_ROLE)
    with _connect(owner, db_name) as conn:
        for table in TABLES:
            ident = sql.Identifier(table)
            conn.execute(sql.SQL("REVOKE ALL ON {} FROM {}").format(ident, ro_id))
            conn.execute(sql.SQL("GRANT SELECT ON {} TO {}").format(ident, ro_id))


def _file_rows(table: str) -> int:
    with (_SEED_DIR / f"{table}.csv").open(newline="", encoding="utf-8") as handle:
        return max(sum(1 for _ in csv.reader(handle)) - 1, 0)


def _step_count(owner: dict, db_name: str) -> list[dict[str, Any]]:
    result = []
    with _connect(owner, db_name) as conn:
        for table in TABLES:
            row = conn.execute(
                sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table))
            ).fetchone()
            db_rows = int(row[0]) if row else 0
            result.append({"table": table, "db_rows": db_rows, "file_rows": _file_rows(table)})
            logger.info("count table=%s db_rows=%d", table, db_rows)
    return result


def _run_step(step: str, func, *args):
    logger.info("step=%s start", step)
    try:
        value = func(*args)
    except StepError:
        raise
    except Exception as exc:
        raise StepError(step, None, _describe(exc, step)) from exc
    logger.info("step=%s done", step)
    return value


def handler(event: Any, context: Any) -> dict[str, Any]:
    """Entry point. The event content is ignored."""
    try:
        _run_step("validate-metadata", _validate_metadata)

        db_name = os.environ["DB_NAME"]
        master = _run_step("roles", _get_secret, os.environ["MASTER_SECRET_ARN"])
        owner = _run_step("roles", _get_secret, os.environ["OWNER_SECRET_ARN"])
        agent_ro = _run_step("roles", _get_secret, os.environ["AGENT_RO_SECRET_ARN"])

        _run_step("roles", _step_roles, master, owner, agent_ro, db_name)
        _run_step("schema", _step_schema, owner, db_name)
        _run_step("load", _step_load, owner, db_name)
        _run_step("grants", _step_grants, owner, db_name)
        tables = _run_step("count", _step_count, owner, db_name)
    except StepError as exc:
        logger.error("step=%s failed table=%s error=%s", exc.step, exc.table, exc.error)
        return {"ok": False, "step": exc.step, "table": exc.table, "error": exc.error}
    except Exception as exc:  # noqa: BLE001 - last resort, class name only
        logger.error("unexpected failure %s", type(exc).__name__)
        return {"ok": False, "step": "unknown", "table": None, "error": type(exc).__name__}
    return {"ok": True, "tables": tables}
