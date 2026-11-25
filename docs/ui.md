# Static chat UI

A static page, hosted on S3 and CloudFront, where a user signs in with Cognito and chats with the
inspection agent. Stack: `infra/ui.yaml`. Site: `ui/`.

## 1. How sign-in works

No framework, no build step: one `index.html`, one `app.js`, one `styles.css`, all same-origin. The
authorization code flow with PKCE, because the Cognito app client has no secret
(`GenerateSecret: false`).

```
Browser (no valid token)
   -> app.js redirects to the Cognito Hosted UI (PKCE challenge), BEFORE any call to the agent
Hosted UI: user signs in
   -> redirect to https://<cloudfront-domain>/callback?code=...&state=...
CloudFront: /callback is not a real object, 403 -> CustomErrorResponses -> index.html, 200
app.js: pathname is /callback
   -> POST https://<hosted-ui-domain>/oauth2/token (code + PKCE verifier from sessionStorage)
   -> access_token, id_token stored in sessionStorage
   -> history.replaceState back to /
Chat UI renders. Every message:
   POST https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<encoded-arn>/invocations?qualifier=DEFAULT
     Authorization: Bearer <access_token>
     X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <session-id>
```

**Token storage.** The access token, ID token, and PKCE verifier/state live only in `sessionStorage` —
never `localStorage`, never a URL or query string beyond the one-time `code`/`state` pair on the
`/callback` redirect itself. Confirmed by hand in DevTools' Application tab: nothing under
`localStorage` for the site's origin.

**Sign-in gate.** `ensureSignedIn()` in `app.js` is the one function that decides whether the chat UI
may run. It is awaited before anything else in `main()`, and its redirect branch performs a navigation
that leaves the page — there is no code path that reaches the invocation URL without this gate having
already resolved to "signed in." A failed `/callback` exchange (bad `state`, expired code) clears
storage and falls through to the same "no valid token" check, so it always ends in a fresh redirect
rather than a dead page.

**Sign out** clears `sessionStorage` and navigates to the Cognito `/logout` endpoint with the real
`logout_uri`.

## 2. The Content-Security-Policy

```
default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:;
connect-src 'self' https://<hosted-ui-domain> https://bedrock-agentcore.<region>.amazonaws.com;
object-src 'none'; base-uri 'none'; frame-ancestors 'none'
```

No `unsafe-inline`, no `unsafe-eval` — `index.html` has no inline `<script>`/`<style>` and no inline
event-handler attributes. `connect-src` names exactly the three origins the site ever calls:

| Origin | Why |
|---|---|
| `'self'` | The page, `app.js`, `styles.css`, `config.json` — all same-origin |
| `https://<hosted-ui-domain>` | The Cognito token endpoint, for the PKCE code exchange |
| `https://bedrock-agentcore.<region>.amazonaws.com` | The AgentCore Runtime invocation endpoint |

The Hosted UI's `/oauth2/authorize` sign-in page is a top-level browser navigation
(`location.replace`), not a `fetch`, so it needs no `connect-src` entry.

Confirmed on the deployed site: `curl -I` over HTTPS returns `Strict-Transport-Security`,
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: same-origin`, and the
exact CSP above with the real domain values substituted in.

## 3. The action log — a convenience view, not audit evidence

Each answer shows the `actions` array the agent returned: tool name, decision, row count. A
`forbidden` decision gets a visibly distinct "Denied" chip. The `session_id` and `trace_id` are shown
as copyable text next to the answer.

**This panel is a presenter's convenience, not the audit record.** It shows only what one browser
session received, with no independent verification. For the real evidence — who accessed what, when,
and under which authorization decision, backed by CloudWatch traces and saved queries — see
[observability.md](observability.md).

## 4. Persona switching

Verified by hand against the deployed site: a sign-out → sign-in-as-a-different-persona cycle, through
to being able to send a message, measured **under 20 seconds**.

**Running more than one persona at once:** open the site in separate browser profiles (for example,
two Chrome profiles, or one regular window plus one Incognito window). Each profile has its own
`sessionStorage`, so each stays signed in independently — signing out in one profile does not affect
the other. Verified by hand: two profiles, two different personas, both stayed signed in
simultaneously.

## 5. Deploy and update

```
make deploy-ui
```

This creates or updates the `inspection-agent-<env>-ui` stack, then (inside the same `deploy`
Operational_Script, no separate step):

1. Builds `build/ui/config.json` with the real, URL-encoded invocation URL, the app client ID, the
   hosted UI domain, and the logout URL — resolved fresh from SSM and the stack's own outputs every
   time, never committed to the repository.
2. Syncs `ui/` to the private S3 bucket (`--delete`, excluding `README.md`), then uploads
   `config.json`.
3. Invalidates the CloudFront distribution's cache (`/*`).

After a fresh deploy of `ui` for the first time, run `scripts/deploy.sh ... deploy auth --param
"CallbackUrl=<the ui stack's CallbackUrl output>" --param "LogoutUrl=<...LogoutUrl output>"` (or
re-run `make deploy`, which does this as step 12) so the Cognito app client accepts the real
CloudFront URLs. This is the same circular-dependency solution spec 04 already established: `ui.yaml`
never reads anything from the `auth` stack; the deploy *script* is the only thing that connects them,
through SSM.

To update the site after an edit to `ui/*`, running `make deploy-ui` again is enough — the sync and
invalidation happen on every deploy.

## 6. Known gaps

- The `/callback` path has no automatic re-redirect loop guard beyond one fallback level: a failed
  exchange clears storage and falls through to a fresh sign-in redirect, which is correct, but a
  pathological sequence of repeated invalid callbacks would simply repeat that cycle rather than
  surfacing a distinct error to the user.
- There is no Enter-to-send keyboard shortcut from the multi-line prompt textarea; the user sends with
  the button. Not a correctness issue, a minor convenience gap.
- The Markdown renderer's table detection is a simple "does this line contain a pipe character" check;
  an answer that happens to contain a literal `|` outside a real table could render oddly. It always
  falls back to escaped plain text rather than guessing incorrectly, so this is cosmetic only.
- No response streaming — out of scope for this spec. The agent's observed latency (roughly 8 s p50,
  10.5 s p95 per question, per `docs/observability.md`) is covered by a loading indicator, not a
  token-by-token stream.
