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
| `sessions.py` | `SessionRegistry`. In-process, bounded (20 sessions, least recently used evicted), keyed by session ID and bound to an owner. |
| `config.py` | Constants and `load_config(env)`. |
| `prompt.py` | `load_system_prompt(path)`. Returns the prompt version and text. |
| `system_prompt.txt` | The system prompt. First line is `prompt-version: <id>`. The version line is not sent to the model. |
| `requirements.txt` | Pins `strands-agents` and `bedrock-agentcore` on top of the core requirements. |

## Configuration

`config.py` reads three environment variables. No variable names a user, group, or Principal.

| Variable | Default | Meaning |
|---|---|---|
| `INSPECTION_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Bedrock model or inference profile ID. |
| `INSPECTION_MODEL_REGION` | `us-west-2` | Region of the Bedrock call. |
| `INSPECTION_ADDITIONAL_REQUEST_FIELDS` | none | JSON object passed to Bedrock as additional model request fields. Any other JSON value raises `ValueError`. |

Fixed in code: the tool-call limit is 6 per request, the prompt is 1 to 4000 characters, and the registry holds 20 sessions.

## Entrypoint contract

Request payload:

```json
{"prompt": "string, 1 to 4000 characters after trim", "session_id": "optional string, 1 to 128 characters"}
```

All other keys are ignored, including any that look like an identity (`user_id`, `principal`, `groups`, `claims`). If `session_id` is absent, the runtime session ID is used, and then a generated one.

Success response:

```json
{"answer": "string", "actions": [{"tool": "list_reports", "decision": "allowed", "row_count": 4}], "session_id": "string"}
```

`actions` has one entry per executed tool call: tool name, decision (`allowed`, `restricted`, `forbidden`, or `null`), and row count. It holds no arguments, result data, or note text.

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

## Runtime preconditions (for the runtime spec)

The runtime spec must provide:

- A custom JWT authorizer on the AgentCore Runtime that validates Cognito access tokens.
- `Authorization` in the request header allowlist, so the runtime forwards it to the entrypoint.
- The runtime ARN published at `/inspection-agent/<env>/runtime/runtime-arn`, which `scripts/invoke.sh` reads.
- The `INSPECTION_*` variables, if the defaults need to change.

## Open question for the observability spec

Whether trace content (tool results with report notes) is captured in traces is not decided here. The agent sets only the span attributes `inspection.prompt_version` and `inspection.model_id`.

## Manual evaluation

There is no test suite. The prompts for the manual check against the deployed runtime are in [docs/evals.md](../../docs/evals.md).
