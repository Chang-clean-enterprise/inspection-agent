# Design Document

## Overview

GitHub issue: #12

This design adds a static chat UI hosted on S3 and CloudFront, signing users in with Cognito and
talking to the already-deployed AgentCore Runtime directly from the browser.

The issue opens with a spike on the one architectural fork that matters: can the browser reach the
Runtime's HTTPS endpoint directly, or does it need a thin proxy that forwards the user's JWT unchanged?
This was answered empirically during planning, against the real deployed runtime, with three HTTP
probes (full detail in the Research record and in `docs/spikes/browser-to-runtime.md`):

1. An `OPTIONS` preflight (no auth, a cross-origin `Origin` header, and the exact three headers the UI
   needs) returned `200` with `access-control-allow-origin: *`.
2. A real cross-origin `POST`, with a genuine Cognito access token, returned `200` with
   `access-control-allow-origin: *` and the full JSON answer.
3. The same CORS header was present on `401` (missing token) and `403` (garbage token) responses too.

**Decision: direct browser calls, no proxy.** This is a fixed property of the AWS-managed
`bedrock-agentcore.<region>.amazonaws.com` data plane, not something this repository's infrastructure
configures and not something agent code needs to add. The AWS doc that mentions adding `CORSMiddleware`
to a `BedrockAgentCoreApp` is scoped to a self-hosted/local-dev container reached directly; it was a
red herring during research and does not apply to the managed `InvokeAgentRuntime` endpoint.

Deliverables:

| File | Change |
|---|---|
| `docs/spikes/browser-to-runtime.md` | New. The spike write-up, with the real evidence, reproduced once more for a clean record. |
| `infra/ui.yaml` | New. Private S3 bucket, CloudFront distribution with Origin Access Control, a response headers policy (security headers and CSP), SPA-style error mapping, the two SSM parameters `scripts/deploy.sh` step 12 already reads. |
| `ui/index.html`, `ui/app.js`, `ui/styles.css` | New. One page, no build step: PKCE sign-in, chat, action log, New Conversation. |
| `scripts/deploy.sh` | Changed. A `ui_parameters` branch and a post-deploy step for the `ui` component: build the runtime config, sync the site, invalidate the cache. |
| `docs/ui.md` | New. Sign-in, the CSP, the action log's scope, the persona switcher, deploy/update, known gaps. |
| `docs/README.md` | Changed (small). Index entry. |

Out of scope: voice, file upload, response streaming, multi-language UI chrome.

`Makefile`, `scripts/teardown.sh`, and `COMPONENTS` in `scripts/deploy.sh` need no change: `ui` is
already wired into all three (teardown position 2 of 9, `deploy_all` steps 11–12, the `deploy-%`/
`delete-%` pattern rules).

### Key decisions

| # | Decision | Reason |
|---|---|---|
| 1 | Direct browser → Runtime calls. No API Gateway, no Lambda. | The spike above. |
| 2 | No custom domain, no ACM certificate, no Route 53. CloudFront's default `*.cloudfront.net` domain, already HTTPS with a valid AWS-managed certificate. | Demo scope. A custom domain needs an ACM certificate in `us-east-1` (CloudFront's fixed region for certificates) and a hosted zone, for no benefit here. |
| 3 | `infra/ui.yaml` derives its own callback and logout URLs from its own `Distribution.DomainName` and takes neither as a parameter. | `scripts/deploy.sh` already reads exactly `/inspection-agent/<env>/ui/callback-url` and `.../logout-url` at step 12 and feeds them to the `auth` stack update. This requires zero change to that existing code. The one-way dependency (ui never reads from auth in the template) is the same shape spec 04 already used to avoid a CloudFormation cycle. |
| 4 | `infra/ui.yaml` *does* read `/inspection-agent/<env>/auth/hosted-ui-domain` and `.../app-client-id` as ordinary `AWS::SSM::Parameter::Value<String>` parameters, to build the CSP's `connect-src`. | Both are fixed at `auth`'s first deploy (step 2, `demo` env default) and never change afterward — only the `CallbackURLs`/`LogoutURLs` list changes at step 12. `ui` deploys at step 11, after `auth` already exists, so there is no ordering problem. |
| 5 | SPA fallback via `CustomErrorResponses`: `403`→`/index.html`/`200`, `404`→`/index.html`/`200`. No CloudFront Function, no Lambda@Edge. | The private bucket plus Origin Access Control returns `403` for any request path that is not a real object key, such as `/callback`. Mapping both codes straight to `index.html` with `200` is the standard static-SPA pattern and needs no extra compute, matching the issue's "no framework build step" default. |
| 6 | No JS framework, no bundler, no npm. `index.html` plus same-origin `app.js`/`styles.css`. No inline `<script>` or `<style>`. | Matches the issue's stated default. Keeps the CSP free of `unsafe-inline`/`unsafe-eval`. PKCE needs only `crypto.subtle.digest` and `crypto.randomUUID`, both in every current browser over HTTPS. |
| 7 | Markdown rendering: a small, hand-written safe subset (bold, italics, inline code, bullet/numbered lists, pipe tables, line breaks) rather than vendoring `marked` + `DOMPurify`. All HTML-significant characters are escaped first; the renderer emits only a fixed, small tag whitelist it constructs itself. | Zero dependencies, consistent with the rest of the repository (no `npm`, no vendored JS anywhere yet). A real agent answer captured during the spike already needed exactly this subset: bold section headers, a pipe table, bullet lists. Never sets `innerHTML` from the unescaped model string. |
| 8 | Tokens and the PKCE verifier live in `sessionStorage` only, never `localStorage`, never a URL or query string. | Literal requirement. `sessionStorage` is cleared when the tab closes but survives a page refresh, which matters for a demo; a pure in-memory store would log the user out on every refresh. |
| 9 | The session ID is a client-generated `crypto.randomUUID()`, sent identically in the request body's `session_id` field and the `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header. | Matches `scripts/invoke.sh` exactly. `entrypoint.py`'s own resolution order prefers the body value over the header-derived one, so sending the same value in both avoids depending on which wins. |
| 10 | The UI's upload, config generation, and cache invalidation live inside `scripts/deploy.sh`'s existing `ui` component branch. No new file under `scripts/`. | `.claude/rules/scripts.md` caps Operational_Scripts at exactly 10; "deploy" already covers this component. |
| 11 | `config.json` is generated at deploy time into `build/ui/` (git-ignored) and uploaded to the bucket. It is never committed. | It holds environment- and account-specific values (the real invocation URL, the app client ID). `build/` is already the repository's convention for generated, ignored output. |

## Research record

Live probes run on 2026-11-25 against the deployed stack `inspection-agent-demo-runtime` in
`us-west-2`, with the user's AWS credentials, via `curl` (not a browser — curl lets the exact HTTP
semantics be observed regardless of what a browser would additionally enforce).

| Topic | Finding | Evidence |
|---|---|---|
| **CORS preflight** | `OPTIONS` to the invocation URL, no `Authorization`, `Origin: https://example.cloudfront.net`, `Access-Control-Request-Method: POST`, `Access-Control-Request-Headers: authorization,content-type,x-amzn-bedrock-agentcore-runtime-session-id` → `HTTP/2 200`, `access-control-allow-origin: *`, `access-control-allow-headers` echoing back exactly what was requested, `access-control-allow-methods: POST`, `access-control-max-age: 172800`. | `curl -i -X OPTIONS`, this session |
| **Real cross-origin POST** | Same headers `scripts/invoke.sh` sends, plus `Origin`, with a real SRP-obtained Cognito access token → `HTTP/2 200`, `access-control-allow-origin: *`, `content-type: application/json`, a single non-chunked JSON object: `{"answer":...,"actions":[],"session_id":...,"trace_id":...}`. | `curl -i -X POST`, this session, persona `supervisor` |
| **Auth-error CORS** | No `Authorization` → `401`, body `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Missing Authentication Token"}}`, same `access-control-allow-origin: *`. Garbage `Authorization: Bearer not-a-real-token` → `403`, body `{"message":"OAuth authorization failed: Failed to parse token"}`, same CORS header. Both error shapes come from the custom JWT authorizer layer, before the request reaches the agent container — neither matches the app's own `{"error":{"code":...,"message":...}}` shape from `entrypoint.py`. | `curl -i -X POST`, this session |
| No service-level CORS configuration exists to misconfigure | `AWS::BedrockAgentCore::Runtime` has no CORS-related property (confirmed against `infra/runtime.yaml` and the CloudFormation resource reference used in spec 09/11). The behavior above is unconditional on the managed endpoint, not something this repository's templates control. | `infra/runtime.yaml`, CFN resource reference |
| Origin Access Control pattern | `AWS::CloudFront::OriginAccessControl` with `OriginAccessControlConfig: {OriginAccessControlOriginType: s3, SigningBehavior: always, SigningProtocol: sigv4}`; the distribution's S3 origin sets `OriginAccessControlId` and an *empty* `S3OriginConfig.OriginAccessIdentity: ""` (required even though OAC, not the older OAI, is used); the bucket policy allows `s3:GetObject` to principal `cloudfront.amazonaws.com` conditioned on `AWS:SourceArn` equal to this distribution's ARN. | AWS CloudFormation template reference and the official `compliant-static-website.yaml` sample |
| Response headers policy shape | `AWS::CloudFront::ResponseHeadersPolicy.ResponseHeadersPolicyConfig.SecurityHeadersConfig` takes `ContentSecurityPolicy: {ContentSecurityPolicy: "<value>", Override: true}`, `ContentTypeOptions: {Override: true}`, `FrameOptions: {FrameOption: DENY, Override: true}`, `ReferrerPolicy: {ReferrerPolicy: "...", Override: true}`, `StrictTransportSecurity: {AccessControlMaxAgeSec, IncludeSubdomains, Override, Preload}`. | CloudFormation template reference |
| SPA error mapping shape | `DistributionConfig.CustomErrorResponses` is a list of `{ErrorCode, ResponsePagePath, ResponseCode, ErrorCachingMinTTL}`. | CloudFormation template reference, AWS quick-reference sample |
| Existing deploy-order anticipation | `scripts/deploy.sh` already has `step 11 ui` / `deploy_stack ui`, then `step 12 auth` reading `/inspection-agent/$ENV/ui/callback-url` and `.../logout-url` via `read_ssm` and passing them as `CallbackUrl=$cb LogoutUrl=$lo` to the `auth` stack update, with `require_param` checks after. No `ui_parameters` function exists yet. | `scripts/deploy.sh`, this repository |
| Auth stack facts | App client: `GenerateSecret: false`, `AllowedOAuthFlows: [code]` only, `AllowedOAuthScopes: [openid, email, profile]`. `hosted-ui-domain` and `app-client-id` are published at `auth`'s first deploy and are stable for the life of the pool/client. | `infra/auth.yaml`, this repository |
| Invocation contract | `scripts/invoke.sh` builds the URL as `https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$ENCODED_ARN/invocations?qualifier=DEFAULT` with `ENCODED_ARN` from `urllib.parse.quote(arn, safe="")`, and sends `Authorization: Bearer <token>`, `Content-Type: application/json`, `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <id>`, body `{"prompt":...,"session_id":...}`. | `scripts/invoke.sh`, this repository, and reproduced live in the Research record above |

## Architecture

```
Browser (not signed in)
   |
   |  GET https://<cloudfront-domain>/
   v
CloudFront (OAC) --- S3 (private) --- index.html, app.js, styles.css, config.json
   |
   |  app.js: no valid token in sessionStorage
   |  -> location.replace(hosted-ui authorize URL, PKCE challenge)
   v
Cognito Hosted UI  (sign in as a persona)
   |
   |  redirect to https://<cloudfront-domain>/callback?code=...&state=...
   v
CloudFront --- 403 (no such object) --- CustomErrorResponses --- index.html, 200
   |
   |  app.js: pathname === '/callback'
   |  POST https://<hosted-ui-domain>/oauth2/token  (code + PKCE verifier from sessionStorage)
   v
Cognito token endpoint -> access_token, id_token  -> sessionStorage
   |
   |  history.replaceState -> '/'
   v
Chat UI renders. User sends a prompt.
   |
   |  POST https://bedrock-agentcore.us-west-2.amazonaws.com/runtimes/<encoded-arn>/invocations?qualifier=DEFAULT
   |     Authorization: Bearer <access_token>
   |     X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <uuid>
   |     body: {"prompt": ..., "session_id": <uuid>}
   v
AgentCore Runtime  (CORS confirmed above; same path scripts/invoke.sh already exercises)
   |
   v
{"answer": ..., "actions": [...], "session_id": ..., "trace_id": ...}
   |
   v
Chat UI: answer through the safe-Markdown renderer; actions into the Action Log,
         a `forbidden` decision gets a visible marker; session_id/trace_id shown as copyable text.
```

## Components and Interfaces

### 1. `infra/ui.yaml`

Parameters: `Env` (standard); `HostedUiDomain`, `AWS::SSM::Parameter::Value<String>`, defaulting to
`/inspection-agent/demo/auth/hosted-ui-domain`. **`AppClientId` is not a parameter of this template** —
it was dropped during implementation because nothing in `ui.yaml` references it (only the CSP's
`connect-src` needs `HostedUiDomain`), and an unused parameter trips `cfn-lint`'s `W2001`, which
conflicts with the zero-warnings rule. `scripts/deploy.sh`'s `config.json` generation step reads
`AppClientId` directly from its own SSM path, independent of this template's parameters, so the site
still gets the value it needs.

Resources:

- **`SiteBucket`** (`AWS::S3::Bucket`): `PublicAccessBlockConfiguration` all four flags `true`,
  `BucketEncryption` with SSE-S3, `Project`/`Env` tags. No versioning (static, regenerable assets).
- **`OriginAccessControl`** (`AWS::CloudFront::OriginAccessControl`):
  `OriginAccessControlOriginType: s3`, `SigningBehavior: always`, `SigningProtocol: sigv4`.
- **`BucketPolicy`** (`AWS::S3::BucketPolicy`): allow `s3:GetObject` on `${SiteBucket.Arn}/*` to
  principal `cloudfront.amazonaws.com`, condition `StringEquals: {AWS:SourceArn:
  !Sub arn:${AWS::Partition}:cloudfront::${AWS::AccountId}:distribution/${Distribution.Id}}` — the
  confused-deputy-safe OAC policy.
- **`ResponseHeadersPolicy`**: `StrictTransportSecurity` (1 year, include subdomains),
  `ContentTypeOptions` (nosniff), `FrameOptions: DENY`, `ReferrerPolicy: same-origin`, and
  `ContentSecurityPolicy` built with `!Sub`:
  ```
  default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:;
  connect-src 'self' https://${HostedUiDomain} https://bedrock-agentcore.${AWS::Region}.amazonaws.com;
  object-src 'none'; base-uri 'none'; frame-ancestors 'none'
  ```
  This is the full list of origins the site calls: itself (document, `app.js`, `styles.css`,
  `config.json`), the Cognito token endpoint (PKCE code exchange), and the AgentCore Runtime invocation
  endpoint. The Hosted UI's `/oauth2/authorize` page is a top-level navigation (`location.replace`), not
  a `fetch`, so it needs no `connect-src` entry.
- **`Distribution`** (`AWS::CloudFront::Distribution`): one S3 origin via `OriginAccessControlId`, empty
  `S3OriginConfig.OriginAccessIdentity`; `ViewerProtocolPolicy: redirect-to-https`;
  `DefaultRootObject: index.html`; `CustomErrorResponses`: `403`→`/index.html`/`200`,
  `404`→`/index.html`/`200`; the response headers policy attached to the default cache behavior;
  `PriceClass_100`; `Project`/`Env` tags. `DefaultCacheBehavior` also needs a `CachePolicyId` — a real
  AWS API requirement that `cfn-lint`'s schema check does not flag — and uses the AWS-managed
  `Managed-CachingOptimized` policy (`658327ea-f89d-4fab-a63d-7e88639e58f6`, the same fixed ID in every
  account and region, not an account-specific literal).
- Two `AWS::SSM::Parameter`s, matching what `scripts/deploy.sh` step 12 already reads verbatim:
  `/inspection-agent/${Env}/ui/callback-url` = `!Sub https://${Distribution.DomainName}/callback`,
  `/inspection-agent/${Env}/ui/logout-url` = `!Sub https://${Distribution.DomainName}/`.
- Outputs: `BucketName`, `DistributionId`, `DistributionDomainName`, `CallbackUrl`, `LogoutUrl`, each
  with a `Description`, no `Export` — per `docs/cloudformation-conventions.md`.

### 2. `ui/index.html`, `ui/app.js`, `ui/styles.css`

One HTML document, no inline `<script>`/`<style>`. `app.js` is organized as plain functions (no
classes needed at this scale), roughly:

- `loadConfig()` — fetch `config.json` once, same-origin.
- `pkce.js`-equivalent functions: `generateVerifier()` (random bytes, base64url), `challengeFor(verifier)`
  (`crypto.subtle.digest('SHA-256', ...)`, base64url).
- `ensureSignedIn(config)` — the gate. If `location.pathname === '/callback'`, exchange the code for
  tokens (`POST https://${config.hostedUiDomain}/oauth2/token`, body
  `grant_type=authorization_code&client_id=...&code=...&redirect_uri=.../callback&code_verifier=...`),
  store both tokens in `sessionStorage`, then `history.replaceState(null, '', '/')`. Otherwise, read a
  stored access token; decode its payload (no verification needed client-side — the Runtime enforces
  identity) to check `exp`; if absent or expired, build the PKCE pair, store the verifier and a random
  `state` in `sessionStorage`, and `location.replace()` straight to
  `https://${config.hostedUiDomain}/oauth2/authorize?response_type=code&client_id=...&redirect_uri=.../callback&scope=openid+email+profile&code_challenge=...&code_challenge_method=S256&state=...`.
  **This redirect happens before any call to the invocation URL — the first acceptance criterion by
  construction, not by a separate check.**
- `callAgent(config, token, sessionId, prompt)` — the one `fetch` call, headers and body exactly as in
  the Research record.
- `extractErrorMessage(httpStatus, body)` — tries `body?.error?.message`, then `body?.message`, then a
  fixed fallback string. Covers all three response shapes observed in the spike.
- `renderMarkdown(text)` — escape HTML-significant characters first; then apply, in order, a fixed
  regex-based pass for `**bold**`, `*italics*`, `` `code` ``, `- ` / `1. ` list lines, and `| a | b |`
  table rows; emit only `<strong>`, `<em>`, `<code>`, `<ul>/<li>`, `<ol>/<li>`, `<table>/<tr>/<td>`,
  `<br>` — a tag set this function itself constructs, never derived from the input.
- Chat state: a message array in memory, `sessionId` in memory (regenerated by **New Conversation** via
  `crypto.randomUUID()`), a `sending` flag that disables the input and shows a loading row while a
  request is in flight.
- Action log rendering: per answer, a small table/list of `{tool, decision, row_count}`; `decision ===
  'forbidden'` gets a distinct class (e.g. a red "denied" chip); `session_id`/`trace_id` rendered as
  `<code>` text with a copy-to-clipboard button (`navigator.clipboard.writeText`).
- Sign-in banner: decode the ID token's `email` and `cognito:groups` claims for display; **Sign out**
  clears `sessionStorage` and navigates to
  `https://${config.hostedUiDomain}/logout?client_id=...&logout_uri=${encodeURIComponent(config.logoutUrl)}`.

`styles.css`: a simple flex layout, base font size ≥18px, high-contrast palette suitable for projection,
no framework.

### 3. `scripts/deploy.sh`

- **`ui_parameters()`**: no required stack-parameter overrides — both of `ui.yaml`'s parameters are
  SSM-typed and resolve themselves. Uses the same guarded-empty-array expansion
  (`${STACK_ARGS[@]+"${STACK_ARGS[@]}"}`) spec 11 already introduced for `observability_parameters`,
  since bash 3.2 with `set -u` treats an empty array's unguarded expansion as an error.
- After `deploy_stack ui` reaches `CREATE_COMPLETE`/`UPDATE_COMPLETE`, a step (mirroring
  `apply_log_retention`'s placement after the `observability` branch in spec 11):
  1. Read `RuntimeArn` from `/inspection-agent/$ENV/runtime/runtime-arn`; URL-encode it with the same
     `python3 -c 'import urllib.parse; ...'` one-liner `invoke.sh` uses; build the real invocation URL —
     no `{EncodedRuntimeArn}` placeholder left in it, unlike the raw `invocation-url` SSM value.
  2. Read `AppClientId` and `HostedUiDomain` from their SSM paths.
  3. Write `build/ui/config.json` (the `build/` directory is already git-ignored) with `invocationUrl`,
     `region`, `appClientId`, `hostedUiDomain`, `sessionHeaderName:
     "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"`, and `logoutUrl` (read back from the `ui` stack's
     own `LogoutUrl` output, so the sign-out redirect always matches the real deployed domain).
  4. `aws s3 sync ui/ s3://<bucket>/ --delete --exclude README.md`, then
     `aws s3 cp build/ui/config.json s3://<bucket>/config.json`.
  5. `aws cloudfront create-invalidation --distribution-id <id> --paths '/*'`.
- `infra/auth.yaml`'s existing step-12 logic is untouched; it already does the right thing once `ui`'s
  two SSM outputs exist.

### 4. `docs/spikes/browser-to-runtime.md`

Structure: the question, the method (three `curl` probes, replicating `scripts/invoke.sh`'s exact
request shape), the three results with full request/response detail, the go/no-go decision, and the two
consequences for the design (two error-body shapes to handle; preflight caching up to 48h). Written so
a reader can reproduce every probe from the commands alone.

### 5. `docs/ui.md`

Sections: how sign-in works (PKCE, token storage, sign-out) with a sequence matching the Architecture
diagram; the CSP and exactly which three origins it allows and why; the action log and what it is
**not** — a convenience view, not the audit evidence, pointing to `docs/observability.md`; the persona
switcher, with the measured sign-out→sign-in timing and the separate-Chrome-profiles recipe for running
more than one persona at once; deploy/update procedure (`make deploy-ui`); known gaps.

## Data Models

### `config.json` (generated, not committed)

| Field | Source |
|---|---|
| `invocationUrl` | `RuntimeArn` SSM value, URL-encoded, assembled into the full invocation URL |
| `region` | The stack's region (`us-west-2`) |
| `appClientId` | `/inspection-agent/<env>/auth/app-client-id` |
| `hostedUiDomain` | `/inspection-agent/<env>/auth/hosted-ui-domain` |
| `logoutUrl` | The `ui` stack's own `LogoutUrl` output |
| `sessionHeaderName` | Fixed: `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` |

### Invoke request/response (unchanged from the existing contract, reproduced for the UI's benefit)

Request: `POST <invocationUrl>`, headers `Authorization: Bearer <access_token>`,
`Content-Type: application/json`, `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <sessionId>`; body
`{"prompt": "<text>", "session_id": "<sessionId>"}`.

Success response: `{"answer": "<string>", "actions": [{"tool": "...", "decision": "allowed" |
"restricted" | "forbidden" | null, "row_count": <int>}], "session_id": "<string>", "trace_id":
"<string>"}`.

Error responses, two shapes the UI must both handle:
- App-level (`entrypoint.py`): `{"error": {"code": "...", "message": "..."}}`.
- Authorizer-level (before the request reaches the agent): `{"jsonrpc":"2.0","error":{"code":-32001,
  "message":"Missing Authentication Token"}}` (401, no token), or a flat `{"message": "..."}` (403,
  malformed token).

## Error Handling

| Situation | Behaviour |
|---|---|
| No valid token on load | Redirect to the Hosted UI before any agent call. Satisfies the first acceptance criterion directly, not through a separate guard. |
| Token expires mid-session | The next `fetch` returns 401/403 from the authorizer layer; `extractErrorMessage` surfaces a plain-language message; the UI then clears `sessionStorage` and redirects to re-authenticate. |
| Non-2xx from the agent (`forbidden_session`, `invalid_request`, `internal_error`) | Shown as a distinct error bubble in the chat using `extractErrorMessage`, never the raw body or a stack trace. |
| `fetch` network failure (no response at all) | Caught, shown as "Could not reach the agent. Check your connection and try again." |
| CORS preflight cached by the browser | No special handling needed; it is a browser-side optimization, transparent to the app. |
| Markdown renderer given unexpected input (e.g. unmatched table pipes) | Falls back to the escaped, unformatted text — never raises, never emits an unescaped fragment. |

## Testing Strategy

The workspace testing policy forbids test files, suites, fixtures, eval harnesses and verification
scripts. Every check below is manual.

Static checks: `cfn-lint infra/ui.yaml` (zero errors/warnings), `ruff check .` (no Python changes
expected, run anyway), `bash -n scripts/deploy.sh`.

Manual verification, each recorded as a dated note under its task in `tasks.md`:
- The three spike probes reproduced once more against the final deployed state.
- Bucket not public (`aws s3api get-public-access-block`); HTTP redirects to HTTPS.
- A fresh browser session with no token is redirected to the Hosted UI before any network call to the
  invocation URL (checked in DevTools' network tab).
- Each demo persona, including the line B denial (demo question 4) with its visible "denied" marker in
  the action log.
- New Conversation changes the next request's session header.
- DevTools/Application tab shows tokens only in `sessionStorage`, never `localStorage`.
- A timed sign-out→sign-in-as-another-persona cycle, under 20 seconds.
- The separate-browser-profiles recipe, run for real with two personas signed in at once.

## Task list guidance

`[implementer]` tasks need only files and local commands: the spike write-up (its content already
known from planning), `infra/ui.yaml`, the three `ui/` files, the `scripts/deploy.sh` changes, the two
docs, `cfn-lint`, `ruff`, `bash -n`.

`[main]` tasks touch AWS, need credentials, need a real browser, or need the user: deploying the stack,
running the auth-stack update, every browser-based verification step, the persona-switch timing, and
recording results.

One ordering constraint: the UI cannot be verified in a browser until `infra/ui.yaml` is deployed *and*
`scripts/deploy.sh`'s existing step 12 has updated the `auth` stack with the real callback/logout URLs,
*and* the deploy step has generated and uploaded `config.json`. All three must happen before any
browser-based task.
