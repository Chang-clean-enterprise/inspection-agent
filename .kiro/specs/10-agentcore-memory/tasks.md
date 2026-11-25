# Implementation Plan: AgentCore Memory

## Overview

This plan adds Amazon Bedrock AgentCore Memory to the inspection agent: the template `infra/memory.yaml`, a thin memory module in `src/inspection_agent/`, the operator script `scripts/memory-inspect.sh`, and the document `docs/memory.md`. The design uses Python 3.12, bash 3.2 and CloudFormation YAML, so no language question applies. The design has no Correctness Properties section, so there are no property test tasks.

The workspace testing policy forbids test files, suites, fixtures, eval harnesses and verification scripts. Every verification task below is a manual step. Each one ends with a note that records what was checked and the real result. Record those notes in this file under the task, and the deploy and timing results also in `docs/memory.md` and `docs/runtime.md`.

Order of work: template, local code, operator script, static checkpoint, deploy, behavior verification, then the documents.

Each task carries a tag. `[implementer]` tasks need only files and local commands. `[main]` tasks touch AWS, need credentials, or need the user.

## Tasks

- [x] 1. [implementer] Write the memory template and trim the memory IAM statement
  - [x] 1.1 [implementer] Write `infra/memory.yaml`
    - Parameters `Env` (String, `demo`, `^[a-z][a-z0-9]{0,9}$`) and `EventExpiryDays` (Number, 30, `MinValue: 7`, `MaxValue: 365`), each with a `Description`.
    - `Memory` (`AWS::BedrockAgentCore::Memory`): `Name: !Sub inspection_agent_${Env}`, `EventExpiryDuration: !Ref EventExpiryDays`, `Description`, and `MemoryStrategies` with `SummaryMemoryStrategy` (`Name: SessionSummary`, `NamespaceTemplates: ["/summaries/{actorId}/{sessionId}/"]`) and `SemanticMemoryStrategy` (`Name: ActorFacts`, `NamespaceTemplates: ["/facts/{actorId}/"]`). No `MemoryExecutionRoleArn`. Tags in map form.
    - `MemoryIdParameter` (`AWS::SSM::Parameter`): `/inspection-agent/${Env}/memory/memory-id`, value `!GetAtt Memory.MemoryId`, with a `Description` and tags.
    - Outputs `MemoryId` and `MemoryArn`, each with a `Description`, no `Export`.
    - Follow `docs/cloudformation-conventions.md`, all 10 rules. Mirror the style of `infra/auth.yaml`.
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

  - [x] 1.2 [implementer] Trim the `Memory` statement in `infra/pre-runtime.yaml`
    - Reduce the action list of the conditional `Memory` statement to `bedrock-agentcore:CreateEvent` and `bedrock-agentcore:RetrieveMemoryRecords`. Keep the `Sid`, the `HasMemory` condition, and the resource unchanged.
    - Change nothing else in the template. Do not touch `infra/network.yaml`.
    - _Requirements: 5.3_

  - [x] 1.3 [implementer] Lint both templates
    - Run `uvx --from "cfn-lint==1.60.1" cfn-lint infra/memory.yaml infra/pre-runtime.yaml`. Expect zero errors and zero warnings.
    - Check `infra/memory.yaml` against the 10 rules in `docs/cloudformation-conventions.md`, one rule at a time, and fix gaps by hand.
    - Record the lint output in the task notes.
    - _Requirements: 1.6_

    Note (2026-11-24): `uvx --from "cfn-lint==1.60.1" cfn-lint infra/memory.yaml infra/pre-runtime.yaml` printed nothing and exited 0, so zero errors and zero warnings on both templates. Run twice: once by the implementer and once in the main session. `infra/memory.yaml` was checked against the 10 conventions rules one at a time; rule 5 does not apply because the template has no IAM resource, and the `MemoryIdParameter` is the literal producer example of rule 10. The `infra/pre-runtime.yaml` diff removes exactly 5 actions (`GetEvent`, `ListEvents`, `ListSessions`, `ListMemoryRecords`, `GetMemoryRecord`) and leaves the `Sid`, the `HasMemory` condition and the `Resource` untouched. `infra/network.yaml` was not changed.

- [x] 2. [implementer] Add memory to the agent code
  - [x] 2.1 [implementer] Write `src/inspection_agent/memory.py`
    - Module docstring stating that identity comes only from the verified `Principal`, that no tool result is ever written, and that no function raises.
    - Constants `SUMMARY_NAMESPACE_PATH`, `FACTS_NAMESPACE_PATH`, `TOP_K = 5`, `MAX_RECORD_CHARS = 400`, `MAX_BACKGROUND_CHARS = 2000`, `MAX_EVENT_TEXT_CHARS = 4000`, and an actor ID pattern.
    - Lazily built, locked, cached `boto3.client("bedrock-agentcore", region_name=...)`, Region from `AWS_REGION` with the `us-west-2` fallback, following the pattern in `src/inspection_core/db.py`.
    - `write_turn(memory_id, actor_id, session_id, prompt, answer) -> bool`: validates the IDs, builds a payload with exactly two conversational entries (`USER` then `ASSISTANT`), truncates each text to `MAX_EVENT_TEXT_CHARS`, calls `create_event`. No metadata, no branch, no blob, no `TOOL` role.
    - `read_background(memory_id, actor_id, query) -> tuple[str, int]`: validates the actor ID, calls `retrieve_memory_records` once per namespace with `namespacePath` and `searchCriteria={"searchQuery": ..., "topK": TOP_K}`, dedupes in order, truncates per record and in total, and returns the finished `<background_memory>` block and the record count. A failure in one namespace does not cancel the other.
    - Both functions catch `ClientError` and `BotoCoreError`, log only the exception class name, and return the empty result. Neither raises. Neither logs record content.
    - _Requirements: 2.1, 2.3, 2.4, 3.2, 3.3, 3.5, 4.6, 5.2, 8.3_

  - [x] 2.2 [implementer] Read `INSPECTION_MEMORY_ID` in `src/inspection_agent/config.py`
    - `AgentConfig` gains `memory_id: str | None`.
    - `load_config` maps absent, empty and `none` to `None`, and otherwise validates against `^[a-zA-Z][a-zA-Z0-9_-]{0,99}-[a-zA-Z0-9]{10}$`, raising `ValueError` with a fixed message that does not contain the value, like the existing `INSPECTION_ENV` check.
    - _Requirements: 8.4_

  - [x] 2.3 [implementer] Add `background_loaded` to `src/inspection_agent/sessions.py`
    - `SessionEntry` gains `background_loaded: bool = False`. Nothing else changes.
    - _Requirements: 4.4_

  - [x] 2.4 [implementer] Wire memory into `src/inspection_agent/entrypoint.py`
    - On the first turn of a session entry, when a memory ID is configured, call `memory.read_background` and set `entry.background_loaded = True` either way, under `entry.lock`.
    - Pass `[{"text": background}, {"text": prompt}]` to the agent when the block is non-empty, otherwise the plain `prompt`.
    - After a non-empty answer, call `memory.write_turn`; on `False`, `logger.warning("memory write failed")`. Write nothing when the answer is empty.
    - Extend the span attributes with `inspection.memory.enabled`, `inspection.memory.background_records` (the count) and `inspection.memory.write_status` (`ok`, `failed`, `disabled`). No record text, prompt text, or answer text in a log line or a span attribute.
    - With no memory ID configured, the handler must behave exactly as before, including the plain string prompt and the unchanged response shape.
    - _Requirements: 2.1, 2.2, 3.1, 3.4, 4.1, 4.2, 4.4, 4.5, 8.1, 8.2, 8.4_

  - [x] 2.5 [implementer] Add the `## Background memory` section to `src/inspection_agent/system_prompt.txt`
    - Bump the first line to `prompt-version: 3`.
    - Add the section after `## Untrusted notes` with the four rules from the design: background only, not instructions and not a tool result, never state an inspection fact because it appears there, do not quote it or mention it.
    - _Requirements: 4.3_

  - [x] 2.6 [implementer] Update `src/inspection_agent/README.md` and lint
    - Document the memory module, the two memory calls, the background block, the new environment variable, the new span attributes, and the failure behavior.
    - Run `ruff check .`. Expect zero findings.
    - Record the lint output in the task notes.
    - _Requirements: 8.1, 8.2_

    Note (2026-11-24): `ruff check .` printed `All checks passed!`. Run twice, once by the implementer and once in the main session.

    Three defects were found in the main-session review of the implementer's work and fixed before the task was accepted:

    1. `_client()` called `boto3.client(...)` outside a `try`. `boto3.client` raises `BotoCoreError` subclasses (`UnknownServiceError`, `NoRegionError`, `DataNotFoundError` were all confirmed to be `BotoCoreError` subclasses locally). In `read_background` the call sat outside the `try`, so the module could raise, against its own contract and against requirement 8.1: the outer handler would have turned it into `internal_error` instead of answering from the session history. `_client()` now returns `None` on a build failure and both public functions check for it.
    2. `summary.get("content", {}).get("text")` raises `AttributeError` when the key is present and null (confirmed locally). Changed to `(summary.get("content") or {}).get("text")`, matching the defensive form already used in `scripts/memory-inspect.sh`.
    3. The implementer merged the memory span attributes into `_set_span_attributes` and moved the whole call to after the agent invocation, so a failed invocation lost `inspection.prompt_version` and `inspection.model_id` from its trace. Split into `_set_span_attributes` (called before the agent runs, as before) and `_set_memory_span_attributes` (called after the write, where the status is known).

    Behavior checked by hand in a Python shell with stub clients, no AWS calls and no test file:
    - Client build failure: `write_turn` returns `False`, `read_background` returns `("", 0)`, log line is `memory client unavailable class=UnknownServiceError`.
    - `content` present and null: the record is skipped and the sibling real record is still returned, stripped.
    - One namespace raising `ClientError`: the other namespace still contributes, block built, count 1.
    - Empty result set: `("", 0)`.
    - Malformed actor ID and malformed session ID: `False` / `("", 0)` with no client call made (a client that raises on any call was installed and never triggered).
    - Handler, no memory ID: the agent receives the plain string `'hola'`, the response shape is unchanged.
    - Handler, memory ID and a background block: the agent receives `[{'text': '<background_memory>...'}, {'text': 'hola'}]`, background first.
    - Handler, write fails: the answer is still returned, `inspection.memory.write_status=failed`, warning `memory write failed` logged.
    - Requirement 4.4: two turns in one session called `read_background` exactly once; turn 1 received the block and turn 2 the plain prompt.
    - No log line or span attribute carried prompt text, answer text, or record text in any of the above.

- [x] 3. [implementer] Write the operator script
  - [x] 3.1 [implementer] Write `scripts/memory-inspect.sh`
    - Bash 3.2, `set -Eeuo pipefail`, header comment with usage and exit codes, `usage()` heredoc to stderr, `die()`, section banners, validation before any AWS call. Mirror `scripts/invoke.sh`.
    - Options `--env`, `--region`, `--persona`, `--actor`, `--session`, `--query`, `--max-events`. Exactly one of `--persona` and `--actor`; both or neither is exit 2.
    - Read `/inspection-agent/<env>/memory/memory-id`: exit 3 when the parameter is missing, exit 1 naming `make deploy-memory` when the value is `none`.
    - `--persona` resolves the Cognito `sub` with `aws cognito-idp admin-get-user`, using the pool ID from SSM and the same fixed persona email table as `invoke.sh`.
    - Short-term: `list-sessions` for the actor (or the single `--session`), then `list-events --include-payloads` per session, printing timestamp, role and truncated text.
    - Long-term: `retrieve-memory-records` with the exact `--namespace` form, `/facts/<actor>/` and `/summaries/<actor>/<session>/` per session. Do not use `--namespace-path`: the installed AWS CLI 2.31.22 does not expose it (see the design Research record). Build `--search-criteria` with `python3 -c 'import json...'`.
    - Print a closing summary: actor, session count, event count, record count per namespace.
    - Read only. No create, update, or delete call. No test or assertion logic.
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 5.4_

  - [x] 3.2 [implementer] Wire the script and check it locally
    - Add a `memory-inspect` target to the `Makefile` plus a help line. The `deploy-%` and `delete-%` pattern rules already cover `make deploy-memory` and `make delete-memory`.
    - Mark Operational_Script 9 as implemented in `scripts/README.md`.
    - Run `bash -n scripts/memory-inspect.sh`. Run it with no actor option, with both actor options, and with an invalid `--env`, and confirm each exits 2 before any AWS call.
    - Record the checks in the task notes.
    - _Requirements: 7.1, 7.5_

    Note (2026-11-24): `bash -n scripts/memory-inspect.sh` exits 0. The three validation checks each exit 2 before any AWS call:
    - no actor option: `Exactly one of --persona or --actor is required.`
    - both actor options: `Both --persona and --actor are present. Use exactly one of them.`
    - `--env BAD_ENV`: the standard invalid-env message with the pattern.
    A fourth check, `--actor 'bad id!'`, also exits 2 on the actor pattern.

    One defect was found in the main-session review and fixed before the task was accepted: `SESSION_ID_PATTERN` was `^[A-Za-z0-9][A-Za-z0-9_]{0,99}$`, which excludes the hyphen. `scripts/invoke.sh` generates session IDs with `uuidgen`, which produces hyphenated values such as `CD34466B-527D-4F7D-8083-9C4B66E93D8B`, and the service `SessionId` pattern is `[a-zA-Z0-9][a-zA-Z0-9-_]*` (read from the local botocore model). So `--session <any real session ID>` would have exited 2, which is the exact path the presenter uses. The pattern is now `^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$` with a comment giving the reason. After the fix, a hyphenated session ID passes validation and reaches the AWS call (exit 3, memory-id parameter not found, because the memory stack is not deployed yet).

    Also changed: the closing summary counted conversational messages but labelled them `events=`. A turn writes two messages, so the number would have misled the presenter. It is now `messages=`, which doubles as a check that each turn wrote exactly two.

    The AWS-calling paths are not exercised here. They run in tasks 5 and 6.

- [x] 4. [main] Checkpoint - Review the static work
  - Review the diff. Run `ruff check .`, `uvx --from "cfn-lint==1.60.1" cfn-lint infra/memory.yaml infra/pre-runtime.yaml`, and `bash -n scripts/memory-inspect.sh`. Confirm no test file was created. Ask the user if questions arise before the first deploy.

  Note (2026-11-24): the full diff of all three implementer tasks was reviewed in the main session. Four defects were found and fixed; they are recorded under tasks 2.6 and 3.2. Final state:
  - `ruff check .` → `All checks passed!`
  - `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` → no output, exit 0 (all 6 templates, not only the two changed).
  - `bash -n` on all 7 scripts in `scripts/` → all ok.
  - `git status --short` shows 8 modified and 4 untracked paths, and no file whose name contains `test`, `spec_`, `conftest` or `pytest`. No test file, suite, fixture, eval harness or verification script was created.

- [x] 5. [main] Deploy the memory stack and wire it to the runtime
  - [x] 5.1 [main] Deploy and inspect
    - Confirm the target account and Region with the user before running anything.
    - Run `make deploy-memory`. Expect `CREATE_COMPLETE`, the memory in a usable status, and `/inspection-agent/demo/memory/memory-id` published.
    - Run `aws bedrock-agentcore-control get-memory` and confirm both strategies exist with the namespace templates from the design, and that the event expiry matches `EventExpiryDays`.
    - Record the memory ID shape (not the value), the strategy IDs, and the status in the task notes.
    - _Requirements: 1.1, 1.3, 1.4_

    Note (2026-11-24, us-west-2, Env=demo): `make deploy-memory` created `inspection-agent-demo-memory` on the first try, no rollback. `get-memory` reports `status: ACTIVE` and `eventExpiryDuration: 30`, matching the `EventExpiryDays` default. Both strategies exist with the namespace templates unchanged from the template:
    - `ActorFacts`, type `SEMANTIC`, namespace `/facts/{actorId}/`
    - `SessionSummary`, type `SUMMARIZATION`, namespace `/summaries/{actorId}/{sessionId}/`

    The memory ID is 32 characters and matches `^inspection_agent_demo-[a-zA-Z0-9]{10}$`, so `Name` plus the service-generated 10-character suffix, as the `MemoryId` pattern expects. The value and the two strategy ID suffixes are account-specific and are deliberately not written down here. `/inspection-agent/demo/memory/memory-id` was published and holds that value.

  - [x] 5.2 [main] Pass the memory ID to the pre-runtime and runtime stacks
    - Run `scripts/deploy.sh deploy pre-runtime --param MemoryId=<memory-id>`, then **`make package`**, then `scripts/deploy.sh deploy runtime`. Expect the built-in `require_param` and `require_resolved` checks of `deploy-all` to hold when run by hand too.
    - The `make package` step is required and easy to miss. This spec changes the agent code (`memory.py`, `entrypoint.py`, `config.py`, `sessions.py`, `system_prompt.txt`). Without a fresh package the runtime would get `INSPECTION_MEMORY_ID` but keep the old code that ignores it, and every check in task 6 would fail for the wrong reason. Confirm the new package has a different SHA-256 from the deployed one, since the source changed.
    - Confirm `aws bedrock-agentcore-control get-agent-runtime` now lists `INSPECTION_MEMORY_ID` with the memory ID, for 8 environment variables in total.
    - Read the deployed execution role policy and confirm the `Memory` statement holds exactly `CreateEvent` and `RetrieveMemoryRecords` on the one memory ARN.
    - This closes the open item in `docs/runtime.md` section 10 about the `memory-id` update once a memory stack exists. Record whether CloudFormation re-resolved the SSM-typed `MemoryId` on the runtime stack update.
    - Record the results in the task notes.
    - _Requirements: 1.7, 5.3_

    Note (2026-11-24): the three steps ran in order and all checks passed.
    - `scripts/deploy.sh deploy pre-runtime --param MemoryId=<memory-id>`: `UPDATE_COMPLETE`. The stack parameter `MemoryId` equals the SSM value, so the `require_param` check of `deploy-all` holds when the step is run by hand.
    - `make package`: produced SHA-256 `e6dabadd...` against the previously deployed `1592ea05...`, confirming the new agent code is in the package. 35,460,933 bytes zipped and 81,197,729 unzipped, both inside the limits.
    - `scripts/deploy.sh deploy runtime`: `UPDATE_COMPLETE`.

    **This closes the open item in `docs/runtime.md` section 10.** The runtime stack's SSM-typed `MemoryId` has `ResolvedValue` equal to the memory stack's published ID after the update, so CloudFormation does re-resolve an `AWS::SSM::Parameter::Value<String>` parameter on a stack update. That was recorded as unverified at the end of spec 09 and is now verified.

    `get-agent-runtime` shows 8 environment variables, one more than before: `AWS_REGION`, `INSPECTION_DB_HOST`, `INSPECTION_DB_SECRET_ARN`, `INSPECTION_ENV`, `INSPECTION_LOG_LEVEL`, `INSPECTION_MEMORY_ID`, `INSPECTION_MODEL_ID`, `INSPECTION_MODEL_REGION`. `INSPECTION_MEMORY_ID` equals the memory stack's ID. No variable holds a secret value.

    The deployed execution role's `Memory` statement holds exactly two actions, `bedrock-agentcore:CreateEvent` and `bedrock-agentcore:RetrieveMemoryRecords`, on a resource ending in `memory/<memory-id>`. A grep of the whole inline policy finds no other `bedrock-agentcore:` action, so the five removed read actions are gone from the deployed role and not only from the template.

- [x] 6. [main] Verify deployed behavior by hand
  - [x] 6.1 [main] Verify continuity across sessions
    - As `supervisor`, run a first session with a fresh session ID and ask a demo question that names a part and a lot. Wait for extraction (task 6.3 measures how long).
    - Run a second session with a different fresh session ID and ask a follow-up that names no part and no lot.
    - Confirm the answer continues the topic and that `actions` is non-empty, so the data was read again through the tools and not recalled from memory.
    - Record the two prompts, the continuation evidence, and the `actions` entries in the task notes.
    - _Requirements: 4.1, 4.2, 4.3, 4.5_

    Note (2026-11-25): PASS, after one prompt fix recorded below.

    Session 1 (`B4518CA3-...`), supervisor, two turns using the real `data/STORIES.md` data:
    - "Is there an out-of-tolerance trend for the bore_diameter characteristic on part DEMO-HOUSING-2001?" -> `characteristic_trend`, 5 rows, rising trend 25.001 to 25.021, matching S1 exactly.
    - "Summarize the findings of lot LOT-20250617-01." -> `get_lot`, 3 rows, `IR-2025-0041` 25.021 and `IR-2025-0042` 25.024 both failing, matching S1 exactly.

    Session 2, a different fresh session ID, prompt naming no part and no lot: "What part were we looking at? Give me the current numbers." The agent answered `DEMO-HOUSING-2001` / `bore_diameter` and called `characteristic_trend` (5 rows, decision `allowed`) in the same reply. Repeated once more with another fresh session ID, same result. So the topic carried across sessions and the data was re-read through the tools, where `authorizer.decide` runs again.

    **Defect found and fixed during this task.** On the first attempt the agent broke two rules of the `## Background memory` prompt section. It opened with "Based on the background notes from your earlier sessions", which the section forbids, and in one run it recited the trend and the 25.02 mm upper limit straight from the block with `actions: []`, no tool call at all. The second breach is the serious one: it states inspection facts from stale memory instead of from a re-authorized tool call, which is exactly what the issue's acceptance criterion rules out. The prompt section was rewritten to say that the block carries only the subject, that no ID, value, mean, count, limit, status or disposition from it may be stated, that a reply referring back to earlier work must call the tool in the same reply, and that the words "background notes", "earlier sessions" and "from memory" must not appear. `prompt-version` stays 3, since 3 was never deployed in its first form for longer than this check. After repackaging and redeploying, both re-tests passed with a tool call and no mention of the block.

  - [x] 6.2 [main] Verify isolation between two actors
    - Run `scripts/memory-inspect.sh --persona inspector-a` and `--persona inspector-b` and confirm the two outputs are disjoint, with no record of one actor appearing for the other.
    - Hold a short conversation as `inspector-a`, wait for extraction, then open a new session as `inspector-b` and ask an open question. Confirm no trace of the `inspector-a` topic appears.
    - Record both results in the task notes and copy the conclusion into the design under the isolation requirement.
    - _Requirements: 5.1, 5.2, 5.4, 5.5_

    Note (2026-11-25): PASS.

    `scripts/memory-inspect.sh` was run for all three personas. Each resolved a distinct Cognito `sub` and returned only its own data:

    | Persona | sessions | messages | facts | summaries |
    |---|---|---|---|---|
    | supervisor | 2 | 6 | 1 | 4 |
    | inspector-a | 1 | 2 | 0 | 1 |
    | inspector-b | 0 | 0 | 0 | 0 |

    `inspector-b` returned zero of everything while the other two actors held records, which is the clearest form of the check. Record text was also dumped per actor and compared: the supervisor's records concern `DEMO-HOUSING-2001` and line B lots, `inspector-a`'s concern `DEMO-SHAFT-3001` and `LOT-20250604-01` on line A, and no record text appears under more than one actor.

    Behavioral check: a fresh `inspector-b` session asked "What were we discussing previously?" and answered "I have no record of previous messages in this conversation", with no trace of either other actor's part, lot or line, and `actions: []`.

    Finding recorded, not a failure of this requirement: the `SummaryMemoryStrategy` records are far richer than the design first assumed. They contain markdown tables with report IDs, measured values, limits and dispositions, verbatim. Per-actor isolation is unaffected and holds. What this changes is the severity of the group-change limit, so the design's Error Handling section was corrected to withdraw its "topics, not data sets" claim and state the real content.

  - [x] 6.3 [main] Measure the extraction delay
    - Note the time of a completed turn, then poll `scripts/memory-inspect.sh` until `/facts/<actor>/` and `/summaries/<actor>/<session>/` both return records.
    - Record the elapsed time for each namespace, and whether the two differ.
    - _Requirements: 6.2_

    Note (2026-11-25): measured by polling `retrieve-memory-records` every 20 seconds from the moment session 1's second turn returned.

    | Namespace | Populated after |
    |---|---|
    | `/facts/<actor>/` | **50 s** |
    | `/summaries/<actor>/<session>/` | **71 s** |

    Both are in the same order of magnitude as the 60-second sleep in the AWS worked example, with summaries trailing facts by about 20 seconds. Short-term events, by contrast, were visible immediately: `memory-inspect` run seconds after the turn already listed all 6 messages, because `create_event` is synchronous and the entrypoint waits for it.

    For the demo this means roughly 90 seconds of margin, not 60. The flow in `docs/memory.md` uses that number.

    Observation worth recording: the `SEMANTIC` strategy produced only one weak record for the supervisor, "The user requested inspection reports for part PN-1002 on line A in October 2025", from a throwaway first question. Continuity in task 6.1 was actually driven by the `SUMMARIZATION` records, not the semantic ones. The semantic strategy extracts what the user asked rather than domain facts about the data. Both strategies are kept, since the issue asks for both, but the summary strategy is the one carrying the demo.

  - [x] 6.4 [main] Verify what the events contain
    - Run `aws bedrock-agentcore list-events --include-payloads` for one session and read the full payloads.
    - Confirm every entry is `conversational` with role `USER` or `ASSISTANT`, that no `TOOL` role, no `blob`, no `json` entry, no tool result and no database row appears, and that exactly two messages were written per turn.
    - Record the check and the message count in the task notes.
    - _Requirements: 3.1, 3.2, 3.3_

    Note (2026-11-25): PASS.

    `list-events --include-payloads` for session `B4518CA3-...` returned 2 events for the 2 turns. Each event has exactly 2 payload entries. Across every entry the only payload key is `conversational`, and the roles are exactly `USER`, `ASSISTANT`, `USER`, `ASSISTANT`. No `blob` entry, no `json` entry, no `TOOL` role, no `OTHER` role.

    The full JSON was also scanned for signatures of raw tool output and database rows: `row_count`, `"decision"`, `effective_lines`, `meta":`, `toolUse`, `toolResult`, `report_id"`, `lot_id"`, `characteristic_id`, `"status": "allowed`, `measurements"`. None were found. Report IDs do appear inside the assistant's prose answer, which is correct: that is the answer the user received, not a tool result.

  - [x] 6.5 [main] Verify the failure behavior
    - Make a memory call fail without breaking the stack, for example by pointing `INSPECTION_MEMORY_ID` at a well-formed memory ID the execution role does not cover, through a temporary `pre-runtime` parameter change and a runtime deploy.
    - Confirm the invoke still returns HTTP 200 with an answer, that the runtime log holds the warning, and that the warning contains no prompt text, no answer text, no record text and no token.
    - Restore the real memory ID and confirm memory works again.
    - Record the checks and the restore in the task notes.
    - _Requirements: 8.1, 8.2, 8.3_

    Note (2026-11-25): PASS.

    The runtime was pointed at `inspection_agent_demo-ZZ0000000Z`, a well-formed ID (it passes the `config.py` pattern, so the container starts) for a memory that does not exist, through `deploy pre-runtime --param MemoryId=...` and a runtime deploy.

    A supervisor invoke then asked for lot `LOT-20250617-01`. Result: **HTTP 200 with a correct, complete answer** from `get_lot` (3 rows), so the turn was served from the session history and the tools while both memory calls were failing. Requirement 8.1 holds.

    The runtime log for that window holds exactly four memory lines and nothing else:
    - `memory retrieve failed class=ResourceNotFoundException` (twice, one per namespace, so a failure in one namespace did not cancel the other)
    - `memory write failed class=ResourceNotFoundException` (from `memory.py`)
    - `memory write failed` (from `entrypoint.py`)

    The log window was searched for `LOT-20250617`, `25.021`, `DEMO-HOUSING`, `IR-2025`, `Summarize the findings`, `bore_diameter`, `Bearer` and `eyJ`. The token and prompt signatures gave zero hits. The data signatures did hit, and were traced to their source: they come from the pre-existing `inspection_core.audit` structured event, one JSON line per tool call, introduced in spec 07 and unchanged here. No memory warning carries record text, prompt text, answer text or a token, so requirement 8.3 holds.

    The real memory ID was then restored on both stacks and `INSPECTION_MEMORY_ID` was confirmed to equal the memory stack's ID again. A follow-up invoke retrieved background normally, confirming the restore.

- [x] 7. [main] Write the documents
  - [x] 7.1 [main] Write `docs/memory.md`
    - Sections: the memory resource and its two strategies, the keys and namespaces, what is and is not written as an event, the retrieval and the background block, the failure behavior, the measured extraction delay from task 6.3, the demo flow that accounts for it, `memory-inspect` usage, the isolation verification result from task 6.2, the known limit about group changes over time, and teardown.
    - Write in English. Link it from `docs/README.md` if that file lists documents.
    - _Requirements: 6.3, 6.4, 5.5_

    Note (2026-11-25): `docs/memory.md` written with 12 sections: the resource and its two strategies, the keys, what is and is not written as an event, what is read and how the block reaches the model, deploy, permissions, timing with the demo flow, `memory-inspect`, failure behavior, the verification result table, known gaps, and teardown. Linked from `docs/README.md`. Four known gaps are recorded, the first being the corrected statement that long-term records carry inspection data rather than topics. All account-specific values are placeholders; a grep for the real actor IDs, the account ID and a real memory ID across `docs/`, `infra/`, `src/`, `scripts/` and this spec folder matched only `inspection_agent_demo-XXXXXXXXXX` in the docs and the deliberately fake `inspection_agent_demo-ZZ0000000Z` in task 6.5's note.

  - [x] 7.2 [main] Update `docs/runtime.md`
    - Record the measured extraction delay.
    - Update section 10 to close the open item about the `memory-id` update, with the result from task 5.2.
    - Add `INSPECTION_MEMORY_ID` to the described environment variables as now read by the agent, and link `docs/memory.md`.
    - _Requirements: 6.3, 1.7_

    Note (2026-11-25): `docs/runtime.md` updated in four places. Section 2 now says `INSPECTION_MEMORY_ID` is read by `config.py` since spec 10 and describes the absent/empty/`none` and malformed cases. Section 4 "Adding the memory ID" now states the SSM re-resolution is verified rather than unverified, adds the missing `make package` step, and links `docs/memory.md`. Section 10 moves the `memory-id` update and the code update out of "still open" into a closed list with their results, leaving only `pre-runtime` teardown open, and records the 50 s / 71 s extraction delay.

- [x] 8. [main] Final checkpoint - Confirm everything is verified
  - Run `ruff check .` and cfn-lint once more. Confirm each verification task has a note with a real result. Run `git status` and confirm no test file exists. Ask the user if questions arise.

  Note (2026-11-25): final state.
  - `ruff check .` -> `All checks passed!`
  - `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` -> no output, exit 0, all 6 templates.
  - `bash -n` on all 7 scripts -> ok.
  - `git status --short` -> no file whose name contains `test`, `conftest` or `pytest`. No test file, suite, fixture, eval harness or verification script was created anywhere in this spec.
  - Every verification task (1.3, 2.6, 3.2, 4, 5.1, 5.2, 6.1 to 6.5, 7.1, 7.2) carries a note with a real observed result.
  - Five defects were found in main-session review and fixed during the spec: three in the agent code (client build outside the try, null `content` crash, span attributes moved after the model call), one in the operator script (session ID pattern rejected the hyphenated IDs that `invoke.sh` generates), and one in the deployed prompt (the model named the background block and recited values from it without a tool call). One design claim was corrected against the evidence. All are recorded under their tasks.
  - AWS left in its intended state: the memory stack exists, `pre-runtime` and `runtime` hold the real memory ID, and the runtime runs the final package.

## Notes

- No task creates a test file, suite, fixture, eval harness or verification script. `scripts/memory-inspect.sh` is Operational_Script 9 from `.claude/rules/scripts.md`: it reads and prints, and asserts nothing.
- `scripts/deploy.sh` and `scripts/teardown.sh` need no change. The memory step, the pre-runtime update and the runtime re-read already exist as steps 7, 8 and 9 of `deploy-all`, and `memory` is already in the teardown sequence.
- `infra/network.yaml` is not changed. Its AgentCore endpoint policy is broader than the execution role, and an endpoint policy grants nothing by itself.
- Deploying tasks (5, 6) change real AWS resources in `us-west-2`. Confirm the target account before running them.
- Task 6.1 depends on task 6.3 in practice: run one conversation, measure the delay, then use that delay when planning the second session.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "2.1", "3.1"] },
    { "id": 1, "tasks": ["1.3", "2.2", "2.3", "2.5"] },
    { "id": 2, "tasks": ["2.4", "3.2"] },
    { "id": 3, "tasks": ["2.6"] },
    { "id": 4, "tasks": ["4"] },
    { "id": 5, "tasks": ["5.1"] },
    { "id": 6, "tasks": ["5.2"] },
    { "id": 7, "tasks": ["6.3"] },
    { "id": 8, "tasks": ["6.1", "6.4"] },
    { "id": 9, "tasks": ["6.2"] },
    { "id": 10, "tasks": ["6.5"] },
    { "id": 11, "tasks": ["7.1", "7.2"] },
    { "id": 12, "tasks": ["8"] }
  ]
}
```
