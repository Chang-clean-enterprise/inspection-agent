# Design Document

## Overview

GitHub issue: #11

This design makes every agent action observable end to end. A presenter opens one trace and shows who
asked, what the agent did, which tools it called, which data came back (by ID), and which authorization
decision was taken. An auditor answers "who accessed lot X, when, and was it allowed?" from saved
queries alone.

The agent already carries most of the audit payload. `src/inspection_core/audit.py` writes one JSON line
per tool call and sets `inspection.<field>` span attributes, and `src/inspection_agent/entrypoint.py`
sets `inspection.prompt_version`, `inspection.model_id` and `inspection.memory.*`. **None of it reaches
CloudWatch today.** The code package ships `opentelemetry-api` with no SDK and no ADOT distro, so
`trace.get_current_span()` always returns the non-recording default span, `is_recording()` is false, and
every `set_attribute` call is dropped. CloudWatch Transaction Search is also off in the account, so no
span would be viewable even if one were exported. This spec closes both gaps and then builds the
dashboard, the saved queries and the runbook on top.

Deliverables:

| File | Change |
|---|---|
| `infra/observability.yaml` | New. Dashboard, three metric filters, three Logs Insights saved queries. |
| `infra/runtime.yaml` | Changed. `EntryPoint` gains `opentelemetry-instrument`; four OTEL environment variables; one new parameter. |
| `src/inspection_agent/requirements.txt` | Changed (small). Adds `aws-opentelemetry-distro>=0.18.0`. |
| `src/inspection_core/requirements.txt` | Changed (small), only if the distro conflicts with the `opentelemetry-api` pin. |
| `src/inspection_core/audit.py` | Changed. Four new event fields and a request-context setter. |
| `src/inspection_agent/tracing.py` | New, small. Current trace and span IDs, and the X-Ray trace-ID form. |
| `src/inspection_agent/entrypoint.py` | Changed. Sets and clears the audit request context; returns `trace_id`. |
| `scripts/deploy.sh` | Changed. Transaction Search preflight and observability parameters. |
| `docs/observability.md` | New. The runbook. |
| `docs/README.md` | Changed (small). Index entry. |

Out of scope: CloudWatch Omni (issue #15) and the UI (issue #12).

`Makefile` needs no change: the `deploy-%` and `delete-%` pattern rules already cover
`make deploy-observability`. `scripts/deploy.sh` already lists `observability` in `COMPONENTS` and
already has `step 10 observability` in `deploy_all`. `scripts/teardown.sh` already lists it.

### Key decisions

| # | Decision | Reason |
|---|---|---|
| 1 | **All model and tool content is stripped from telemetry**, with `AWS_REDACT_SPAN_ATTRIBUTES`. | Agreed with the user. Our tool results carry inspector notes text, and the agent's own answer to demo question 3 quotes the note for `LOT-20250528-01` back to the user. Keeping prompts or answers would therefore put notes text in CloudWatch and break the acceptance criterion "THE telemetry SHALL NOT contain JWTs, passwords, or notes text". Capture-time redaction is the only layer where the data never leaves the process. The trace keeps span names, timings, token counts and every `inspection.*` attribute, which is what the auditor walkthrough actually reads. |
| 2 | **Transaction Search is not a CloudFormation resource.** It is enabled once by hand and guarded by a `deploy.sh` preflight. | `AWS::XRay::TransactionSearchConfig` exists, but Transaction Search is an account-level singleton. A stack that owns it would disable it for every workload in the account on `make delete-observability` or `make teardown`. The issue's own acceptance criterion asks for the deploy-script gate, not for the resource. |
| 3 | Unified telemetry: `UNIFIED_TRACES_DESTINATION_ENABLED=true`. | Spans land in the agent's own log group next to its logs, instead of the shared `aws/spans`. One log group for the saved queries, the metric filters and the runbook. Requires ADOT >= 0.18.0, which decision 4 pins. |
| 4 | `aws-opentelemetry-distro>=0.18.0` plus `EntryPoint: [opentelemetry-instrument, main.py]`. | This is the documented instrumentation path for a code-deployed (S3 zip) Python runtime. There is no container and no `CMD` to change. See the Research record. |
| 5 | `session_id` and `actor_id` reach `inspection_core.audit` through a `contextvars.ContextVar`, set by the entrypoint. | Keeps `inspection_core` free of any `inspection_agent` import, and keeps the identity out of the tool signatures the model can reach. The non-negotiable rule stands: the model never supplies the user identity. |
| 6 | **Log retention is applied by `deploy.sh`, not by an `AWS::Logs::LogGroup` resource.** | AgentCore creates the runtime log group itself, and its name embeds a service-generated agent ID (`/aws/bedrock-agentcore/runtimes/inspection_agent_demo-<agentId>-DEFAULT`). Three such groups already exist in the account from earlier runtime versions. A CloudFormation log group would fail with `AlreadyExists` and would contend with the service for ownership. `LogRetentionDays` stays a template parameter so the value has one home, and the deploy step applies it with `aws logs put-retention-policy`. This is a deliberate deviation from "all infrastructure in CloudFormation"; the reason is recorded here. |
| 7 | Tool-calls-by-decision comes from **Logs metric filters on the audit line**, not from a new custom metric emitted by the agent. | The audit line already exists and already carries `decision`. Emitting a CloudWatch metric from the agent would add a `cloudwatch:PutMetricData` call per tool call, a new namespace to the execution role, and a failure path inside a read-only agent. A metric filter is free and cannot fail the request. |
| 8 | No new script in `scripts/`. The preflight lives inside `scripts/deploy.sh`. | `.claude/rules/scripts.md` allows exactly ten Operational_Scripts and none of them is an observability script. The acceptance criterion names the deploy script anyway. |

## Research record

Pages read on 2026-11-25. Live read-only probes run against account `<account-id>` in `us-west-2` on the
same day.

| Topic | Finding | Source |
|---|---|---|
| **Instrumenting a code-deployed runtime** | For a .zip package, the entry point becomes an array: `entryPoint: ["opentelemetry-instrument", "main.py"]`, with the ADOT distro present in the package. For containers it is `CMD ["opentelemetry-instrument", "python", "main.py"]`. Omitting the distro while keeping the prefix fails creation with "OpenTelemetry instrumentation executable not found". | [Direct code deployment for Python](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-code-deploy-python.html), [Troubleshooting direct code deployment](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-code-deploy-common-issues.html) |
| CloudFormation shape | `AWS::BedrockAgentCore::Runtime` -> `AgentRuntimeArtifact.CodeConfiguration.EntryPoint` is `List<String>`. `infra/runtime.yaml` already writes it in list form, so the change is one added list item. | [CodeConfiguration](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-bedrockagentcore-runtime-codeconfiguration.html) |
| Dependencies | `aws-opentelemetry-distro>=0.18.0` and `boto3`. Nothing else. | [Add observability to your AgentCore resources](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html) |
| Strands needs no instrumentation library | The Strands SDK has built-in telemetry under scope `strands.telemetry.tracer`. On AgentCore Runtime with ADOT, the Runtime injects `session.id` and exports spans automatically. Spans are classified by `gen_ai.operation.name`: `invoke_agent`, `chat`, `execute_tool`. | [Set up Strands Agents telemetry](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks-strands.html) |
| Transaction Search | One-time, account-level. Two steps: a CloudWatch Logs resource policy letting `xray.amazonaws.com` call `logs:PutLogEvents` on `aws/spans` and `/aws/application-signals/data`, then `aws xray update-trace-segment-destination --destination CloudWatchLogs`. Optional `update-indexing-rule` sets the indexed percentage. | [Enabling CloudWatch Transaction Search](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html) |
| **Transaction Search is off here** | `aws xray get-trace-segment-destination` returns `Destination: XRay`, `Status: ACTIVE`. The `aws/spans` log group does not exist. So no span is viewable today, and the preflight of decision 2 will fire until it is enabled. | Live probe, 2026-11-25 |
| Span destination | With `UNIFIED_TRACES_DESTINATION_ENABLED=true` and ADOT >= 0.18.0, spans go to the `spans` log stream of `/aws/bedrock-agentcore/runtimes/<agent_id>-<endpoint_name>`. Requires `logs:PutResourcePolicy` on that group for the execution role. **Already granted**: the `LogGroup` statement in `infra/pre-runtime.yaml` holds `logs:CreateLogGroup`, `logs:DescribeLogStreams` and `logs:PutResourcePolicy` on `/aws/bedrock-agentcore/runtimes/inspection_agent_<Env>-*`. No IAM change is needed. | [Span destination](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html), repository |
| Service-provided span | AgentCore emits `AgentCore.Runtime.Invoke` (operation `InvokeAgentRuntime`) as the first span of every trace, with `session.id`, `latency_ms`, `error_type`, `aws.agent.id`, `aws.request_id`. Filtering on it returns complete traces. | [AgentCore generated runtime observability data](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-runtime-metrics.html) |
| Resource attributes | `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` are merged with the attributes AgentCore sets. Merge behaviour takes effect 2026-11-16, so it is live. `cloud.provider` cannot be overridden. Keep the merged value under 4096 bytes. Do not put secrets in either. | [Add custom resource attributes](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html) |
| **Redaction** | `AWS_REDACT_SPAN_ATTRIBUTES` takes a comma-separated list of attribute keys. Matching values in **span attributes, span events and span links** are replaced with `REDACTED`, in process, before export. Wildcards are supported. It applies to all span attributes, not only ADOT's. | [Protect sensitive data](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/omni-data-protection.html) |
| Where the content sits | Unified mode keeps content in inline span events: `gen_ai.user.message` with attribute `content`, `gen_ai.choice` with attribute `message`, `gen_ai.tool.message` with attribute `content`. Split mode moves it to separate event records with attributes `gen_ai.input.messages` / `gen_ai.output.messages`. The redact list must cover both shapes. | [Telemetry setup and delivery](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks-telemetry.html), [Strands example spans](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks-strands.html) |
| `AWS_GENAI_CONTENT_EXTRACTION_OPT_OUT` | Documented only as "Keeps model payloads and tool request/response data on spans. Requires ADOT >=0.18.0", which reads against the variable's name. **Not used.** The design relies on `AWS_REDACT_SPAN_ATTRIBUTES`, whose semantics are unambiguous, and task 6.4 verifies the result empirically rather than trusting either variable. | [Enabling observability](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html) |
| **Metric dimensions** | Namespace `AWS/Bedrock-AgentCore`, dimension set `{Name, Operation, Resource}` with `Name=inspection_agent_<env>::DEFAULT`, `Operation=InvokeAgentRuntime`, `Resource=<runtime ARN>`. Metrics present: `Invocations`, `Latency`, `SystemErrors`, `UserErrors`, `Throttles`, `Sessions`. A wider set `{ComputeType, Name, Operation, Resource}` also exists; the three-dimension set is the stable one to chart. | Live `cloudwatch:ListMetrics`, 2026-11-25 |
| Token metrics | `AWS/Bedrock` publishes `InputTokenCount`, `OutputTokenCount`, `InvocationLatency`, `TimeToFirstToken` with dimension `ModelId` (observed values include `us.anthropic.claude-haiku-4-5-20251001-v1:0`). These are **account-wide per model**, not per agent, so they include any other Bedrock traffic in the account. `AWS/Bedrock-AgentCore` `InputTokenUsage` / `OutputTokenUsage` exist but carry `Operation=Extraction|Consolidation`, which is AgentCore Memory's own model usage, not the agent's. | Live `cloudwatch:ListMetrics`, 2026-11-25 |
| **Existing log groups** | Three groups exist: `/aws/bedrock-agentcore/runtimes/inspection_agent_demo-<agentId>-DEFAULT, one per runtime version`, none with a retention policy. Only one matches the current runtime ID. This is what rules out an `AWS::Logs::LogGroup` resource (decision 6) and means the stale two should be removed by hand. | Live `logs:DescribeLogGroups`, 2026-11-25 |
| Audit event today | `AuditEvent` in `src/inspection_core/audit.py` holds `tool`, `parameters` (every string cut to 200 chars), `user_id`, `groups`, `decision`, `effective_lines`, `row_count`, `report_ids` (capped at `MAX_REPORT_IDS = 20`), `duration_ms`, `status`. `emit` writes the JSON line first and sets span attributes second, each in its own `try`, so neither can fail a tool call. | Repository |

## Architecture

```
scripts/deploy.sh observability
   require_transaction_search()  -- xray get-trace-segment-destination
        |  not CloudWatchLogs -> die with the exact enable commands
        v
   deploy infra/observability.yaml     then  logs put-retention-policy

invoke (Bearer token)
        |
        v
AgentCore Runtime
   ADOT auto-instrumentation  (entry point: opentelemetry-instrument main.py)
   emits span  AgentCore.Runtime.Invoke     <- trace starts here, carries session.id
        |
        v
entrypoint.handler
   principal_from_headers(...)            -> Principal (user_id = Cognito sub)
   audit.set_request_context(session_id, actor_id)
        |
        v
   Strands Agent
     span  invoke_agent inspection-agent
     span  chat                            <- model call, gen_ai.usage.*
     span  execute_tool <name>             <- one per tool call
        |
        |   inspection_core.tools._run
        |     authorizer.decide(...)       -> allowed | restricted | forbidden
        |     audit.emit(event)
        |        JSON line  -> stdout -> runtime log group
        |        inspection.* attributes   -> the execute_tool span
        v
   {"answer": ..., "actions": [...], "session_id": ..., "trace_id": ...}

AWS_REDACT_SPAN_ATTRIBUTES replaces every content attribute with REDACTED
before any span leaves the process.

        |                                  |
        v                                  v
/aws/bedrock-agentcore/runtimes/<agentId>-DEFAULT
   stream  spans         <- the trace
   stream  runtime-logs  <- the audit JSON lines
        |
        |-- 3 metric filters -> inspection-agent / ToolCallsByDecision{Decision}
        |-- 3 saved queries
        +-- dashboard
```

## Components and Interfaces

### 1. `infra/runtime.yaml`

Entry point:

```yaml
      AgentRuntimeArtifact:
        CodeConfiguration:
          Runtime: PYTHON_3_12
          EntryPoint:
            - opentelemetry-instrument
            - main.py
```

New parameter:

```yaml
  RedactSpanAttributes:
    Type: String
    Description: >-
      Comma-separated OpenTelemetry attribute keys whose values are replaced with REDACTED in span
      attributes, span events and span links before export. Keeps model prompts, model answers and
      tool payloads, which carry inspector notes text, out of CloudWatch.
    Default: gen_ai.input.messages,gen_ai.output.messages,gen_ai.prompt,gen_ai.completion,content,message
    AllowedPattern: ^[A-Za-z0-9_.*-]+(,[A-Za-z0-9_.*-]+)*$
    MaxLength: 512
```

New environment variables, added to the existing `EnvironmentVariables` map:

| Variable | Value | Purpose |
|---|---|---|
| `UNIFIED_TRACES_DESTINATION_ENABLED` | `"true"` | Spans into the agent's own log group. |
| `OTEL_SERVICE_NAME` | `!Sub inspection-agent-${Env}` | Stable service name on every span. |
| `OTEL_RESOURCE_ATTRIBUTES` | `!Sub deployment.environment.name=${Env}` | Filterable, lands on `AgentCore.Runtime.Invoke`. |
| `AWS_REDACT_SPAN_ATTRIBUTES` | `!Ref RedactSpanAttributes` | Decision 1. |

The redact list covers both delivery modes: `content` and `message` are the inline event attributes of
unified mode (`gen_ai.user.message`, `gen_ai.choice`, `gen_ai.tool.message`), and
`gen_ai.input.messages` / `gen_ai.output.messages` are the split-mode attribute names. `content` and
`message` are deliberately broad; task 6.4 confirms by hand that nothing needed was lost.

`gen_ai.system_instructions` is **not** redacted. The system prompt is in the repository, holds no
secret, and seeing it in the trace helps explain the agent's behaviour during the demo.

### 2. Dependencies

`src/inspection_agent/requirements.txt` gains `aws-opentelemetry-distro>=0.18.0`. This is the one
unpinned dependency in the repository; the floor is required by the unified span destination and by
`AWS_REDACT_SPAN_ATTRIBUTES`. The resolved version is recorded in the task note so the build stays
reproducible in practice.

`src/inspection_core/requirements.txt` pins `opentelemetry-api==1.41.1`. The distro brings
`opentelemetry-sdk` and its own `opentelemetry-api` range. If `uv` reports a conflict, relax the core
pin to the version the distro resolves and record both in the task note. The redaction processor
documented by AWS needs `opentelemetry-sdk >= 1.39.0`, which the distro satisfies.

The package must stay inside the limits already enforced by `scripts/package-agent.sh`: 250 MB zipped,
750 MB unzipped. The last build was 35 MB / 81 MB, so there is room.

### 3. `src/inspection_core/audit.py`

`AuditEvent` gains four fields:

```python
    session_id: str
    actor_id: str
    trace_id: str
    span_id: str
```

A module-level request context supplies the first two:

```python
_REQUEST_CONTEXT: ContextVar[tuple[str, str]] = ContextVar("inspection_audit_request", default=("", ""))

def set_request_context(*, session_id: str = "", actor_id: str = "") -> Token: ...
def reset_request_context(token: Token) -> None: ...
```

A `ContextVar` is correct here rather than a module global: `SequentialToolExecutor` still runs inside
whatever thread Strands uses, and `SessionRegistry` serialises per session but not per process.

`trace_id` and `span_id` are read inside `emit` from
`_otel_trace.get_current_span().get_span_context()`, formatted as 32 and 16 lowercase hex digits, and set
to `""` when the span is not recording or `_otel_trace` is `None`. The existing optional-import guard and
the two `try` blocks stay exactly as they are: nothing added here may raise, and nothing may change a
Tool_Result.

Because `_set_span_attributes` iterates the prepared event, the four fields also appear as
`inspection.session_id`, `inspection.actor_id`, `inspection.trace_id` and `inspection.span_id` on the
`execute_tool` span. `inspection.trace_id` is redundant on the span and kept anyway: it makes a copied
span and a copied log line self-describing.

`actor_id` is the AgentCore Memory actor ID, which is `Principal.user_id`. It is emitted as its own field
rather than assumed equal to `user_id`, because the issue asks for the memory actor ID when present and
the two are only equal by current convention.

No new field can carry notes text. `parameters` holds caller-supplied arguments only, and the JWT is
decoded and discarded inside `src/inspection_agent/identity.py`.

### 4. `src/inspection_agent/tracing.py`

Small, no dependency beyond `opentelemetry-api`, and tolerant of a missing SDK:

- `current_trace_id() -> str` — 32 hex digits, or `""`.
- `current_span_id() -> str` — 16 hex digits, or `""`.
- `xray_trace_id(hex_trace_id: str) -> str` — `1-` + first 8 hex + `-` + remaining 24 hex, or `""` for
  anything that is not 32 hex digits. This is the form the CloudWatch trace view searches on; the runbook
  shows both.

### 5. `src/inspection_agent/entrypoint.py`

- After the principal and the session ID are resolved, call
  `audit.set_request_context(session_id=session_id, actor_id=principal.user_id)` and reset it in a
  `finally`, so one request cannot leak its context into the next on a reused thread.
- Add `trace_id` to the success payload:
  `{"answer": ..., "actions": [...], "session_id": ..., "trace_id": ...}`.
- The four fixed error payloads are unchanged. They are returned before or outside a recording span in
  several paths, and changing their shape would be a visible API change for a case the runbook handles
  through the log group instead.
- Set `inspection.session_id` on the entrypoint span alongside the existing attributes, so the top-level
  span is filterable by session without opening a tool span.

### 6. `infra/observability.yaml`

Follows all ten rules in `docs/cloudformation-conventions.md`: YAML only, every parameter with a
`Description` and a constraint, `Project` / `Env` tags on every taggable resource, no literal account ID
or Region, cross-stack values read as `AWS::SSM::Parameter::Value<String>`, and zero cfn-lint findings.

Parameters:

| Name | Type | Default | Constraint |
|---|---|---|---|
| `Env` | String | `demo` | `^[a-z][a-z0-9]{0,9}$` |
| `LogRetentionDays` | Number | `7` | `AllowedValues` from the CloudWatch set (1, 3, 5, 7, 14, 30, 60, 90, ...) |
| `RuntimeId` | `AWS::SSM::Parameter::Value<String>` | `/inspection-agent/demo/runtime/runtime-id` | — |
| `RuntimeArn` | `AWS::SSM::Parameter::Value<String>` | `/inspection-agent/demo/runtime/runtime-arn` | — |
| `ModelId` | `AWS::SSM::Parameter::Value<String>` | `/inspection-agent/demo/pre-runtime/model-id` | — |
| `MetricNamespace` | String | `inspection-agent` | `^[A-Za-z0-9_.\-/#:]{1,255}$` |

The log group name is derived, not passed:
`!Sub /aws/bedrock-agentcore/runtimes/${RuntimeId}-DEFAULT`.

`LogRetentionDays` is a parameter but has no resource (decision 6). The template documents in a comment
that `scripts/deploy.sh` applies it, and the stack outputs the resolved log group name and the retention
value so the deploy step reads them back instead of recomputing them.

**Metric filters.** Three `AWS::Logs::MetricFilter` on the runtime log group, one per decision, all
publishing `ToolCallsByDecision` into `MetricNamespace` with a `Decision` dimension:

```yaml
      FilterPattern: '"\"decision\":\"forbidden\""'
      MetricTransformations:
        - MetricNamespace: !Ref MetricNamespace
          MetricName: ToolCallsByDecision
          MetricValue: "1"
          Unit: Count
          Dimensions:
            - Key: Decision
              Value: forbidden
```

A quoted substring pattern, not a JSON selector (`{ $.decision = "forbidden" }`). A JSON selector
requires the whole log event to be valid JSON, and the event may carry a logging prefix or be wrapped by
the OTLP log exporter once ADOT is active. `audit.emit` writes the line with
`separators=(",", ":")`, so `"decision":"forbidden"` has no space and the substring is exact. **Task 5.3
reads a real log line and confirms or corrects these three patterns before the stack is deployed.**

**Saved queries.** Three `AWS::Logs::QueryDefinition`, each named
`inspection-agent/<env>/<name>` and scoped to the runtime log group.

1. `actions-by-user`:

```
fields @timestamp, tool, decision, effective_lines, row_count, report_ids, session_id, trace_id
| filter user_id = 'REPLACE_WITH_COGNITO_SUB'
| sort @timestamp desc
| limit 200
```

2. `forbidden-decisions`:

```
fields @timestamp, user_id, groups, tool, parameters, session_id, trace_id
| filter decision = 'forbidden'
| sort @timestamp desc
| limit 200
```

Run with the time range set to the last hour. The range is a console control, not part of a saved query.

3. `lot-access`:

```
fields @timestamp, user_id, groups, tool, decision, effective_lines, row_count, session_id, trace_id
| filter parameters like /REPLACE_LOT_ID/
| sort @timestamp desc
| limit 200
```

`parameters` catches both ways a lot is reached: `get_lot(lot_id=...)` and `list_reports(lot_id=...)`.
Filtering on `parameters` rather than on a `lot_id` field is deliberate — there is no top-level `lot_id`
in the audit event, and `parameters` is the field that holds whatever the caller asked for.

All three rely on CloudWatch Logs discovering the audit JSON line's fields automatically. Task 5.3
confirms that discovery works against the real line; if the line turns out to be prefixed, each query
gains a `parse` stage and the task note records the change.

**Dashboard.** One `AWS::CloudWatch::Dashboard`, `inspection-agent-<env>`:

| Widget | Source |
|---|---|
| Invocations | `AWS/Bedrock-AgentCore` `Invocations`, Sum, dims `{Name, Operation, Resource}` |
| Errors | `SystemErrors` + `UserErrors` + `Throttles`, Sum, same dims |
| Latency p50 / p95 | `Latency`, `ExtendedStatistic` `p50` and `p95`, same dims |
| Sessions | `Sessions`, Sum, same dims |
| Tool calls by decision | `<MetricNamespace>` `ToolCallsByDecision`, Sum, one series per `Decision` |
| Token usage | `AWS/Bedrock` `InputTokenCount` / `OutputTokenCount`, Sum, dim `ModelId` |
| Caveat text | A `text` widget stating that the token widget is account-wide for that model, not scoped to this agent, and naming the per-trace `gen_ai.usage.*` attributes as the exact source. |

`Name` is `!Sub inspection_agent_${Env}::DEFAULT` and `Resource` is `!Ref RuntimeArn`, both confirmed
against live `ListMetrics` output rather than guessed.

Outputs: `DashboardName`, `RuntimeLogGroupName`, `LogRetentionDays`, `MetricNamespace`, each with a
`Description` and no `Export`.

### 7. `scripts/deploy.sh`

Two additions, in the style of the existing code (bash 3.2, `set -Eeuo pipefail`, validation before any
mutating call, fixed messages).

`require_transaction_search()` — called from `deploy_stack` for the `observability` component, so it
guards both `make deploy-observability` and step 10 of `deploy-all`:

```sh
require_transaction_search() {
  local dest
  dest=$(aws xray get-trace-segment-destination --region "$REGION" --query Destination --output text 2>/dev/null || echo UNKNOWN)
  [[ "$dest" == "CloudWatchLogs" ]] && return 0
  die "CloudWatch Transaction Search is not enabled in $REGION (trace segment destination is '$dest'). ..."
}
```

The message prints the two exact commands (`aws logs put-resource-policy ...` with the
`xray.amazonaws.com` / `logs:PutLogEvents` policy on `aws/spans` and `/aws/application-signals/data`,
then `aws xray update-trace-segment-destination --destination CloudWatchLogs`) and the console path
(CloudWatch, Application Signals (APM), Transaction search, Enable Transaction Search, tick "ingest spans
as structured logs", Save). It is a one-time, account-level action.

`observability_parameters()` — a new branch in the `case "$c"` of `deploy_stack`, following
`pre_runtime_parameters` and `runtime_parameters`. It passes `LogRetentionDays` when overridden and
nothing else: the three SSM-typed parameters resolve themselves.

After the stack reaches `CREATE_COMPLETE` or `UPDATE_COMPLETE`, the observability branch reads the
`RuntimeLogGroupName` and `LogRetentionDays` outputs and runs
`aws logs put-retention-policy --log-group-name <name> --retention-in-days <days>`. A missing log group
is a warning, not a failure: AgentCore creates it on the first invoke, so a freshly created runtime has
none yet.

### 8. `docs/observability.md`

Sections:

1. What is instrumented and what is deliberately not (decision 1, in plain words).
2. One-time setup: enabling Transaction Search, with both the CLI and the console path, and what the
   deploy preflight prints when it is missing.
3. Finding the trace for a session: from the `trace_id` in the invoke response, from the session ID, and
   from the log group. Includes the OTel-hex to X-Ray-ID conversion with a worked example.
4. What each span means: `AgentCore.Runtime.Invoke`, `invoke_agent inspection-agent`, `chat`,
   `execute_tool <name>`, and which attributes each carries.
5. The `inspection.*` attribute table: attribute, meaning, and matching audit log field.
6. The three saved queries, what each answers, and what to substitute.
7. **Auditor walkthrough** — "who accessed lot `LOT-20250604-01`, when, and was it allowed?" End to end,
   using only the saved queries and the trace view, written for someone who has not seen the demo.
8. The dashboard and how to read each widget, including the token-metric caveat.
9. **Five-minute pre-demo checklist**, including the privacy check.
10. Known gaps and teardown.

## Data Models

### Audit event, after this spec

| Field | Type | Source | New |
|---|---|---|---|
| `tool` | str | tool name | |
| `parameters` | dict | caller arguments, strings cut to 200 chars | |
| `user_id` | str | `Principal.user_id` (Cognito `sub`) | |
| `groups` | list[str] | `Principal.groups` | |
| `decision` | `allowed` / `restricted` / `forbidden` / null | `authorizer.decide` | |
| `effective_lines` | list[str] | the scoped lines, empty when forbidden | |
| `row_count` | int | rows returned | |
| `report_ids` | list[str] | capped at 20 | |
| `duration_ms` | int | call duration | |
| `status` | str | `ok` / `forbidden` / `not_found` / `invalid_request` / `error` | |
| `session_id` | str | request context | yes |
| `actor_id` | str | request context (memory actor ID) | yes |
| `trace_id` | str | current span context, 32 hex, `""` when not recording | yes |
| `span_id` | str | current span context, 16 hex, `""` when not recording | yes |

Each also appears as `inspection.<field>` on the `execute_tool` span.

### Span inventory

| Span | Emitted by | Key attributes |
|---|---|---|
| `AgentCore.Runtime.Invoke` | AgentCore Runtime | `session.id`, `latency_ms`, `error_type`, `aws.agent.id`, `aws.request_id`, merged resource attributes |
| `invoke_agent inspection-agent-<env>` | Strands | `gen_ai.operation.name=invoke_agent`, `gen_ai.agent.tools`, `gen_ai.usage.*`, `session.id`, `inspection.prompt_version`, `inspection.model_id`, `inspection.memory.*`, `inspection.session_id` |
| `chat` | Strands | `gen_ai.operation.name=chat`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |
| `execute_tool <name>` | Strands | `gen_ai.operation.name=execute_tool`, `gen_ai.tool.name`, `gen_ai.tool.status`, plus every `inspection.*` audit field |

Content-bearing attributes on all of the above are `REDACTED`.

### Runtime environment variables, after this spec

`INSPECTION_ENV`, `AWS_REGION`, `INSPECTION_MODEL_ID`, `INSPECTION_MODEL_REGION`, `INSPECTION_DB_HOST`,
`INSPECTION_DB_SECRET_ARN`, `INSPECTION_LOG_LEVEL`, `INSPECTION_MEMORY_ID`,
**`UNIFIED_TRACES_DESTINATION_ENABLED`**, **`OTEL_SERVICE_NAME`**, **`OTEL_RESOURCE_ATTRIBUTES`**,
**`AWS_REDACT_SPAN_ATTRIBUTES`** — 12 in total, none holding a secret.

## Error Handling

| Situation | Behaviour |
|---|---|
| Transaction Search not enabled | `deploy.sh` stops before touching the stack, with the exact enable commands and the console path. |
| ADOT distro missing but `opentelemetry-instrument` in the entry point | Runtime creation fails with "OpenTelemetry instrumentation executable not found". Caught by task 5.1, before any stack update. |
| No recording span (local run, ADOT absent) | `current_trace_id()` returns `""`, `trace_id` in the response is `""`, the audit line still has every other field. Nothing raises. The agent behaves exactly as it does today. |
| `audit.emit` fails | Already swallowed by the two existing `try` blocks. The four new fields are computed inside them, so they cannot change that. |
| Request context not set | Defaults to `("", "")`. The audit line carries empty `session_id` and `actor_id` rather than failing. |
| Log group absent when retention is applied | `deploy.sh` warns and continues. AgentCore creates the group on the first invoke. |
| Metric filter pattern does not match the real line | Tool-calls-by-decision stays flat at zero. Caught by task 5.3, which reads a real line *before* the stack is deployed, and again by task 6.3. |
| Redaction removes more than intended | Visible in the trace as `REDACTED` on an attribute that should have survived. Task 6.4 inspects the attribute list by hand; `RedactSpanAttributes` can be narrowed without a code change. |

## Testing Strategy

The workspace testing policy forbids test files, suites, fixtures, eval harnesses and verification
scripts. Every check below is manual.

Static checks:

- `ruff check .` — zero findings.
- `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` — zero errors, zero warnings, all templates.
- `bash -n scripts/deploy.sh`.
- `infra/observability.yaml` read against the ten rules in `docs/cloudformation-conventions.md`, one rule
  at a time.

Manual verification, each recorded as a dated note under its task in `tasks.md`:

- Transaction Search enabled and confirmed by `get-trace-segment-destination`.
- Package builds with the distro and stays inside the size limits.
- The runtime accepts the two-element entry point and reaches `UPDATE_COMPLETE`.
- An invoke returns a non-empty `trace_id`, and that trace exists in CloudWatch.
- The trace shows model calls and each tool call as spans with the audit attributes.
- The line B inspector asking for line A data produces a tool span with `decision = forbidden`.
- The lot saved query lists every user and decision for that lot.
- The telemetry holds no JWT, no password and no notes text — checked by searching for a known note
  fragment from `data/STORIES.md`, for `Bearer`, and for `eyJ`.
- The runbook lets someone who has not seen the demo answer the auditor question.

## Task list guidance

`[implementer]` tasks need only files and local commands: Python, CloudFormation, bash, docs, `ruff`,
`cfn-lint`, `bash -n`. No AWS access, no credentials, no user input.

`[main]` tasks touch AWS, need credentials, need the user, or are ambiguous: enabling Transaction Search,
packaging, deploying, reading a real log line, running the demo questions, the privacy review, and every
verification note.

One ordering constraint drives the task list: the metric filter patterns and the saved-query field names
both depend on the shape of the real audit log line once ADOT is active, and that shape cannot be known
locally. So the template is authored, the runtime is instrumented and invoked, a real line is read, the
patterns are confirmed or corrected, and only then is the observability stack deployed.
