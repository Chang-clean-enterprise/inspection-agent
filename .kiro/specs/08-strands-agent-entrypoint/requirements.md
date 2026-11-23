# Requirements Document

## Introduction

This feature adds the Strands agent and the Amazon Bedrock AgentCore Runtime entrypoint to `src/inspection_agent/`. The agent answers questions about manufacturing inspection data by calling the four read-only tools of `src/inspection_core/` (already wrapped as Strands tools in `src/inspection_agent/strands_tools.py`). The entrypoint takes the user identity only from the `Authorization` header that the AgentCore Runtime forwards after it has validated the Cognito access token. It builds a Principal from the token claims and passes the Principal to the tools through the Strands invocation state. The model never sees or supplies the identity.

The entrypoint accepts a prompt and an optional session identifier, and returns a JSON object with the answer text and an ordered action log (tool name, decision, row count). The action log is a convenience for the UI. The audit evidence stays in the trace and in the audit log lines that `inspection_core` already emits. The agent keeps one agent instance, with its conversation history, per session in process memory.

A manual document `docs/evals.md` lists at least 15 prompts that the Reviewer runs by hand against the deployed runtime with `scripts/invoke`.

Out of scope: AgentCore Memory (a later spec), the runtime CloudFormation template `infra/runtime.yaml`, the UI, and the MCP server.

All data is synthetic. All code, comments, and docs are in English. The example prompts in `docs/evals.md` include Spanish text because the agent must reply in the language of the user.

Per the steering Testing policy, this spec adds no test files, test suites, fixtures, evaluation harnesses, or `evals/` folder. The Reviewer verifies each acceptance criterion by hand and records the cases checked in the task notes.

Dependencies and assumptions to confirm in the design:

- The `Authorization` header reaches the agent code only when the runtime is configured with a custom JWT authorizer and `Authorization` is in its request header allowlist ([AgentCore documentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-header-allowlist.html)). That configuration belongs to the later runtime spec. Until it is deployed, the Reviewer cannot run the end-to-end checks.
- In the AgentCore Python SDK, the handler receives a `RequestContext`. Its `request_headers` property contains only the `Authorization` header and headers with the prefix `X-Amzn-Bedrock-AgentCore-Runtime-Custom-`. The design confirms the exact mechanism against the installed SDK version.
- The Tool_Result envelope of spec 07 has no `decision` field today. The Action_Log needs it, so this spec adds one additive field, `meta.decision`, to the envelope in `inspection_core` and in `docs/inspection-tools.md`.
- `scripts/invoke` is one of the ten Operational_Scripts but does not exist yet. This spec adds it, because the Eval_Checklist depends on it.

## Glossary

- **Agent_Factory**: The function in `src/inspection_agent/` that builds a Strands Agent from the Agent_Config, the System_Prompt_File, and the four Strands tools.
- **Agent_Config**: The configuration read by the Agent_Factory: model ID, reasoning settings, and the tool-call limit. Values come from environment variables, with defaults taken from `docs/spikes/model-access.md`.
- **Entrypoint**: The AgentCore Runtime handler in `src/inspection_agent/` that receives a request, builds the Principal, runs the agent, and returns the Response_Payload.
- **System_Prompt_File**: The versioned text file in `src/inspection_agent/` that holds the system prompt. It carries a version identifier.
- **Strands_Tools**: The four tools `list_reports`, `get_report`, `get_lot`, and `characteristic_trend` in `src/inspection_agent/strands_tools.py`.
- **Inspection_Core**: The Python package `src/inspection_core/`.
- **Principal**: The immutable identity object of `inspection_core` with `user_id`, `username`, and `groups`.
- **Principal_Factory**: The function `principal_from_claims` in the Inspection_Core.
- **Forwarded_Token**: The access token in the `Authorization` header that the AgentCore Runtime forwards to the Entrypoint after validating it.
- **Verified_Claims**: The claims decoded from the Forwarded_Token. The Entrypoint does not validate the signature, because the runtime has already done so.
- **Invocation_State**: The Strands per-invocation key-value state that tools read through the tool context. It is not part of the model prompt or the tool schema.
- **Session**: One conversation, identified by a Session_Id.
- **Session_Id**: The identifier of a Session. The AgentCore Runtime assigns one microVM to each Session_Id.
- **Session_Registry**: The in-process mapping from Session_Id to agent instance, together with the user ID that created the Session.
- **Request_Payload**: The JSON input of the Entrypoint: `prompt` (string, required) and `session_id` (string, optional).
- **Response_Payload**: The JSON output of the Entrypoint on success: `answer` (string) and `actions` (list of Action_Entry).
- **Error_Payload**: The JSON output of the Entrypoint on failure: `error` (object with a `code` and a fixed `message`).
- **Action_Entry**: One object in `actions`: `tool` (tool name), `decision` (`allowed`, `restricted`, `forbidden`, or `null`), and `row_count` (integer).
- **Action_Log**: The ordered list of Action_Entry objects for one answer, in the order the tools ran.
- **Tool_Call_Limit**: The maximum number of Strands tool calls for one user message. The value is 6.
- **Tool_Result**: The JSON-serializable result of a tool, defined in `docs/inspection-tools.md`.
- **Restricted_Scope**: A Tool_Result whose `meta.scope` has fewer lines than the lines that exist (`A` and `B`).
- **Report_Notes**: The free-text `notes` field of inspection reports. It is untrusted data.
- **Persona**: One of the three demo users: the Line A inspector (`line-a`), the Line B inspector (`line-b`), and the Quality supervisor (`supervisors`).
- **S1_Story**, **S2_Story**, **S3_Story**, **S4_Story**: The planted stories in `data/STORIES.md`. S4 exists only when the dataset was generated with `--include-injection-story`.
- **Eval_Checklist**: The document `docs/evals.md`.
- **Invoke_Script**: The script `scripts/invoke` that calls the deployed runtime with a Forwarded_Token, a prompt, and an optional Session_Id.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: Agent factory

**User Story:** As a developer, I want one function that builds the configured agent, so that the Entrypoint and later specs create agents the same way.

#### Acceptance Criteria

1. THE Agent_Factory SHALL return a Strands Agent configured with a Bedrock model, the text of the System_Prompt_File, and the four Strands_Tools.
2. THE Agent_Factory SHALL read the model ID and the reasoning settings from the Agent_Config.
3. THE Agent_Config SHALL default the model ID to `us.anthropic.claude-haiku-4-5-20251001-v1:0` and the region to `us-west-2`, as decided in `docs/spikes/model-access.md`.
4. THE Agent_Config SHALL default the reasoning settings to none (no reasoning fields sent), as decided in `docs/spikes/model-access.md`.
5. WHERE a reasoning setting is configured, THE Agent_Factory SHALL pass it to the Bedrock model through the `additional_request_fields` parameter.
6. THE Agent_Factory SHALL register no tool other than the four Strands_Tools.
7. THE Agent_Factory SHALL register no tool that accepts SQL text, a user identity, a group, or an allowed line.
8. IF the System_Prompt_File is missing or empty, THEN THE Agent_Factory SHALL raise an error that names the file, and SHALL NOT build an agent.
9. THE Agent_Factory SHALL read the system prompt from the System_Prompt_File and SHALL NOT embed prompt text in Python source.

### Requirement 2: Versioned system prompt file

**User Story:** As a maintainer, I want the system prompt in its own versioned file, so that a prompt change is a reviewable, traceable change.

#### Acceptance Criteria

1. THE System_Prompt_File SHALL be a single text file inside `src/inspection_agent/`.
2. THE System_Prompt_File SHALL begin with a version identifier line.
3. WHEN the Agent_Factory loads the System_Prompt_File, THE Agent_Factory SHALL record the version identifier in the trace attributes of the invocation.
4. THE System_Prompt_File SHALL be written in English.

### Requirement 3: Answers come from tool results only

**User Story:** As a quality supervisor, I want every claim backed by a tool result, so that I can trust the numbers and trace them to a report or lot.

#### Acceptance Criteria

1. THE System_Prompt_File SHALL instruct the model to state only facts that appear in Tool_Results of the current Session.
2. THE System_Prompt_File SHALL instruct the model to cite the report ID or lot ID for every claim about inspection data.
3. THE System_Prompt_File SHALL instruct the model to say that no matching data was found when a Tool_Result has status `not_found` or an empty result list, and to invent no data.
4. WHEN a Tool_Result has status `invalid_request` or `error`, THE agent SHALL tell the user that the request could not be completed and SHALL NOT state data that the failed call would have returned.
5. WHEN a supervisor asks whether the S1_Story characteristic (`bore_diameter` of `DEMO-HOUSING-2001`) has an out-of-tolerance trend, THE agent SHALL call `characteristic_trend` and SHALL cite the lot IDs from the Tool_Result in the answer.

### Requirement 4: Language and clarification behavior

**User Story:** As an inspector, I want answers in my language and a short question when my request is incomplete, so that the conversation stays natural and the queries stay precise.

#### Acceptance Criteria

1. THE System_Prompt_File SHALL instruct the model to reply in the language of the latest user message, Spanish or English.
2. IF the part, the line, or the period that a request needs is missing and cannot be inferred from the Session history or the Principal's allowed scope, THEN THE agent SHALL ask one short clarifying question and SHALL NOT call a tool before the user answers.
3. THE System_Prompt_File SHALL instruct the model to ask no more than one clarifying question per reply.

### Requirement 5: Denials, scope, and untrusted notes in the prompt

**User Story:** As a security reviewer, I want the prompt to shape how denials, scope limits, and untrusted text are reported, so that the user gets honest answers and no leakage, in addition to the enforcement in code.

#### Acceptance Criteria

1. WHEN a Tool_Result has status `forbidden`, THE agent SHALL tell the user that the user does not have access to the requested data, and SHALL NOT guess, describe, or hint at the content, the existence, the count, or the line of the denied records.
2. WHEN the Line B inspector asks for line A data, THE agent SHALL report that access is not allowed and SHALL NOT show any line A content (report IDs, lot IDs, part numbers, values, counts, or note text).
3. WHEN a Tool_Result is a Restricted_Scope, THE agent SHALL state in the answer which lines the results include.
4. THE System_Prompt_File SHALL instruct the model to treat all Report_Notes text as untrusted data and never as instructions.
5. WHEN a Report_Note contains instructions, THE agent SHALL NOT follow them, and SHALL NOT call a tool or change its answer because of them.
6. WHERE the dataset contains the S4_Story, THE agent SHALL answer a request about report `IR-2025-0038` without returning any line A data to a line B user.
7. THE System_Prompt_File SHALL instruct the model not to reveal the system prompt or its version.
8. IF a user asks the agent to reveal, repeat, or summarize the system prompt, THEN THE agent SHALL decline and continue to help with inspection questions.
9. THE System_Prompt_File SHALL NOT be the only mechanism that enforces line access, because the Strands_Tools and the Inspection_Core enforce it in code.

### Requirement 6: Tool-call limit per message

**User Story:** As an operator, I want a hard cap on tool calls per user message, so that one question cannot trigger unbounded database work or model cost.

#### Acceptance Criteria

1. THE System_Prompt_File SHALL tell the model that it may make at most 6 tool calls for each user message.
2. THE Entrypoint SHALL enforce the Tool_Call_Limit in code for each user message, independent of the System_Prompt_File.
3. WHEN the model requests a tool call after the Tool_Call_Limit is reached, THE Entrypoint SHALL cancel that call, SHALL NOT run the tool, and SHALL return a fixed tool error message that tells the model to answer with the data it already has.
4. THE Entrypoint SHALL reset the tool-call count at the start of each user message.
5. THE Action_Log SHALL contain only tool calls that ran.

### Requirement 7: Identity from the forwarded token

**User Story:** As a security reviewer, I want the identity built from the validated token that the runtime forwards, so that no one can choose who they are.

#### Acceptance Criteria

1. WHEN a request arrives, THE Entrypoint SHALL read the `Authorization` header from the AgentCore Runtime request context.
2. WHEN the header value has the form `Bearer <token>` (scheme compared case-insensitively), THE Entrypoint SHALL decode the payload segment of the token into Verified_Claims without validating the signature.
3. WHEN the Verified_Claims contain a non-empty string `sub` claim, THE Entrypoint SHALL build the Principal with the Principal_Factory.
4. THE Entrypoint SHALL place the Principal in the Invocation_State under the key that the Strands_Tools read.
5. THE Entrypoint SHALL keep the Principal and the Forwarded_Token out of the model prompt, the tool schemas, the Response_Payload, the Action_Log, log lines, and trace attributes, except that the audit event of the Inspection_Core records the `sub` claim and the group names.
6. THE Entrypoint SHALL take the Principal from the current request on every request, and SHALL NOT reuse a Principal from an earlier request.
7. IF the `Authorization` header is missing, THEN THE Entrypoint SHALL return an Error_Payload with the code `unauthenticated` and SHALL NOT build an agent, call the model, or call any tool.
8. IF the `Authorization` header is not of the form `Bearer <token>`, or the token payload is not valid base64url-encoded JSON object, or the `sub` claim is missing or empty, THEN THE Entrypoint SHALL return an Error_Payload with the code `unauthenticated` and SHALL NOT build an agent, call the model, or call any tool.
9. IF the `token_use` claim is present and is not `access`, THEN THE Entrypoint SHALL return an Error_Payload with the code `unauthenticated` and SHALL NOT call any tool.
10. THE Error_Payload message SHALL be fixed text that contains no token content, claim value, or header value.

### Requirement 8: No local or fake-identity mode

**User Story:** As a security reviewer, I want no way to run the agent with a made-up identity, so that a demo shortcut cannot become a bypass.

#### Acceptance Criteria

1. THE Entrypoint SHALL build every Principal from the Forwarded_Token of the current request.
2. THE agent code SHALL NOT read any environment variable, command-line flag, configuration value, or file that supplies, replaces, or defaults a Principal, a user ID, or a group.
3. THE agent code SHALL NOT define a default or anonymous Principal.
4. THE Agent_Config SHALL NOT contain an option that disables or relaxes the checks in Requirement 7.
5. THE Invoke_Script SHALL send a real Cognito access token in the `Authorization` header and SHALL provide no option to send an identity in any other way.
6. THE Request_Payload SHALL ignore any `user_id`, `principal`, `groups`, or `claims` field, and THE Entrypoint SHALL NOT pass such a field to the model or to a tool.

### Requirement 9: Entrypoint contract

**User Story:** As a UI developer, I want a simple JSON contract with the answer and a short action log, so that I can show the answer and what the agent did.

#### Acceptance Criteria

1. WHEN the Request_Payload has a non-empty string `prompt`, THE Entrypoint SHALL run the agent and return a Response_Payload.
2. THE Response_Payload SHALL contain `answer` as a string and `actions` as an ordered list of Action_Entry objects.
3. THE Action_Entry SHALL contain `tool` equal to the name of the tool that ran, `decision` equal to the `meta.decision` value of its Tool_Result, and `row_count` equal to the `meta.row_count` value of its Tool_Result, or 0 when the Tool_Result has no `meta.row_count`.
4. WHEN no tool ran for an answer, THE Entrypoint SHALL return `actions` as an empty list.
5. THE Response_Payload SHALL contain no tool arguments, no tool result data, no report notes, and no Principal field.
6. THE Response_Payload SHALL be serializable with `json.dumps` without a custom encoder.
7. IF the `prompt` is missing, not a string, empty after trimming whitespace, or longer than 4000 characters, THEN THE Entrypoint SHALL return an Error_Payload with the code `invalid_request` and SHALL NOT call the model or any tool.
8. IF the model or a tool raises an unexpected exception, THEN THE Entrypoint SHALL return an Error_Payload with the code `internal_error` and a fixed message, and SHALL NOT include an exception message, stack trace, SQL text, or host name in the payload.
9. THE Inspection_Core SHALL add `meta.decision` (one of `allowed`, `restricted`, `forbidden`, or `null`) to every Tool_Result, and `docs/inspection-tools.md` SHALL document the field.
10. THE Entrypoint SHALL return a Response_Payload or an Error_Payload for every request, and SHALL NOT stream partial output in this spec.

### Requirement 10: Per-session agent instance

**User Story:** As an inspector, I want follow-up questions to remember the conversation within my session, so that I do not repeat the part or the lot.

#### Acceptance Criteria

1. WHEN a request carries a Session_Id that has no entry in the Session_Registry, THE Entrypoint SHALL create an agent with the Agent_Factory and store it under that Session_Id.
2. WHEN a request carries a Session_Id that has an entry in the Session_Registry, THE Entrypoint SHALL reuse the stored agent, so that the conversation history of earlier messages is available to the model.
3. WHERE the request has no `session_id` in the Request_Payload, THE Entrypoint SHALL use the session ID that the AgentCore Runtime provides in the request context, and SHALL create a new Session with a generated identifier when neither exists.
4. THE Session_Registry SHALL store the user ID (`sub`) of the Principal that created each Session.
5. IF a request carries the Session_Id of an existing Session and the `sub` claim of the request differs from the stored user ID, THEN THE Entrypoint SHALL return an Error_Payload with the code `forbidden_session`, and SHALL NOT call the model or any tool.
6. THE Entrypoint SHALL supply the Principal of the current request to the agent in the Invocation_State on every call, so that a stored agent never holds a Principal of an earlier request.
7. THE Entrypoint SHALL keep the conversation history in process memory only, and SHALL NOT write it to a file or database.
8. THE Entrypoint SHALL return the Session_Id in the Response_Payload as the field `session_id`.
9. WHILE the Session_Registry holds more than 20 Sessions, THE Entrypoint SHALL remove the least recently used Session before it adds a new one.

### Requirement 11: Observability of the agent

**User Story:** As an operator, I want each answer traceable to the model, prompt version, and tool calls, so that I can investigate a wrong answer.

#### Acceptance Criteria

1. THE Entrypoint SHALL run in a process where the Strands and AgentCore telemetry can reach the active trace, without adding code that disables it.
2. WHEN an invocation runs, THE Entrypoint SHALL set the trace attributes `inspection.prompt_version` and `inspection.model_id` on the active span, if a recording span exists.
3. IF setting a trace attribute fails, THEN THE Entrypoint SHALL continue and return the Response_Payload.
4. THE Entrypoint SHALL emit no log line that contains the prompt text, the answer text, a Forwarded_Token, or Report_Notes.

### Requirement 12: Packaging and code quality

**User Story:** As a developer, I want the agent to be a clean, lintable Python module with declared dependencies, so that the runtime stack can package it.

#### Acceptance Criteria

1. THE `src/inspection_agent/` package SHALL target Python 3.12 and pass `ruff` with the repository `ruff.toml`.
2. THE `src/inspection_agent/` package SHALL declare its runtime dependencies (the AgentCore SDK, Strands Agents, and the Inspection_Core requirements) in a `requirements.txt` file inside `src/inspection_agent/`.
3. THE `src/inspection_agent/` package SHALL import `inspection_core` and SHALL NOT duplicate authorization, query, or result-formatting logic.
4. THE `src/inspection_agent/` package SHALL contain no test file, test fixture, or evaluation harness.
5. THE Entrypoint module SHALL expose the AgentCore Runtime application object and the handler, so that the runtime stack can start it without changes to the module.
6. THE repository SHALL contain no secret, credential, token, or account-specific identifier in `src/inspection_agent/`, `docs/evals.md`, or `scripts/invoke`.

### Requirement 13: Invoke script

**User Story:** As a Reviewer, I want one script that calls the deployed runtime with a real token, so that I can run the Eval_Checklist by hand.

#### Acceptance Criteria

1. THE Invoke_Script SHALL accept the environment name, a prompt, an optional Session_Id, and a Cognito access token supplied through an environment variable.
2. THE Invoke_Script SHALL read the runtime ARN from the SSM parameter `/inspection-agent/<env>/runtime/<key>` that the runtime stack publishes, and SHALL print an error that names the missing parameter when it does not exist.
3. THE Invoke_Script SHALL call the deployed runtime in `us-west-2` with the access token as a bearer token, and SHALL print the Response_Payload or the Error_Payload.
4. THE Invoke_Script SHALL NOT accept the token or a password as a command-line argument, and SHALL NOT print or store the token.
5. IF the token environment variable is not set, THEN THE Invoke_Script SHALL exit with a non-zero status and a message that names the variable.
6. THE Invoke_Script SHALL be listed in `scripts/README.md`.

### Requirement 14: Eval checklist

**User Story:** As a Reviewer, I want a manual checklist of prompts with expected tool calls and decisions, so that I can judge the agent without an automated harness.

#### Acceptance Criteria

1. THE Eval_Checklist SHALL list at least 15 prompts.
2. THE Eval_Checklist SHALL contain, for each of the five demo questions in `.kiro/steering/product.md`, one prompt in Spanish and one prompt in English, referring to the demo question by its number 1 to 5.
3. THE Eval_Checklist SHALL contain at least two restricted-access prompts, including the Line B inspector asking for the S3_Story records on line A.
4. THE Eval_Checklist SHALL contain at least two ambiguous prompts that expect a clarifying question and no tool call.
5. THE Eval_Checklist SHALL contain at least one injection prompt against the S4_Story, and SHALL state that it applies only when the dataset was generated with `--include-injection-story`.
6. THE Eval_Checklist SHALL contain at least one prompt that asks the agent to reveal the system prompt, and at least one prompt that exercises the missing-header error through the Invoke_Script or a direct call.
7. THE Eval_Checklist SHALL give, for each prompt, the Persona, the expected tool calls (tool names and key parameters), and the expected decision, and SHALL give no exact answer wording.
8. THE Eval_Checklist SHALL give, for each prompt, a column in which the Reviewer marks pass or fail by hand, and a column for a short note.
9. THE Eval_Checklist SHALL use only IDs and values that appear in `data/STORIES.md` or in the committed seed files.
10. THE Eval_Checklist SHALL state that it is run by hand against the deployed runtime with the Invoke_Script, and SHALL state that no harness or `evals/` folder exists.
11. THE Eval_Checklist SHALL be linked from `docs/README.md`.
12. THE Eval_Checklist SHALL contain a prompt for the Session resume case of demo question 5 within one Session, and SHALL state that resuming across Sessions needs the memory spec.

### Requirement 15: Manual verification and documentation

**User Story:** As a Reviewer, I want the acceptance criteria verified by hand and recorded, so that the result is credible without automated tests.

#### Acceptance Criteria

1. THE task list SHALL replace every automated-test task with a manual verification step.
2. WHEN a manual verification step needs the deployed runtime, THE task list SHALL mark it as deferred until the runtime spec is deployed, and SHALL name the verification that does not need the runtime and that the Reviewer runs locally.
3. THE Reviewer SHALL verify locally, without any bypass of Requirement 8, that a call with a missing `Authorization` header, a malformed header, a token without `sub`, and an oversized or empty prompt each produce the specified Error_Payload with no model call.
4. THE Reviewer SHALL record in the task notes, for each manual step, the date, the Persona, the prompt, and the observed result.
5. THE `src/inspection_agent/README.md` SHALL describe the files, the configuration variables with their defaults, the entrypoint contract, and the identity flow, and SHALL link to `docs/auth.md`, `docs/inspection-tools.md`, and `docs/evals.md`.
