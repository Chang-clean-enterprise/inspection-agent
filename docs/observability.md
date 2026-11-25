# Observability and audit evidence

How to find the trace for a request, read it, and answer an auditor's question from it. Everything
here was verified by hand against the deployed demo (spec `11-observability`).

Placeholders used throughout: `<account-id>`, `<agent-id>` (the AgentCore runtime ID, which looks like
`inspection_agent_demo-XXXXXXXXXX`), `<sub>` (a Cognito user ID), `<trace-id>`.

## 1. What is instrumented, and what is deliberately not

The agent runs under `opentelemetry-instrument` with the AWS Distro for OpenTelemetry. Every request
produces a trace: the model calls and each tool call appear as spans, and each tool span carries the
full audit record (who asked, which tool, which parameters, which authorization decision, how many
rows, which report IDs).

**Model prompts, model answers and tool payloads are stripped before anything leaves the agent
process.** They are replaced with `REDACTED`. This is deliberate. The inspection data includes
free-text inspector notes, and the agent quotes them back in its answers, so keeping prompts or
answers would put notes text into CloudWatch. Two settings enforce it, both in `infra/runtime.yaml`:

| Setting | What it stops |
|---|---|
| `AWS_REDACT_SPAN_ATTRIBUTES` | Content on span attributes, span events and span links. Includes `tool.result`, where Strands puts the raw tool output. |
| `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false` | Content in the OTLP **log records** the botocore bedrock-runtime instrumentation emits. Span redaction cannot reach these; they are not spans. |

Both are template literals rather than CloudFormation parameters, on purpose. `aws cloudformation
deploy` reuses an existing stack's stored value for any parameter it is not explicitly passed, so a
parameter default can silently go stale on an existing stack. That happened once during development
and the redaction was quietly not applied. To narrow redaction, edit the template.

So the trace answers **who did what to which data under which decision**. It does not show the
conversation. The audit evidence does not need the conversation.

## 2. One-time setup

Two account-level steps, both already done for the demo account. Neither is in CloudFormation:
Transaction Search is an account-wide singleton, and a stack deletion must not switch it off for
every other workload.

**Enable CloudWatch Transaction Search.** Without it no span is viewable at all.

```
aws logs put-resource-policy --region us-west-2 \
  --policy-name TransactionSearchXRayAccess \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"TransactionSearchXRayAccess","Effect":"Allow","Principal":{"Service":"xray.amazonaws.com"},"Action":"logs:PutLogEvents","Resource":["arn:aws:logs:us-west-2:<account-id>:log-group:aws/spans:*","arn:aws:logs:us-west-2:<account-id>:log-group:/aws/application-signals/data:*"],"Condition":{"ArnLike":{"aws:SourceArn":"arn:aws:xray:us-west-2:<account-id>:*"},"StringEquals":{"aws:SourceAccount":"<account-id>"}}}]}'

aws xray update-trace-segment-destination --region us-west-2 --destination CloudWatchLogs
```

Or in the console: **CloudWatch → Application Signals (APM) → Transaction search → Enable Transaction
Search**, tick *ingest spans as structured logs*, Save.

Confirm with `aws xray get-trace-segment-destination --region us-west-2`. Expect `Destination:
CloudWatchLogs`, `Status: ACTIVE`. **It takes three to four minutes to go from `PENDING` to
`ACTIVE`.** Do not start a demo in that window.

**Raise the trace indexing percentage.** The default is **1 percent**, which is not enough to demo.

```
aws xray update-indexing-rule --region us-west-2 --name Default \
  --rule '{"Probabilistic":{"DesiredSamplingPercentage":100}}'
```

All spans reach CloudWatch Logs either way, so a trace can always be opened by its ID. But only the
indexed percentage becomes a searchable trace *summary*, and summaries are what the Transaction
Search UI lists and filters. At 1 percent a five-question demo will show you nothing. 100 percent is
fine at demo volume; it would not be a sensible production default.

`scripts/deploy.sh` refuses to deploy the observability stack when Transaction Search is off, and
prints these commands.

## 3. Finding the trace for a request

**The reliable way: the invoke response returns the trace ID.**

```json
{"answer": "...", "actions": [...], "session_id": "...", "trace_id": "6b0665df5727caee74c981c92c32accb"}
```

The CloudWatch trace view searches on the **X-Ray form** of that ID, not the raw hex. The conversion
is `1-` + the first 8 hex digits + `-` + the remaining 24:

```
6b0665df5727caee74c981c92c32accb  ->  1-6b0665df-5727caee74c981c92c32accb
```

`src/inspection_agent/tracing.py` exposes `xray_trace_id()` for this, and it lowercases, so an ID
pasted from a console works too.

**By session.** Every span carries `session.id`, and the agent's own spans also carry
`inspection.session_id`. Filter on either in the trace view.

**In the logs.** Everything for this agent lands in one log group:

```
/aws/bedrock-agentcore/runtimes/<agent-id>-DEFAULT
```

| Stream | Holds |
|---|---|
| `spans` | the trace, one JSON span per record |
| `runtime-logs-<session-id>...` | the container's stdout, including the audit JSON lines |
| `otel-rt-logs` | the OTLP copy of the logs |

Retention is 7 days, applied by `scripts/deploy.sh` from the `LogRetentionDays` parameter of the
observability stack. AgentCore owns this log group and its name embeds a generated agent ID, which is
why no CloudFormation resource creates it.

## 4. What each span means

A single question produces roughly this, in one trace:

| Span | Meaning |
|---|---|
| `POST /invocations` | The whole request. This is the top span. |
| `invoke_agent Strands Agents` | The agent run. Carries `inspection.prompt_version`, `inspection.model_id`, `inspection.session_id`, `inspection.memory.*`. |
| `execute_event_loop_cycle` | One reason-and-act cycle. There is one per model turn. |
| `chat` / `chat <model-id>` | One model call. Carries `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`. |
| `execute_tool <name>` | **One tool call. This is the audit span.** |
| `Bedrock AgentCore.RetrieveMemoryRecords` | Long-term memory read, at the start of a session. |
| `Bedrock AgentCore.CreateEvent` | The turn being written to memory, at the end. |
| `Secrets Manager.GetSecretValue` | The database credential fetch on a cold container. |

Two things that surprise people, neither of them a fault:

- The top span is `POST /invocations`, not `AgentCore.Runtime.Invoke`. The service-side span is not
  delivered into this log group.
- The agent span is named `invoke_agent Strands Agents`, because the Strands `Agent` is built without
  an explicit name. The *service* is still labelled correctly: `service.name` is
  `inspection-agent-demo`, set by `OTEL_SERVICE_NAME`.

## 5. The audit attributes on a tool span

Every `execute_tool` span carries these. The same values are on one JSON line in the
`runtime-logs` stream, so a span and a log line can always be matched up.

| Span attribute | Audit log field | Meaning |
|---|---|---|
| `inspection.tool` | `tool` | Tool name |
| `inspection.user_id` | `user_id` | Cognito `sub` of the caller, from the verified token |
| `inspection.actor_id` | `actor_id` | AgentCore Memory actor ID (same value as `user_id`) |
| `inspection.groups` | `groups` | The caller's Cognito groups |
| `inspection.decision` | `decision` | `allowed`, `restricted`, or `forbidden` |
| `inspection.effective_lines` | `effective_lines` | Lines the call was scoped to. Empty when forbidden. |
| `inspection.parameters` | `parameters` | The caller's arguments, strings cut to 200 characters. Never notes text. |
| `inspection.row_count` | `row_count` | Rows returned |
| `inspection.report_ids` | `report_ids` | Report IDs returned, at most 20 |
| `inspection.status` | `status` | `ok`, `forbidden`, `not_found`, `invalid_request`, `error` |
| `inspection.duration_ms` | `duration_ms` | Call duration |
| `inspection.session_id` | `session_id` | The session |
| `inspection.trace_id` / `inspection.span_id` | `trace_id` / `span_id` | Correlation |

`decision` is the one to point at. `restricted` means the caller was authorized but scoped to a
subset of lines; `forbidden` means the call was refused. The decision is taken in code, in
`src/inspection_core/authorizer.py`, from the verified identity. It is never taken by the model.

## 6. The saved queries

Three, in **CloudWatch → Logs Insights → Queries**, under `inspection-agent/demo/`. Each is scoped to
the runtime log group. Replace the placeholder in the query text before running.

| Query | Answers | Replace |
|---|---|---|
| `actions-by-user` | Everything one user did | `REPLACE_WITH_COGNITO_SUB` |
| `forbidden-decisions` | Every refused call. Set the time range to the last hour. | nothing |
| `lot-access` | Every access to one lot, by any user, allowed or not | `REPLACE_LOT_ID` |

Each query extracts its fields with `parse` rather than relying on automatic field discovery. That is
necessary: ADOT installs a logging formatter, so the audit line is prefixed and is no longer a bare
JSON object, and discovery finds nothing. Parsing also keeps older pre-instrumentation lines
readable, which carry every field except `session_id`, `actor_id`, `trace_id` and `span_id`.

To find a persona's `sub`:

```
aws cognito-idp admin-get-user --region us-west-2 \
  --user-pool-id "$(aws ssm get-parameter --region us-west-2 --name /inspection-agent/demo/auth/user-pool-id --query Parameter.Value --output text)" \
  --username <email> --query 'UserAttributes[?Name==`sub`].Value' --output text
```

## 7. Auditor walkthrough

> **"Who accessed lot LOT-20250604-01, when, and was it allowed?"**

You need nothing but the saved queries and the trace view.

1. Open **CloudWatch → Logs Insights**. Load the saved query `inspection-agent/demo/lot-access`.
2. Replace both occurrences of `REPLACE_LOT_ID` with `LOT-20250604-01`. Set the time range to cover
   the period in question. Run.
3. Read the result. One row per access, newest first:

   | @timestamp | tool | decision | user_id | groups | effective_lines | row_count |
   |---|---|---|---|---|---|---|
   | 2026-11-25 04:46:31 | `get_lot` | **forbidden** | `<sub of the line B inspector>` | `line-b` | *(empty)* | 0 |
   | 2026-11-25 04:46:15 | `get_lot` | allowed | `<sub of the supervisor>` | `supervisors` | `A`, `B` | 5 |

   That is the answer. Two people touched the lot. The supervisor was allowed and received 5 rows.
   The line B inspector was refused, received nothing, and the empty `effective_lines` shows the
   refusal was total rather than a narrowing.

4. To put a name to a `user_id`, resolve the `sub` with the Cognito command in section 6.
5. To show the evidence rather than assert it, copy the `trace_id` from the row, convert it to the
   X-Ray form (section 3), and open it in the trace view. Expand the `execute_tool get_lot` span. The
   attributes repeat the same decision, independently of the log line.

Why this holds up: the lot is on line A, the line B inspector is only entitled to line B, and the
refusal was decided in `src/inspection_core/authorizer.py` from the verified JWT, before any query
ran. The tool returns a fixed denial message with no row count, no IDs and no values, so nothing
leaked. The span and the log line are two independent records of the same decision, sharing a trace
ID.

## 8. The dashboard

**CloudWatch → Dashboards → `inspection-agent-demo`.**

| Widget | Source | Read it as |
|---|---|---|
| Invocations | `AWS/Bedrock-AgentCore` | Requests to the runtime |
| Errors | `SystemErrors`, `UserErrors`, `Throttles` | Should be flat zero during a demo |
| Latency p50 / p95 | `Latency` | About **8 s** p50 and **10.5 s** p95 per question in this demo. Pace accordingly. |
| Sessions | `Sessions` | New sessions created |
| Tool calls by decision | `inspection-agent` namespace | Three series: allowed, restricted, forbidden |
| Token usage | `AWS/Bedrock` by `ModelId` | **Account-wide for that model, not just this agent.** |

The token widget's caveat is on the dashboard itself. For a true per-request figure use
`gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens` on the `chat` span of a trace.

The decision series come from three CloudWatch Logs metric filters over the audit line, one per
decision, rather than from one metric with a `Decision` dimension. CloudWatch does not allow
dimensions on a substring filter pattern, and a JSON pattern is not usable because the log line is
prefixed. Only demo question 1 produces `restricted`, so run it if you want all three series
populated.

## 9. Five minutes before the demo

1. `aws xray get-trace-segment-destination --region us-west-2` → `CloudWatchLogs` / `ACTIVE`.
   If it is not, enabling it takes three to four minutes.
2. `aws xray get-indexing-rules --region us-west-2` → `DesiredSamplingPercentage: 100`.
3. Run one throwaway question with `scripts/invoke.sh --persona supervisor`. Confirm HTTP 200 and a
   **non-empty `trace_id`** in the response. An empty `trace_id` means the agent is not instrumented
   and the whole trace part of the demo is dead.
4. Open that trace and confirm the `execute_tool` span is there with `inspection.decision` on it.
5. Open the dashboard and confirm the widgets have recent data.
6. Load all three saved queries once, so they are in the recent list and you are not hunting during
   the demo.
7. **Privacy check.** In Logs Insights over the runtime log group, run:

   ```
   fields @timestamp, @message
   | filter @message like 'Journal oversize' or @message like 'Hole looks off' or @message like 'Bearer ' or @message like 'eyJ'
   | limit 20
   ```

   Expect **zero rows**. Those are note fragments from `data/STORIES.md` and JWT signatures. Then
   confirm the redaction is actually on, rather than the data simply being absent:

   ```
   fields @timestamp, @message | filter @message like 'REDACTED' | limit 20
   ```

   Expect rows. Zero rows here, with traffic in the window, means redaction is not running and step
   7's clean result proves nothing.

## 10. Known gaps

- The service-side `AgentCore.Runtime.Invoke` span is not delivered to the agent's log group, so the
  top span in the trace is the container's `POST /invocations`.
- The agent span is named `invoke_agent Strands Agents` rather than after this project.
- The token widget is account-wide per model. There is no per-agent token metric.
- The `report_ids` cap of 20 was not exercised against a query returning more than 20 reports; the
  cap is unchanged code from spec 07.
- Tool calls by decision uses three metric names instead of one dimensioned metric, for the
  CloudWatch reason in section 8.
- Redaction is all-or-nothing per attribute key. There is no way to keep the user's prompt while
  dropping notes text, because the agent's own answer quotes the notes.

## 11. Teardown

`make delete-observability` removes the dashboard, the three metric filters and the three saved
queries. It does **not** disable Transaction Search, change the indexing percentage, or delete the
runtime log group, all of which are outside the stack on purpose. Log retention stays at whatever was
last applied.

## See also

- [inspection-tools.md](inspection-tools.md) section 6, the audit event and its fields.
- [runtime.md](runtime.md), the runtime stack and how to update the code package.
- [memory.md](memory.md), the memory spans and the extraction delay.
