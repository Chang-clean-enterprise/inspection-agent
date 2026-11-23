# Inspection tools

This page describes the four read-only inspection tools in `src/inspection_core/`: their parameters, the result schema, the authorization rules, the audit event, and how to verify them by hand. All data is synthetic.

The tools are plain Python functions with no dependency on Strands or on a model. The agent wraps them as Strands tools, and the MCP server reuses the same functions. Every result is a `dict` that `json.dumps` serializes without a custom encoder.

## 1. Tools and parameters

Every tool takes a `Principal` as its first argument. The Principal is built from the validated token claims (`sub`, `username`, `cognito:groups`). The adapter hides it from the schema the model sees, so the model never supplies a user identity, a group, or an allowed line. If the invocation state of the agent holds no `Principal`, the adapter returns the standard `forbidden` result with the reason `This user has no access to any inspection line.` and runs no query and no audit event (the core function is not called). All other parameters are keyword-only. Dates are `YYYY-MM-DD` strings. String parameters are 1 to 100 characters.

| Tool | Parameters | Returns |
|---|---|---|
| `list_reports` | `line` (`A` or `B`), `part_number`, `lot_id`, `date_from`, `date_to`, `status` (`draft`, `submitted`, `closed`), `limit` (all optional) | Report summaries, newest first. No notes text. |
| `get_report` | `report_id` (required) | One report with its measurements and notes. |
| `get_lot` | `lot_id` (required) | One lot with its reports (up to 50), measurements, and notes. |
| `characteristic_trend` | `part_number`, `characteristic` (required), `line`, `date_from`, `date_to` (optional) | Per-lot aggregates and a trend indicator for one characteristic. |

Matching on `part_number`, `lot_id`, and `characteristic` is exact and case-sensitive. No `LIKE` is used, so `%` and `_` are plain characters.

Limits:

- Row cap: one call returns at most 50 reports (or 50 lots for `characteristic_trend`).
- `list_reports` `limit`: absent means 50, 1 to 50 is applied as given, above 50 is clamped to 50, below 1 is `invalid_request`. Clamping alone does not set `truncated`.
- `get_lot` returns the first 50 reports by `report_date` then `report_id`, ascending.
- `characteristic_trend` returns the most recent 50 lots, in ascending order.
- Each call runs in a read-only transaction with a 5 second statement timeout, as the `agent_ro` database role.

## 2. Group-to-line table

The tool layer derives the allowed lines from the `cognito:groups` claim. Group names are compared exactly and case-sensitively. A user with several groups gets the union of their lines. A user with none of these groups has no allowed line.

| Group | Allowed lines |
|---|---|
| `line-a` | A |
| `line-b` | B |
| `supervisors` | A, B |

See [auth.md](auth.md) for the personas and how to get a token.

## 3. Result envelope

Every tool returns the same envelope. The current `schema_version` is `1.0`.

| Field | Type | Present |
|---|---|---|
| `status` | `ok`, `forbidden`, `not_found`, `invalid_request`, or `error` | Always |
| `reason` | string | When `status` is not `ok` |
| `meta.tool` | string | Always |
| `meta.schema_version` | string | Always |
| `meta.decision` | `allowed`, `restricted`, `forbidden`, or `null` | Always |
| `meta.scope` | list of lines, sorted, for example `["A","B"]` | When `status` is `ok` |
| `meta.truncated` | bool | When `status` is `ok` |
| `meta.row_count` | int, rows or entries returned | When `status` is `ok` |
| `meta.total_matches` | int, full match count | `list_reports` and `characteristic_trend`, when `ok` |
| `meta.limit_applied` | int | `list_reports` only, when `ok` |
| `meta.total_reports` | int, full report count of the lot | `get_lot` only, when `ok` |

Payload fields appear only when `status` is `ok`. Results with any other status carry no payload, no `scope`, and no counts. Dates are `YYYY-MM-DD` strings and numeric database values are JSON numbers. A field that does not apply to a result is omitted. Nullable record fields (`disposition`, `notes`) are always present and `null` when empty.

`meta.decision` is the same authorization verdict that the audit event records (see section 4), and it is `null` when no verdict was computed. It is an additive field, so `schema_version` stays `1.0`. The Strands adapter's no-principal denial also carries it, with the value `forbidden`.

`truncated` is true when more rows match than the call returned. For `list_reports` that means `total_matches` is above `limit_applied`. For `get_lot` it means `total_reports` is above 50. For `characteristic_trend` it means `total_matches` is above 50.

### `list_reports`

Payload: `reports`, a list of `{report_id, report_date, line, part_number, lot_id, status, disposition, overall_result}`. `overall_result` is `fail` when any measurement of the report failed, `pass` when it has measurements and none failed, and `none` when it has no measurements. Order is `report_date` descending, then `report_id` ascending.

```json
{"status":"ok",
 "meta":{"tool":"list_reports","schema_version":"1.0","scope":["B"],"truncated":false,
         "row_count":1,"total_matches":1,"limit_applied":50},
 "reports":[{"report_id":"IR-2025-0024","report_date":"2025-05-30","line":"B",
   "part_number":"DEMO-BRACKET-4001","lot_id":"LOT-20250528-01","status":"submitted",
   "disposition":null,"overall_result":"pass"}]}
```

The `overall_result` value above is illustrative. The real value comes from the seeded measurements.

### `get_report`

Payload: `report`, an object with `report_id`, `report_date`, `line`, `part_number`, `lot_id`, `inspector_id`, `status`, `disposition`, `notes`, `overall_result`, and `measurements`. Each measurement has `characteristic_id`, `characteristic_name`, `unit`, `measured_value`, `lower_limit`, `upper_limit`, and `result`. The notes text is returned unchanged. It is data, not an instruction.

```json
{"status":"ok",
 "meta":{"tool":"get_report","schema_version":"1.0","scope":["A"],"truncated":false,"row_count":1},
 "report":{"report_id":"IR-2025-0031","report_date":"2025-06-06","line":"A",
   "part_number":"DEMO-SHAFT-3001","lot_id":"LOT-20250604-01","inspector_id":"insp-a-02",
   "status":"closed","disposition":"scrap","notes":"Journal oversize, lot segregated, scrap per MRB.",
   "overall_result":"fail",
   "measurements":[{"characteristic_id":"CHR-3001-01","characteristic_name":"journal_diameter",
     "unit":"mm","measured_value":20.014,"lower_limit":19.99,"upper_limit":20.01,"result":"fail"}]}}
```

### `get_lot`

Payload: `lot`, an object with `lot_id`, `part_number`, `line`, `produced_on`, `quantity`, and `reports`. Each entry of `reports` has the same shape as the `report` object of `get_report`. `meta.row_count` is the number of reports returned and `meta.total_reports` is the full count.

```json
{"status":"ok",
 "meta":{"tool":"get_lot","schema_version":"1.0","scope":["B"],"truncated":false,
         "row_count":1,"total_reports":1},
 "lot":{"lot_id":"LOT-20250528-01","part_number":"DEMO-BRACKET-4001","line":"B",
   "produced_on":"2025-05-28","quantity":120,
   "reports":[{"report_id":"IR-2025-0024","report_date":"2025-05-30","line":"B",
     "part_number":"DEMO-BRACKET-4001","lot_id":"LOT-20250528-01","inspector_id":"insp-b-01",
     "status":"submitted","disposition":null,
     "notes":"Hole looks off on piece 2. Fixture? Tool wear? Not sure. Will recheck.",
     "overall_result":"pass","measurements":[]}]}}
```

The quantity, inspector ID, and measurement list in this example are illustrative.

### `characteristic_trend`

Payload: `characteristic` (`characteristic_id`, `name`, `unit`, `nominal`, `lower_limit`, `upper_limit`), `lots` (one entry per lot, `produced_on` ascending then `lot_id` ascending, with `lot_id`, `produced_on`, `count`, `mean`, `min`, `max`, `out_of_tolerance_count`), and `trend` (`direction` and `consecutive_lots_toward_limit`). `meta.row_count` is the number of lots and `meta.total_matches` is the full lot count.

A measurement is out of tolerance when its value is below the lower limit or above the upper limit of the characteristic. The mean is rounded to 4 decimals. The trend is computed in code from the rounded means.

When no measurement matches the filters in the allowed scope, the result is `ok` with `lots` empty and `trend` set to `{"direction":"flat","consecutive_lots_toward_limit":0}`.

```json
{"status":"ok",
 "meta":{"tool":"characteristic_trend","schema_version":"1.0","scope":["B"],"truncated":false,
         "row_count":5,"total_matches":5},
 "characteristic":{"characteristic_id":"CHR-2001-01","name":"bore_diameter","unit":"mm",
                   "nominal":25.0,"lower_limit":24.98,"upper_limit":25.02},
 "lots":[{"lot_id":"LOT-20250512-01","produced_on":"2025-05-12","count":3,"mean":25.001,
          "min":24.998,"max":25.004,"out_of_tolerance_count":0}],
 "trend":{"direction":"rising","consecutive_lots_toward_limit":4}}
```

The example shows only the first of five lots. Its `min` and `max` are illustrative.

### Trend indicator

`direction` is `rising` when the last lot mean is higher than the previous one, `falling` when it is lower, and `flat` when the two are equal or fewer than two lots exist.

`consecutive_lots_toward_limit` counts only same-direction mean changes. It counts the consecutive lot-to-lot changes, backward from the last lot, that have the same direction as `direction`, and it is 0 when `direction` is `flat`. Despite the name, it does not test how close a mean is to a tolerance limit. A count of 4 means the mean rose four lots in a row. It does not mean the mean is near the upper limit. Read `out_of_tolerance_count` and the limits for that.

## 4. Decision and status

`status` describes the outcome. `decision` is the authorization verdict and appears in the audit event. The decision rule is the same for every tool.

| Allowed lines | `line` filter | Decision | Effective scope |
|---|---|---|---|
| none | any | `forbidden` | `[]` |
| any | outside the allowed lines | `forbidden` | `[]` |
| any | inside the allowed lines | `allowed` | the filter line |
| A and B | none | `allowed` | A, B |
| one line | none | `restricted` | the allowed line |

The line restriction is applied twice: in Python, and as a bound `line_id = ANY(...)` predicate in every SQL statement.

| `status` | `decision` | When | Data |
|---|---|---|---|
| `ok` | `allowed` or `restricted` | Authorization passed and the query ran. | Yes, within the scope |
| `not_found` | `allowed` or `restricted` | Authorization passed, but the ID, part, or characteristic does not exist. | No |
| `forbidden` | `forbidden` | The user has no lines, the `line` filter is outside the allowed lines, or an ID lookup hit a record on a line outside them. | No |
| `invalid_request` | `null` | Argument validation failed before authorization ran. | No |
| `error` | The decision if already computed, otherwise `null` | Timeout, unreachable database, secret failure, or unexpected exception. | No |

The order of checks is validate, authorize, query. A request that is both invalid and unauthorized returns `invalid_request`, which reveals nothing about the data.

Reason strings are fixed text. They never contain an ID, count, or value read from a record.

| Status | Reason |
|---|---|
| `forbidden`, denied line filter | `Access to line <X> is not permitted for this user.` (`<X>` is the validated request value) |
| `forbidden`, user with no lines | `This user has no access to any inspection line.` |
| `forbidden`, ID lookup | `Access to this record is not permitted for this user.` |
| `not_found` | `No report with this report_id.`, `No lot with this lot_id.`, `Unknown part_number.`, or `Unknown characteristic for this part.` |
| `invalid_request` | Names the parameter and lists allowed values, for example `status must be one of: draft, submitted, closed.` or `date_from must not be later than date_to.` |
| `error` | `The request could not be completed. Try again later.` |

An `error` result never contains a host name, secret value, SQL text, or driver message. The operator log `inspection_core.errors` records only the exception class name and the SQLSTATE.

## 5. `forbidden` versus `not_found`

When a user asks for a report or lot ID on a line they may not read, a tool can answer `forbidden` ("it exists, you may not see it") or `not_found` ("no such record").

| | `forbidden` | `not_found` |
|---|---|---|
| Leaks record existence | Yes. A caller can probe IDs and learn which exist on the denied line. | No. Denied and missing look the same. |
| Honest to the user | Yes. The user learns where the access boundary is. | No. The user may conclude the data is missing. |
| Demo question 4 | Shows an explicit denial. | Shows "not found", which does not demonstrate the permission model. |
| Debugging | Clear in the audit log and the UI. | The audit log is needed to tell the cases apart. |

This demo returns `forbidden`. Demo question 4 (ask for data from the other line and get a denial) exists to show the Line B inspector an explicit denial, so the audience sees that the boundary is enforced and not that the data is absent.

The leak is limited and accepted. The result reveals only that the ID exists. Every denied record gets the same fields and the same reason, with no report count, line, part, value, or note. IDs here are guessable by design (`IR-2025-0031`) and the data is synthetic. A user with no allowed line gets `forbidden` for every ID, existing or not, so that case leaks nothing.

A production system with sensitive IDs should return `not_found` for denied IDs and keep the real cause in the audit event. In the code that is one return statement in each lookup plus the reason text, because the audit event already records the true decision.

## 6. Audit event

Every tool call emits exactly one audit event, whatever the status. The event is one JSON object on one line, written through the Python logger `inspection_core.audit` at `INFO` level. When a recording OpenTelemetry span is active, the same fields are also set as span attributes with the prefix `inspection.` (for example `inspection.decision`). A failure to set span attributes never blocks the log line or the tool result.

| Field | Content |
|---|---|
| `tool` | Tool name |
| `parameters` | The parameters as the caller supplied them. Each string is cut to 200 characters. Never contains notes text. |
| `user_id` | The Cognito `sub` claim |
| `groups` | The user's group names |
| `decision` | `allowed`, `restricted`, `forbidden`, or `null` (for example after `invalid_request`) |
| `effective_lines` | The lines the call queried. Empty when denied. |
| `row_count` | Rows or entries returned |
| `report_ids` | IDs of the returned reports, at most 20. Empty for `characteristic_trend`. |
| `duration_ms` | Elapsed time of the call in milliseconds |
| `status` | The result status |

On the span, `parameters` is a JSON string, list fields are lists of strings, and a `null` decision is the string `none`. Result data never enters the event, so notes text cannot reach it.

## 7. Manual verification

This project has no automated tests. Verify each rule by hand against the deployed runtime, using the persona tokens from [auth.md](auth.md).

The verification table is in the design of the spec `07-inspection-tools-authorization`, section "Manual Verification" (`.kiro/specs/07-inspection-tools-authorization/design.md`). It lists 50 numbered rows in six groups. Each row gives the persona or check, the tool, the parameters, and the expected result. The groups are:

- Persona by tool (rows 1 to 13): each persona against the four tools, including the S1 trend (`DEMO-HOUSING-2001`, `bore_diameter`) from [data/STORIES.md](../data/STORIES.md).
- Denial and scope (rows 14 to 21): the Line B inspector denied on line A for `list_reports`, `get_report`, and `get_lot`, the `not_found` comparison, a user with no group, and the check that the tool schema has no identity parameter.
- Not found and invalid input (rows 22 to 26), and the row cap and `limit` clamp (rows 27 to 30).
- SQL injection (rows 31 to 40): `' OR '1'='1`, `'; DROP TABLE inspection_reports; --`, and a value with `%` and `_` in each string parameter.
- No write possible (rows 41 to 44), including a write attempt as `agent_ro` from the VPC session in [database.md](database.md).
- Audit and trace (rows 45 to 50): one audit line and one set of `inspection.` span attributes per call, and no notes text in the line (call `get_report` on `IR-2025-0024` and read the log).

For each call, check that the audit log has exactly one line. Record the observed result and the date in the design table.
