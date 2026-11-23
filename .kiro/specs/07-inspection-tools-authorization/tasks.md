# Implementation Plan: Inspection Tools and Authorization

## Overview

The implementation is Python 3.12 and follows the design. The core in `src/inspection_core/` has no `strands` or model imports. The thin Strands adapter goes in `src/inspection_agent/strands_tools.py`. Work goes bottom-up: pure modules first (principal, authorizer, results, trend, audit), then database access and queries, then the four tool functions, then the adapter and the docs page.

Testing policy: this plan creates no test files, suites, fixtures, eval harnesses, pytest files, property-based tests, or CI test steps. Every place that would write tests is a manual verification step. Local checks run as one-off `python -c` invocations that create no file. There is no local database, so checks that need RDS are marked **Deferred** and run after the runtime (spec 09) is deployed. The only quality check is `ruff` with the root `ruff.toml` (`cfn-lint` is not relevant, because no template changes). Each verification task records what was checked, the observed result, and the date in its task notes. Deferred tasks also fill in the Observed and Date cells of the design's manual verification table.

## Tasks

- [x] 1. Principal and authorizer
  - [x] 1.1 Create `principal.py` and `requirements.txt`
    - Add `src/inspection_core/principal.py` with the frozen `Principal` dataclass (`user_id`, `username`, `groups` as a tuple), `principal_from_claims`, and `MissingClaimError`.
    - Read only `sub`, `username`, and `cognito:groups`. Accept groups only as a list of strings, otherwise use an empty tuple. Raise `MissingClaimError("sub")` when `sub` is missing or empty.
    - Add `src/inspection_core/requirements.txt` with pinned `psycopg[binary]`, `typing-extensions`, `boto3`, and `opentelemetry-api`.
    - _Requirements: 1.1, 1.2, 1.5, 2.1, 2.2, 2.3, 2.4_

  - [x] 1.2 Create `authorizer.py`
    - Add `ALL_LINES`, `GROUP_LINES`, `allowed_lines` (union, exact-case match), the `Authorization` dataclass, and `decide(principal, line)` following the design's decision table.
    - Keep these as pure functions with no I/O. No parameter text may reach the decision.
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 8.1, 8.2, 8.3, 8.4, 8.8_

  - [x] 1.3 Manual verification (local): Principal and Authorizer
    - Run one-off `python -c` calls with no saved file. Check `principal_from_claims` with full claims, extra claims, missing, empty, non-list, and mixed-list `cognito:groups`, and missing or empty `sub`.
    - Check `allowed_lines` and `decide` for `line-a`, `line-b`, `supervisors`, a combination, `Line-A` (wrong case), and no groups, each with line filter `None`, `A`, and `B`.
    - Covers design Properties 1, 2, and 3. Run `ruff check` and `ruff format --check` on the new files.
    - Record the inputs checked, the observed outputs, and the date in the task notes.
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 8.1, 8.2, 8.3, 8.4_
    - **Task notes (2026-11-22, local, one-off `python -c`, `PYTHONPATH=src`, venv `miscellaneous`, submodules imported directly). Result: all checks passed.**
      - `principal_from_claims` (Property 1):
        - Full claims `{sub:u1, username:alice, cognito:groups:[line-a], email:x}` gave `Principal('u1','alice',('line-a',))`.
        - Extra claims only (`foo`, `admin`) gave `Principal('u1','',())`, so unknown claims are ignored.
        - Missing groups gave `groups=()`. Empty list gave `()`.
        - Non-list groups gave `()` for the string `"line-a"` and for the tuple `("line-a",)`.
        - Mixed list `["line-a", 1]` gave `()`.
        - `sub` missing, `""`, or non-string `5` each raised `MissingClaimError` with message `sub`.
      - `allowed_lines` and `decide` (Properties 2 and 3), shown as `None / A / B`:
        - `line-a`: allowed `{A}`. Decisions: restricted `(A,)` / allowed `(A,)` / forbidden `()`.
        - `line-b`: allowed `{B}`. Decisions: restricted `(B,)` / forbidden `()` / allowed `(B,)`.
        - `supervisors`: allowed `{A,B}`. Decisions: allowed `(A,B)` / allowed `(A,)` / allowed `(B,)`.
        - `line-a` + `line-b`: same result as `supervisors`.
        - `Line-A` (wrong case): allowed `{}`. Forbidden `()` for all three filters.
        - No groups: allowed `{}`. Forbidden `()` for all three filters.
        - Extra check, `["x","line-a"]` (unknown group plus a known one): same result as `line-a`.
      - `ruff check` on `principal.py` and `authorizer.py`: all checks passed. `ruff format --check`: 2 files already formatted.

- [x] 2. Results, trend, and audit modules
  - [x] 2.1 Create `results.py`
    - Add `SCHEMA_VERSION = "1.0"`, envelope builders for `ok`, `forbidden`, `not_found`, `invalid_request`, and `error`, and the fixed reason strings from the design.
    - Add serialization helpers: dates as `YYYY-MM-DD` strings, `Decimal` as `float`, `int` counts.
    - Add a helper that builds the standard `forbidden` envelope for a missing principal, for the adapter to use.
    - Results contain no ID, count, or value from a record in any non-`ok` reason.
    - _Requirements: 8.5, 8.7, 9.4, 10.13, 12.1, 12.2, 12.3, 12.4, 12.6_

  - [x] 2.2 Create `trend.py`
    - Add pure `trend_indicator(means)` returning `direction` (`rising`, `falling`, `flat`) and `consecutive_lots_toward_limit`.
    - Implement R7.7 and R7.8: `flat` with 0 when fewer than two means or the last two are equal. Otherwise count consecutive same-sign changes backward from the end.
    - _Requirements: 7.6, 7.7, 7.8, 7.12_

  - [x] 2.3 Create `audit.py`
    - Add the `AuditEvent` shape, `emit`, and parameter sanitizing (each string cut to 200 characters).
    - Write one JSON line (`sort_keys`, compact separators) through logger `inspection_core.audit` at INFO. Attach a stdout `StreamHandler` with format `%(message)s` only when neither this logger nor the root logger has a handler.
    - Set `inspection.<field>` attributes on the current span when `span.is_recording()`. Guard the OpenTelemetry import and isolate the span block in its own `try/except Exception`. Write the log line first. An audit failure must never change the Tool_Result.
    - Cap `report_ids` at 20.
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 11.11_

  - [x] 2.4 Manual verification (local): trend, results, and audit shape
    - Run one-off `python -c` calls. Call `trend_indicator` on literal lists: empty, one value, two equal, two rising, `[25.001, 25.006, 25.012, 25.019, 25.021]` (expect `rising`, 4), a series that turns at the end, and a falling series.
    - Build one result per status with `results.py` and check that `json.dumps` works without a custom encoder, that `status` and `meta` are present, and that `reason` is present for every non-`ok` status.
    - Call `audit.emit` directly with a sample event that has a 500-character string parameter and 30 report IDs. Check the single log line, the ten fields, the 200-character cut, the 20-ID cap, and that `decision` is `null` when `None`. Call it again with a span that raises on `set_attribute` (a throwaway local object in the one-off call) and check that the log line is still written.
    - Covers design Properties 7, 10 (shape), 11, and 12. Run `ruff check` on the new files.
    - Record what was checked, the observed output, and the date in the task notes.
    - _Requirements: 7.6, 7.7, 7.8, 7.12, 11.2, 11.4, 11.7, 11.9, 11.11, 12.1, 12.3_
    - **Task notes (2026-11-22, one-off `python -c`, Python 3.13.9 from the `miscellaneous` virtualenv, submodules imported directly with `sys.path` set to `src/inspection_core`; no files saved):**
      - `trend_indicator`: `[]`, `[1.0]`, `[1,1]`, and `[1,2,2]` give `flat`, 0. `[1,2]` gives `rising`, 1. `[25.001, 25.006, 25.012, 25.019, 25.021]` gives `rising`, 4. `[1,2,3,2.5]` gives `falling`, 1 (turn at end). `[3,2,1,2]` gives `rising`, 1. `[5,4,3,2]` gives `falling`, 3.
      - `results.py`: built `ok`, `forbidden`, `not_found`, `invalid_request`, `error`, and `forbidden_no_principal`. `json.dumps` worked with no custom encoder (the `ok` result held a `Decimal` and a `date`, serialized as `1.5` and `"2025-01-02"`). Each result has `status` and `meta` (`tool`, `schema_version`). Every non-`ok` result has `reason`; `ok` has none.
      - `audit.emit`: sample event with a 500-character `part_number`, 30 report IDs, `decision=None`. One log line. Ten fields: `decision, duration_ms, effective_lines, groups, parameters, report_ids, row_count, status, tool, user_id`. `part_number` cut to 200 characters, `report_ids` capped at 20, `decision` is `null`.
      - Span that raises on `set_attribute` (a local throwaway object replacing `audit._otel_trace`): `emit` did not raise and the log line was still written (1 record captured by a handler on `inspection_core.audit`).
      - `ruff check` on `trend.py`, `results.py`, `audit.py`: All checks passed.
      - No source change was needed. Note: the default stdout handler binds to the stream current at the first `emit`, so a repeat check needs a capturing handler, not `redirect_stdout`.

- [x] 3. Database access and queries
  - [x] 3.1 Create `db.py`
    - Add secret loading from `inspection-agent/<env>/database/agent-ro` (`INSPECTION_ENV` default `demo`, validated against `^[a-z][a-z0-9]{0,9}$`; `AWS_REGION` default `us-west-2`). Cache the secret in memory for 5 minutes and drop the cache on authentication failure. Never log the secret and never read the owner or master secrets.
    - Add `connect()` with `sslmode=require`, `connect_timeout=5`, and `application_name=inspection-core`.
    - Add the `read_only_session()` context manager: `conn.read_only = True`, first statement `SET LOCAL statement_timeout = '5s'`, `dict_row` factory, always roll back and close.
    - _Requirements: 10.1, 10.4, 10.5, 10.6, 10.13_

  - [x] 3.2 Create `queries.py`
    - Add module-level static `SELECT` constants with named placeholders: the `list_reports` query (with `overall_result` and `count(*) OVER ()`), the report and lot header lookups (select `line_id` only), the `get_report` data query, the `get_lot` lot, reports, and measurements queries (reports `ORDER BY report_date ASC, report_id ASC`, `count(*) OVER ()`), the part and characteristic existence checks, and the `characteristic_trend` aggregate query.
    - Apply the line restriction as `line_id = ANY(%(lines)s::text[])` in every data query. Use exact equality and the `(%(x)s::text IS NULL OR col = %(x)s)` pattern, and no `LIKE`. No `notes` column in the list query. Only `SELECT` statements.
    - _Requirements: 4.2, 4.3, 4.4, 4.5, 5.1, 5.2, 6.1, 6.4, 7.2, 7.3, 7.4, 7.5, 8.6, 10.2, 10.3, 10.7, 10.14_

- [ ] 4. Tool functions
  - [x] 4.1 Create `tools.py` with the runner and `list_reports`
    - Add the `_run(tool, principal, params, handler)` runner with a `CallState`. It starts the timer, calls the handler, converts unexpected exceptions and database failures to a generic `error` result (class name and SQLSTATE only go to logger `inspection_core.errors`), and emits exactly one audit event in `finally`.
    - Add shared validation (strings of 1 to 100 characters, `limit` an `int` and not a `bool`, `YYYY-MM-DD` dates) and the constants `ROW_CAP`, `DEFAULT_LIMIT`, `SCHEMA_VERSION`.
    - Implement `list_reports` with keyword-only typed parameters, the validation order from the design, limit resolution (absent gives 50, 1 to 50 as given, above 50 clamped, below 1 is `invalid_request`), `meta.limit_applied`, and `truncated` only when `total_matches > limit_applied`.
    - Order of checks: validate, then authorize, then query. `invalid_request` carries decision `null`.
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 10.2, 10.7, 10.8, 10.9, 10.10, 10a, 10.11, 10.12, 10.13, 11.1, 11.10, 12.1, 12.3, 12.4_

  - [x] 4.2 Add `get_report` and `get_lot` to `tools.py`
    - Implement the lookup flow: authorize with no line filter (empty Allowed_Lines gives the uniform `forbidden`), unscoped header lookup selecting `line_id` only, `not_found` when no row, `forbidden` with the uniform reason when the line is outside the Allowed_Lines, otherwise the scoped data queries in the same transaction (`not_found` if the data query returns nothing).
    - `get_report` returns the header, `inspector_id`, `notes` unchanged, `overall_result`, and measurements ordered by `characteristic_id`.
    - `get_lot` returns the lot fields and the first 50 reports with measurements and notes, sets `truncated` and `meta.total_reports` when the lot has more, and uses `row_count` for reports returned.
    - Record `report_ids` (capped at 20) and `row_count` in the call state.
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 6.1, 6.2, 6.3, 6.4, 3.7, 9.1, 9.4, 11.4_

  - [x] 4.3 Add `characteristic_trend` to `tools.py`
    - Validate dates and `line`, authorize with the line filter, check part then characteristic existence on the catalog tables (case-sensitive), with the two distinct `not_found` reasons.
    - Run the scoped aggregate query, reverse the rows to ascending order, round means to 4 decimals with `Decimal.quantize(ROUND_HALF_UP)`, compute the Trend_Indicator from the rounded means, and set `truncated` when more than 50 lots exist.
    - Return `ok` with `lots=[]` and a `flat` indicator with count 0 when nothing matches in scope. Return the characteristic fields.
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.9, 7.10, 7.11, 7.12, 8.1, 8.6, 14.3, 14.4_

  - [x] 4.4 Create `__init__.py` exports
    - Add `src/inspection_core/__init__.py` that re-exports the four tool functions, `Principal`, and `principal_from_claims`. Keep the `seed/` package untouched.
    - _Requirements: 1.1, 1.2_

  - [x] 4.5 Manual verification (local): argument validation, imports, and SQL hygiene
    - Run one-off `python -c` calls with a literal `Principal`. Call each tool with invalid arguments that fail before any database call: bad `line`, bad `status`, `date_from` after `date_to`, bad date string, `limit=0`, `limit=True`, empty string, non-`str` ID. Check status `invalid_request`, the named parameters and allowed values in the reason, and one audit line per call with `decision` `null`.
    - Call each tool with a no-group Principal and check `forbidden` with the fixed reasons, without a database call, plus one audit line. Check that every result is JSON-serializable.
    - Check the isolation of the core: `python -c "import inspection_core, sys; assert 'strands' not in sys.modules"` and `grep -rn "strands" src/inspection_core` (excluding `seed/`) finds nothing.
    - Check SQL hygiene: `grep -rniE "\b(insert|update|delete|truncate|create|alter|drop|copy)\b" src/inspection_core --include=*.py` (excluding `seed/`) matches only comments or docstrings (table row 41). Check by reading `queries.py` that no statement is built by string formatting.
    - Run `ruff check` and `ruff format --check` on `src/inspection_core` and `src/inspection_agent`.
    - Record the commands, the observed results, and the date in the task notes.
    - _Requirements: 1.2, 1.5, 3.7, 4.6, 4.7, 4.8, 7.10, 10.3, 10.7, 10.10, 11.1, 12.1, 12.3, 13.7_
    - **Task notes (2026-11-22, local, one-off `python -c` via heredoc, no file saved, `PYTHONPATH=src`, Python 3.13.9 from the `miscellaneous` virtualenv). Result: all checks passed, no source change.**
      - Argument validation: `db.read_only_session` was replaced by a function that raises `AssertionError`, so any database call would fail the run. A `Principal("u1","alice",("supervisors",))` called 18 invalid cases through the package exports. Every result had status `invalid_request`, was `json.dumps`-serializable, and produced exactly one audit line with `decision` `null` and `status` `invalid_request`. Reasons observed:
        - `line` `"C"` / `"Z"`: `line must be one of: A, B.`
        - `status` `"open"`: `status must be one of: draft, submitted, closed.`
        - `date_from` after `date_to` (list_reports and characteristic_trend): `date_from must not be later than date_to.`
        - `date_from` `"2025-13-45"` / `"bad"`, `date_to` `"01/02/2025"`: `<name> must be a date in YYYY-MM-DD format.`
        - `limit=0`: `limit must be at least 1.`. `limit=True`: `limit must be an integer.`
        - Empty string or non-`str` for `part_number`, `lot_id`, `report_id`, `characteristic`: `<name> must be a string of 1 to 100 characters.`
      - No-group Principal (`("u2","nobody",())`), no database call, one audit line each (decision `forbidden`, status `forbidden`), JSON-serializable:
        - `list_reports` (no filter and `line="A"`) and `characteristic_trend`: `forbidden`, reason `This user has no access to any inspection line.`
        - `get_report` and `get_lot`: `forbidden`, reason `Access to this record is not permitted for this user.`
        - 23 audit lines in total for 23 calls.
      - Isolation: `python -c "import inspection_core, sys; assert 'strands' not in sys.modules"` printed `isolation ok`. `grep -rn "strands" src/inspection_core --include='*.py' --exclude-dir=seed` found nothing (rc 1). (In zsh the `--include` glob must be quoted.)
      - SQL hygiene: `grep -rniE "\b(insert|update|delete|truncate|create|alter|drop|copy)\b" ... --include='*.py' --exclude-dir=seed` matched 5 lines: a comment and a docstring in `principal.py` and `db.py` (`"immutable copy"`, `"Drop the cached secret"`) and the `.update(...)` dict method calls in `results.py` (lines 78, 97, 99). No SQL statement. `queries.py` read in full: every statement is a module-level constant with `%(name)s` placeholders, only `SELECT`, and `line_id = ANY(%(lines)s::text[])` in each data query. A grep for f-strings, `.format(`, `%` formatting, and `+` concatenation in `queries.py` found nothing. Every `cur.execute` in `tools.py` takes a `queries.*` constant plus a params dict.
      - `ruff check src/inspection_core src/inspection_agent`: All checks passed. `ruff format --check`: 12 files already formatted.
    - **Task 4.3 rounding check (same date, one-off `python -c`, `db.read_only_session` replaced by a stub context manager returning scripted rows):**
      - Newest-first aggregate rows with raw means `25.02105, 25.01905, 25.01205, 25.00605, 25.00105` returned lots in ascending order (`L4..L0`) with means `25.0011, 25.0061, 25.0121, 25.0191, 25.0211` (4 decimals, half up: `25.00105` became `25.0011`). Trend: `{'direction': 'rising', 'consecutive_lots_toward_limit': 4}`. Meta: `truncated` false, `row_count` 5, `total_matches` 5. Result is JSON-serializable.
      - Tie check: mean `1.00005` gave `1.0001`. Mean `2.00004999` gave `2.0`.
    - **list_reports `truncated` / `limit_applied` (same stub approach):**
      - `limit=500`, total 50: `limit_applied` 50, `truncated` false, `row_count` 50.
      - `limit=3`, total 50: `limit_applied` 3, `truncated` true, `row_count` 3.
      - No limit, total 50: `limit_applied` 50, `truncated` false.
      - `limit=3`, total 3: `truncated` false.

- [x] 5. Checkpoint - Core checks pass
  - Confirm tasks 1.3, 2.4, and 4.5 are recorded with passing observed results and `ruff` is clean. Ask the user if questions arise.

- [x] 6. Strands adapter
  - [x] 6.1 Verify the Strands `@tool(context=True)` and `invocation_state` assumption
    - Check the installed Strands version (`pip show strands-agents` or `python -c` importing `strands`). If it is not installed, install it in a scratch virtualenv outside the repository, or read the documentation for the version pinned for the agent.
    - Confirm by a one-off `python -c` or by reading the installed source that `@tool(context=True)` passes a `ToolContext`, that the context parameter is excluded from the model-visible tool spec, and that `ToolContext.invocation_state` carries caller-supplied values. Print a tool's `tool_spec` and confirm no `principal` or `tool_context` field appears.
    - If the API differs from the design, adjust only the design of `strands_tools.py` (document the real mechanism in the task notes) and keep the core unchanged.
    - Record the Strands version and what was confirmed or changed in the task notes.
    - _Requirements: 1.3, 1.4, 2.5_
    - **Notes (2026-11-22):**
      - Version: `strands-agents` was not installed. Installed `strands-agents 1.65.0` into the user's `miscellaneous` virtualenv (Python 3.13.9; the target runtime is 3.12, the API is the same). No requirements file exists yet in `src/inspection_agent/`, so the pin is for spec 09 to decide. Nothing was added to the repository.
      - Method: one-off `python` script via stdin (no file saved) with a `@tool(context=True)` function, `from strands import Agent, tool, ToolContext`, and a stub `Model` that emits one `toolUse` and then a final text. No AWS call.
      - Confirmed, `ToolContext`: the tool receives a `ToolContext` instance (`type(tool_context).__name__ == "ToolContext"`).
      - Confirmed, schema: `demo.tool_spec["inputSchema"]["json"]` has only `line` (properties and `required`). No `tool_context` or `principal` field. The `tool_specs` that the agent passes to the model show the same schema.
      - Confirmed, `invocation_state`: `agent("hi", invocation_state={"principal": X})` gives `tool_context.invocation_state["principal"] == X`. The legacy `agent("hi", principal=X)` kwargs path also works, but it emits a deprecation warning (`**kwargs` is deprecating, use `invocation_state`). With no value supplied, `invocation_state` is `{}` (no `KeyError` on `.get`), so a missing principal is detectable.
      - Changed: nothing in the design. The design is correct. Use the explicit `invocation_state=` argument (not bare kwargs) in the entrypoint (spec 09), and read it in the wrapper with `tool_context.invocation_state.get("principal")` so a missing principal returns the `forbidden` envelope. The core is unchanged.

  - [x] 6.2 Create `src/inspection_agent/strands_tools.py`
    - Add four `@tool(context=True)` wrappers (`list_reports`, `get_report`, `get_lot`, `characteristic_trend`) with typed model-facing arguments, docstrings that describe each tool, and a `tool_context` parameter.
    - Each body reads `tool_context.invocation_state["principal"]`, calls the core function with keyword arguments, and returns the dict. A missing principal returns the standard `forbidden` envelope from `inspection_core.results` with no query.
    - No authorization, SQL, or formatting logic. No identity, group, line-scope, SQL, table, column, or sort parameter in any signature.
    - _Requirements: 1.3, 1.4, 2.5, 10.7_

  - [x] 6.3 Manual verification (local): adapter schema and missing principal
    - With a one-off `python -c`, import the four wrappers and print their tool specs. Check that exactly four tools exist, that no spec has a `principal`, `tool_context`, user, group, line-scope, SQL, table, column, or sort property, and that `limit`, `line`, and the other typed arguments are present (table row 44).
    - Invoke one wrapper with an empty `invocation_state` and check that it returns the `forbidden` envelope and issues no database call.
    - Run `ruff check` and `ruff format --check` on `src/inspection_agent`.
    - Record what was checked, the observed result, and the date in the task notes.
    - _Requirements: 1.3, 1.4, 2.5, 10.7, 13.8_
    - **Task notes (2026-11-22, local, one-off `python` via stdin heredoc, no file saved, `PYTHONPATH=src`, `miscellaneous` virtualenv with strands-agents 1.65.0). Result: all checks passed, no source change.**
      - Tool specs: `TOOLS` has exactly 4 tools: `list_reports`, `get_report`, `get_lot`, `characteristic_trend`. A regex check for `principal|tool_context|user|group|scope|sql|table|column|sort|order` on every property name matched nothing.
      - Properties present: `list_reports` has `line`, `part_number`, `lot_id`, `date_from`, `date_to`, `status` (strings) and `limit` (integer), all optional. `get_report` requires `report_id`. `get_lot` requires `lot_id`. `characteristic_trend` requires `part_number` and `characteristic`, with optional `line`, `date_from`, `date_to`. (Table row 44.)
      - Missing principal: `db.read_only_session` was patched to raise `AssertionError`. Each of the four wrappers called with a stub context whose `invocation_state` is `{}` returned status `forbidden` (reason `This user has no access to any inspection line.`), JSON-serializable, with no database call.
      - Non-Principal values: `invocation_state={"principal": {dict with groups ["supervisors"]}}` and `{"principal": "alice"}` also gave `forbidden` for all four wrappers, no database call.
      - `ruff check src/inspection_agent`: All checks passed. `ruff format --check`: 2 files already formatted.
      - Not covered here: the wrappers were called through `_tool_func` with a stub context, not through a Strands agent loop (task 6.1 covered that path).

- [x] 7. Documentation
  - [x] 7.1 Write `docs/inspection-tools.md` and link it from `docs/README.md`
    - Document the four tools with parameters, the result envelope and per-tool payload schema with one example each, the group-to-line table, the decision and status table, the `forbidden` versus `not_found` trade-off and the reason `forbidden` is chosen for demo question 4, the Audit_Event fields, the note that `consecutive_lots_toward_limit` counts same-direction mean changes only, and the manual verification procedure (pointing to the design's table).
    - Add a link to the page in `docs/README.md`. All text in English.
    - _Requirements: 9.2, 9.3, 12.5, 12.7_

  - [x] 7.2 Manual verification (local): docs match the code
    - Read `docs/inspection-tools.md` against the implemented signatures, reason strings, and `meta` fields in `tools.py` and `results.py`. Fix any mismatch. Check that the `docs/README.md` link resolves.
    - Record what was compared and the date in the task notes.
    - _Requirements: 12.5, 12.7_
    - **Task notes (2026-11-22, local, read-only comparison, docs-only changes, no source change):**
      - Compared `docs/inspection-tools.md` with `tools.py` (signatures and defaults of the four tools, `ROW_CAP`/`DEFAULT_LIMIT`/`MAX_STRING_LENGTH`, validation reasons, limit resolution, `truncated` rules, ordering and 50-row caps, `meta` fields per tool, audit event fields, `report_ids` cap of 20, one audit event per call), `results.py` (all fixed reason strings, `schema_version` `1.0`, meta keys, non-`ok` results carry only `tool` and `schema_version`, `forbidden_no_principal`), and `strands_tools.py` (four wrappers, typed model-facing parameters, no identity parameter, `_principal` reads `invocation_state["principal"]`). Everything matched except the two points below.
      - Fixed: the docs did not describe the missing-principal behavior. Added to section 1: with no `Principal` in the invocation state the adapter returns `forbidden` with `This user has no access to any inspection line.`, runs no query, and the core is not called (so no audit event).
      - Fixed: section 7 said the design table lists 30 cases. The design table has 50 rows (1 to 50). Rewrote the list of groups with the real row ranges (1 to 13, 14 to 21, 22 to 26, 27 to 30, 31 to 40, 41 to 44, 45 to 50).
      - `docs/README.md`: the link `[inspection-tools.md](inspection-tools.md)` resolves to `docs/inspection-tools.md`, which exists. Observation, not changed (outside this task): `docs/README.md` has two near-duplicate `database.md` entries.

- [ ] 8. Deferred verification against the deployed runtime
  - [~] 8.1 Persona by tool (design table rows 1 to 13) - Deferred until the runtime (spec 09) is deployed
    - Call each tool as the Line A inspector, the Line B inspector, and the Quality supervisor, using tokens from `docs/auth.md`. Check the S1 trend (row 13: means 25.001, 25.006, 25.012, 25.019, 25.021, out-of-tolerance 0, 0, 0, 1, 2, `rising`, count 4), `IR-2025-0031` with disposition `scrap`, the `DEMO-SHAFT-3001` list of 10 reports, and `IR-2025-0024` with its note unchanged and empty disposition.
    - Fill the Observed and Date cells in the design table and record the summary in the task notes.
    - _Requirements: 13.1, 13.2, 13.3, 14.2, 14.3, 14.4, 14.6, 14.7, 5.5, 8.5_

  - [~] 8.2 Denial and scope (rows 14 to 21) - Deferred until the runtime is deployed
    - Check the Line B inspector denied on line A for `list_reports`, `get_report`, and `get_lot` (row 14 to 16), the `not_found` comparison (row 17), the identical reason for the Line A inspector on a line B record (row 18), a user with no group (row 19), a trend with a denied line filter (row 20), and that the model-visible schema carries no identity parameter (row 21).
    - Fill the design table and record the summary in the task notes.
    - _Requirements: 13.4, 14.1, 14.5, 3.7, 8.1, 8.7, 9.1, 9.4, 2.5_

  - [~] 8.3 Not found, invalid input, and row cap (rows 22 to 30) - Deferred until the runtime is deployed
    - Check unknown part and characteristic (rows 22, 23), invalid dates and `limit` (rows 24 to 26), and the row cap with `limit=500`, `limit=3`, and no limit (rows 27 to 29, covering requirements 10.8, 10.9, 10.10, 10a, 10.11, 10.12). Row 30 (a regenerated seed with more than 50 reports in a scratch checkout) is optional. Record whether it ran.
    - Fill the design table and record the summary in the task notes.
    - _Requirements: 4.6, 7.9, 7.10, 10.8, 10.9, 10.10, 10a, 10.11, 10.12, 13.5_

  - [~] 8.4 SQL injection attempts (rows 31 to 40) - Deferred until the runtime is deployed
    - For each string parameter run `' OR '1'='1`, `'; DROP TABLE inspection_reports; --`, and `100%_x`. After the run, confirm `inspection_reports` still holds 50 rows from a VPC session (`docs/database.md` section 9). Check that the audit line shows each value cut to 200 characters and that no stack trace appears in any result.
    - Fill the design table and record the summary in the task notes.
    - _Requirements: 10.2, 10.7, 10.14, 8.8, 13.6_

  - [~] 8.5 No write possible (rows 41 to 44) - Deferred until the runtime is deployed
    - Re-run the grep from task 4.5 (row 41). From the VPC session attempt `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, and `CREATE TABLE` as `agent_ro` and confirm each is rejected (row 42). Check `SHOW transaction_read_only` returns `on` inside `read_only_session` (row 43). Confirm the model sees exactly four tools (row 44).
    - Fill the design table and record the summary in the task notes.
    - _Requirements: 10.3, 10.4, 13.7, 14.8_

  - [~] 8.6 Audit and trace (rows 45 to 50) - Deferred until the runtime is deployed
    - Run rows 1, 14, 17, and 24 and count the `inspection_core.audit` log lines (exactly one each, statuses `ok`, `forbidden`, `not_found`, `invalid_request`). Check the ten fields and `decision` `null` for row 24. Check the `inspection.*` span attributes in the trace view. Call `get_report` on `IR-2025-0024` as the Line B inspector and confirm no note text in the log line. Check `report_ids` stays at 20 or fewer, or record "not reachable with committed seed". Stop the database or use an unknown `INSPECTION_ENV` and confirm status `error` with a generic reason and one audit line.
    - Fill the design table and record the summary in the task notes.
    - _Requirements: 10.13, 11.1, 11.2, 11.3, 11.4, 11.7, 11.8, 11.10, 13.8, 13.9_

- [~] 9. Final checkpoint - Review recorded verification
  - Confirm every verification task has its observations recorded in the task notes, the deferred rows are filled in once the runtime is deployed (or listed as still deferred), `ruff` is clean, and the repository contains no test file, suite, fixture, harness, or verification script. Ask the user if questions arise.

## Notes

- No test files, test suites, fixtures, eval harnesses, pytest files, property-based tests, or CI test steps are created (R13.10, R13.11). Manual verification steps take their place.
- The design's correctness properties are verified by hand with the manual verification table. Local one-off `python -c` calls cover the pure functions and the argument validation. Deployed calls cover the database-backed behavior.
- Tasks 8.1 to 8.6 are deferred until the runtime (spec 09) is deployed and the demo users exist. Until then they stay unchecked.
- Each verification task records what was checked, the observed result, and the date in its task notes.
- The quality checks are `ruff` (root `ruff.toml`) only. `cfn-lint` does not apply because no template changes.
- Criterion 10a in the requirements (between 10.10 and 10.11) is cited as 10a.
- Core code stays free of `strands` and model imports. The adapter in `src/inspection_agent/strands_tools.py` is the only place that imports Strands.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "2.2", "3.2"] },
    { "id": 1, "tasks": ["1.2", "2.3", "3.1"] },
    { "id": 2, "tasks": ["1.3", "2.4", "4.1"] },
    { "id": 3, "tasks": ["4.2"] },
    { "id": 4, "tasks": ["4.3"] },
    { "id": 5, "tasks": ["4.4"] },
    { "id": 6, "tasks": ["4.5"] },
    { "id": 7, "tasks": ["5"] },
    { "id": 8, "tasks": ["6.1", "7.1"] },
    { "id": 9, "tasks": ["6.2"] },
    { "id": 10, "tasks": ["6.3", "7.2"] },
    { "id": 11, "tasks": ["8.1"] },
    { "id": 12, "tasks": ["8.2"] },
    { "id": 13, "tasks": ["8.3"] },
    { "id": 14, "tasks": ["8.4"] },
    { "id": 15, "tasks": ["8.5"] },
    { "id": 16, "tasks": ["8.6"] },
    { "id": 17, "tasks": ["9"] }
  ]
}
```
