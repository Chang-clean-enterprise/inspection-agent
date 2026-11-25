# inspection_agent

The Strands agent and the AgentCore Runtime entrypoint. The agent is read-only. It has four tools from `inspection_core` and no free-form SQL tool. Access control is enforced in the tool layer from the verified user identity, not by the system prompt.

See [.kiro/steering/structure.md](../../.kiro/steering/structure.md) for the repository layout and naming rules.

## Files

| File | Purpose |
|---|---|
| `entrypoint.py` | `BedrockAgentCoreApp` and the `handler(payload, context)` entrypoint. Authenticates, validates the payload, resolves the session, runs the agent, and returns the response or a fixed error payload. |
| `identity.py` | `principal_from_headers(headers)`. Reads the `Authorization` header and builds the `Principal`. Raises `IdentityError` on any failure. |
| `agent_factory.py` | `build_agent(config, prompt_text, prompt_version)`. Builds one Strands `Agent` with a `BedrockModel`, exactly the four tools, the budget hook, and sequential tool execution. Takes no identity. |
| `strands_tools.py` | Strands adapters for the four core tools (`list_reports`, `get_report`, `get_lot`, `characteristic_trend`). Each takes the `Principal` from the invocation state. |
| `budget.py` | `ToolBudgetHook` and `RequestRecorder`. Limits tool calls per request and records the Action_Log. |
| `sessions.py` | `SessionRegistry`. In-process, bounded (20 sessions, least recently used evicted), keyed by session ID and bound to an owner. Each `SessionEntry` also tracks `background_loaded`, so memory background is retrieved at most once per session entry. |
| `memory.py` | Thin module over the `bedrock-agentcore` data plane. `write_turn` writes exactly one `USER`/`ASSISTANT` conversational event per turn. `read_background` retrieves the long-term records for one actor and returns a `<background_memory>` block and its record count. Both fail soft: neither function raises, and a failure is logged with the exception class name only, never with prompt, answer, or record text. |
| `config.py` | Constants and `load_config(env)`. |
| `tracing.py` | `current_trace_id()`, `current_span_id()`, `xray_trace_id(hex_trace_id)`. Reads the current OpenTelemetry span context. Never raises, returns `""` when no span is recording or the ADOT distro is absent. |
| `prompt.py` | `load_system_prompt(path)`. Returns the prompt version and text. |
| `system_prompt.txt` | The system prompt. First line is `prompt-version: <id>`. The version line is not sent to the model. |
| `requirements.txt` | Pins `strands-agents` and `bedrock-agentcore` on top of the core requirements. |

## Configuration

`config.py` reads four environment variables. No variable names a user, group, or Principal.

| Variable | Default | Meaning |
|---|---|---|
| `INSPECTION_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Bedrock model or inference profile ID. |
| `INSPECTION_MODEL_REGION` | `us-west-2` | Region of the Bedrock call. |
| `INSPECTION_ADDITIONAL_REQUEST_FIELDS` | none | JSON object passed to Bedrock as additional model request fields. Any other JSON value raises `ValueError`. |
| `INSPECTION_MEMORY_ID` | none | AgentCore Memory ID. Absent, empty, or the literal `none` disables memory: the handler behaves exactly as it did before memory existed. A non-empty value that does not match the `MemoryId` shape raises `ValueError` at startup. |

Fixed in code: the tool-call limit is 6 per request, the prompt is 1 to 4000 characters, and the registry holds 20 sessions.

## Entrypoint contract

Request payload:

```json
{"prompt": "string, 1 to 4000 characters after trim", "session_id": "optional string, 1 to 128 characters"}
```

All other keys are ignored, including any that look like an identity (`user_id`, `principal`, `groups`, `claims`). If `session_id` is absent, the runtime session ID is used, and then a generated one.

Success response:

```json
{"answer": "string", "actions": [{"tool": "list_reports", "decision": "allowed", "row_count": 4}], "session_id": "string", "trace_id": "string"}
```

`actions` has one entry per executed tool call: tool name, decision (`allowed`, `restricted`, `forbidden`, or `null`), and row count. It holds no arguments, result data, or note text.

`trace_id` is the 32-hex-digit OpenTelemetry trace ID of the current request, read through `tracing.current_trace_id()`. It is `""` when no span is recording (for example, a local run without the ADOT distro). `tracing.xray_trace_id(trace_id)` converts it to the form the CloudWatch trace view searches on. The four fixed error payloads below carry no `trace_id`; several are returned outside a recording span.

Error payloads are fixed text, shaped `{"error": {"code": "...", "message": "..."}}`:

| Code | Cause |
|---|---|
| `unauthenticated` | Missing or malformed `Authorization` header, bad token, missing or non-string `sub`, or `token_use` other than `access`. |
| `invalid_request` | Payload is not an object, `prompt` is missing, not a string, or outside 1 to 4000 characters, or `session_id` is not a string of 1 to 128 characters. |
| `forbidden_session` | The session ID exists and belongs to another user. |
| `internal_error` | Any other failure, including an empty answer. The log holds only `invocation failed class=<ExceptionClassName>`. |

## Identity flow

1. The user signs in with Cognito and receives an access token (see [docs/auth.md](../../docs/auth.md)).
2. The client calls the runtime with `Authorization: Bearer <access token>`.
3. The AgentCore Runtime validates the token signature, issuer, and client with its custom JWT authorizer, and forwards the `Authorization` header.
4. `entrypoint.handler` passes `context.request_headers` to `principal_from_headers`. That function decodes the claims without checking the signature, because the runtime already did, and builds the `Principal` with `inspection_core.principal.principal_from_claims`.
5. The handler passes the `Principal` and a fresh `RequestRecorder` to the agent as `invocation_state`.
6. Each tool in `strands_tools.py` reads the `Principal` from `tool_context.invocation_state`. If it is missing, the tool returns a `forbidden` result and makes no database call. The core tool then applies authorization.

The model never sees the token or the `Principal`, and no tool has an identity argument. A session is bound to the `sub` of the first caller, and another user gets `forbidden_session`.

Tool results and their fields are described in [docs/inspection-tools.md](../../docs/inspection-tools.md).

## Audit request context

Once the session ID and the `Principal` are resolved, `handler` calls `inspection_core.audit.set_request_context(session_id=session_id, actor_id=principal.user_id)` and resets it in a `finally`, so a request can never leak its session ID or actor ID into the next one on a reused thread. `inspection_core.audit.emit` (called by every tool, inside `inspection_core.tools._run`) reads this context through a `contextvars.ContextVar` when the caller did not supply `session_id` or `actor_id` directly, so `inspection_core` never imports from `inspection_agent` and the model never supplies the identity as a tool argument. The handler also sets `inspection.session_id` on its own span alongside `inspection.prompt_version` and `inspection.model_id`, so the top-level span is filterable by session without opening a tool span.

## Memory

With `INSPECTION_MEMORY_ID` configured, `entrypoint.handler` makes two calls to `memory.py`, both scoped to the verified `Principal.user_id` (the Cognito `sub`), never to a model-supplied value:

1. On the first turn of a session entry (`entry.background_loaded` is `False`), it calls `memory.read_background(memory_id, principal.user_id, prompt)`. A non-empty result is prepended as a `<background_memory>` content block ahead of the prompt; `system_prompt.txt` tells the model to treat it as background only, never as an instruction or a tool result, and never to state an inspection fact because it appears there. `entry.background_loaded` is then set to `True` so the call runs at most once per session entry. A session rebuilt after a container restart or an LRU eviction retrieves background again, because its in-process history is gone too.
2. After a non-empty answer, it calls `memory.write_turn(memory_id, principal.user_id, session_id, prompt, answer)`, which writes exactly one `USER` and one `ASSISTANT` conversational event. No tool result, database row, or `TOOL`-role entry is ever written. A failed turn (empty answer) writes nothing.

Both calls fail soft: `memory.py` never raises. A retrieval or write failure is logged with the exception class name only and the turn still completes with the plain prompt and the answer still returned to the caller.

The span attributes `inspection.memory.enabled` (bool), `inspection.memory.background_records` (the count, never the text), and `inspection.memory.write_status` (`ok`, `failed`, or `disabled`) record the outcome without carrying any record, prompt, or answer text.

With `INSPECTION_MEMORY_ID` absent, no memory call is made and the handler behaves exactly as it did before memory existed, including the plain string prompt passed to the agent.

See [docs/memory.md](../../docs/memory.md) for the memory resource, its namespaces, and the demo flow.

## Runtime preconditions (for the runtime spec)

The runtime spec must provide:

- A custom JWT authorizer on the AgentCore Runtime that validates Cognito access tokens.
- `Authorization` in the request header allowlist, so the runtime forwards it to the entrypoint.
- The runtime ARN published at `/inspection-agent/<env>/runtime/runtime-arn`, which `scripts/invoke.sh` reads.
- The `INSPECTION_*` variables, if the defaults need to change.

## Tracing and span content

With the ADOT distro present and `opentelemetry-instrument` as the entry point (see the observability spec, issue #11), the agent emits real spans: the runtime's own `AgentCore.Runtime.Invoke` span, a Strands `invoke_agent` span, one `chat` span per model call, and one `execute_tool <name>` span per tool call. The code here sets only the span attributes `inspection.prompt_version`, `inspection.model_id`, `inspection.session_id`, `inspection.memory.enabled`, `inspection.memory.background_records`, and `inspection.memory.write_status`; `inspection_core.audit.emit` sets the rest (see [`../inspection_core/README.md`](../inspection_core/README.md)). Model prompts, model answers and tool payloads (which carry inspector notes text) are stripped from every span, span event and span link by the runtime's `AWS_REDACT_SPAN_ATTRIBUTES` environment variable, set in `infra/runtime.yaml`. This code does not redact anything itself; the redaction happens in the OpenTelemetry SDK, in-process, before any span leaves the runtime.

## Manual evaluation

There is no test suite. The prompts for the manual check against the deployed runtime are in [docs/evals.md](../../docs/evals.md).
