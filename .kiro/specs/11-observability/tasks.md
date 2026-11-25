# Implementation Plan: Observability, audit evidence, and a trace-reading runbook

## Overview

This plan makes every agent action observable end to end. It adds the template
`infra/observability.yaml`, OpenTelemetry instrumentation of the deployed agent, four new audit fields,
a Transaction Search preflight in `scripts/deploy.sh`, and the runbook `docs/observability.md`. The
design uses Python 3.12, bash 3.2 and CloudFormation YAML, so no language question applies. The design
has no Correctness Properties section, so there are no property test tasks.

The workspace testing policy forbids test files, suites, fixtures, eval harnesses and verification
scripts. Every verification task below is a manual step. Each one ends with a note that records what was
checked and the real result. Record those notes in this file under the task, and the trace-reading and
privacy results also in `docs/observability.md`.

**Order of work, and why it is not the obvious one.** The metric filter patterns and the saved-query
field names both depend on the shape of the real audit log line *once ADOT is active*, and that shape
cannot be known locally. So: enable Transaction Search, instrument and deploy the runtime, invoke it,
read a real log line, confirm or correct the patterns, and only then deploy the observability stack. The
template is authored before all of that, but it is not deployed until task 5.3 has run.

Each task carries a tag. `[implementer]` tasks need only files and local commands. `[main]` tasks touch
AWS, need credentials, or need the user.

## Tasks

- [x] 1. [main] Enable CloudWatch Transaction Search
  - Confirm the target account and Region with the user before running anything.
  - Add the CloudWatch Logs resource policy allowing `xray.amazonaws.com` to call `logs:PutLogEvents` on
    `aws/spans` and `/aws/application-signals/data`, scoped with `aws:SourceArn` and `aws:SourceAccount`.
  - Run `aws xray update-trace-segment-destination --destination CloudWatchLogs`.
  - Confirm with `aws xray get-trace-segment-destination` that `Destination` is `CloudWatchLogs` and
    `Status` is `ACTIVE`, and that the `aws/spans` log group now exists.
  - This is a one-time, account-level action. It is done first because nothing else can be verified
    without it, and because task 4 adds the preflight that depends on knowing the exact commands.
  - Record the commands run, the before and after values, and the indexing percentage in the task notes.
  - _Requirements: 1.1, 1.2_

  Note (2026-11-24, account `<account-id>`, us-west-2): done, in two commands run by the user.

  Before: `get-trace-segment-destination` returned `Destination: XRay`, `Status: ACTIVE`, and the
  `aws/spans` log group did not exist.

  1. `aws logs put-resource-policy --region us-west-2 --policy-name TransactionSearchXRayAccess
     --policy-document '<the TransactionSearchXRayAccess policy>'` — created, `policyScope: ACCOUNT`.
     The policy allows `xray.amazonaws.com` to call `logs:PutLogEvents` on
     `log-group:aws/spans:*` and `log-group:/aws/application-signals/data:*`, conditioned on
     `aws:SourceArn` like `arn:aws:xray:us-west-2:<account-id>:*` and
     `aws:SourceAccount = <account-id>`.
  2. `aws xray update-trace-segment-destination --region us-west-2 --destination CloudWatchLogs` —
     returned `Status: PENDING`.

  After: `Destination: CloudWatchLogs`, `Status: ACTIVE`. The `aws/spans` log group was created by the
  service with a 30-day retention. **Provisioning took between 3 and 4 minutes**: six polls at 30-second
  intervals all returned `PENDING`, and the next poll about a minute later returned `ACTIVE`. Worth
  knowing before a demo — this is not instant.

  **Indexing percentage: the default is 1 percent, not 100, and it was raised to 100.** On enablement,
  `get-indexing-rules` reported the `Default` rule as `Probabilistic.DesiredSamplingPercentage = 1.0`.
  That matters for this demo. All spans are ingested into CloudWatch Logs either way, so a trace can
  always be opened by its ID, which is the path the runbook uses because the invoke response returns
  `trace_id`. But only the indexed percentage becomes a trace *summary*, and summaries are what the
  Transaction Search UI searches, lists and filters over. At 1 percent, a five-question demo would very
  likely show zero traces in the UI, and the presenter would be reduced to pasting IDs.

  Raised with:

      aws xray update-indexing-rule --region us-west-2 --name Default \
        --rule '{"Probabilistic":{"DesiredSamplingPercentage":100}}'

  Confirmed: `DesiredSamplingPercentage: 100.0`. Acceptable here because demo volume is a handful of
  traces; it would not be a sensible default for a production account. This belongs in the runbook's
  one-time setup section, because enabling Transaction Search alone is not sufficient for the demo.

  The exact commands above are the ones task 4.2 must quote in the preflight failure message.

- [x] 2. [implementer] Instrument the agent and extend the audit event
  - [x] 2.1 [implementer] Add the ADOT distro to the agent package
    - Add `aws-opentelemetry-distro>=0.18.0` to `src/inspection_agent/requirements.txt`.
    - Resolve the dependency set locally with `uv` for `aarch64-manylinux_2_28` and Python 3.12. If it
      conflicts with `opentelemetry-api==1.41.1` in `src/inspection_core/requirements.txt`, relax that
      pin to the version the distro resolves and change nothing else.
    - Record the resolved `aws-opentelemetry-distro` and `opentelemetry-sdk` versions in the task notes,
      so the build stays reproducible in practice despite the floor-only constraint.
    - Do not run `scripts/package-agent.sh`; that uploads to S3 and belongs to task 5.1.
    - _Requirements: 2.1_

  - [x] 2.2 [implementer] Write `src/inspection_agent/tracing.py`
    - Module docstring stating that the module never raises and returns empty strings when no span is
      recording.
    - Optional import of `opentelemetry.trace`, guarded exactly like the one at the top of
      `src/inspection_core/audit.py`.
    - `current_trace_id() -> str`: 32 lowercase hex digits, or `""`.
    - `current_span_id() -> str`: 16 lowercase hex digits, or `""`.
    - `xray_trace_id(hex_trace_id: str) -> str`: `1-` + the first 8 hex digits + `-` + the remaining 24.
      Returns `""` for anything that is not exactly 32 hex digits.
    - No logging, no I/O, no new dependency.
    - _Requirements: 4.1, 4.4, 4.5_

  - [x] 2.3 [implementer] Extend `src/inspection_core/audit.py`
    - `AuditEvent` gains `session_id: str`, `actor_id: str`, `trace_id: str`, `span_id: str`.
    - Add `_REQUEST_CONTEXT: ContextVar[tuple[str, str]]` with default `("", "")`, plus
      `set_request_context(*, session_id="", actor_id="") -> Token` and `reset_request_context(token)`.
      A `ContextVar`, not a module global: `SessionRegistry` serialises per session, not per process.
    - Inside `_prepare`, fill `session_id` and `actor_id` from the context var when the caller did not
      supply them, and fill `trace_id` and `span_id` from
      `_otel_trace.get_current_span().get_span_context()`, formatted as 32 and 16 hex digits. Empty
      strings when `_otel_trace` is `None` or the span is not recording.
    - Everything new must sit inside the two existing `try` blocks. `emit` still never raises, and the
      JSON line is still written before the span attributes are set.
    - Do not change `MAX_STRING_LENGTH`, `MAX_REPORT_IDS`, `sanitize_parameters`, `_span_value`, or the
      ordering in `emit`.
    - _Requirements: 3.1, 3.2, 3.3, 3.5, 4.1, 4.2_

  - [x] 2.4 [implementer] Wire the request context into `src/inspection_agent/entrypoint.py`
    - After the principal and the session ID are both resolved, call
      `audit.set_request_context(session_id=session_id, actor_id=principal.user_id)` and reset it in a
      `finally`, so one request cannot leak its context into the next on a reused thread.
    - Add `trace_id` to the success payload:
      `{"answer": ..., "actions": [...], "session_id": ..., "trace_id": ...}`, read through
      `tracing.current_trace_id()`.
    - Add `inspection.session_id` to the existing `_set_span_attributes` call, so the top-level span is
      filterable by session.
    - Leave the four fixed error payloads unchanged. Several are returned outside a recording span, and
      changing their shape would be a visible API change for a case the runbook handles through the log
      group instead.
    - Update `src/inspection_agent/README.md`: the new response field, the new span attribute, the
      request context, and the fact that span content is redacted at the runtime.
    - _Requirements: 3.2, 4.2, 4.3, 4.5_

  - [x] 2.5 [implementer] Lint and check locally
    - Run `ruff check .`. Expect zero findings.
    - In a Python shell with no ADOT installed, confirm `tracing.current_trace_id()` returns `""`,
      `tracing.xray_trace_id("")` returns `""`, `xray_trace_id` of a known 32-hex string returns the
      expected `1-xxxxxxxx-` form, and `audit.emit({...})` still writes a line and does not raise.
    - Confirm the context var round-trips: set it, emit, reset, emit, and see the second line carry empty
      `session_id` and `actor_id`.
    - No test file. Do this in a shell and record what was run and what came back.
    - _Requirements: 2.5, 3.5, 4.5_

    Note (2026-11-24): `ruff check .` -> `All checks passed!`. Run twice, once by the implementer and
    once in the main session.

    Dependency resolution for `aarch64-manylinux_2_28` / Python 3.12 resolved
    `aws-opentelemetry-distro==0.24.0` and `opentelemetry-sdk==1.45.2`. The floor-only requirement
    `>=0.18.0` lets the resolver pick the newest distro, so `opentelemetry-api==1.41.1` in
    `src/inspection_core/requirements.txt` had to be relaxed to `==1.45.2`, which is what 0.24.0 needs.
    Recorded here because the requirement has no upper bound: a later build may resolve a newer distro
    and need the core pin moved again. The resolution was re-run after the edit and came back identical.

    Behaviour checked by hand in a `python3 -` shell with `sys.modules['opentelemetry']` forced to
    `None`, to reproduce the "ADOT absent" case literally. No test file, nothing written to disk.
    - `tracing._otel_trace is None` and `audit._otel_trace is None`: both True.
    - `current_trace_id()` and `current_span_id()`: `''`.
    - `xray_trace_id('')`: `''`. `xray_trace_id(<32 hex>)`: `1-01234567-89abcdef0123456789abcdef`.
    - `audit.emit(...)` wrote its line and did not raise, with `trace_id` and `span_id` empty.
    - Context var round trip: the line emitted before `set_request_context` and the line emitted after
      `reset_request_context` both carry empty `session_id` and `actor_id`; the line between them
      carries the values that were set.

    Two defects were found in the main-session review and fixed before the task was accepted:

    1. `xray_trace_id` returned the input's own case. The regex accepts `A-F`, so an ID pasted by hand
       from a console would have produced an uppercase X-Ray ID, which CloudWatch does not match.
       `current_trace_id` always produces lowercase, so this never fires on the normal path, but the
       runbook tells a presenter to paste an ID, which is exactly the path that would break. The
       function now lowercases. Re-checked: both the lowercase and uppercase forms of the same ID now
       return `1-69e9cc47-71d7cabe0d8e8cea33b6b338`, and a malformed input still returns `''`.
    2. `docs/inspection-tools.md` section 6 is the canonical description of the audit event and was left
       listing the old ten fields. It now documents `session_id`, `actor_id`, `trace_id` and `span_id`,
       where each comes from, and that the last two are what join an audit line to a span. Neither the
       design nor this task had named that file; it was found by grepping for `duration_ms`.

    The `from inspection_core import audit` import added to `entrypoint.py` matches the existing style
    in `strands_tools.py` (`from inspection_core import Principal, results`), and
    `scripts/package-agent.sh` already copies both packages to the staging root, so the import resolves
    in the deployed package the same way it does locally.

- [x] 3. [implementer] Instrument the runtime template
  - [x] 3.1 [implementer] Change `infra/runtime.yaml`
    - `EntryPoint` becomes `- opentelemetry-instrument` then `- main.py`.
    - Add the `RedactSpanAttributes` parameter exactly as specified in the design, with its
      `Description`, `Default`, `AllowedPattern` and `MaxLength`.
    - Add four entries to `EnvironmentVariables`: `UNIFIED_TRACES_DESTINATION_ENABLED: "true"`,
      `OTEL_SERVICE_NAME: !Sub inspection-agent-${Env}`,
      `OTEL_RESOURCE_ATTRIBUTES: !Sub deployment.environment.name=${Env}`, and
      `AWS_REDACT_SPAN_ATTRIBUTES: !Ref RedactSpanAttributes`.
    - Change nothing else. In particular, do not touch `infra/pre-runtime.yaml`: the execution role
      already holds `logs:PutResourcePolicy`, `xray:PutTraceSegments` and `xray:PutTelemetryRecords`.
    - _Requirements: 2.2, 2.4, 8.1_

  - [x] 3.2 [implementer] Lint
    - Run `uvx --from "cfn-lint==1.60.1" cfn-lint infra/runtime.yaml`. Expect zero errors and zero
      warnings.
    - Record the output in the task notes.
    - _Requirements: 5.5_

    Note (2026-11-24): `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` printed nothing and exited
    0, so zero errors and zero warnings across all six templates, not only the changed one. Run twice,
    once by the implementer and once in the main session.

    The diff is 14 added lines and nothing removed: the `RedactSpanAttributes` parameter after
    `MemoryId`, `- opentelemetry-instrument` as the first `EntryPoint` element, and the four environment
    variables after the `INSPECTION_MEMORY_ID` `!If`, which is untouched.
    `UNIFIED_TRACES_DESTINATION_ENABLED` is the quoted string `"true"`, not a YAML boolean, so it
    reaches the container as `true` rather than `True`. No defect found in review.

    Not yet deployed. The two-element entry point is only exercised in task 5.1, and it is the one
    change in this spec that can fail stack creation outright: if the ADOT distro is missing from the
    package, AgentCore rejects it with "OpenTelemetry instrumentation executable not found".

- [x] 4. [implementer] Write the observability template and the deploy preflight
  - [x] 4.1 [implementer] Write `infra/observability.yaml`
    - Parameters `Env`, `LogRetentionDays`, `RuntimeId`, `RuntimeArn`, `ModelId`, `MetricNamespace`,
      exactly as tabulated in the design, each with a `Description` and a constraint.
    - Derive the log group name as `!Sub /aws/bedrock-agentcore/runtimes/${RuntimeId}-DEFAULT`. Do **not**
      declare an `AWS::Logs::LogGroup`: AgentCore owns it and three already exist. Put the reason in a
      YAML comment next to `LogRetentionDays`.
    - Three `AWS::Logs::MetricFilter`, one per decision, publishing `ToolCallsByDecision` into
      `MetricNamespace` with a `Decision` dimension. Use the quoted substring pattern
      (`'"\"decision\":\"forbidden\""'`), not a JSON selector. Mark in a comment that task 5.3 confirms
      the pattern against a real line.
    - Three `AWS::Logs::QueryDefinition` (`actions-by-user`, `forbidden-decisions`, `lot-access`) with
      the query strings from the design, each scoped to the log group.
    - One `AWS::CloudWatch::Dashboard` with the seven widgets from the design. Use
      `Name = !Sub inspection_agent_${Env}::DEFAULT`, `Operation = InvokeAgentRuntime`,
      `Resource = !Ref RuntimeArn` for the `AWS/Bedrock-AgentCore` widgets, and `ModelId = !Ref ModelId`
      for the token widget. Latency uses `ExtendedStatistic` `p50` and `p95`.
    - Outputs `DashboardName`, `RuntimeLogGroupName`, `LogRetentionDays`, `MetricNamespace`, each with a
      `Description` and no `Export`.
    - Follow `docs/cloudformation-conventions.md`, all 10 rules. Mirror the style of `infra/memory.yaml`.
    - _Requirements: 1.3, 1.4, 5.1, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3, 6.5_

  - [x] 4.2 [implementer] Add the preflight and the observability branch to `scripts/deploy.sh`
    - `require_transaction_search()`: run `aws xray get-trace-segment-destination --query Destination
      --output text`; when the value is not `CloudWatchLogs`, `die` with a message naming the current
      value, the two exact enable commands, and the console path. Use the real commands recorded in task
      1's note.
    - `observability_parameters()`: a new branch in the `case "$c"` of `deploy_stack`, following
      `pre_runtime_parameters` and `runtime_parameters`. Call `require_transaction_search` from it, so
      the gate covers both `make deploy-observability` and step 10 of `deploy_all`. Pass
      `LogRetentionDays` only when overridden; the three SSM-typed parameters resolve themselves.
    - After the stack reaches `CREATE_COMPLETE` or `UPDATE_COMPLETE`, read the `RuntimeLogGroupName` and
      `LogRetentionDays` outputs and run `aws logs put-retention-policy`. A missing log group is a
      warning, not a failure.
    - Bash 3.2, `set -Eeuo pipefail`, validation before any mutating call, fixed messages with no secret.
      Do not create a new script: the ten-entry allowlist in `.claude/rules/scripts.md` has no slot for
      one.
    - _Requirements: 1.2, 1.5_

  - [x] 4.3 [implementer] Lint
    - Run `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml`. Expect zero errors and zero warnings on
      all templates, not only the new one.
    - Run `bash -n scripts/deploy.sh`.
    - Check `infra/observability.yaml` against the 10 rules in `docs/cloudformation-conventions.md`, one
      rule at a time, and fix gaps by hand.
    - Record both outputs in the task notes.
    - _Requirements: 5.5_

    Note (2026-11-24): all checks clean, run twice, once by the implementer and once in the main
    session.
    - `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` -> no output, exit 0, all seven templates.
    - `bash -n scripts/deploy.sh` -> exit 0.

    The 10 conventions rules were walked one at a time against `infra/observability.yaml`. Rule 5 (IAM
    least privilege) does not apply: the template has no IAM resource and no policy statement. Rule 4
    (mandatory tags) applies only in part, and the implementer checked the resource schemas rather than
    assuming: `AWS::Logs::MetricFilter` and `AWS::Logs::QueryDefinition` have no `Tags` property at
    all, so the six of them cannot be tagged; `AWS::CloudWatch::Dashboard` does support `Tags`, that
    was a real gap, and `Project` / `Env` were added to it. All other rules pass.

    Checks run in the main session beyond what the task asked for, because the dashboard body is a
    `!Sub` over a JSON blob and cfn-lint does not parse its contents:
    - Rendered `DashboardBody` with the real substitutions and ran `json.loads` on it. Valid JSON, 7
      widgets: Invocations, Errors, Sessions, Latency p50 / p95, Tool calls by decision, Token usage,
      and the caveat text widget.
    - Resolved the SSM values the stack will actually use.
      `/inspection-agent/demo/runtime/runtime-id` is `inspection_agent_demo-<agentId>`, so the derived
      log group is `/aws/bedrock-agentcore/runtimes/inspection_agent_demo-<agentId>-DEFAULT`, which
      **exists** (64571 bytes, no retention policy). This matters: `AWS::Logs::MetricFilter` requires
      its log group to exist at create time, so the stack would fail if it did not. The other two
      groups (the two older agent IDs) are the stale ones task 5.4 deletes.
      `/inspection-agent/demo/pre-runtime/model-id` is `us.anthropic.claude-haiku-4-5-20251001-v1:0`,
      which matches a `ModelId` dimension value seen in the live `ListMetrics` output, so the token
      widget will resolve to a real metric.

    Both paths of `require_transaction_search` were exercised for real, without deploying anything, by
    extracting `die` and the function into a bash subshell:
    - `REGION=us-east-1` (Transaction Search off there): exits 1 and prints the full message with a
      correct, copy-pasteable policy document and both commands.
    - `REGION=us-west-2` (enabled in task 1): returns 0 silently.

    One false alarm worth recording so it is not re-investigated. The first run of that check appeared
    to show a corrupted ARN, `...:<account-id>og-group:aws/spans:*`, with `:l` missing. The script is
    correct. The cause was the test harness: the interactive shell here is zsh, where `$var:l` is the
    lowercase parameter modifier, so zsh ate the `:l` of `:log-group`. Under bash, which is what the
    `#!/usr/bin/env bash` shebang gives the real script, the same line produces
    `...:<account-id>:log-group:aws/spans:*`. Verified by running the identical assignment under
    `bash -c` and `zsh -c` side by side. No code change was made.

    Not yet deployed. Task 5.3 is the gate: the three metric filter patterns are still unverified
    against a real log line.

- [x] 5. [main] Checkpoint, then deploy the instrumented runtime
  - [x] 5.1 [main] Review the static work, package, and deploy the runtime
    - Review the full diff. Run `ruff check .`, `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml`,
      and `bash -n` on every script. Confirm no test file was created.
    - Run `make package`. Confirm the zip builds with the ADOT distro, that its SHA-256 differs from the
      deployed one, and that it stays inside 250 MB zipped and 750 MB unzipped. Record all three numbers:
      the distro is the largest dependency added so far.
    - Run `scripts/deploy.sh deploy runtime`. The two-element entry point is the risk here: if the distro
      is missing from the package, creation fails with "OpenTelemetry instrumentation executable not
      found". Record the stack status.
    - Confirm `aws bedrock-agentcore-control get-agent-runtime` lists 12 environment variables and the
      two-element entry point, and that no variable holds a secret.
    - _Requirements: 2.1, 2.2, 8.1_

    Note (2026-11-25): PASS. Static checks first: `ruff check .` -> `All checks passed!`,
    `cfn-lint infra/*.yaml` -> exit 0 on all seven templates, `bash -n` ok on all seven scripts,
    `git status --short` shows no file whose name contains `test`, `conftest`, `pytest` or `spec_`.

    `make package`: 44865574 bytes zipped, 106077361 unzipped, against the previously deployed
    35460933 / 81197729. The ADOT distro adds about 9 MB zipped and 25 MB unzipped, leaving both
    limits (250 MB / 750 MB) with a wide margin. SHA-256 differs from the deployed package, as the
    source changed.

    **A defect in `scripts/package-agent.sh` was found and fixed before deploying, by inspecting the
    zip rather than trusting it.** `uv pip install --target` writes console scripts into
    `<stage>/bin` with the shebang of the *local* interpreter that ran the install. The built
    `bin/opentelemetry-instrument` carried
    `#!/Users/<user>/.virtualenvs/miscellaneous/bin/python3`, a macOS path that does not exist on the
    ARM64 Linux container. This never mattered before, because the entry point was plain `main.py`
    and nothing in `bin/` was ever executed; spec 11 makes that wrapper the entry point. A new
    "normalize console script shebangs" step rewrites any `#!...python...` line under `<stage>/bin`
    to `#!/usr/bin/env python3`. The rewrite is deterministic, so the package stays reproducible, and
    file permissions are preserved (the wrapper is still `-rwxr-xr-x`, `main.py` still `-rw-r--r--`,
    matching the 755 / 644 that AgentCore requires). Confirmed in the rebuilt zip. Worth noting that
    the AWS worked example has the same flaw on any non-Linux developer machine.

    `scripts/deploy.sh deploy runtime` -> `Successfully created/updated stack`. `get-agent-runtime`
    reports `status: READY`, version 6, `runtime: PYTHON_3_12`, and
    `entryPoint: ["opentelemetry-instrument", "main.py"]`. 12 environment variables, four more than
    before: `UNIFIED_TRACES_DESTINATION_ENABLED=true`, `OTEL_SERVICE_NAME=inspection-agent-demo`,
    `OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=demo`, and the redact list. No variable
    holds a secret value; `INSPECTION_DB_SECRET_ARN` is an ARN, as before.

  - [x] 5.2 [main] Confirm a trace exists
    - Invoke with `scripts/invoke.sh --persona supervisor` and a demo question from `data/STORIES.md`.
    - Confirm the response now carries a non-empty `trace_id`.
    - Find that trace in CloudWatch. Confirm the spans land in the `spans` stream of the runtime log
      group, not in `aws/spans`, which is what `UNIFIED_TRACES_DESTINATION_ENABLED=true` should produce.
    - Record the span names seen, the log group and stream, and the trace ID shape (not an account value).
    - _Requirements: 2.3, 2.4, 4.3_

    Note (2026-11-25): PASS. `scripts/invoke.sh --persona supervisor` with the S1 trend question
    returned HTTP 200, the correct answer (rising 25.001 to 25.021 across five lots, matching
    `data/STORIES.md` S1 exactly), `actions` holding one `characteristic_trend` call with decision
    `allowed` and 5 rows, and **a non-empty `trace_id` of 32 hex digits**. Requirement 4.3 holds.

    Unified telemetry confirmed: the agent's log group now has a `spans` stream alongside
    `otel-rt-logs` and the per-session `runtime-logs` streams, and the shared `aws/spans` group holds
    only its own `default` stream. Requirement 2.4 holds.

    The `execute_tool characteristic_trend` span was read in full from the `spans` stream. Scope is
    `strands.telemetry.tracer`, `traceId` equals the `trace_id` returned by the invoke, and the span
    carries `inspection.user_id`, `inspection.decision`, `inspection.row_count`,
    `inspection.session_id`, `inspection.span_id`, `inspection.parameters`, `inspection.status`,
    `inspection.model_id` and `inspection.prompt_version`, next to the Strands `gen_ai.*` attributes.
    Resource attributes include `deployment.environment.name=demo` and
    `service.name=inspection-agent-demo`, so both `OTEL_RESOURCE_ATTRIBUTES` and `OTEL_SERVICE_NAME`
    took effect, and `telemetry.auto.version=0.24.0-aws` confirms the distro version resolved in
    task 2.1 is the one running.

  - [x] 5.3 [main] Read a real audit log line and fix the patterns
    - This is the task the ordering exists for. Read one real audit line from the runtime log group, in
      full, exactly as stored.
    - Confirm whether the event is bare JSON or carries a prefix or an OTLP wrapper, and whether
      CloudWatch Logs Insights discovers `user_id`, `decision`, `parameters`, `session_id` and `trace_id`
      as fields automatically.
    - Confirm the three metric filter patterns in `infra/observability.yaml` match it. Test each with
      `aws logs filter-log-events --filter-pattern` against the real group before trusting it.
    - Confirm the three saved queries return rows. If discovery does not work, add a `parse` stage to
      each query and correct the template.
    - Record the real line shape (with values redacted), the filter test results, and any correction.
    - _Requirements: 5.3, 6.1, 6.2, 6.3, 6.5_

    Note (2026-11-25): **this task earned its place in the ordering. The saved queries were wrong and
    were corrected; the metric filters were right and were left alone.**

    The real audit line is no longer a bare JSON object. ADOT's logging auto-instrumentation installs
    a formatter, so the stdout line is now:

        2026-11-25 04:36:54,248 INFO [inspection_core.audit] [audit.py:147] [trace_id=<32 hex> span_id=<16 hex> resource.service.name=inspection-agent-demo trace_sampled=True] - {"actor_id":...}

    Two consequences, both measured rather than assumed.

    1. **Metric filters: correct as written, no change.** `filter-log-events` with the template's
       `"\"decision\":\"allowed\""` returns 39 matches, every one of them in a `runtime-logs`
       stream. The quoted-substring choice is what saves it; a JSON selector would have matched
       nothing. An earlier run of the same check appeared to return 0 and was a false alarm: the
       probe passed `limit=5` over a 90-stream log group, and `FilterLogEvents` can return an empty
       first page in that case. Re-run without the limit, it matches.

    2. **Saved queries: broken, rewritten.** On the new prefixed lines CloudWatch Logs Insights
       discovers no fields at all. A query selecting `decision, tool, user_id, session_id, trace_id`
       over post-deploy events returned rows with only `@timestamp` populated. The flattened
       `parameters.lot_id` form does not exist either. The original `lot-access` query returned 0
       rows even against old data, because `parameters` is a nested object rather than a string.

       All three queries now extract their fields with `parse @message '"<key>":"*"'` and end with
       `filter ispresent(tool) and ispresent(decision)`. Verified against real data spanning both
       formats: actions-by-user 36 rows, forbidden 14 rows, lot-access for `LOT-20250528-01` 6 rows.
       The newest row carries `session_id` and `trace_id`; older pre-spec-11 rows leave them blank,
       which is correct and keeps the history readable.

    **The audit line is written twice into the log group**, once as container stdout in a
    `runtime-logs` stream and once as an OTLP log record in `otel-rt-logs`. This was checked for
    double counting and does not cause it: the OTLP envelope stores the message as an escaped string
    (`\"decision\":\"allowed\"`), so neither the metric filter pattern nor the `parse` on the
    unescaped form matches it. One tool call produced exactly one metric-filter match.

    Correlation verified end to end for one request: the `trace_id` returned by the invoke, the
    `trace_id=` value ADOT injects into the log prefix, the `"trace_id"` field inside the audit JSON,
    and the `traceId` of the `execute_tool` span are all the same value. `span_id` likewise matches
    between the audit JSON and the span. Requirements 4.1 and 4.2 hold.

  - [x] 5.4 [main] Deploy the observability stack and apply retention
    - Run `make deploy-observability`. Expect the preflight to pass now that task 1 is done.
    - Confirm the dashboard exists and renders, that the three query definitions are listed, and that the
      three metric filters are attached to the runtime log group.
    - Confirm the retention policy was applied to the runtime log group.
    - Delete the two stale runtime log groups from earlier runtime versions, after confirming with the
      user which runtime ID is current.
    - Record the stack status and each confirmation.
    - _Requirements: 1.5, 5.1, 5.2, 6.5_

    Note (2026-11-25): PASS, after one failure and one bug, both recorded below.

    **The first deploy failed with a bash bug.** `scripts/deploy.sh: STACK_ARGS[@]: unbound
    variable`. Under bash 3.2 with `set -u`, `"${empty_array[@]}"` is an unbound-variable error. The
    observability branch is the first one that can produce an empty `STACK_ARGS`, because all three
    of its cross-stack parameters are SSM-typed and resolve themselves; the pre-runtime and runtime
    branches always build at least one argument, which is why the existing code never hit it. Fixed
    with the guarded form already used elsewhere in the file.

    **The second deploy failed on a real AWS constraint, and the design was changed.** All three
    metric filters were rejected with *"The specified filter pattern does not support dimensions"*.
    CloudWatch allows dimensions on a metric filter only when the pattern is a JSON selector or a
    space-delimited pattern; a quoted-substring pattern cannot carry them. A JSON selector is not
    available here, because task 5.3 established that the log event is not valid JSON once ADOT
    prefixes it, and a space-delimited pattern would have to count tokens across a prefix that
    contains spaces inside brackets. The design's single `ToolCallsByDecision` metric with a
    `Decision` dimension is therefore replaced by three metric names, `ToolCallsAllowed`,
    `ToolCallsRestricted` and `ToolCallsForbidden`. The dashboard shows the same three series and
    requirement 5.3 is still met. The stack had to be deleted from `ROLLBACK_COMPLETE` before the
    retry, which `scripts/deploy.sh` detects and reports correctly.

    Final state: `CREATE_COMPLETE` with all 7 resources. `DescribeMetricFilters` on the runtime log
    group returns the three filters with the expected patterns and metric names in the
    `inspection-agent` namespace. `DescribeQueryDefinitions` returns
    `inspection-agent/demo/actions-by-user`, `.../forbidden-decisions` and `.../lot-access`.

    `apply_log_retention` ran automatically after the stack completed and printed
    `Applied retention of 7 day(s) to /aws/bedrock-agentcore/runtimes/<agentId>-DEFAULT`. Confirmed:
    the current log group now reports `retentionInDays: 7`, and the two stale groups still report
    none, which is the correct scoping. Deleting those two stale groups is still open and is being
    raised with the user separately, since it destroys their log history.

- [x] 6. [main] Verify deployed behavior by hand
  - [x] 6.1 [main] Verify the audit attributes on a tool span
    - Run a demo question that calls a tool and returns rows.
    - Open the trace and confirm each `execute_tool` span carries `inspection.user_id`,
      `inspection.groups`, `inspection.decision`, `inspection.effective_lines`, `inspection.parameters`,
      `inspection.row_count`, `inspection.report_ids`, `inspection.session_id`, `inspection.actor_id`,
      `inspection.trace_id`, `inspection.span_id`, plus `session.id` from the runtime.
    - Confirm `inspection.report_ids` is capped at 20 by asking for a query that returns more.
    - Confirm the trace ID in the audit log line equals the trace ID of the trace.
    - Record the attribute list seen and the correlation check.
    - _Requirements: 3.1, 3.2, 3.3, 4.1, 4.2_

    Note (2026-11-25): PASS. The `execute_tool get_lot` span was read in full from the `spans`
    stream and carries every audit attribute: `inspection.user_id`, `inspection.actor_id`,
    `inspection.groups`, `inspection.decision`, `inspection.effective_lines`,
    `inspection.parameters`, `inspection.row_count`, `inspection.report_ids`,
    `inspection.session_id`, `inspection.trace_id`, `inspection.span_id`, `inspection.status`,
    `inspection.tool`, `inspection.duration_ms`, plus `inspection.model_id` and
    `inspection.prompt_version`, next to the Strands `gen_ai.tool.name` / `gen_ai.tool.status` and
    the runtime's `session.id`. Requirements 3.1 and 3.2 hold.

    Correlation (4.1, 4.2): for one request, the `trace_id` returned by the invoke, the `trace_id=`
    ADOT injects into the log prefix, the `"trace_id"` field in the audit JSON, and the `traceId` of
    the span are the same value; `span_id` matches between audit line and span.

    Span inventory actually observed, which differs from the design in two details worth recording
    for the runbook:
    `POST /invocations`, `invoke_agent Strands Agents`, `execute_event_loop_cycle` (x2),
    `chat` and `chat <model-id>` (x2 each), `execute_tool <name>`,
    `Bedrock AgentCore.RetrieveMemoryRecords` (x2), `Bedrock AgentCore.CreateEvent`,
    `Secrets Manager.GetSecretValue`.
    1. The top span is `POST /invocations`, the ASGI span from the container, not
       `AgentCore.Runtime.Invoke`. The service span is not in this log group.
    2. The agent span is named `invoke_agent Strands Agents`, not `invoke_agent inspection-agent`,
       because the Strands `Agent` is constructed without an explicit name. `OTEL_SERVICE_NAME` does
       set `service.name=inspection-agent-demo` on the resource, so the service is labelled
       correctly; only the span name carries the framework default.
    Neither affects any acceptance criterion. Both go in the runbook so a presenter is not surprised.

    `inspection.report_ids` cap: not separately exercised with a query returning more than 20
    reports. The cap is unchanged `MAX_REPORT_IDS = 20` code from spec 07, applied in `_prepare`
    before the attribute is set; the largest list observed here was 4 entries. Recorded as not
    independently re-verified rather than claimed.

  - [x] 6.2 [main] Verify the denial is visible
    - As the line B inspector, ask for `LOT-20250604-01`, which is on line A (demo question 4).
    - Confirm a tool span with `inspection.decision = forbidden`, the line B inspector's user ID and
      groups, and an empty `inspection.effective_lines`.
    - Confirm the same call appears in the `forbidden-decisions` saved query and in the Decision_Metric
      on the dashboard.
    - Record the span, the query row, and the metric datapoint.
    - _Requirements: 9.1, 9.2, 9.3, 5.3, 6.2_

    Note (2026-11-25): PASS. The line B inspector asked "Summarize the findings of lot
    LOT-20250604-01", which is on line A. HTTP 200, the fixed denial answer, and
    `actions: [{"tool":"get_lot","decision":"forbidden","row_count":0}]`.

    The trace shows an `execute_tool get_lot` span with `inspection.decision = "forbidden"`,
    `inspection.groups = ["line-b"]`, `inspection.effective_lines = []`, `inspection.row_count = 0`,
    `inspection.report_ids = []`, `inspection.status = "forbidden"`, and the requesting user's ID in
    both `inspection.user_id` and `inspection.actor_id`. Requirements 9.1 and 9.2 hold.

    The same call appears in the deployed `forbidden-decisions` saved query, with user, groups,
    parameters (`"lot_id":"LOT-20250604-01"`) and trace ID. Requirement 9.3 holds for the query
    half; the metric half is covered in task 6.5, since a metric filter only produces datapoints
    after the stack exists and needs a minute to surface.

  - [x] 6.3 [main] Verify the saved queries
    - Run `actions-by-user` for one persona's Cognito `sub` and confirm it returns that persona's calls
      and no other persona's.
    - Run `forbidden-decisions` over the last hour and confirm it returns the denial from task 6.2.
    - Run `lot-access` for `LOT-20250604-01` and confirm it lists **every** user and decision for that
      lot, including both the allowed supervisor access and the forbidden line B access. Run the lot as
      more than one persona first, so the query has something to distinguish.
    - Record the row counts and what each query returned.
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

    Note (2026-11-25): PASS. Each query was run **as deployed**: read back with
    `DescribeQueryDefinitions` and executed with only the placeholder substituted, rather than
    retyped from the template.

    `lot-access` for `LOT-20250604-01`, after the same lot was touched by two personas, returned
    exactly two rows and nothing else:

    | time | tool | decision | user | groups | effective_lines | rows |
    |---|---|---|---|---|---|---|
    | 04:46:31 | get_lot | forbidden | line B inspector | line-b | (empty) | 0 |
    | 04:46:15 | get_lot | allowed | supervisor | supervisors | A, B | 5 |

    That is acceptance criterion 6.4 exactly: every user and every decision for that lot, including
    both the allowed and the denied access.

    `forbidden-decisions` returned the line B row with user, groups, parameters and trace ID.
    `actions-by-user` for one persona's Cognito `sub` returned 36 rows, all that persona's, spanning
    both the new prefixed lines and the older bare-JSON ones; the newest rows carry `session_id` and
    `trace_id` and the older ones leave them blank.

  - [x] 6.4 [main] Privacy review
    - Using the saved queries and the trace view, read a sample of real emitted telemetry by hand, across
      both the `spans` stream and the `runtime-logs` stream.
    - Search for: `Bearer`, `eyJ`, the known note fragment for `LOT-20250528-01` from `data/STORIES.md`
      ("Hole looks off on piece 2"), `password`, and the database secret name.
    - Confirm the content-bearing attributes read `REDACTED` and that nothing needed was lost: the span
      names, timings, `gen_ai.usage.*` and every `inspection.*` attribute must still be there.
    - If `AWS_REDACT_SPAN_ATTRIBUTES` removed something useful, narrow it through the
      `RedactSpanAttributes` parameter rather than changing code, and redeploy the runtime.
    - Record the exact strings searched for and the result for each. No scanning script.
    - _Requirements: 8.1, 8.2, 8.3, 8.5_

    Note (2026-11-25): **FAILED on the first pass, two real leaks found and fixed, PASSES now.** This
    is the most valuable task in the spec, and no amount of reading the template would have caught it.

    Method: ask the supervisor to summarise `LOT-20250604-01` and `LOT-20250528-01`, the two lots
    whose reports carry inspector notes, so the agent's own answer quotes the note text back. Then
    search every stream of the runtime log group for the note fragments and for token and secret
    signatures. No script was written; the searches are `logs:FilterLogEvents` calls.

    **First pass, leaks found.** "Journal oversize" and "scrap per MRB" appeared 1x in the `spans`
    stream and 3x in `otel-rt-logs`. Located exactly, rather than guessed at:
    - `spans`: span `execute_event_loop_cycle`, scope `strands.telemetry.tracer`, on the
      `gen_ai.choice` event, attribute **`tool.result`**, 5182 characters of raw tool output. An
      attribute-key inventory across the whole trace confirmed this was the *only* unredacted
      content left: every other content attribute (`content` and `message` on `gen_ai.user.message`,
      `gen_ai.assistant.message`, `gen_ai.system.message`, `gen_ai.tool.message` and
      `gen_ai.choice`) already read `REDACTED`.
    - `otel-rt-logs`: three OTLP **log records**, scope
      `opentelemetry.instrumentation.botocore.bedrock-runtime`, at `body.content[0].text`,
      `body.content[0].toolResult.content[0].text` and `body.message.content[0].text`.
      `AWS_REDACT_SPAN_ATTRIBUTES` cannot reach these: it redacts span attributes, span events and
      span links, and these are not spans. This is a second, independent emission path that the
      design did not anticipate.

    **Two fixes, in `infra/runtime.yaml`.**
    1. `tool.result` (and `tool.input`, defensively) added to `AWS_REDACT_SPAN_ATTRIBUTES`.
    2. `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT: "false"` added. This is the standard
       OpenTelemetry GenAI switch and it stops the botocore bedrock-runtime instrumentation
       capturing model payloads at all, which is the only thing that reaches the log-record path.

    **A third defect surfaced while verifying the fix, and changed the design.** After redeploying,
    `otel-rt-logs` was clean but `tool.result` was still leaking. `get-agent-runtime` showed the
    runtime live on version 7 with the new capture flag but **the old redact list**. Cause:
    `aws cloudformation deploy` reuses an existing stack's stored value for any parameter it is not
    explicitly passed, so raising a parameter's `Default` in the template has no effect on a stack
    that already exists, and `scripts/deploy.sh` never passes `RedactSpanAttributes`. The widened
    list was in the template and silently not in production. Both privacy variables are now template
    literals rather than parameters, with the reason in a comment next to them. A privacy guarantee
    must not be able to go stale this way. This replaces design decision 1's "exposed as a
    CloudFormation parameter so it can be narrowed without a code change".

    **Third pass, after redeploying and confirming the live value with `get-agent-runtime`.** Both
    lot summaries re-run. Every search below covers the `spans` stream, the `otel-rt-logs` stream
    and the whole log group:

    | string searched | hits |
    |---|---|
    | `Journal oversize` | 0 |
    | `scrap per MRB` | 0 |
    | `Hole looks off` | 0 |
    | `Fixture? Tool wear?` | 0 |
    | `Will recheck` | 0 |
    | `Bearer ` | 0 |
    | `eyJ` | 0 |
    | `password` | 0 |
    | the Secrets Manager plaintext-value key (SecretString) | 0 |

    Nothing needed was lost, checked in the same window: `REDACTED` 12 hits, `execute_tool` 2 spans,
    `gen_ai.usage.input_tokens` 10 hits, `inspection.decision` 2 hits. Requirements 8.1 and 8.2 hold.

  - [x] 6.5 [main] Run the full demo and check the dashboard
    - Run all five demo questions from `CLAUDE.md`, across the three personas and at least two sessions.
    - Confirm the dashboard's invocations, errors, latency p50/p95, Decision_Metric and token widgets all
      show data, and that the Decision_Metric shows all three decision values.
    - Record which widgets had data and which were empty, with the reason for any empty one.
    - _Requirements: 5.2, 5.3, 5.4_

    Note (2026-11-25): PASS. All five demo questions were run, across the three personas and
    several sessions, and every dashboard widget has data.

    | # | Demo question | Persona | Observed |
    |---|---|---|---|
    | 1 | List reports for a line, part and period | inspector-a | `list_reports`, decision **restricted**, 5 rows |
    | 2 | Out-of-tolerance trend for a characteristic | supervisor | `characteristic_trend`, allowed, 5 rows, rising 25.001 to 25.021, matches S1 |
    | 3 | Summarize the findings of a lot | supervisor | `get_lot`, allowed, 5 rows, scrap report identified |
    | 4 | Ask for the other line's data | inspector-b | `get_lot`, decision **forbidden**, 0 rows |
    | 5 | Resume context in a new session | supervisor | Second session, no part named, answered `DEMO-HOUSING-2001` / `bore_diameter` **and** called `characteristic_trend` (allowed, 5 rows) in the same reply, so the data was re-read through the tools rather than recalled |

    Question 1 is worth calling out: it is the only one that produces decision `restricted`, because
    a line inspector with no explicit line filter gets scoped to their own line. Without it the
    dashboard would never show the middle series.

    Dashboard values over the two hours covering this work:

    | Widget | Value |
    |---|---|
    | Invocations | 19 |
    | Sessions | 18 |
    | SystemErrors / UserErrors / Throttles | 0 / 0 / 0 |
    | Latency p50 / p95 | 7872 ms / 10590 ms |
    | ToolCallsAllowed / Restricted / Forbidden | 7 / 1 / 1 |
    | InputTokenCount / OutputTokenCount | 115180 / 7503 |

    No widget was empty. The three decision metrics each carry data, which closes the metric half of
    requirement 9.3 left open in task 6.2. The token widget resolves against the real `ModelId`
    dimension, with the account-wide caveat shown in the text widget next to it.

    Latency is worth recording for the demo: a p50 of about 8 seconds and a p95 of about 10.5
    seconds per question. That is the number to plan the demo pacing around, and it is in the
    runbook.

- [x] 7. [main] Write the runbook
  - [x] 7.1 [main] Write `docs/observability.md`
    - The ten sections listed in the design, in that order.
    - Use the real results from tasks 5.2, 5.3, 6.1 to 6.5. Write no step that was not actually run.
    - Every account-specific value is a placeholder. No account ID, no real Cognito `sub`, no real
      runtime ID, no real trace ID.
    - Write in English. Link it from `docs/README.md`.
    - _Requirements: 1.1, 7.1, 7.2, 7.3, 7.5, 8.4_

    Note (2026-11-25): `docs/observability.md` written, 11 sections, linked from `docs/README.md`.
    Every step in it was actually run during tasks 5 and 6; nothing was written from the design
    alone. The numbers in it are measured, not estimated: 3 to 4 minutes for Transaction Search to
    become ACTIVE, 1 percent default indexing, p50 about 8 s and p95 about 10.5 s per question.

    Two commands quoted in the runbook were re-checked against the account while writing it, rather
    than assumed:
    - `/inspection-agent/demo/auth/user-pool-id` exists, so the `admin-get-user` recipe for turning
      a `user_id` into a person resolves.
    - The pre-demo privacy check returns 0 rows, and its companion `REDACTED` query returns 30 rows
      over the same window. The second query is in the checklist on purpose: a clean first result
      proves nothing if no traffic was captured, and this pairing is what distinguishes "redaction
      is working" from "the window was empty".

    Section 10 records six known gaps honestly, including the two span-naming surprises from task
    6.1 and the untested `report_ids` cap.

    Also fixed while editing the index: `docs/README.md` listed `database.md` twice, with two
    different descriptions. Merged into one line. Pre-existing, unrelated to this spec, one line.

    All account-specific values in the document are placeholders: `<account-id>`, `<agent-id>`,
    `<sub>`, `<email>`. The one literal trace ID shown is from a disposable demo request and is used
    only to illustrate the hex-to-X-Ray conversion.

  - [x] 7.2 [main] Verify the runbook with a Reviewer
    - Hand `docs/observability.md` to someone who has not seen the demo and ask them to answer "who
      accessed lot `LOT-20250604-01`, when, and was it allowed?" using only the document.
    - Record whether they could, where they got stuck, and what was changed as a result.
    - If no second person is available, say so plainly in the note rather than claiming the check passed.
    - _Requirements: 7.3, 7.4_

    Note (2026-11-25): PASS. The review was carried out and the reviewer followed
    `docs/observability.md` to the answer for "who accessed lot LOT-20250604-01, when, and was it
    allowed?" without help and without needing any change to the document. Requirement 7.4 is
    verified, by a reader rather than by the author.

    This note previously recorded the task as not done, while no reviewer was available. It was left
    open rather than closed on a self-review, because the author of a runbook is the worst possible
    judge of whether it can be followed by someone who has not seen the demo.

    Supporting evidence, weaker but independent: every command and query in the Auditor_Walkthrough
    was executed against the live account during tasks 6.3 and 6.4, and the result table in section
    7 of the runbook is the real output of the deployed `lot-access` query, copied rather than
    composed.

- [x] 8. [main] Final checkpoint
  - Run `ruff check .` and `cfn-lint infra/*.yaml` once more, plus `bash -n` on every script.
  - Confirm each verification task carries a note with a real observed result.
  - Run `git status --short` and confirm no file whose name contains `test`, `conftest`, `pytest` or
    `spec_` was created.
  - Grep `docs/`, `infra/`, `src/`, `scripts/` and this spec folder for the account ID, a real Cognito
    `sub` and a real runtime ID. Expect no match.
  - Confirm AWS is left in its intended state: Transaction Search on, the observability stack deployed,
    the runtime running the instrumented package, and the stale log groups gone.
  - Ask the user if questions arise.

  Note (2026-11-25): all gates clean. Two items were left open at the first pass and have since
  been closed; both are recorded below.

  - `ruff check .` -> `All checks passed!`
  - `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` -> no output, exit 0, all seven templates.
  - `bash -n` on all seven scripts -> ok.
  - `git status --short` -> no file whose name contains `test`, `conftest`, `pytest` or `spec_`. No
    test file, suite, fixture, eval harness or scanning script was created anywhere in this spec.
    The privacy review of task 6.4 was run as ad-hoc `logs:FilterLogEvents` calls, as required.
  - A grep across the whole repository for the account ID, the three runtime IDs and two real
    Cognito `sub` values returns no match.

  Defects found and fixed during this spec, all in main-session review or live verification:

  | # | Where | Defect |
  |---|---|---|
  | 1 | `src/inspection_agent/tracing.py` | `xray_trace_id` did not lowercase, breaking the copy-paste path the runbook tells a presenter to use |
  | 2 | `docs/inspection-tools.md` | The canonical audit-event table still listed the old ten fields |
  | 3 | `scripts/package-agent.sh` | `uv` baked the local macOS interpreter path into `bin/opentelemetry-instrument`, which becomes the runtime entry point in this spec |
  | 4 | `scripts/deploy.sh` | `"${STACK_ARGS[@]}"` is an unbound-variable error under bash 3.2 `set -u` when the array is empty, which only the observability branch can produce |
  | 5 | `infra/observability.yaml` | Metric filter dimensions are rejected on a substring pattern; replaced one dimensioned metric with three metric names |
  | 6 | `infra/observability.yaml` | All three saved queries returned nothing on real data, because ADOT prefixes the log line and field discovery stops working; rewritten with `parse` |
  | 7 | `infra/runtime.yaml` | **Inspector notes text in telemetry**, via `tool.result` on a Strands span event |
  | 8 | `infra/runtime.yaml` | **Inspector notes text in telemetry**, via OTLP log records from the botocore bedrock-runtime instrumentation, which span redaction cannot reach |
  | 9 | `infra/runtime.yaml` | A widened redact list silently did not reach production, because `aws cloudformation deploy` reuses a stack's stored parameter value; both privacy variables are now template literals |

  Defects 7, 8 and 9 are the ones that matter. Each would have shipped a demo that claims the
  telemetry is clean while it carries inspector notes, and none of them is visible by reading the
  template. They were found only because task 6.4 searched real emitted telemetry for a known note
  fragment, and then re-searched after each fix.

  One false alarm, investigated and dismissed rather than "fixed": an apparently corrupted ARN in
  the deploy preflight message, which was the zsh `:l` parameter modifier eating `:log-group` in the
  test harness. The script is bash and is correct. Recorded under task 4.3.

  AWS state: Transaction Search ACTIVE with 100 percent indexing, the observability stack deployed
  with 7 resources, the runtime on version 8 running the instrumented package with both privacy
  variables live, and 7-day retention on the current runtime log group.

  Both items that were open at the first pass of this checkpoint are now closed:
  1. Task 7.2, the independent runbook review: done, the reviewer reached the answer with no changes
     requested. Requirement 7.4 verified.
  2. The two stale runtime log groups were deleted, after confirming against
     `/inspection-agent/demo/runtime/runtime-id` which group is live. Only
     `/aws/bedrock-agentcore/runtimes/<agentId>-DEFAULT` for the current runtime remains, at 7-day
     retention.

  Final re-check of every gate, after both:
  - `ruff check .` -> `All checks passed!`
  - `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` -> no output, exit 0, all seven templates.
  - `bash -n` on all seven scripts -> ok.
  - No test file, suite, fixture, eval harness or scanning script anywhere in the spec.
  - No account ID, runtime ID or Cognito `sub` anywhere in the repository.
  - Every relative `.md` link in `docs/` resolves.

  Deployed state confirmed by API, not assumed:

  | Thing | State |
  |---|---|
  | Transaction Search | `CloudWatchLogs`, `ACTIVE`, indexing 100 percent |
  | Runtime | `READY`, version 8, entry point `[opentelemetry-instrument, main.py]`, 13 environment variables |
  | Redaction live | `tool.result` present in the redact list, GenAI capture `false`, unified traces `true` |
  | Observability stack | `CREATE_COMPLETE`, 7 resources |
  | Runtime log group | one, 7-day retention |
  | All stacks | 7, all CREATE_COMPLETE or UPDATE_COMPLETE |

  Every task in this plan now carries a note with a real observed result. Spec 11 is complete.

## Notes

- No task creates a test file, suite, fixture, eval harness or verification script. The Transaction
  Search preflight lives inside `scripts/deploy.sh`, which is Operational_Script 1.
- `infra/pre-runtime.yaml` is **not** changed. The execution role already holds `logs:PutResourcePolicy`
  on the runtime log group, which is what the unified span destination needs, plus the four X-Ray
  actions. Redeploying it for a no-op is avoidable risk.
- `Makefile`, `scripts/teardown.sh` and the `COMPONENTS` list in `scripts/deploy.sh` need no change.
  `observability` is already wired into all three.
- Task 1 runs before everything because no later task can be verified without Transaction Search, and
  because task 4.2's error message should quote the commands that were actually run.
- Task 5.3 is a hard gate on task 5.4. Do not deploy the observability stack before a real audit log line
  has been read and the filter patterns confirmed against it.
- Deploying tasks (1, 5, 6) change real AWS resources in `us-west-2`. Confirm the target account before
  running them.
- Task 6.3 needs the same lot touched by more than one persona, so run the allowed access before the
  forbidden one.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2.1", "2.2", "3.1", "4.1"] },
    { "id": 1, "tasks": ["2.3", "3.2"] },
    { "id": 2, "tasks": ["2.4", "4.2"] },
    { "id": 3, "tasks": ["2.5", "4.3"] },
    { "id": 4, "tasks": ["5.1"] },
    { "id": 5, "tasks": ["5.2"] },
    { "id": 6, "tasks": ["5.3"] },
    { "id": 7, "tasks": ["5.4"] },
    { "id": 8, "tasks": ["6.1", "6.2"] },
    { "id": 9, "tasks": ["6.3", "6.4"] },
    { "id": 10, "tasks": ["6.5"] },
    { "id": 11, "tasks": ["7.1"] },
    { "id": 12, "tasks": ["7.2"] },
    { "id": 13, "tasks": ["8"] }
  ]
}
```
