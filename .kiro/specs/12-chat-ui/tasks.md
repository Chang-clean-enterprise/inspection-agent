# Implementation Plan: Static chat UI with Cognito sign-in

## Overview

This plan adds the static chat UI: `infra/ui.yaml`, the site in `ui/`, the `scripts/deploy.sh` wiring,
the spike write-up, and the runbook `docs/ui.md`. The design uses CloudFormation YAML, bash 3.2, and
plain browser JavaScript/HTML/CSS with no build step, so no language question applies. The design has no
Correctness Properties section, so there are no property test tasks.

The workspace testing policy forbids test files, suites, fixtures, eval harnesses and verification
scripts. Every verification task below is a manual step. Each one ends with a note that records what was
checked and the real result. Record those notes in this file under the task, and the deploy, browser,
and persona-switch results also in `docs/ui.md`.

**The core architectural question is already answered.** During planning, three live `curl` probes
against the deployed runtime (`inspection-agent-demo-runtime`, `us-west-2`) confirmed that the browser
can call the AgentCore Runtime invocation endpoint directly — real CORS headers
(`access-control-allow-origin: *`) on the preflight, on a real successful cross-origin POST, and on
auth-error responses. No proxy. The exact commands and captured output are handed to task 3 below so
the spike document can be written and the reproduction commands verified without needing to re-derive
anything.

Order of work: the three static deliverables (template, site, spike doc) can be written in any order
and are independent of each other; the deploy-script wiring depends on nothing else; only after all four
are written and linted does deployment and browser verification begin, because the UI cannot be tested
in a real browser until the stack exists, the `auth` stack has been updated with the real callback URL,
and `config.json` has been generated and uploaded.

Each task carries a tag. `[implementer]` tasks need only files and local commands. `[main]` tasks touch
AWS, need a real browser, or need the user.

## Tasks

- [x] 1. [implementer] Write `infra/ui.yaml`
  - Parameters `Env` (standard, `^[a-z][a-z0-9]{0,9}$`, default `demo`), `HostedUiDomain` and
    `AppClientId` (`AWS::SSM::Parameter::Value<String>`, defaults
    `/inspection-agent/demo/auth/hosted-ui-domain` and `/inspection-agent/demo/auth/app-client-id`),
    each with a `Description`.
  - `SiteBucket` (`AWS::S3::Bucket`): `PublicAccessBlockConfiguration` with all four flags `true`,
    `BucketEncryption` SSE-S3, `Project`/`Env` tags. No `BucketName` override (let CloudFormation
    generate one).
  - `OriginAccessControl` (`AWS::CloudFront::OriginAccessControl`):
    `OriginAccessControlConfig: {Name: !Sub ui-${Env}-${AWS::StackName}, OriginAccessControlOriginType:
    s3, SigningBehavior: always, SigningProtocol: sigv4}`.
  - `Distribution` (`AWS::CloudFront::Distribution`): one `S3OriginConfig` origin pointing at
    `SiteBucket.RegionalDomainName`, empty `OriginAccessIdentity`, `OriginAccessControlId:
    !GetAtt OriginAccessControl.Id`; `ViewerProtocolPolicy: redirect-to-https`;
    `DefaultRootObject: index.html`; `CustomErrorResponses` mapping both `403` and `404` to
    `/index.html` with `ResponseCode: "200"`; `PriceClass_100`; the response headers policy below
    attached to the default cache behavior; `Project`/`Env` tags.
  - `ResponseHeadersPolicy` (`AWS::CloudFront::ResponseHeadersPolicy`):
    `SecurityHeadersConfig.StrictTransportSecurity` (`AccessControlMaxAgeSec: 31536000`,
    `IncludeSubdomains: true`, `Override: true`), `ContentTypeOptions.Override: true`,
    `FrameOptions: {FrameOption: DENY, Override: true}`,
    `ReferrerPolicy: {ReferrerPolicy: same-origin, Override: true}`, and
    `ContentSecurityPolicy.ContentSecurityPolicy` built with `!Sub` exactly as specified in
    `design.md` section 1 (the three-origin `connect-src`), `Override: true`.
  - `BucketPolicy` (`AWS::S3::BucketPolicy`): `Action: s3:GetObject`, `Resource:
    !Sub ${SiteBucket.Arn}/*`, `Principal: {Service: cloudfront.amazonaws.com}`, `Condition:
    {StringEquals: {"AWS:SourceArn": !Sub arn:${AWS::Partition}:cloudfront::${AWS::AccountId}:distribution/${Distribution.Id}}}`.
  - Two `AWS::SSM::Parameter`s: `/inspection-agent/${Env}/ui/callback-url` and
    `/inspection-agent/${Env}/ui/logout-url`, values `!Sub https://${Distribution.DomainName}/callback`
    and `!Sub https://${Distribution.DomainName}/`, each with a `Description` and `Project`/`Env` tags.
  - Outputs `BucketName`, `DistributionId`, `DistributionDomainName`, `CallbackUrl`, `LogoutUrl`, each
    with a `Description`, no `Export`.
  - Follow `docs/cloudformation-conventions.md`, all 10 rules. Mirror the style of `infra/observability.yaml`
    (the most recent template) for parameter/output formatting.
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 4.1, 4.2_

  Note (2026-11-25): `cfn-lint` zero errors/zero warnings, confirmed independently in the main session
  across all 8 templates (`uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` → exit 0). The 10
  conventions rules were walked one at a time by the implementer and spot-checked in review; rule 4
  (tags) and rule 5 (least privilege) both noted correctly that `OriginAccessControl`,
  `ResponseHeadersPolicy` and `BucketPolicy` have no `Tags` property in their CloudFormation schema, so
  there is nothing to tag on those three resource types.

  Two deliberate deviations from the task text, both accepted after independent verification, and both
  now reflected in `design.md`:
  1. **`AppClientId` dropped as a template parameter.** It was never referenced anywhere in the
     template (only `HostedUiDomain` feeds the CSP), and an unused parameter trips `cfn-lint`'s `W2001`,
     which would have violated the zero-warnings rule. `scripts/deploy.sh`'s `config.json` generation
     (task 4) reads `AppClientId` from its own SSM path independently, so the site still gets the value
     it needs; nothing is lost.
  2. **Added `CachePolicyId: 658327ea-f89d-4fab-a63d-7e88639e58f6` (AWS-managed `Managed-CachingOptimized`)**
     on `DefaultCacheBehavior`. Not in the original design text, but a real AWS API requirement that
     `cfn-lint`'s schema check does not catch — a CloudFront distribution needs either a `CachePolicyId`
     or the legacy `ForwardedValues` block to actually create. The fixed, AWS-managed ID is identical in
     every account and region, not an account-specific literal, so it does not violate convention rule 6.

- [x] 2. [implementer] Write the static site: `ui/index.html`, `ui/app.js`, `ui/styles.css`
  - `index.html`: one page, a `<main>` with a sign-in banner region, the message list, the input row,
    and the action-log panel per message. References `app.js` and `styles.css` by same-origin relative
    path. No inline `<script>`, no inline `<style>`, no inline event-handler attributes (`onclick=`
    etc. — attach listeners in `app.js` instead).
  - `app.js`: implement, as plain functions (no classes, no framework):
    - `loadConfig()` — `fetch('/config.json')` once on load.
    - PKCE helpers: `generateVerifier()`, `challengeFor(verifier)` using `crypto.subtle.digest('SHA-256', ...)`
      and base64url encoding (no padding, `+`→`-`, `/`→`_`).
    - `ensureSignedIn(config)` — the gate described in `design.md` section 2. On `/callback`, exchange
      the code at `config.hostedUiDomain`'s `/oauth2/token`, store both tokens in `sessionStorage`,
      `history.replaceState` to `/`. Otherwise check a stored, unexpired access token (decode the JWT
      payload only, no signature check); if missing/expired, build the PKCE pair, store the verifier
      and a random `state` in `sessionStorage`, and `location.replace()` to `/oauth2/authorize` with
      `code_challenge_method=S256`. This call must run, and must redirect, before any call to
      `config.invocationUrl` is possible from any code path.
    - `callAgent(config, token, sessionId, prompt)` — the one `fetch`, headers and body exactly as in
      `design.md`'s Data Models section.
    - `extractErrorMessage(httpStatus, body)` — `body?.error?.message ?? body?.message ?? "The agent
      could not complete this request. Try again."`.
    - `renderMarkdown(text)` — escape `&`, `<`, `>`, `"`, `'` first; then a fixed ordered set of
      regex passes for `**bold**`, `*italics*`, `` `code` ``, `- `/`1. ` list lines, and `| a | b |`
      table rows, emitting only `<strong>`, `<em>`, `<code>`, `<ul>/<ol>/<li>`, `<table>/<tr>/<td>`,
      `<br>`. On any unexpected shape, fall back to the escaped plain text — never throw, never emit an
      unescaped fragment.
    - Chat state: in-memory message array, in-memory `sessionId` (new `crypto.randomUUID()` on load and
      on **New Conversation**), a `sending` flag disabling the input and showing a loading row mid-flight.
    - Action log: per answer, list `{tool, decision, row_count}`; `decision === 'forbidden'` gets a
      distinct CSS class (a visible "denied" marker); render `session_id` and `trace_id` as `<code>`
      with a copy button (`navigator.clipboard.writeText`).
    - Sign-in banner: decode the ID token's `email` and `cognito:groups` for display; a **Sign out**
      button clears `sessionStorage` and navigates to `config.hostedUiDomain`'s `/logout` endpoint with
      `client_id` and `logout_uri=encodeURIComponent(config.logoutUrl)`.
  - `styles.css`: flex layout, base font size ≥18px, high-contrast colors suitable for projection. No
    `@import` of any remote stylesheet or font.
  - Nowhere in `app.js` does `innerHTML`, `outerHTML`, `insertAdjacentHTML`, or `document.write` receive
    a string built from unescaped model/user text. `renderMarkdown`'s own output is the only string ever
    assigned to `innerHTML`.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4a.1, 4a.2, 4a.3, 5.1, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3, 9.1,
    9.2, 9.3, 9.4_

  Note (2026-11-25): accepted after a full line-by-line review in the main session (not just the
  implementer's own report) of both `ui/app.js` and `ui/index.html`, since this is the highest-risk file
  in the spec: it owns the only CSP-exempt code path (same-origin JS) and the only place tokens exist in
  the browser. Confirmed directly, not just by grep:
  - `.innerHTML` is assigned in exactly one line (`bubble.innerHTML = renderMarkdown(message.text)`),
    and `renderMarkdown` escapes `&`, `<`, `>`, `"`, `'` *before* any regex-based formatting pass runs,
    so no transformation step can introduce an unescaped `<`/`>` that becomes a real tag. Every other
    dynamic value (email, action tool/decision/rows, copyable session/trace fields, error text) is set
    via `.textContent`, confirmed by reading each call site, not just the earlier grep.
  - `node --check ui/app.js` → `app.js: syntax OK`, re-run in the main session.
  - Traced all four sign-in-gate branches (no token, expired token, valid token, on `/callback`) by hand
    against the real code, not the implementer's description of it, and confirmed none of them reaches
    `callAgent`/`config.invocationUrl` before `ensureSignedIn` has resolved `true`.
  - `styles.css`: 18px base font size, high-contrast dark palette, distinct colors for
    allowed/restricted/forbidden decision chips, no `@import`, one narrow-window media query. No remote
    font or stylesheet.

  **One real gap found and fixed in the main session, not by the implementer.** The implementer's own
  report flagged, as an open question rather than a defect: `handleCallback`'s failure path (missing
  code, state mismatch, failed token exchange) cleared `sessionStorage` and reset the URL to `/`, but
  `ensureSignedIn` then returned `false` directly without falling through to the normal "no valid token"
  check — so a failed `/callback` left the page inert (blank, no redirect) until the user manually
  reloaded. This never risked an agent call (the hard security property held throughout), but it
  contradicts the spirit of requirement 3.1: a signed-out state should always end at the Hosted UI, not
  at a dead page. Fixed by making the `/callback` branch fall through to the same "no valid token ->
  redirect" check on failure, so any bad callback now self-heals into a fresh sign-in redirect on the
  same page load. Verified: `node --check` still passes after the edit; the one-`innerHTML`-site
  invariant is unaffected (the change is entirely inside `ensureSignedIn`'s control flow).

- [x] 3. [implementer] Write `docs/spikes/browser-to-runtime.md`
  - Use the exact commands and captured output from the planning research record below. Do not invent
    or approximate any value; quote the real responses.
    - Probe 1 (preflight): `curl -i -X OPTIONS "$URL" -H "Origin: https://example.cloudfront.net" -H
      "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers:
      authorization,content-type,x-amzn-bedrock-agentcore-runtime-session-id"` → `HTTP/2 200`,
      `access-control-allow-origin: *`, `access-control-allow-headers` echoing the request,
      `access-control-allow-methods: POST`, `access-control-max-age: 172800`.
    - Probe 2 (real POST): same three headers as `scripts/invoke.sh` plus `Origin`, a real SRP-obtained
      access token for `supervisor` → `HTTP/2 200`, `access-control-allow-origin: *`, a full JSON
      answer (`answer`, `actions: []`, `session_id`, `trace_id`).
    - Probe 3 (auth errors): no `Authorization` → `401`,
      `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Missing Authentication Token"}}`,
      `access-control-allow-origin: *`. Garbage token → `403`,
      `{"message":"OAuth authorization failed: Failed to parse token"}`, same CORS header.
  - State the decision plainly: direct browser calls, no proxy, and why (requirement 2's acceptance
    criterion is already met by the managed endpoint itself).
  - State the two design consequences: two different error-body shapes to parse defensively; preflight
    caching up to 48h (browser-dependent, often capped lower).
  - Write every command so a reader can run it again, substituting only their own `$ENV`/`$REGION` and
    getting their own token via `scripts/invoke.sh`'s own sign-in method — no placeholder left
    unexplained.
  - This is the one-time research baseline. Task 10 re-runs it for real against the final deployed
    state and records a second, independent confirmation.
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

  Note (2026-11-25): written faithfully from the planning research record with no invented values —
  confirmed in review by comparing every quoted command and response against this conversation's own
  probe output line by line. `grep -nE '[0-9]{12}' docs/spikes/browser-to-runtime.md` found no match,
  confirming no account ID leaked in. The document defers task 10's live re-confirmation to a dated
  follow-up section rather than pretending to have already run it, as instructed.

- [x] 4. [implementer] Wire `scripts/deploy.sh`
  - `ui_parameters()`: mirrors `observability_parameters()`'s shape — builds `STACK_ARGS` from any
    explicit overrides only (both of `ui.yaml`'s own parameters are SSM-typed and resolve themselves),
    using the guarded `${STACK_ARGS[@]+"${STACK_ARGS[@]}"}` expansion. Wire it into the `case "$c"` of
    `deploy_stack`, alongside the existing `pre-runtime`/`runtime`/`observability` branches.
  - A step that runs after the `ui` component reaches `CREATE_COMPLETE`/`UPDATE_COMPLETE` (same
    placement pattern as `apply_log_retention` for `observability` in spec 11):
    1. Read `RuntimeArn` from SSM; URL-encode with the same `python3 -c 'import urllib.parse;
       print(urllib.parse.quote(sys.argv[1], safe=""))'` one-liner `scripts/invoke.sh` already uses;
       assemble the real invocation URL.
    2. Read `AppClientId` and `HostedUiDomain` from SSM; read the `ui` stack's own `LogoutUrl` output.
    3. Create `build/ui/` if absent; write `build/ui/config.json` with `invocationUrl`, `region`,
       `appClientId`, `hostedUiDomain`, `logoutUrl`, `sessionHeaderName`.
    4. `aws s3 sync ui/ s3://<bucket>/ --delete --exclude README.md`.
    5. `aws s3 cp build/ui/config.json s3://<bucket>/config.json`.
    6. `aws cloudfront create-invalidation --distribution-id <id> --paths '/*'`.
  - Do not touch `infra/auth.yaml`'s existing step-12 logic (`cb=$(read_ssm ...)`,
    `deploy_stack auth "CallbackUrl=$cb" "LogoutUrl=$lo"`, the two `require_param` checks) — it already
    does the right thing once `ui`'s two SSM outputs exist.
  - Bash 3.2, `set -Eeuo pipefail`, validation before any mutating call, fixed messages with no secret.
    No new file under `scripts/`.
  - _Requirements: 4.3, 8.1, 8.2, 8.3, 8.4, 8.5_

  Note (2026-11-25): `bash -n scripts/deploy.sh` -> exit 0, confirmed independently in the main session.
  `ui_parameters()` uses the same guarded `${STACK_ARGS[@]+"${STACK_ARGS[@]}"}` expansion as
  `observability_parameters()` (the bash 3.2 `set -u` empty-array fix from spec 11). The new
  `deploy_ui_assets()` validates every SSM read and stack-output read with a single combined check and
  calls `fail` before any of `mkdir -p build/ui`, the `config.json` write, `aws s3 sync`, `aws s3 cp`, or
  `aws cloudfront create-invalidation` can run. `git diff` confirms the existing step-12 auth-update
  block (`cb=$(read_ssm ...)`, `deploy_stack auth "CallbackUrl=$cb" "LogoutUrl=$lo"`, both
  `require_param` calls) has zero changes. `CURRENT_STEP` is confirmed already set by the enclosing
  `step()`/single-component call path before `deploy_stack` ever runs, so `fail`'s step-number argument
  is always meaningful. `config.json` is built via a `python3 -c 'import json; json.dump(...)'` call with
  values passed as `sys.argv` entries (not hand-interpolated into the script text), avoiding shell-quoting
  bugs with URL query characters in `invocationUrl`. No new file under `scripts/`; `COMPONENTS` and
  `Makefile` already covered `ui` and needed no change.

- [x] 5. [implementer] Lint checkpoint
  - Run `uvx --from "cfn-lint==1.60.1" cfn-lint infra/ui.yaml`. Expect zero errors and zero warnings.
  - Run `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` to confirm the other seven templates are
    still clean.
  - Run `ruff check .` (no Python changed by this spec, but confirm nothing regressed).
  - Run `bash -n scripts/deploy.sh`.
  - Check `infra/ui.yaml` against the 10 rules in `docs/cloudformation-conventions.md`, one rule at a
    time, and fix gaps by hand.
  - Record all four outputs and the rule-by-rule walk in the task notes.
  - _Requirements: 2.1 through 2.6 (template correctness)_

  Note (2026-11-25): done directly in the main session rather than through a fresh implementer agent,
  since it is a re-consolidation of checks already run individually while reviewing tasks 1–4.
  - `cfn-lint infra/ui.yaml` -> exit 0.
  - `cfn-lint infra/*.yaml` (all 8 templates) -> exit 0.
  - `ruff check .` -> `All checks passed!`.
  - `bash -n scripts/deploy.sh` -> exit 0.
  - `node --check ui/app.js` -> exit 0 (not one of the four listed checks, but run anyway since this
    spec's static site has no other static-analysis gate).
  - `infra/ui.yaml` rule walk: already recorded under task 1's note (rules 4 and 5 don't fully apply to
    three resource types with no `Tags`/IAM-statement surface; everything else passes).
  - `git status --short` shows exactly the expected file set
    (`infra/ui.yaml`, `ui/{app.js,index.html,styles.css}`, `docs/spikes/browser-to-runtime.md`,
    `scripts/deploy.sh` modified, the spec folder) and no file whose name contains `test`, `conftest`,
    `pytest`, or `spec_`.

- [x] 6. [main] Checkpoint — review the static work
  - Review the full diff. Confirm no test file, fixture, or verification script was created anywhere
    under `ui/` or `scripts/`. Re-run `ruff check .` and `cfn-lint infra/*.yaml` once more in the main
    session.
  - Open `ui/app.js` and `ui/index.html` by eye and confirm no inline script/style and no
    `innerHTML`/`document.write` call takes anything but `renderMarkdown`'s own output.
  - Ask the user if questions arise before the first deploy.

  Note (2026-11-25): done across the review of tasks 1 through 5 above, not as a separate pass. Full
  diff reviewed for all four files/changesets; one real defect found and fixed (task 2's note, the
  `/callback`-failure dead-end). `ruff check .` and `cfn-lint infra/*.yaml` both re-run clean in this
  session. `ui/app.js` and `ui/index.html` read in full: confirmed no inline `<script>`/`<style>`, no
  inline event-handler attributes, and `.innerHTML` assigned in exactly one place, fed only by
  `renderMarkdown()`'s return value. No test file, fixture, or verification script anywhere under `ui/`
  or `scripts/`.

- [x] 7. [main] Deploy the UI stack and update `auth`
  - Confirm the target account and Region with the user before running anything.
  - Run `make deploy-ui`. Expect `CREATE_COMPLETE`, the distribution deployed, and
    `/inspection-agent/demo/ui/callback-url` and `.../logout-url` published.
  - Confirm `config.json` is reachable at `https://<distribution-domain>/config.json` and its fields are
    correct — in particular that `invocationUrl` has no `{EncodedRuntimeArn}` placeholder left in it.
  - Confirm the bucket is not public: `aws s3api get-public-access-block --bucket <bucket>` shows all
    four flags `true`; a direct unauthenticated request to the bucket's own URL (not through CloudFront)
    is denied.
  - Confirm HTTPS-only: `curl -I http://<distribution-domain>/` redirects to `https://`.
  - Run (or re-run `deploy_all` through) step 12: confirm the Cognito app client's `CallbackURLs` and
    `LogoutURLs` now include the real `https://<distribution-domain>/callback` and
    `https://<distribution-domain>/`, alongside the kept `localhost` default.
  - Record the stack status, the fetched `config.json`, and the confirmed callback/logout URLs in the
    task notes.
  - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6, 4.1, 4.2, 4.3, 8.1, 8.2, 8.3_

  Note (2026-11-25, account `<account-id>`, us-west-2): PASS. `make deploy-ui` -> `CREATE_COMPLETE`.
  Outputs: `DistributionDomainName=<cloudfront-domain>`,
  `BucketName=<bucket-name>`, `DistributionId=<distribution-id>`,
  `CallbackUrl=https://<cloudfront-domain>/callback`,
  `LogoutUrl=https://<cloudfront-domain>/`. The deploy step's own post-deploy upload ran inline
  (3 files synced, `config.json` uploaded, distribution invalidated) — no separate manual step needed.

  `config.json` fetched from the live site: `invocationUrl` has the real, fully URL-encoded runtime ARN
  (no `{EncodedRuntimeArn}` placeholder), correct `appClientId`, correct `hostedUiDomain`, `logoutUrl`
  matching the stack's own output, fixed `sessionHeaderName`.

  Bucket: `GetPublicAccessBlock` shows all four flags `true`. A direct request to the bucket's own
  regional endpoint (`https://<bucket>.s3.us-west-2.amazonaws.com/index.html`, bypassing CloudFront)
  returns `403 AccessDenied` — only the distribution's OAC identity can read it.

  HTTPS-only: `curl -I http://<distribution-domain>/` returns `301 Moved Permanently`. The `200` HTTPS
  response carries all four response-headers-policy headers: `X-Frame-Options: DENY`,
  `Referrer-Policy: same-origin`, `X-Content-Type-Options: nosniff`,
  `Strict-Transport-Security: max-age=31536000; includeSubDomains`, and the exact three-origin CSP from
  the design (`'self'`, the real hosted UI domain, `bedrock-agentcore.us-west-2.amazonaws.com`).

  SPA fallback: `GET /callback?code=fake` (no real object at that path) returns `200` serving
  `index.html`, confirming the `403`→`index.html` `CustomErrorResponse` works for the one path the
  OAuth round trip actually needs.

  Ran step 12 by hand (`scripts/deploy.sh ... deploy auth --param "CallbackUrl=..." --param
  "LogoutUrl=..."` — note the manual invocation needs the `--param` prefix per-value, unlike
  `deploy_all`'s internal call). `DescribeUserPoolClient` confirms `CallbackURLs` and `LogoutURLs` each
  now list two entries: the kept `http://localhost:3000/...` default and the real
  `https://<cloudfront-domain>/...` value.

- [x] 8. [main] Verify sign-in and chat in a real browser
  - [x] 8.1 [main] Sign-in gate and token storage
    - Open the site in a fresh private/incognito window. Confirm, in DevTools' Network tab, that the
      page redirects to the Cognito Hosted UI and that **no request to the invocation URL happens
      first**.
    - Sign in as `supervisor`. Confirm the signed-in banner shows the email and `supervisors` group.
    - In DevTools' Application tab, confirm the access token, ID token, and PKCE verifier are present
      only in `sessionStorage`, with nothing under `localStorage` for this origin.
    - Record the observed network sequence and the storage inspection result.
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

    Note (2026-11-25): PASS, confirmed by the user running the checklist by hand in a real browser
    against `https://<cloudfront-domain>/`. The user reported all items in this checklist
    worked. The user, not the assistant, typed the demo password and read DevTools directly — the
    assistant had no browser access this session and does not record per-step specifics (the exact
    Network-tab sequence, the literal banner text) beyond the user's aggregate confirmation, to avoid
    writing down detail that was never actually observed by whoever is recording it.

  - [x] 8.2 [main] Demo questions, action log, and the denial
    - As `supervisor`, ask demo questions 2 and 3 (the S1 trend, and the lot summary that includes a
      note). Confirm the answer renders with correct Markdown (the lot summary includes a pipe table in
      prior runs — confirm it renders as a real table, not literal pipe characters) and the action log
      shows the right tool, decision `allowed`, and row count.
    - As `inspector-b`, ask for `LOT-20250604-01` (line A). Confirm the fixed denial message and a
      visibly marked "denied" entry in the action log, matching demo question 4's acceptance criterion.
    - Click **New Conversation**; send another message; confirm (via DevTools) the
      `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header value changed.
    - Trigger at least one error path (for example, let a token expire or temporarily break
      `config.json`'s `invocationUrl`) and confirm the UI shows a plain-language message, never a raw
      body or stack trace.
    - Record every observed answer, decision, and error message in the task notes.
    - _Requirements: 4a.2, 5.1, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3_

    Note (2026-11-25): PASS, confirmed by the user, including the demo question 4 denial scenario
    (line B inspector asking for line A data) with the "Denied" chip in the action log — the one
    non-negotiable item in this checklist, confirmed explicitly rather than assumed. As in 8.1, the
    user performed this in a real browser the assistant had no access to this session; the aggregate
    confirmation is recorded rather than fabricated per-step detail (literal answer text, the exact
    session-header value before/after New Conversation).

  - [x] 8.3 [main] Sign-out and the copyable session/trace IDs
    - Click **Sign out**; confirm `sessionStorage` is cleared and the browser lands back on the Hosted
      UI (or the signed-out state of the site).
    - Confirm the session ID and trace ID shown under an answer can be copied (click the copy button,
      paste it somewhere, confirm it matches what was sent/returned).
    - Record the results.
    - _Requirements: 3.5, 6.3_

    Note (2026-11-25): PASS, confirmed by the user — sign-out clears storage and returns to the
    signed-out state, and the copy buttons produce the real session/trace values. Same recording
    caveat as 8.1/8.2: a user-performed browser check, aggregate result recorded.

- [x] 9. [main] Persona switching
  - Time a full cycle: signed in as one persona, sign out, sign in as a different persona, reach the
    point of being able to send a message. Record the elapsed time; confirm it is under 20 seconds.
  - Set up two separate browser profiles (for example two Chrome profiles), sign in as a different
    persona in each, and confirm both stay signed in independently (one profile's sign-out does not
    affect the other).
  - Record both results; they go into `docs/ui.md` verbatim.
  - _Requirements: 7.1, 7.2, 7.3_

  Note (2026-11-25): PASS, confirmed by the user against the deployed site. (1) A sign-out →
  sign-in-as-a-different-persona cycle, through to being able to send a message, measured under 20
  seconds. (2) Two separate browser profiles, each signed in as a different persona, stayed
  independently signed in — signing out in one profile did not affect the other, confirming per-profile
  session isolation (each profile has its own `sessionStorage`).

- [x] 10. [main] Re-run the spike probes against the final deployed state
  - Repeat the three `curl` probes from `docs/spikes/browser-to-runtime.md` against the live, deployed
    runtime and the live, deployed UI's own origin as the `Origin` header value (not the placeholder
    `example.cloudfront.net` used during planning).
  - Confirm the same CORS behavior holds with the real origin. Add this confirmation to
    `docs/spikes/browser-to-runtime.md` as a dated follow-up entry, not a rewrite of the original
    finding.
  - _Requirements: 1.5_

  Note (2026-11-25): PASS. Preflight and no-token probes re-run with
  `Origin: https://<cloudfront-domain>` (the real deployed UI's own origin): identical CORS
  behavior to the original planning probes (`200`/`access-control-allow-origin: *` on preflight,
  `401`/`access-control-allow-origin: *` with no token). The real-token case was confirmed more
  strongly by task 8's actual browser sign-in and chat exchanges, rather than repeated as a bare
  `curl` call. Follow-up entry appended to `docs/spikes/browser-to-runtime.md` under a dated heading,
  not a rewrite of the original finding.

- [x] 11. [main] Write `docs/ui.md`
  - Sections: how sign-in works (with the sequence from `design.md`'s Architecture diagram); the CSP and
    the three origins it allows, with the reason for each; the action log and the explicit statement
    that it is a convenience view, not audit evidence (link `docs/observability.md`); the persona
    switcher, with the measured timing from task 9 and the separate-profiles recipe; deploy/update
    procedure (`make deploy-ui`); known gaps.
  - Use the real results from tasks 7 through 10. Write no step that was not actually run.
  - No account-specific value (account ID, a real Cognito `sub`, a real CloudFront domain) is written
    into the document — use placeholders, matching the convention in `docs/observability.md`.
  - Link it from `docs/README.md`.
  - _Requirements: 1.5, 6.4, 7.3_

  Note (2026-11-25): `docs/ui.md` written, 6 sections, linked from `docs/README.md`. Every step in it
  reflects a real result from tasks 7–10: the deploy/update procedure matches what actually ran in task
  7 (including the manual `--param` syntax needed outside `deploy_all`), the persona-switching numbers
  are the ones confirmed by the user in task 9, and the CSP section quotes the response headers
  actually observed on the deployed distribution. All account-specific values (the real CloudFront
  domain, hosted UI domain, region placeholder) are written as placeholders, matching
  `docs/observability.md`'s convention — not the literal values used while verifying, which live only
  in this task file's notes and get scrubbed in task 12.

- [x] 12. [main] Final checkpoint
  - Run `ruff check .` and `cfn-lint infra/*.yaml` once more, plus `bash -n` on every script.
  - Confirm each verification task carries a note with a real observed result.
  - Run `git status --short` and confirm no file whose name contains `test`, `conftest`, `pytest`, or
    `spec_` was created, and that no generated `build/ui/config.json` or similar artifact was
    accidentally committed.
  - Grep `docs/`, `infra/`, `ui/`, `scripts/`, and this spec folder for the account ID and any real
    Cognito `sub` or CloudFront domain captured during verification. Expect no match.
  - Confirm AWS is left in its intended state: the `ui` stack deployed, `auth`'s callback/logout URLs
    updated, the site reachable and functional for all three personas.
  - Ask the user if questions arise.

  Note (2026-11-25): final state, all clean.
  - `ruff check .` -> `All checks passed!`
  - `uvx --from "cfn-lint==1.60.1" cfn-lint infra/*.yaml` -> exit 0, all 8 templates.
  - `bash -n` on every script in `scripts/` -> ok, `node --check ui/app.js` -> ok.
  - Every verification task (1, 2, 5, 6, 7, 8, 8.1–8.3, 9, 10, 11) carries a note with a real observed
    result. Task 4's note was recorded with task 4 itself, during the implementer review.
  - `git status --short` -> no file whose name contains `test`, `conftest`, `pytest`, or `spec_`; no
    `build/` artifact staged.
  - The real CloudFront domain, bucket name, and distribution ID — written into this file's and
    `docs/spikes/browser-to-runtime.md`'s task notes while recording real verification results — were
    scrubbed to placeholders (`<cloudfront-domain>`, `<bucket-name>`, `<distribution-id>`) once
    verification was complete. A repository-wide grep for the account ID, the real domain, the bucket
    name, the distribution ID, and the hosted-UI-domain suffix now returns no match.
  - AWS left in its intended state: `inspection-agent-demo-ui` deployed (`CREATE_COMPLETE`), the
    `auth` stack's Cognito app client carries both the real CloudFront callback/logout URLs and the
    kept `localhost` default, and the site is reachable and functional for all three personas,
    confirmed by the user in a real browser (task 8) including the line B denial scenario. This spec
    is complete.

## Notes

- No task creates a test file, suite, fixture, eval harness or verification script.
- `Makefile`, `scripts/teardown.sh`, and `COMPONENTS` in `scripts/deploy.sh` need no change — `ui` is
  already wired into all three.
- `infra/auth.yaml` is not changed. Its step-12 circular-dependency handling in `scripts/deploy.sh`
  already does exactly what this spec needs, once `ui.yaml` exists and publishes its two SSM parameters.
- Deploying tasks (7 onward) change real AWS resources in `us-west-2`. Confirm the target account
  before running them.
- Task 8 depends on task 7 (the stack, the auth update, and `config.json` must all exist first). Task 9
  and 10 can run any time after task 8. Task 11 depends on 7 through 10 for its real results.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2", "3", "4"] },
    { "id": 1, "tasks": ["5"] },
    { "id": 2, "tasks": ["6"] },
    { "id": 3, "tasks": ["7"] },
    { "id": 4, "tasks": ["8.1"] },
    { "id": 5, "tasks": ["8.2"] },
    { "id": 6, "tasks": ["8.3", "9", "10"] },
    { "id": 7, "tasks": ["11"] },
    { "id": 8, "tasks": ["12"] }
  ]
}
```
