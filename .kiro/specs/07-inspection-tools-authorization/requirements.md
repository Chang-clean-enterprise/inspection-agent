# Requirements Document

## Introduction

This feature adds the shared, read-only inspection tools to the Python package `src/inspection_core/`, together with the identity-based authorization that decides what each user may see. Four tool functions (`list_reports`, `get_report`, `get_lot`, `characteristic_trend`) read the inspection data in Amazon RDS for PostgreSQL through the `agent_ro` database role. Each function takes a Principal built from validated JWT claims, derives the allowed inspection lines from the Cognito groups, and restricts or denies the request in code. Each call emits one audit event as a log line and as trace attributes.

The core logic does not depend on the model or on Strands. Thin adapters in a separate module wrap the functions as Strands tools, and a later spec reuses the same functions in the MCP server. Return values are JSON-serializable and follow one documented schema, so the agent and the MCP server share them.

Out of scope: the agent prompt, the runtime, the UI, the MCP server, and the infrastructure templates.

All data is synthetic. All code, comments, docs, and output are in English. Per the steering Testing policy, this spec adds no test files, test suites, fixtures, or verification scripts. There is no local database, so the Reviewer verifies each acceptance criterion by hand against the deployed runtime and records the cases checked in the design document.

## Glossary

- **Inspection_Core**: The Python package `src/inspection_core/`. It holds the Tool_Functions, the Authorizer, the Database_Access module, and the Audit_Emitter.
- **Tool_Functions**: The four functions `list_reports`, `get_report`, `get_lot`, and `characteristic_trend` in the Inspection_Core.
- **Strands_Adapter**: The thin module that wraps each Tool_Function as a Strands tool. It lives in `src/inspection_agent/` and contains no authorization or query logic.
- **Principal**: An immutable object with three fields: `user_id` (the Cognito `sub` claim), `username`, and `groups` (a list of group names).
- **Verified_Claims**: The JWT claims of an access token that the AgentCore Runtime has already validated. The Inspection_Core does not validate signatures.
- **Principal_Factory**: The function in the Inspection_Core that builds a Principal from the Verified_Claims.
- **Authorizer**: The component of the Inspection_Core that maps a Principal to its Allowed_Lines and decides each request.
- **Allowed_Lines**: The set of inspection lines (`A`, `B`) that a Principal may read, derived from the groups.
- **Line_Filter**: The optional `line` parameter of a Tool_Function.
- **Effective_Scope**: The set of lines a call actually queried. It is a subset of the Allowed_Lines.
- **Decision**: The authorization outcome of one call. One of `allowed`, `restricted`, or `forbidden`.
- **Tool_Result**: The JSON-serializable object that a Tool_Function returns. The schema is defined in the design document.
- **Result_Status**: The `status` field of a Tool_Result. One of `ok`, `forbidden`, `not_found`, `invalid_request`, or `error`.
- **Row_Cap**: The hard maximum number of report rows (or lot aggregates for `characteristic_trend`) that one call returns. The value is 50.
- **Statement_Timeout**: The maximum run time of one SQL statement issued by a Tool_Function.
- **Database_Access**: The module of the Inspection_Core that opens connections as the `agent_ro` role and runs parameterized read-only queries.
- **Audit_Event**: The structured record of one Tool_Function call.
- **Audit_Emitter**: The component of the Inspection_Core that writes the Audit_Event as a JSON log line and as attributes on the current trace span.
- **Trend_Indicator**: The value computed in code by `characteristic_trend` from the per-lot means. It has a direction and a count of consecutive lots moving toward a limit.
- **Persona**: One of the three demo users: the Line A inspector (group `line-a`), the Line B inspector (group `line-b`), and the Quality supervisor (group `supervisors`).
- **Reviewer**: A person who verifies acceptance criteria by hand.
- **Stories_File**: The file `data/STORIES.md`.
- **S1_Part**: The part `DEMO-HOUSING-2001` on line B, with the characteristic `bore_diameter` described in the Stories_File.

## Requirements

### Requirement 1: Package structure and independence from the model

**User Story:** As a developer, I want the tool logic in a shared package that does not depend on the model or on Strands, so that the agent and the later MCP server use identical behavior.

#### Acceptance Criteria

1. THE Inspection_Core SHALL contain the Tool_Functions, the Principal_Factory, the Authorizer, the Database_Access module, and the Audit_Emitter.
2. THE Inspection_Core SHALL import neither the `strands` package nor any model-provider package.
3. THE Strands_Adapter SHALL wrap each Tool_Function as a Strands tool without adding authorization, query, or formatting logic.
4. THE Strands_Adapter SHALL hide the Principal from the tool schema that the model sees, and SHALL obtain the Principal from the verified request context.
5. THE Inspection_Core SHALL target Python 3.12 and pass `ruff` with the repository `ruff.toml`.

### Requirement 2: Principal from validated claims

**User Story:** As a security reviewer, I want the user identity built only from validated token claims, so that the model cannot choose who the user is.

#### Acceptance Criteria

1. WHEN the Principal_Factory receives Verified_Claims, THE Principal_Factory SHALL return a Principal whose `user_id` equals the `sub` claim, whose `username` equals the `username` claim, and whose `groups` equal the `cognito:groups` claim.
2. IF the `cognito:groups` claim is missing, empty, or not a list of strings, THEN THE Principal_Factory SHALL return a Principal with an empty `groups` list.
3. IF the `sub` claim is missing or empty, THEN THE Principal_Factory SHALL raise an error that names the missing claim.
4. THE Principal_Factory SHALL read no claim other than `sub`, `username`, and `cognito:groups` when it builds a Principal.
5. THE Tool_Functions SHALL receive the Principal through a parameter that is excluded from the model-visible tool schema, and no Tool_Function parameter that the model can set SHALL carry a user ID, a username, a group, or an allowed line.

### Requirement 3: Group-to-line mapping

**User Story:** As a security reviewer, I want the allowed lines derived from the groups by a fixed rule, so that access is predictable.

#### Acceptance Criteria

1. WHEN a Principal has the group `line-a`, THE Authorizer SHALL include line A in the Allowed_Lines.
2. WHEN a Principal has the group `line-b`, THE Authorizer SHALL include line B in the Allowed_Lines.
3. WHEN a Principal has the group `supervisors`, THE Authorizer SHALL include line A and line B in the Allowed_Lines.
4. IF a Principal has no group that appears in criteria 1 to 3, THEN THE Authorizer SHALL return an empty Allowed_Lines set.
5. THE Authorizer SHALL compare group names exactly and case-sensitively.
6. WHEN a Principal has several of the groups in criteria 1 to 3, THE Authorizer SHALL return the union of the lines.
7. WHILE the Allowed_Lines set is empty, THE Tool_Functions SHALL return a Tool_Result with Result_Status `forbidden` and no data for every call.

### Requirement 4: Tool `list_reports`

**User Story:** As an inspector, I want to list inspection report summaries filtered by line, part, lot, date, and status, so that I can find the reports I need.

#### Acceptance Criteria

1. THE `list_reports` function SHALL accept the optional typed parameters `line`, `part_number`, `lot_id`, `date_from`, `date_to`, `status`, and `limit`.
2. WHEN `list_reports` returns rows, THE `list_reports` function SHALL return for each report the fields `report_id`, `report_date`, `line`, `part_number`, `lot_id`, `status`, `disposition`, and `overall_result`.
3. THE `list_reports` function SHALL derive `overall_result` as `fail` WHEN at least one measurement of the report has the result `fail`, as `pass` WHEN the report has measurements and none has the result `fail`, and as `none` WHEN the report has no measurements.
4. THE `list_reports` function SHALL NOT include the notes text in any returned row.
5. THE `list_reports` function SHALL order rows by `report_date` descending, then by `report_id` ascending.
6. IF `date_from` is later than `date_to`, THEN THE `list_reports` function SHALL return Result_Status `invalid_request` with a reason that names both parameters.
7. IF `status` is not one of `draft`, `submitted`, or `closed`, THEN THE `list_reports` function SHALL return Result_Status `invalid_request` with a reason that lists the allowed values.
8. IF `line` is not one of `A` or `B`, THEN THE `list_reports` function SHALL return Result_Status `invalid_request` with a reason that lists the allowed values.

### Requirement 5: Tool `get_report`

**User Story:** As an inspector, I want one report with its measurements and notes, so that I can read the details.

#### Acceptance Criteria

1. WHEN a caller requests an existing report on an allowed line, THE `get_report` function SHALL return the report header fields, all measurements of the report, and the notes text.
2. THE `get_report` function SHALL return for each measurement the fields `characteristic_id`, `characteristic_name`, `unit`, `measured_value`, `lower_limit`, `upper_limit`, and `result`.
3. IF the `report_id` does not exist, THEN THE `get_report` function SHALL return Result_Status `not_found`.
4. IF the report exists on a line outside the Allowed_Lines, THEN THE `get_report` function SHALL return Result_Status `forbidden` and no report fields, no measurements, and no notes.
5. THE `get_report` function SHALL return the notes text as a data field and SHALL leave the text unchanged.

### Requirement 6: Tool `get_lot`

**User Story:** As an inspector, I want a lot with all its reports, measurements, and notes, so that I can summarize its findings.

#### Acceptance Criteria

1. WHEN a caller requests an existing lot on an allowed line, THE `get_lot` function SHALL return the lot fields (`lot_id`, `part_number`, `line`, `produced_on`, `quantity`) and every report of the lot, each with its measurements and notes text.
2. IF the `lot_id` does not exist, THEN THE `get_lot` function SHALL return Result_Status `not_found`.
3. IF the lot is on a line outside the Allowed_Lines, THEN THE `get_lot` function SHALL return Result_Status `forbidden` and no lot fields, no report count, no report IDs, no measurements, and no notes.
4. IF a lot has more reports than the Row_Cap, THEN THE `get_lot` function SHALL return the first Row_Cap reports ordered by `report_date` ascending then `report_id` ascending, and SHALL set `truncated` to true and `total_reports` to the full count in the result metadata.

### Requirement 7: Tool `characteristic_trend`

**User Story:** As a quality supervisor, I want per-lot aggregates and a trend indicator for one characteristic of a part, so that I can see whether the process drifts toward a limit.

#### Acceptance Criteria

1. THE `characteristic_trend` function SHALL accept the typed parameters `part_number` and `characteristic` (required) and `line`, `date_from`, and `date_to` (optional).
2. THE `characteristic_trend` function SHALL match `characteristic` against the characteristic `name` of the given part, case-sensitively.
3. WHEN trend data exists, THE `characteristic_trend` function SHALL return one entry per lot, ordered by the lot `produced_on` date ascending then `lot_id` ascending, with the fields `lot_id`, `produced_on`, `count`, `mean`, `min`, `max`, and `out_of_tolerance_count`.
4. THE `characteristic_trend` function SHALL count a measurement as out of tolerance WHEN its value is lower than the lower limit or higher than the upper limit of the characteristic.
5. THE `characteristic_trend` function SHALL return the characteristic `characteristic_id`, `name`, `unit`, `nominal`, `lower_limit`, and `upper_limit`.
6. THE `characteristic_trend` function SHALL compute the Trend_Indicator in code from the per-lot means, with the fields `direction` (`rising`, `falling`, or `flat`) and `consecutive_lots_toward_limit`.
7. THE `characteristic_trend` function SHALL set `direction` to `rising` WHEN the last lot mean is higher than the previous lot mean, to `falling` WHEN it is lower, and to `flat` WHEN the two are equal or fewer than two lots exist.
8. THE `characteristic_trend` function SHALL set `consecutive_lots_toward_limit` to the number of consecutive lot-to-lot mean changes, counted backward from the last lot, that have the same direction as `direction`, and to 0 WHEN `direction` is `flat`.
9. IF the part or the characteristic does not exist, THEN THE `characteristic_trend` function SHALL return Result_Status `not_found` with a reason that names which of the two is unknown.
10. IF `date_from` is later than `date_to`, THEN THE `characteristic_trend` function SHALL return Result_Status `invalid_request`.
11. IF more lots match than the Row_Cap, THEN THE `characteristic_trend` function SHALL return the most recent Row_Cap lots in ascending order and SHALL set `truncated` to true in the result metadata.
12. WHEN no measurement matches the filters in the Effective_Scope, THE `characteristic_trend` function SHALL return Result_Status `ok` with an empty lot list and a `flat` Trend_Indicator with count 0.

### Requirement 8: Authorization of line filters and scope

**User Story:** As a security reviewer, I want every call authorized in the tool layer from the Principal, so that no prompt can widen a user's access.

#### Acceptance Criteria

1. IF a Line_Filter names a line outside the Allowed_Lines, THEN THE Tool_Function SHALL return Result_Status `forbidden` with a `reason`, SHALL return no data, and SHALL set the Decision to `forbidden`.
2. WHEN a call has no Line_Filter and the Allowed_Lines are a strict subset of all lines, THE Tool_Function SHALL query only the Allowed_Lines and SHALL set the Decision to `restricted`.
3. WHEN a call has no Line_Filter and the Allowed_Lines contain all lines, THE Tool_Function SHALL query all lines and SHALL set the Decision to `allowed`.
4. WHEN a call has a Line_Filter inside the Allowed_Lines, THE Tool_Function SHALL query only that line and SHALL set the Decision to `allowed`.
5. THE Tool_Function SHALL include the Effective_Scope in the `meta.scope` field of every Tool_Result that has Result_Status `ok`.
6. THE Tool_Function SHALL apply the line restriction inside the SQL statement as a parameterized predicate on the Effective_Scope, in addition to any check made in Python.
7. THE `reason` of a `forbidden` Tool_Result SHALL NOT contain any report ID, lot ID, part number, measurement value, note text, or record count from the denied line.
8. THE Authorizer SHALL decide every call from the Principal and the request parameters, and no instruction text in any parameter or database field SHALL change the decision.

### Requirement 9: Forbidden versus not_found for ID lookups

**User Story:** As a security reviewer, I want ID lookups on inaccessible lines to be denied explicitly, with the trade-off documented, so that the demo behavior is clear and intentional.

#### Acceptance Criteria

1. IF `get_report` or `get_lot` targets an existing record on a line outside the Allowed_Lines, THEN THE Tool_Function SHALL return Result_Status `forbidden`.
2. THE design document SHALL describe the trade-off between returning `forbidden` and returning `not_found` for such lookups, including the leak of record existence that `forbidden` allows.
3. THE design document SHALL state why `forbidden` is chosen for this demo, namely that the demo shows an explicit denial for the Line B inspector (demo question 4).
4. THE `forbidden` Tool_Result for an ID lookup SHALL contain the same fields and the same `reason` wording for every denied record, so that the result reveals nothing beyond the existence of the ID.

### Requirement 10: Read-only, parameterized, bounded queries

**User Story:** As a security reviewer, I want every query to be read-only, parameterized, and bounded, so that tools cannot change data or exhaust the database.

#### Acceptance Criteria

1. THE Database_Access module SHALL connect with the `agent_ro` credentials that it reads from the AWS Secrets Manager secret `inspection-agent/<env>/database/agent-ro`, and SHALL NOT read the owner or master secrets.
2. THE Database_Access module SHALL pass every parameter value to the database driver as a bound parameter and SHALL NOT build SQL text by string concatenation or formatting from caller input.
3. THE Inspection_Core SHALL contain only `SELECT` statements, and no `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, DDL, or `COPY` statement.
4. THE Database_Access module SHALL run each Tool_Function call in a read-only transaction.
5. THE Database_Access module SHALL set the Statement_Timeout to 5 seconds for each call.
6. THE Database_Access module SHALL connect with TLS.
7. THE Tool_Functions SHALL expose no parameter that carries SQL text, a table name, a column name, or a sort expression.
8. WHEN `limit` is larger than the Row_Cap, THE `list_reports` function SHALL clamp the applied limit to the Row_Cap and SHALL report the applied limit in `meta.limit_applied`, and the clamping alone SHALL NOT set `truncated`.
9. WHEN `limit` is absent, THE `list_reports` function SHALL use the default of 50 rows as the applied limit and SHALL report the applied limit in `meta.limit_applied`.
10. IF `limit` is less than 1, THEN THE `list_reports` function SHALL return Result_Status `invalid_request`.
10a. WHEN `limit` is between 1 and the Row_Cap inclusive, THE `list_reports` function SHALL apply that value and SHALL report it in `meta.limit_applied`.
11. WHEN the number of matching rows exceeds `meta.limit_applied`, THE `list_reports` function SHALL return the first rows in the defined order, SHALL set `truncated` to true, and SHALL set `total_matches` to the full count of matching rows in the result metadata.
12. WHEN the number of matching rows is less than or equal to `meta.limit_applied`, THE `list_reports` function SHALL set `truncated` to false.
13. IF a query exceeds the Statement_Timeout or the database is unreachable, THEN THE Tool_Function SHALL return Result_Status `error` with a generic reason that contains no host name, secret value, SQL text, or driver message.
14. IF a parameter value contains SQL syntax, THEN THE Tool_Function SHALL treat the value as data and SHALL leave the structure of the query unchanged.

### Requirement 11: Audit event

**User Story:** As an operator, I want one structured audit event per call, so that I can see who asked what and what the tool decided.

#### Acceptance Criteria

1. WHEN a Tool_Function is called, THE Audit_Emitter SHALL emit exactly one Audit_Event, whatever the Result_Status, including `forbidden`, `not_found`, `invalid_request`, and `error`.
2. THE Audit_Event SHALL contain the fields `tool`, `parameters`, `user_id`, `groups`, `decision`, `effective_lines`, `row_count`, `report_ids`, `duration_ms`, and `status`.
3. THE `parameters` field SHALL hold the tool parameters as the caller supplied them, and SHALL NOT contain the notes text of any record.
4. THE `report_ids` field SHALL hold the IDs of the returned reports, capped at 20 IDs.
5. THE `decision` field SHALL hold the Decision of the call.
6. THE `duration_ms` field SHALL hold the elapsed time of the call in milliseconds, measured from the start of the Tool_Function to the point before the Audit_Event is emitted.
7. THE Audit_Emitter SHALL write the Audit_Event as one JSON object on one line through the Python logger `inspection_core.audit`.
8. THE Audit_Emitter SHALL set the same fields as attributes on the current OpenTelemetry span, using the attribute prefix `inspection.`, WHEN a recording span is active.
9. IF the Audit_Emitter fails to set span attributes, THEN THE Audit_Emitter SHALL still write the log line and the Tool_Function SHALL still return its Tool_Result.
10. IF a Tool_Function raises an unexpected exception, THEN THE Audit_Emitter SHALL still emit the Audit_Event with `status` `error` before the exception handling returns a Tool_Result.
11. THE `parameters` field SHALL limit each string value to 200 characters.

### Requirement 12: Stable, JSON-serializable return schema

**User Story:** As a developer of the agent and the MCP server, I want one documented return schema, so that both consumers handle the same results.

#### Acceptance Criteria

1. THE Tool_Functions SHALL return a Python `dict` that `json.dumps` serializes without a custom encoder.
2. THE Tool_Functions SHALL return dates as ISO 8601 strings (`YYYY-MM-DD`) and numeric database values as JSON numbers.
3. THE Tool_Functions SHALL return in every Tool_Result the fields `status` and `meta`, and the field `reason` WHEN Result_Status is not `ok`.
4. THE `meta` field SHALL contain `tool`, `schema_version`, and, for Result_Status `ok`, `scope`, `truncated`, and `row_count`, and, for the `list_reports` function only, `limit_applied`.
5. THE design document SHALL define the full schema of each Tool_Result, with field names, types, and one example per tool.
6. WHERE a field is not applicable to a Tool_Result, THE Tool_Function SHALL omit the field or set it to `null` consistently, as the design document defines.
7. THE `docs/` folder SHALL contain a page that describes the tools, the Tool_Result schema, the authorization rules, and the Audit_Event fields.

### Requirement 13: Manual verification with the demo personas

**User Story:** As a Reviewer, I want a manual verification plan against the deployed runtime, so that I can confirm the tools and the authorization without automated tests.

#### Acceptance Criteria

1. THE design document SHALL contain a manual verification table with one row per case checked, with the Persona, the tool, the parameters, the expected result, the observed result, and the date.
2. THE Reviewer SHALL check each Persona against each of the four Tool_Functions, once the runtime is deployed.
3. THE Reviewer SHALL check the S1 trend from the Stories_File.
4. THE Reviewer SHALL check the denial of the Line B inspector on line A for `list_reports`, `get_report`, and `get_lot`.
5. THE Reviewer SHALL check the Row_Cap with a `limit` above 50 and with a query that matches more than 50 reports.
6. THE Reviewer SHALL check SQL injection attempts in each string parameter, including `' OR '1'='1`, `'; DROP TABLE inspection_reports; --`, and a value that contains `%` and `_`.
7. THE Reviewer SHALL check that no write is possible, by confirming that the Inspection_Core contains no statement other than `SELECT` and by attempting a write as `agent_ro` from the VPC session described in `docs/database.md`.
8. THE Reviewer SHALL check that each call produces exactly one Audit_Event in the log and one set of `inspection.` attributes on the trace.
9. THE Reviewer SHALL check that the Audit_Event never contains notes text, by calling `get_report` on `IR-2025-0024` and reading the log line.
10. THE spec task list SHALL replace every task that would write tests with a manual verification step, and the task notes SHALL record what was checked.
11. THE Inspection_Core and the repository SHALL contain no test file, test suite, test fixture, evaluation harness, or verification script for this feature.

### Requirement 14: Acceptance behaviors for the demo personas

**User Story:** As a demo presenter, I want the personas to see exactly the data they are allowed to see, so that the demo questions work as planned.

#### Acceptance Criteria

1. WHEN the Line B inspector calls `list_reports` with `line` set to `A`, THE `list_reports` function SHALL return Result_Status `forbidden` and no rows.
2. WHEN the Line B inspector calls `list_reports` without `line`, THE `list_reports` function SHALL return only line B rows and SHALL report the Effective_Scope `["B"]`.
3. WHEN the Quality supervisor calls `characteristic_trend` for the S1_Part and the characteristic `bore_diameter`, THE `characteristic_trend` function SHALL return five lots with the means 25.001, 25.006, 25.012, 25.019, and 25.021 (rounded to three decimals), with `out_of_tolerance_count` 0, 0, 0, 1, and 2, and with `direction` `rising`.
4. WHEN the Line A inspector calls `characteristic_trend` for the S1_Part, THE `characteristic_trend` function SHALL return Result_Status `ok` with an empty lot list for the Effective_Scope `["A"]`, because no S1_Part lot exists on line A.
5. WHEN the Line B inspector calls `get_lot` for `LOT-20250604-01` (line A), THE `get_lot` function SHALL return Result_Status `forbidden` with no report IDs, no values, no notes, and no report count.
6. WHEN the Line A inspector or the Quality supervisor calls `list_reports` for the part `DEMO-SHAFT-3001`, THE `list_reports` function SHALL return the 10 reports of the Stories_File, including `IR-2025-0031` with disposition `scrap`.
7. WHEN the Line B inspector calls `get_lot` for `LOT-20250528-01`, THE `get_lot` function SHALL return the report `IR-2025-0024` with its note text unchanged and an empty disposition.
8. THE Tool_Functions SHALL perform no write and no DDL.
