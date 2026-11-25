# Requirements Document

## Introduction

This feature gives the agent short-term memory inside a session and long-term memory across sessions, isolated per user. It adds the template `infra/memory.yaml`, a thin memory module in `src/inspection_agent/`, the operator script `scripts/memory-inspect.sh`, and the document `docs/memory.md`.

Memory keys are taken only from the verified user identity. The actor ID is the Cognito `sub` of the validated token, and the session ID is the runtime session ID. The model never supplies either one.

Long-term records are background, not truth. Every inspection fact is read again through the tools, so the authorization in `src/inspection_core/authorizer.py` applies to each answer.

Out of scope: the tools, the UI, the MCP server, and the observability stack.

Facts found in the repository while writing these requirements (the design confirms them):

- `infra/pre-runtime.yaml` already has a `MemoryId` parameter, a `HasMemory` condition, a conditional `Memory` IAM statement with seven actions, and publishes `/inspection-agent/<env>/pre-runtime/memory-id` with the sentinel `none` when empty.
- `infra/runtime.yaml` already sets `INSPECTION_MEMORY_ID` when the memory-id SSM value is not `none`. No Python code reads that variable today.
- `scripts/deploy.sh` already has step 7 (`deploy memory`), step 8 (pre-runtime with the resolved memory ID plus `require_param`), and step 9 (runtime plus `require_resolved`). `scripts/teardown.sh` already lists `memory`. Neither needs a change for the deploy order.
- `src/inspection_agent/sessions.py` keeps history only in memory, in a bounded LRU of 20 Strands agents. History is lost on eviction, on a new session, and on a cold container.
- `bedrock-agentcore==1.27.0` is already pinned in `src/inspection_agent/requirements.txt`, and `boto3==1.44.9` in `src/inspection_core/requirements.txt`. No new dependency is needed.
- The testing policy forbids test files. Every acceptance criterion in this document is verified by hand.

## Glossary

- **Memory_Stack**: The CloudFormation stack `inspection-agent-<env>-memory`, defined in `infra/memory.yaml`.
- **Memory_Resource**: The `AWS::BedrockAgentCore::Memory` resource in the Memory_Stack.
- **Memory_Template**: The file `infra/memory.yaml`.
- **Memory_Module**: The file `src/inspection_agent/memory.py`.
- **Inspect_Script**: The script `scripts/memory-inspect.sh`, Operational_Script number 9.
- **Actor_ID**: The Cognito `sub` of the validated token, carried as `Principal.user_id`.
- **Session_ID**: The session identifier resolved by the entrypoint, from the payload, the runtime session header, or a generated UUID.
- **Short_Term_Event**: One `CreateEvent` call holding exactly two conversational messages, the user message and the assistant answer of one turn.
- **Long_Term_Record**: A memory record produced asynchronously by a memory strategy and stored under a namespace.
- **Summary_Strategy**: The `SummaryMemoryStrategy` of the Memory_Resource, with the namespace template `/summaries/{actorId}/{sessionId}/`.
- **Facts_Strategy**: The `SemanticMemoryStrategy` of the Memory_Resource, with the namespace template `/facts/{actorId}/`.
- **Background_Block**: The `<background_memory>` text block that the entrypoint prepends to the first user message of a session.
- **Extraction_Delay**: The time between a Short_Term_Event and the moment its Long_Term_Records can be retrieved.
- **Execution_Role**: The IAM role `inspection-agent-<env>-runtime-exec`, defined in `infra/pre-runtime.yaml`.
- **Memory_Doc**: The document `docs/memory.md`.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: Memory resource in CloudFormation

**User Story:** As an operator, I want the memory resource defined in CloudFormation, so that it is created, updated, and deleted with the rest of the infrastructure.

#### Acceptance Criteria

1. THE Memory_Template SHALL define exactly one Memory_Resource and SHALL follow every rule in `docs/cloudformation-conventions.md`.
2. THE Memory_Template SHALL expose the event expiry as a parameter with a `Description` and a numeric constraint.
3. THE Memory_Resource SHALL declare the Summary_Strategy and the Facts_Strategy, and each namespace template SHALL contain `{actorId}`.
4. THE Memory_Template SHALL publish the memory ID as the SSM parameter `/inspection-agent/<env>/memory/memory-id`.
5. THE Memory_Template SHALL declare outputs for the memory ID and the memory ARN, each with a `Description`.
6. THE Memory_Template SHALL pass `cfn-lint` with zero errors and zero warnings.
7. WHEN the Memory_Stack is deployed after the runtime stack, THEN the deploy entry point SHALL update the pre-runtime stack with the resolved memory ID and SHALL then update the runtime stack so it reads the new value.

### Requirement 2: Keys

**User Story:** As a security reviewer, I want memory keys taken only from the verified identity, so that a user cannot address another user's memory.

#### Acceptance Criteria

1. THE Memory_Module SHALL take the Actor_ID only from `Principal.user_id`.
2. THE Memory_Module SHALL take the Session_ID only from the session identifier that the entrypoint already resolved.
3. THE Memory_Module SHALL NOT accept an actor ID or a session ID from the request payload or from a model argument.
4. THE Memory_Module SHALL reject an Actor_ID that does not match a conservative identifier pattern, before it is placed in a namespace path.

### Requirement 3: Short-term memory

**User Story:** As a presenter, I want each turn stored as an event, so that long-term extraction has something to work with.

#### Acceptance Criteria

1. WHEN a turn completes with an answer, THE entrypoint SHALL write one Short_Term_Event for the Actor_ID and the Session_ID.
2. THE Short_Term_Event SHALL contain exactly two conversational messages: the user message with role `USER` and the assistant answer with role `ASSISTANT`.
3. THE Short_Term_Event SHALL NOT contain a raw tool result, a database row, a tool-use block, or any identity field other than the Actor_ID.
4. WHEN a turn ends without an answer, THE entrypoint SHALL write no Short_Term_Event.
5. THE Memory_Module SHALL truncate a message text that exceeds its documented limit before it is sent.

### Requirement 4: Long-term memory

**User Story:** As a user, I want the agent to pick up the topic of my earlier sessions, so that I do not have to repeat myself.

#### Acceptance Criteria

1. WHEN the first turn of a session runs and a memory ID is configured, THE entrypoint SHALL retrieve Long_Term_Records for the Actor_ID from the Summary_Strategy and the Facts_Strategy namespaces.
2. THE entrypoint SHALL give the retrieved text to the model as a Background_Block, marked as background and not as instructions.
3. THE system prompt SHALL instruct the model to treat the Background_Block as background only, never to state an inspection fact because it appears there, and to read the data again with the tools.
4. THE entrypoint SHALL retrieve Long_Term_Records at most once per session entry.
5. WHEN no Long_Term_Record is found, THE entrypoint SHALL send the user message unchanged.
6. THE Memory_Module SHALL limit the Background_Block by record count, by per-record length, and by total length.

### Requirement 5: Isolation

**User Story:** As a security reviewer, I want one user's memory to be unreachable from another user's session, so that the demo claim holds.

#### Acceptance Criteria

1. THE namespace of every long-term strategy SHALL contain the Actor_ID.
2. THE Memory_Module SHALL retrieve only from namespace paths built from the Actor_ID of the current request.
3. THE Execution_Role SHALL grant only the memory actions that the agent calls, on the single configured memory resource.
4. WHEN the Inspect_Script runs for one actor, THE Inspect_Script SHALL list that actor's records only.
5. THE Reviewer SHALL verify isolation by hand with two actors using the Inspect_Script, and the design SHALL record the result.

### Requirement 6: Timing

**User Story:** As a presenter, I want to know how long extraction takes, so that the rehearsal and the demo account for it.

#### Acceptance Criteria

1. THE design SHALL state the expected Extraction_Delay before the first deploy.
2. THE Reviewer SHALL measure the real Extraction_Delay in the account.
3. THE Memory_Doc and `docs/runtime.md` SHALL record the measured Extraction_Delay.
4. THE Memory_Doc SHALL describe a demo flow that accounts for the Extraction_Delay.

### Requirement 7: Operator script

**User Story:** As a presenter, I want one command that shows an actor's memory, so that I can confirm memory is ready before the demo.

#### Acceptance Criteria

1. THE Inspect_Script SHALL accept one actor, either as a persona name or as an actor ID, and SHALL reject both given together.
2. THE Inspect_Script SHALL list the actor's Short_Term_Events and Long_Term_Records.
3. THE Inspect_Script SHALL read the memory ID from `/inspection-agent/<env>/memory/memory-id` and SHALL stop with a clear message when it is missing or `none`.
4. THE Inspect_Script SHALL read only. It SHALL create, update, and delete nothing.
5. THE Inspect_Script SHALL follow the conventions of the existing Operational_Scripts: bash 3.2, `set -Eeuo pipefail`, validation before any AWS call, exit 2 for a usage error and exit 3 for a missing SSM parameter.

### Requirement 8: Failure behavior

**User Story:** As a presenter, I want a memory outage to degrade the demo, not break it, so that the talk continues.

#### Acceptance Criteria

1. IF a memory call fails, THEN THE entrypoint SHALL answer from the session history and SHALL NOT return an error to the caller.
2. IF a memory call fails, THEN THE entrypoint SHALL record a warning in the log and an attribute in the trace.
3. THE warning SHALL contain no record content, no prompt text, no answer text, and no token.
4. WHEN no memory ID is configured, THE agent SHALL behave exactly as it did before this feature.
