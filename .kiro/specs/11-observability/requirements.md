# Requirements Document

## Introduction

This feature makes every agent action observable end to end. A presenter opens one trace and shows who
asked, what the agent did, which tools it called, which data came back (by ID), and which authorization
decision was taken. An auditor answers "who accessed lot X, when, and was it allowed?" from saved
queries alone.

It adds the template `infra/observability.yaml`, OpenTelemetry instrumentation of the deployed agent, a
Transaction Search preflight in `scripts/deploy.sh`, and the runbook `docs/observability.md`.

Out of scope: CloudWatch Omni (issue #15) and the UI (issue #12).

Facts found in the repository and in account `<account-id>` / `us-west-2` while writing these
requirements (the design confirms them):

- `src/inspection_core/audit.py` already writes one JSON line per tool call and already sets
  `inspection.<field>` span attributes. `src/inspection_agent/entrypoint.py` already sets
  `inspection.prompt_version`, `inspection.model_id` and `inspection.memory.*`.
- **None of that reaches CloudWatch.** The code package pins `opentelemetry-api==1.41.1` with no SDK and
  no ADOT distro, so `trace.get_current_span()` returns the non-recording default and every
  `set_attribute` call is dropped.
- CloudWatch Transaction Search is **off**: `aws xray get-trace-segment-destination` returns `XRay`, and
  the `aws/spans` log group does not exist.
- `infra/runtime.yaml` already writes `EntryPoint` as a YAML list, and the CloudFormation property is
  `List<String>`, so the `opentelemetry-instrument` prefix is an added list item.
- The execution role in `infra/pre-runtime.yaml` already holds `logs:PutResourcePolicy`,
  `xray:PutTraceSegments` and `xray:PutTelemetryRecords`. **No IAM change is needed.**
- `scripts/deploy.sh` already lists `observability` in `COMPONENTS` and already has `step 10
  observability` in `deploy_all`. `scripts/teardown.sh` already lists it. The `Makefile` pattern rules
  already cover `make deploy-observability`.
- Three runtime log groups already exist, named
  `/aws/bedrock-agentcore/runtimes/inspection_agent_demo-<agentId>-DEFAULT`, none with a retention
  policy. AgentCore creates them and their names embed a service-generated ID.
- The testing policy forbids test files. Every acceptance criterion in this document is verified by hand.

## Glossary

- **Observability_Stack**: The CloudFormation stack `inspection-agent-<env>-observability`, defined in
  `infra/observability.yaml`.
- **Observability_Template**: The file `infra/observability.yaml`.
- **Runtime_Log_Group**: `/aws/bedrock-agentcore/runtimes/<runtimeId>-DEFAULT`, created by AgentCore. It
  holds the agent's stdout in the `runtime-logs` stream and, under unified telemetry, its spans in the
  `spans` stream.
- **Transaction_Search**: The account-level CloudWatch feature that ingests spans as structured logs and
  makes traces searchable. Required to view any span.
- **ADOT_Distro**: The Python package `aws-opentelemetry-distro`, version 0.18.0 or later.
- **Audit_Event**: The JSON line written per tool call by `src/inspection_core/audit.py`.
- **Audit_Attributes**: The `inspection.<field>` span attributes carrying the Audit_Event fields.
- **Tool_Span**: A span with `gen_ai.operation.name = execute_tool`, one per tool call.
- **Model_Span**: A span with `gen_ai.operation.name = chat`, one per model call.
- **Service_Span**: `AgentCore.Runtime.Invoke`, emitted by AgentCore Runtime as the first span of every
  trace.
- **Redact_List**: The value of the runtime environment variable `AWS_REDACT_SPAN_ATTRIBUTES`.
- **Saved_Query**: An `AWS::Logs::QueryDefinition` in the Observability_Stack.
- **Decision_Metric**: The CloudWatch metric `ToolCallsByDecision`, with a `Decision` dimension, produced
  by metric filters over the Audit_Event.
- **Runbook**: The document `docs/observability.md`.
- **Auditor_Walkthrough**: The section of the Runbook that answers "who accessed lot X, when, and was it
  allowed?".
- **Pre_Demo_Checklist**: The section of the Runbook listing what to verify five minutes before the demo.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: Enablement

**User Story:** As an operator, I want the one-time setup to be explicit and guarded, so that nobody
discovers during the demo that traces were never being recorded.

#### Acceptance Criteria

1. THE Runbook SHALL document how to enable Transaction_Search, with both the AWS CLI commands and the
   console path.
2. WHEN Transaction_Search is not enabled, THE deploy script SHALL stop before changing the
   Observability_Stack and SHALL print the exact command or console step to enable it.
3. THE Observability_Template SHALL NOT create a resource that enables or disables Transaction_Search,
   because it is an account-level setting and stack deletion would disable it for every workload in the
   account.
4. THE Observability_Template SHALL expose log retention as a parameter with a `Description` and an
   `AllowedValues` constraint, with a short default.
5. THE deploy script SHALL apply the retention value to the Runtime_Log_Group, and SHALL warn rather than
   fail when that log group does not exist yet.

### Requirement 2: Instrumentation

**User Story:** As a presenter, I want the deployed agent to emit real spans, so that the trace view has
something to show.

#### Acceptance Criteria

1. THE agent package SHALL include the ADOT_Distro.
2. THE runtime entry point SHALL run the agent under `opentelemetry-instrument`.
3. WHEN a request runs, THE trace SHALL contain the Service_Span, at least one Model_Span, and one
   Tool_Span per tool call.
4. THE runtime SHALL deliver its spans to the Runtime_Log_Group rather than to the shared `aws/spans` log
   group.
5. WHEN the ADOT_Distro is absent, THE agent SHALL still run and answer, with empty trace identifiers and
   no raised exception.

### Requirement 3: Audit attributes

**User Story:** As an auditor, I want every tool call to carry its own evidence, so that one span answers
who did what to which data under which decision.

#### Acceptance Criteria

1. EACH Tool_Span SHALL carry the Audit_Attributes for user ID, groups, decision, effective lines,
   parameters, row count and returned report IDs.
2. EACH Tool_Span SHALL carry the session ID and, when present, the memory actor ID.
3. THE returned report IDs SHALL remain capped at the existing limit of 20.
4. THE Audit_Event and the Audit_Attributes SHALL NOT contain a JWT, a secret value, or notes text.
5. THE addition of these fields SHALL NOT change any Tool_Result, and SHALL NOT be able to raise.

### Requirement 4: Correlation

**User Story:** As a presenter, I want to find the trace for the request I just ran, without searching.

#### Acceptance Criteria

1. THE Audit_Event SHALL carry the trace ID and the span ID of the span that was active when it was
   emitted.
2. THE final answer span, the Tool_Spans and the Audit_Events of one request SHALL share one trace ID.
3. THE invoke response SHALL return the trace ID alongside the session ID.
4. THE Runbook SHALL document how to convert the returned trace ID into the form the CloudWatch trace
   view searches on.
5. WHEN no span is recording, THE invoke response SHALL still return a well-formed payload with an empty
   trace ID.

### Requirement 5: Dashboard

**User Story:** As an operator, I want one page showing whether the agent is healthy and what it is
deciding.

#### Acceptance Criteria

1. THE Observability_Stack SHALL define a CloudWatch dashboard in CloudFormation.
2. THE dashboard SHALL show invocations, errors, and latency p50 and p95 for the deployed runtime.
3. THE dashboard SHALL show the Decision_Metric broken down by `allowed`, `restricted` and `forbidden`.
4. THE dashboard SHALL show token usage where a metric exists, and SHALL state on the page that the
   source metric is account-wide per model rather than scoped to this agent.
5. THE Observability_Template SHALL pass `cfn-lint` with zero errors and zero warnings, and SHALL follow
   every rule in `docs/cloudformation-conventions.md`.

### Requirement 6: Saved queries

**User Story:** As an auditor, I want the three questions I always ask to be one click away.

#### Acceptance Criteria

1. THE Observability_Stack SHALL define a Saved_Query returning all actions by one user.
2. THE Observability_Stack SHALL define a Saved_Query returning all `forbidden` decisions.
3. THE Observability_Stack SHALL define a Saved_Query returning all accesses to a given lot ID.
4. WHEN the lot Saved_Query runs for a lot that was accessed, THE result SHALL list every user and
   every decision for that lot.
5. EACH Saved_Query SHALL be scoped to the Runtime_Log_Group and SHALL name the field to substitute.

### Requirement 7: Runbook

**User Story:** As a presenter, I want someone who has never seen this demo to be able to run the
evidence part of it.

#### Acceptance Criteria

1. THE Runbook SHALL explain how to find the trace for a session.
2. THE Runbook SHALL explain what each span in the trace means and which attributes it carries.
3. THE Runbook SHALL contain the Auditor_Walkthrough, answering "who accessed lot X, when, and was it
   allowed?" using only the Saved_Queries and the trace view.
4. THE Auditor_Walkthrough SHALL be sufficient for a Reviewer who has not seen the demo to answer that
   question.
5. THE Runbook SHALL contain the Pre_Demo_Checklist, covering what to verify five minutes before the
   demo.

### Requirement 8: Privacy

**User Story:** As a security reviewer, I want to know that turning on tracing did not turn on data
exfiltration.

#### Acceptance Criteria

1. THE runtime SHALL be configured with a Redact_List that removes model prompts, model answers and tool
   payloads from spans before export.
2. THE telemetry SHALL NOT contain a JWT, a password, or notes text.
3. A Reviewer SHALL verify requirement 8.2 by hand over a sample of real emitted telemetry, using the
   Saved_Queries and the trace view, and SHALL record the exact strings searched for.
4. THE Pre_Demo_Checklist SHALL include that privacy check.
5. NO test file, test suite, test fixture, eval harness, or scanning script SHALL be created for any of
   the above.

### Requirement 9: The demo denial is visible

**User Story:** As a presenter, I want demo question 4 to produce visible evidence, because the denial is
the point of the demo.

#### Acceptance Criteria

1. WHEN the line B inspector asks for line A data, THE trace SHALL show a Tool_Span with
   `inspection.decision = forbidden` for that user.
2. THAT Tool_Span SHALL carry the requesting user's ID and groups, and an empty effective-lines list.
3. THAT tool call SHALL also appear in the `forbidden` Saved_Query and in the Decision_Metric.
