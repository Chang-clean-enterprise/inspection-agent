# Browser-to-Runtime spike: can the browser call AgentCore Runtime directly?

| Field | Value |
|---|---|
| GitHub issue | #12 |
| Spike date | 2026-11-25 |
| Runtime stack probed | `inspection-agent-demo-runtime` |
| Calling Region | `us-west-2` |
| Tool used | `curl` (not a real browser — see [Method](#method) for why that is still decisive) |

## Question

Can a browser call the AgentCore Runtime's HTTPS invocation endpoint directly with a bearer token
(CORS, required headers, response format), or does it need a proxy (API Gateway + Lambda) that forwards
the user's own JWT unchanged?

## Method

All three probes used `curl` against the real invocation URL, built the same way `scripts/invoke.sh`
builds it:

```bash
RUNTIME_ARN=$(aws ssm get-parameter --region us-west-2 \
  --name /inspection-agent/demo/runtime/runtime-arn \
  --query Parameter.Value --output text)
ENCODED=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$RUNTIME_ARN")
URL="https://bedrock-agentcore.us-west-2.amazonaws.com/runtimes/$ENCODED/invocations?qualifier=DEFAULT"
```

A reader reproducing this needs only their own `$ENV` (default `demo`) and `$REGION` (default
`us-west-2`) substituted above, and AWS credentials able to read that one SSM parameter.

`curl` lets the exact HTTP semantics be observed regardless of what a real browser additionally
enforces. A real browser would refuse to even attempt the actual request if the preflight response were
wrong; `curl` lets us see the server's actual behavior directly, which is the more decisive test — if
`curl` shows the server already returning the right CORS headers unconditionally, a real browser gets
them too.

## Probe 1 — CORS preflight (no auth)

Command:

```bash
curl -sS -i -X OPTIONS "$URL" \
  -H "Origin: https://example.cloudfront.net" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization,content-type,x-amzn-bedrock-agentcore-runtime-session-id" \
  --max-time 15
```

Observed response:

```
HTTP/2 200
date: Wed, 25 Nov 2026 17:33:29 GMT
content-length: 0
x-amzn-requestid: 463c1fca-e9ac-487d-8155-1dfff09980dc
access-control-allow-origin: *
access-control-allow-headers: authorization,content-type,x-amzn-bedrock-agentcore-runtime-session-id
access-control-allow-methods: POST
access-control-expose-headers: smithy-protocol,baggage,WWW-Authenticate,Date,Mcp-Session-Id,X-Amzn-Trace-Id,X-Amzn-Bedrock-AgentCore-Runtime-Session-Id,Mcp-Protocol-Version,tracestate,x-amzn-ErrorMessage,traceparent,x-amzn-RequestId,x-amzn-ErrorType
access-control-max-age: 172800
```

No `Authorization` header was sent or needed for this probe — browsers never send custom headers,
including `Authorization`, on a CORS preflight `OPTIONS` request, by specification. The server answered
with a `200` and full CORS headers anyway, with `access-control-allow-headers` echoing back exactly the
three headers requested and `access-control-allow-methods: POST`.

## Probe 2 — real cross-origin POST, real token

A real Cognito access token for persona `supervisor` was obtained the same way `scripts/invoke.sh
--persona` obtains one (see `scripts/invoke.sh` and `docs/auth.md` section 7): SRP sign-in via
`pycognito.aws_srp.AWSSRP`, in a throwaway virtual environment, with the token read into a shell
variable only — never printed, never written to disk, never passed as a command-line argument, the same
hygiene rule `scripts/invoke.sh` already follows. A reader can reproduce this exactly by running
`scripts/invoke.sh --prompt "..." --persona supervisor` (which performs this sign-in internally and then
makes the same kind of call), or by adapting the SRP snippet in `scripts/invoke.sh` to capture `$TOKEN`
into their own shell for use in the command below.

Command (the token is piped via stdin to `-H @-` so it never appears in the process list, exactly like
`scripts/invoke.sh` does):

```bash
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -sS -i -X POST "$URL" \
  -H @- \
  -H "Origin: https://example.cloudfront.net" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  --data-binary "$BODY" \
  --max-time 30
```

where `$BODY` was `{"prompt": "What demo questions can you answer?", "session_id": "<uuid>"}` and
`$SESSION_ID` was that same uuid (at least 33 characters, per `scripts/invoke.sh`'s rule).

Observed response:

```
HTTP/2 200
date: Wed, 25 Nov 2026 17:35:13 GMT
content-type: application/json
x-amzn-requestid: 6188d76e-2147-439a-b2cb-975485fdc041
access-control-allow-origin: *
x-amzn-bedrock-agentcore-runtime-session-id: DBE3BAE8-6254-4A31-BA32-41DF15FE2571
access-control-expose-headers: smithy-protocol,baggage,WWW-Authenticate,Date,Mcp-Session-Id,X-Amzn-Trace-Id,X-Amzn-Bedrock-AgentCore-Runtime-Session-Id,Mcp-Protocol-Version,tracestate,x-amzn-ErrorMessage,traceparent,x-amzn-RequestId,x-amzn-ErrorType

{"answer": "I can answer questions about inspection data for manufacturing parts. ... What inspection data would you like to see? ...", "actions": [], "session_id": "DBE3BAE8-6254-4A31-BA32-41DF15FE2571", "trace_id": "6b071c472a0f77d509b6c1e57826f64b"}
```

(The full answer text is longer prose describing the agent's capabilities, abbreviated above with an
ellipsis.) The point is the shape: a single, complete, non-chunked JSON object, `content-type:
application/json`, with `access-control-allow-origin: *` present on the real data response — not only on
the preflight.

## Probe 3 — CORS on auth-error responses

Two sub-probes, same URL, same `Origin` header, no real token.

**(a) No `Authorization` header at all:**

```bash
curl -sS -i -X POST "$URL" \
  -H "Origin: https://example.cloudfront.net" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <uuid>" \
  --data-binary '{"prompt":"hi"}' \
  --max-time 15
```

Response: `HTTP/2 401`, `access-control-allow-origin: *`, body:

```json
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Missing Authentication Token"}}
```

**(b) A garbage `Authorization: Bearer not-a-real-token` header** (same command, with
`-H "Authorization: Bearer not-a-real-token"` added):

Response: `HTTP/2 403`, `access-control-allow-origin: *`, body:

```json
{"message":"OAuth authorization failed: Failed to parse token"}
```

Both error responses come from the custom JWT authorizer layer, which rejects the request *before* it
ever reaches the agent container — this is why their error shape (`jsonrpc`-wrapped, or a flat
`{"message":...}`) is different from this application's own error payloads in
`src/inspection_agent/entrypoint.py` (which are shaped `{"error":{"code":"...","message":"..."}}`). A
browser client must therefore extract a human-readable message from any of these shapes, not assume one.

## Decision

**Direct browser calls to the AgentCore Runtime invocation endpoint. No proxy, no API Gateway, no
Lambda.**

The CORS behavior shown above is a fixed property of the AWS-managed
`bedrock-agentcore.<region>.amazonaws.com` data plane itself, present unconditionally on this account's
deployed runtime with no configuration from this repository's templates — there is no CORS-related
property anywhere on the `AWS::BedrockAgentCore::Runtime` CloudFormation resource. One AWS
troubleshooting page recommends adding `CORSMiddleware` to a `BedrockAgentCoreApp`, but that applies to a
self-hosted or local-development container reached directly, a different code path entirely — it does
not apply to the managed `InvokeAgentRuntime` endpoint used here and should not be acted on for this
project.

## Consequences for the design

1. The UI's error handling must defensively extract a message from either error shape shown in
   [Probe 3](#probe-3--cors-on-auth-error-responses) (and from the application's own
   `{"error":{"code":...,"message":...}}` shape), never assuming one fixed structure.
2. `access-control-max-age: 172800` (two days) means a browser may cache the preflight result for a
   while — actual cap varies by browser (Chrome caps at 2 hours regardless of the header value) — so
   only the first request of a fresh browser session necessarily pays a preflight round trip.

## Follow-up re-confirmation

A later task (task 10 of this spec's `tasks.md`) re-runs these same three probes against the final
deployed state, using the live UI's own CloudFront origin as the `Origin` header value instead of the
`https://example.cloudfront.net` placeholder used above. That confirmation is appended below as a dated
entry once the UI itself is deployed — it is not a rewrite of the findings above.

### Follow-up entry — 2026-11-25, against the deployed UI

The UI stack (`inspection-agent-demo-ui`) deployed to `https://<cloudfront-domain>`. Probes 1
and 3 were re-run against the real invocation URL with `Origin: https://<cloudfront-domain>`
(the live site's real origin, not the `example.cloudfront.net` placeholder):

- Preflight: `HTTP/2 200`, `access-control-allow-origin: *`, same `access-control-allow-headers`,
  `access-control-allow-methods: POST`, `access-control-max-age: 172800` as before — unaffected by the
  `Origin` value, confirming the `*` wildcard behaves as documented.
- No-token POST: `HTTP/2 401`, `access-control-allow-origin: *`, same shape as the original probe 3(a).

Probe 2 (a real token, real cross-origin POST) was not repeated as a standalone `curl` call here — it
was instead confirmed more strongly: the deployed site was exercised end to end in a real browser,
signed in as each of the three personas, with real chat exchanges including the line B denial
scenario, all working as designed. That is a stronger confirmation than another `curl` probe would
have been, since it also exercises the browser's own CORS enforcement (not just the server's response
headers, which `curl` cannot fully validate by itself).

**Decision unchanged and now confirmed against the final deployed state.**
