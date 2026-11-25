# Requirements Document

## Introduction

This feature adds a small static web app, hosted on S3 and CloudFront, where a user signs in with
Cognito and chats with the inspection agent. It adds the template `infra/ui.yaml`, the static site in
`ui/`, a deploy step in `scripts/deploy.sh`, the spike write-up `docs/spikes/browser-to-runtime.md`, and
the runbook `docs/ui.md`.

The issue opens with a spike: can a browser call the AgentCore Runtime HTTPS endpoint directly, or does
it need a proxy (API Gateway + Lambda) that forwards the user's JWT unchanged? This was resolved during
planning with three live probes against the deployed runtime, with AWS credentials available:

- A CORS preflight (`OPTIONS`, no auth, a cross-origin `Origin` header, the three headers the UI needs)
  returned `HTTP 200` with `access-control-allow-origin: *`, `access-control-allow-methods: POST`, and
  `access-control-allow-headers` echoing back exactly the headers requested.
- A real cross-origin `POST`, with a real Cognito access token and an `Origin` header set, returned
  `HTTP 200` with `access-control-allow-origin: *` and the full JSON answer.
- The same CORS header was present on auth-error responses too (`401` with no token, `403` with a
  garbage token), so the browser can read an error body in every case, not only on success.

**Decision: the browser calls the Runtime directly. No proxy, no API Gateway, no Lambda.** The CORS
behavior is a fixed property of the AWS-managed `bedrock-agentcore.<region>.amazonaws.com` data plane,
not something `infra/runtime.yaml` configures or that agent code adds.

Out of scope: voice, file upload, response streaming, multi-language UI chrome.

Facts found in the repository while writing these requirements (the design confirms them):

- `scripts/deploy.sh` already has `step 11 ui` / `deploy_stack ui`, and `step 12 auth` already reads
  `/inspection-agent/<env>/ui/callback-url` and `/inspection-agent/<env>/ui/logout-url` from SSM and
  passes them to the `auth` stack update. The circular dependency between `ui` and `auth` is already
  solved by this two-step deploy order — `infra/ui.yaml` only needs to publish those two SSM parameters.
- `infra/auth.yaml` already publishes `/inspection-agent/<env>/auth/hosted-ui-domain` and
  `/inspection-agent/<env>/auth/app-client-id` at `auth`'s first deploy (step 2), before `ui` deploys at
  step 11. Both values are fixed for the life of the pool and client; only the callback/logout URL list
  changes at step 12. `ui.yaml` can read both as ordinary SSM-typed parameters with no ordering problem.
- The Cognito app client has `GenerateSecret: false` and `AllowedOAuthFlows: [code]` only, so the
  authorization code flow with PKCE is mandatory — there is no client secret to protect.
- `scripts/invoke.sh` already shows the exact request shape a browser must replicate: `POST` to
  `https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<url-encoded-arn>/invocations?qualifier=DEFAULT`,
  headers `Authorization: Bearer <token>`, `Content-Type: application/json`,
  `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <session-id>`, body
  `{"prompt": "...", "session_id": "..."}`. The response is a single JSON object (not streamed):
  `{"answer": "...", "actions": [...], "session_id": "...", "trace_id": "..."}`.
- The entrypoint's four fixed error payloads are `{"error":{"code":"...","message":"..."}}`. The AWS
  authorizer layer, which rejects a missing or malformed token before the request reaches the agent
  code, returns a *different* shape: `{"jsonrpc":"2.0","error":{"code":-32001,"message":"..."}}` for a
  missing token, or a flat `{"message":"..."}` for a token that fails to parse. A client must extract a
  human message from any of these shapes.
- `.claude/rules/scripts.md` caps Operational_Scripts at exactly 10. The UI's upload and cache
  invalidation must be part of the existing `deploy` script, not a new script.
- The testing policy forbids test files. Every acceptance criterion in this document is verified by hand.

## Glossary

- **Site_Stack**: The CloudFormation stack `inspection-agent-<env>-ui`, defined in `infra/ui.yaml`.
- **Site_Bucket**: The private `AWS::S3::Bucket` in the Site_Stack.
- **Distribution**: The `AWS::CloudFront::Distribution` in the Site_Stack, the site's only public entry
  point.
- **Invocation_Url**: The full, URL-encoded HTTPS endpoint of the deployed AgentCore Runtime, built the
  same way `scripts/invoke.sh` builds it.
- **Site_Config**: The generated file `config.json`, served from the Site_Bucket, holding the
  Invocation_Url, the Cognito app client ID, the hosted UI domain, and the session header name. Not
  committed to the repository; written by the deploy step.
- **PKCE**: Proof Key for Code Exchange, RFC 7636, required here because the app client has no secret.
- **Hosted_UI**: The Cognito-managed sign-in pages at the `hosted-ui-domain` SSM value.
- **Decision**: One of `allowed`, `restricted`, `forbidden`, or `null`, as returned in one entry of the
  invoke response's `actions` list.
- **Action_Log**: The UI panel showing, per answer, the `actions` list from the response: tool, decision,
  row count, with a visible marker for a `forbidden` decision. A convenience view, not audit evidence.
- **Session_Id**: The client-generated identifier sent identically in the request body's `session_id`
  field and the `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header.
- **Spike_Doc**: The file `docs/spikes/browser-to-runtime.md`.
- **Site_Doc**: The file `docs/ui.md`.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: The spike is a recorded, reproducible deliverable

**User Story:** As a future maintainer, I want the browser-to-Runtime CORS question answered in writing,
with evidence, so that nobody re-litigates it from scratch.

#### Acceptance Criteria

1. THE Spike_Doc SHALL record the exact `OPTIONS` preflight request and response observed against the
   deployed runtime, including the CORS response headers.
2. THE Spike_Doc SHALL record a real cross-origin `POST` request and response, including the CORS
   response headers on a successful answer.
3. THE Spike_Doc SHALL record the CORS behavior of at least one auth-error response.
4. THE Spike_Doc SHALL state the go/no-go decision (direct call, no proxy) and the reason.
5. THE Spike_Doc SHALL be reproducible by a reader who has not seen this work, using only commands it
   lists and SSM parameters that already exist.

### Requirement 2: Hosting

**User Story:** As an operator, I want the site privately hosted and publicly reachable only over
HTTPS, so that the only way to the content is through CloudFront.

#### Acceptance Criteria

1. THE Site_Bucket SHALL block all public access and SHALL NOT have a public bucket policy.
2. THE Distribution SHALL be the only principal the Site_Bucket's policy allows to read objects, scoped
   to this Distribution's ARN.
3. THE Distribution SHALL redirect HTTP requests to HTTPS and SHALL NOT serve content over plain HTTP.
4. THE Distribution SHALL attach a response headers policy carrying `Strict-Transport-Security`,
   `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, a `Referrer-Policy`, and a
   `Content-Security-Policy` that names only the origins the site actually calls.
5. THE Site_Stack SHALL publish the Distribution's callback and logout URLs to
   `/inspection-agent/<env>/ui/callback-url` and `/inspection-agent/<env>/ui/logout-url`, matching what
   `scripts/deploy.sh` step 12 already reads.
6. A request to a path that is not a real object, such as `/callback`, SHALL still serve `index.html`
   with an HTTP success status, so the client-side router can run.

### Requirement 3: Sign-in

**User Story:** As a user, I want to sign in with my Cognito account and not be able to use the chat
until I do.

#### Acceptance Criteria

1. WHEN a user with no valid session loads the site, THE site SHALL redirect to the Hosted_UI and SHALL
   NOT call the Invocation_Url first.
2. THE site SHALL use the authorization code flow with PKCE, with no client secret anywhere in the site.
3. THE site SHALL keep the access token, the ID token, and the PKCE verifier only in memory or
   `sessionStorage`, and SHALL NOT write any of them to `localStorage`.
4. WHEN sign-in completes, THE site SHALL show the signed-in user's email and Cognito groups.
5. WHEN the user signs out, THE site SHALL clear its stored tokens and SHALL redirect to the Cognito
   logout endpoint.

### Requirement 4: Callback and logout URLs

**User Story:** As an operator, I want the callback URL wiring to need no manual step and no circular
stack dependency.

#### Acceptance Criteria

1. THE Site_Stack SHALL derive its callback and logout URLs from its own Distribution's domain name and
   SHALL NOT take them as parameters.
2. THE Site_Stack SHALL NOT read any value from the `auth` stack's `CallbackUrl` or `LogoutUrl`
   parameters, directly or indirectly.
3. THE deploy procedure SHALL update the `auth` stack with the Site_Stack's published callback and
   logout URLs after the Site_Stack exists, using the existing `scripts/deploy.sh` step 12 logic
   unchanged.

### Requirement 4a: Audience and purpose

**User Story:** As a presenter, I want a chat UI I can run during the demo without engineering help.

#### Acceptance Criteria

1. THE site SHALL show a message list, a text input, a send action, and a loading state while a request
   is in flight.
2. THE site SHALL show a New Conversation action that starts a new Session_Id for the next request,
   with no server-side reset required.
3. THE site SHALL be legible at a distance: a base font size of at least 18 pixels and a high-contrast
   color scheme.

### Requirement 5: Chat behavior

**User Story:** As a user, I want to ask a question and see the agent's answer and what it is based on.

#### Acceptance Criteria

1. WHEN a signed-in user sends a prompt, THE site SHALL call the Invocation_Url with the headers and
   body shape `scripts/invoke.sh` already uses.
2. THE site SHALL render the answer as text or sanitized Markdown only, and SHALL NOT insert model
   output as raw HTML.
3. WHEN the response is not a success status, THE site SHALL extract a human-readable message from
   either error shape named in the Introduction and SHALL show it in plain language, never a stack
   trace or the raw response body.
4. WHEN the line B inspector asks for line A data, THE site SHALL show the fixed denial message and an
   Action_Log entry marked as denied.

### Requirement 6: Action log

**User Story:** As a presenter, I want to show, for each answer, what the agent actually did.

#### Acceptance Criteria

1. THE Action_Log SHALL show, for each action in the response, the tool name, the Decision, and the row
   count.
2. A Decision of `forbidden` SHALL carry a visibly distinct marker from `allowed` or `restricted`.
3. THE site SHALL show the response's `session_id` and `trace_id` as copyable text next to the answer.
4. THE Site_Doc SHALL state that the Action_Log is a convenience view, not the audit evidence, and SHALL
   point to `docs/observability.md` for the latter.

### Requirement 7: Persona switching

**User Story:** As a presenter, I want to change which persona I am signed in as quickly, and to keep
more than one signed in if needed.

#### Acceptance Criteria

1. A Reviewer SHALL measure a sign-out-then-sign-in-as-another-persona cycle and record the elapsed
   time.
2. THAT cycle SHALL take under 20 seconds.
3. THE Site_Doc SHALL document a way to keep several personas signed in at once in separate browser
   profiles, verified by hand.

### Requirement 8: Deploy and config

**User Story:** As an operator, I want one command to publish the site and have it point at the right
backend.

#### Acceptance Criteria

1. THE deploy step for the `ui` component SHALL upload the site files to the Site_Bucket.
2. THE deploy step SHALL generate the Site_Config with the real Invocation_Url (URL-encoded, with no
   unresolved placeholder), the app client ID, and the hosted UI domain, and SHALL upload it alongside
   the site files.
3. THE deploy step SHALL invalidate the Distribution's cache after every upload.
4. THE deploy logic SHALL live inside the existing `deploy` Operational_Script. NO new file SHALL be
   added under `scripts/`.
5. THE Site_Config SHALL NOT be committed to the repository.

### Requirement 9: Accessibility and safety

**User Story:** As a security reviewer, I want model output to never become executable content in the
page.

#### Acceptance Criteria

1. THE site SHALL NOT use `innerHTML`, `document.write`, or an equivalent with unescaped model text as
   input.
2. THE Markdown renderer SHALL escape all HTML-significant characters before applying any formatting
   rule, and SHALL emit only a fixed, small set of tags that the renderer itself constructs.
3. THE site SHALL include no inline `<script>` or `<style>` content, and the Content-Security-Policy
   SHALL NOT include `unsafe-inline` or `unsafe-eval`.
4. THE site SHALL load no script, style, font, or image from a third-party CDN; every asset is
   same-origin.
