"use strict";

/*
 * Static chat UI for the inspection agent.
 *
 * No framework, no build step, no classes. Plain functions, organized in
 * sections:
 *   1. Storage keys and small constants
 *   2. Base64url + PKCE helpers
 *   3. JWT decode helpers (no signature verification: the Runtime is the
 *      real enforcement point, this is only for display and expiry checks)
 *   4. Config loading
 *   5. Sign-in gate (ensureSignedIn) and the Cognito Hosted UI round trip
 *   6. Agent invocation and error-message extraction
 *   7. Safe-subset Markdown renderer
 *   8. Chat state and rendering
 *   9. Wiring and startup
 *
 * Hard rule: `.innerHTML` is assigned in exactly one place in this file,
 * with the return value of renderMarkdown() and nothing else. Every other
 * place that shows dynamic text uses `.textContent`.
 */

// ---------------------------------------------------------------------------
// 1. Storage keys and small constants
// ---------------------------------------------------------------------------

const STORAGE_KEYS = {
  accessToken: "ia_access_token",
  idToken: "ia_id_token",
  pkceVerifier: "ia_pkce_verifier",
  pkceState: "ia_pkce_state",
};

const FALLBACK_ERROR_MESSAGE = "The agent could not complete this request. Try again.";
const NETWORK_ERROR_MESSAGE = "Could not reach the agent. Check your connection and try again.";

// ---------------------------------------------------------------------------
// 2. Base64url + PKCE helpers (RFC 7636)
// ---------------------------------------------------------------------------

function base64UrlEncode(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  const base64 = btoa(binary);
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function generateRandomBase64Url(byteLength) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

// 64 random bytes -> 86 base64url characters, within the 43-128 range RFC 7636 requires.
function generateVerifier() {
  return generateRandomBase64Url(64);
}

function generateState() {
  return generateRandomBase64Url(16);
}

async function challengeFor(verifier) {
  const encoder = new TextEncoder();
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(verifier));
  return base64UrlEncode(new Uint8Array(digest));
}

// ---------------------------------------------------------------------------
// 3. JWT decode helpers (decode only, no signature verification)
// ---------------------------------------------------------------------------

function decodeJwtPayload(token) {
  try {
    const parts = token.split(".");
    if (parts.length < 2) {
      return null;
    }
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    const json = new TextDecoder().decode(bytes);
    return JSON.parse(json);
  } catch (err) {
    return null;
  }
}

function isTokenExpired(token) {
  const payload = decodeJwtPayload(token);
  if (!payload || typeof payload.exp !== "number") {
    return true;
  }
  const nowSeconds = Date.now() / 1000;
  return payload.exp <= nowSeconds;
}

// ---------------------------------------------------------------------------
// 4. Config loading
// ---------------------------------------------------------------------------

async function loadConfig() {
  const response = await fetch("/config.json");
  if (!response.ok) {
    throw new Error("Failed to load config.json");
  }
  return response.json();
}

// ---------------------------------------------------------------------------
// 5. Sign-in gate
// ---------------------------------------------------------------------------

function buildRedirectUri() {
  return `${location.origin}/callback`;
}

async function exchangeCodeForTokens(config, code, verifier) {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: config.appClientId,
    code,
    redirect_uri: buildRedirectUri(),
    code_verifier: verifier,
  });
  const response = await fetch(`https://${config.hostedUiDomain}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  if (!response.ok) {
    throw new Error("Token exchange failed");
  }
  return response.json();
}

// Reads the authorization code from the /callback query string, verifies the
// state, exchanges it for tokens, and returns to a clean URL. Returns true
// once a valid token is stored, false if anything about the callback was
// invalid (missing code, state mismatch, failed exchange) -- in which case
// storage is cleared so the caller falls back to a fresh sign-in redirect.
async function handleCallback(config) {
  const params = new URLSearchParams(location.search);
  const code = params.get("code");
  const state = params.get("state");
  const storedState = sessionStorage.getItem(STORAGE_KEYS.pkceState);
  const verifier = sessionStorage.getItem(STORAGE_KEYS.pkceVerifier);

  if (!code || !state || !storedState || state !== storedState || !verifier) {
    sessionStorage.clear();
    history.replaceState(null, "", "/");
    return false;
  }

  try {
    const tokens = await exchangeCodeForTokens(config, code, verifier);
    sessionStorage.setItem(STORAGE_KEYS.accessToken, tokens.access_token);
    sessionStorage.setItem(STORAGE_KEYS.idToken, tokens.id_token);
    sessionStorage.removeItem(STORAGE_KEYS.pkceVerifier);
    sessionStorage.removeItem(STORAGE_KEYS.pkceState);
    history.replaceState(null, "", "/");
    return true;
  } catch (err) {
    sessionStorage.clear();
    history.replaceState(null, "", "/");
    return false;
  }
}

// Builds the PKCE pair, stores the verifier and state, and navigates away to
// the Cognito Hosted UI. This performs a top-level navigation; it does not
// return control to a meaningful continuation inside this app.
async function redirectToHostedUi(config) {
  const verifier = generateVerifier();
  const challenge = await challengeFor(verifier);
  const state = generateState();
  sessionStorage.setItem(STORAGE_KEYS.pkceVerifier, verifier);
  sessionStorage.setItem(STORAGE_KEYS.pkceState, state);

  const redirectUri = buildRedirectUri();
  const url =
    `https://${config.hostedUiDomain}/oauth2/authorize` +
    `?response_type=code` +
    `&client_id=${encodeURIComponent(config.appClientId)}` +
    `&redirect_uri=${encodeURIComponent(redirectUri)}` +
    `&scope=openid+email+profile` +
    `&code_challenge=${encodeURIComponent(challenge)}` +
    `&code_challenge_method=S256` +
    `&state=${encodeURIComponent(state)}`;

  location.replace(url);
}

// The sign-in gate. Returns true only once a valid, unexpired access token is
// present in sessionStorage and the caller may proceed to use the app
// (including calling config.invocationUrl). Returns false only when it has
// just initiated a redirect away from the page -- the caller MUST NOT
// proceed to call the agent in that case. A failed /callback exchange does
// NOT return false on its own: it falls through to the normal "no valid
// token" check below, so a bad state/code/exchange always ends in a fresh
// redirect to the Hosted UI rather than leaving the page inert.
async function ensureSignedIn(config) {
  if (location.pathname === "/callback") {
    const ok = await handleCallback(config);
    if (ok) {
      return true;
    }
    // handleCallback already cleared storage and reset the URL to "/" on
    // failure; fall through to the same check the non-callback path uses.
  }

  const accessToken = sessionStorage.getItem(STORAGE_KEYS.accessToken);
  if (accessToken && !isTokenExpired(accessToken)) {
    return true;
  }

  await redirectToHostedUi(config);
  return false;
}

function signOut(config) {
  sessionStorage.clear();
  const logoutUrl =
    `https://${config.hostedUiDomain}/logout` +
    `?client_id=${encodeURIComponent(config.appClientId)}` +
    `&logout_uri=${encodeURIComponent(config.logoutUrl)}`;
  location.href = logoutUrl;
}

// ---------------------------------------------------------------------------
// 6. Agent invocation and error-message extraction
// ---------------------------------------------------------------------------

async function callAgent(config, accessToken, sessionId, prompt) {
  const response = await fetch(config.invocationUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      [config.sessionHeaderName]: sessionId,
    },
    body: JSON.stringify({ prompt, session_id: sessionId }),
  });

  let body = null;
  try {
    body = await response.json();
  } catch (err) {
    body = null;
  }

  return { status: response.status, body };
}

// Defensive by design: never throws, never returns a raw body. Covers the
// app's own error shape, the authorizer-layer shapes observed in the spike,
// and a fixed fallback for anything else.
function extractErrorMessage(httpStatus, body) {
  return body?.error?.message ?? body?.message ?? FALLBACK_ERROR_MESSAGE;
}

// ---------------------------------------------------------------------------
// 7. Safe-subset Markdown renderer
// ---------------------------------------------------------------------------

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Applies bold/italic/code inline transforms, in that fixed order, to an
// already-escaped fragment. Only ever emits <strong>, <em>, <code>.
function applyInline(escapedFragment) {
  return escapedFragment
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/`(.+?)`/g, "<code>$1</code>");
}

function isTableRow(line) {
  return line.includes("|");
}

function parseTableRow(line) {
  let trimmed = line.trim();
  if (trimmed.startsWith("|")) {
    trimmed = trimmed.slice(1);
  }
  if (trimmed.endsWith("|")) {
    trimmed = trimmed.slice(0, -1);
  }
  return trimmed.split("|").map((cell) => cell.trim());
}

function isSeparatorRow(cells) {
  return cells.every((cell) => /^:?-{1,}:?$/.test(cell));
}

// Builds a <table> from a block of consecutive pipe-delimited lines. Returns
// null when the block is ambiguous (inconsistent column counts), signalling
// the caller to fall back to plain escaped text instead of guessing.
function renderTable(tableLines) {
  const rows = tableLines.map(parseTableRow);
  const colCount = rows[0].length;
  const consistent = colCount > 0 && rows.every((row) => row.length === colCount);
  if (!consistent) {
    return null;
  }

  let bodyRows = rows;
  if (rows.length > 1 && isSeparatorRow(rows[1])) {
    bodyRows = [rows[0], ...rows.slice(2)];
  }

  const rowsHtml = bodyRows
    .map((row) => `<tr>${row.map((cell) => `<td>${applyInline(cell)}</td>`).join("")}</tr>`)
    .join("");
  return `<table>${rowsHtml}</table>`;
}

function isUnorderedItem(line) {
  return /^\s*-\s+/.test(line);
}

function stripUnorderedMarker(line) {
  return line.replace(/^\s*-\s+/, "");
}

function isOrderedItem(line) {
  return /^\s*\d+\.\s+/.test(line);
}

function stripOrderedMarker(line) {
  return line.replace(/^\s*\d+\.\s+/, "");
}

function renderMarkdownUnsafe(text) {
  const escaped = escapeHtml(text);
  const lines = escaped.split("\n");
  const htmlParts = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.trim() === "") {
      i += 1;
      continue;
    }

    if (isTableRow(line)) {
      const tableLines = [];
      while (i < lines.length && isTableRow(lines[i])) {
        tableLines.push(lines[i]);
        i += 1;
      }
      const tableHtml = renderTable(tableLines);
      if (tableHtml !== null) {
        htmlParts.push(tableHtml);
      } else {
        htmlParts.push(`<p>${tableLines.join("<br>")}</p>`);
      }
      continue;
    }

    if (isUnorderedItem(line)) {
      const items = [];
      while (i < lines.length && isUnorderedItem(lines[i])) {
        items.push(stripUnorderedMarker(lines[i]));
        i += 1;
      }
      const itemsHtml = items.map((item) => `<li>${applyInline(item)}</li>`).join("");
      htmlParts.push(`<ul>${itemsHtml}</ul>`);
      continue;
    }

    if (isOrderedItem(line)) {
      const items = [];
      while (i < lines.length && isOrderedItem(lines[i])) {
        items.push(stripOrderedMarker(lines[i]));
        i += 1;
      }
      const itemsHtml = items.map((item) => `<li>${applyInline(item)}</li>`).join("");
      htmlParts.push(`<ol>${itemsHtml}</ol>`);
      continue;
    }

    const paragraphLines = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      !isTableRow(lines[i]) &&
      !isUnorderedItem(lines[i]) &&
      !isOrderedItem(lines[i])
    ) {
      paragraphLines.push(applyInline(lines[i]));
      i += 1;
    }
    htmlParts.push(`<p>${paragraphLines.join("<br>")}</p>`);
  }

  return htmlParts.join("");
}

// Public entry point. Never throws; falls back to escaped plain text on any
// unexpected error. Only ever emits tags this function itself constructs.
function renderMarkdown(text) {
  try {
    return renderMarkdownUnsafe(text);
  } catch (err) {
    return escapeHtml(text);
  }
}

// ---------------------------------------------------------------------------
// 8. Chat state and rendering
// ---------------------------------------------------------------------------

const state = {
  config: null,
  sessionId: null,
  messages: [],
  sending: false,
};

function newSessionId() {
  return crypto.randomUUID();
}

function startNewConversation() {
  state.sessionId = newSessionId();
  state.messages = [];
  renderMessages();
}

function setSending(value) {
  state.sending = value;
  const sendBtn = document.getElementById("send-btn");
  const input = document.getElementById("prompt-input");
  const indicator = document.getElementById("loading-indicator");
  sendBtn.disabled = value;
  input.disabled = value;
  indicator.hidden = !value;
}

function buildCopyableField(label, value) {
  const wrapper = document.createElement("span");
  wrapper.className = "copyable-field";

  const labelSpan = document.createElement("span");
  labelSpan.className = "copyable-label";
  labelSpan.textContent = `${label}: `;

  const codeEl = document.createElement("code");
  codeEl.textContent = value ?? "";

  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "copy-btn";
  copyBtn.textContent = "Copy";
  copyBtn.addEventListener("click", () => {
    navigator.clipboard.writeText(value ?? "");
  });

  wrapper.append(labelSpan, codeEl, copyBtn);
  return wrapper;
}

function buildActionLog(message) {
  const section = document.createElement("div");
  section.className = "action-log";

  const list = document.createElement("ul");
  list.className = "action-list";
  for (const action of message.actions ?? []) {
    const item = document.createElement("li");
    item.className = "action-item";

    const toolSpan = document.createElement("span");
    toolSpan.className = "action-tool";
    toolSpan.textContent = action.tool ?? "unknown tool";

    const decision = action.decision ?? "none";
    const decisionSpan = document.createElement("span");
    decisionSpan.className = `decision decision-${decision}`;
    decisionSpan.textContent = decision === "forbidden" ? "Denied" : decision;

    const rowsSpan = document.createElement("span");
    rowsSpan.className = "action-rows";
    rowsSpan.textContent = `${action.row_count ?? 0} rows`;

    item.append(toolSpan, decisionSpan, rowsSpan);
    list.appendChild(item);
  }
  section.appendChild(list);

  const meta = document.createElement("div");
  meta.className = "message-meta";
  meta.appendChild(buildCopyableField("Session", message.sessionId));
  meta.appendChild(buildCopyableField("Trace", message.traceId));
  section.appendChild(meta);

  return section;
}

function buildMessageElement(message) {
  const wrapper = document.createElement("div");
  wrapper.className = `message message-${message.role}`;

  const bubble = document.createElement("div");
  bubble.className = "bubble";
  if (message.role === "assistant") {
    // The one and only place in this file that assigns .innerHTML, and only
    // ever with renderMarkdown's own return value.
    bubble.innerHTML = renderMarkdown(message.text);
  } else {
    bubble.textContent = message.text;
  }
  wrapper.appendChild(bubble);

  if (message.role === "assistant") {
    wrapper.appendChild(buildActionLog(message));
  }

  return wrapper;
}

function renderMessages() {
  const container = document.getElementById("messages");
  container.textContent = "";
  for (const message of state.messages) {
    container.appendChild(buildMessageElement(message));
  }
  container.scrollTop = container.scrollHeight;
}

function renderSignInBanner() {
  const idToken = sessionStorage.getItem(STORAGE_KEYS.idToken);
  const payload = idToken ? decodeJwtPayload(idToken) : null;
  const emailSpan = document.getElementById("signin-email");

  if (!payload) {
    emailSpan.textContent = "";
    return;
  }

  const email = payload.email ?? "unknown user";
  const groups = Array.isArray(payload["cognito:groups"]) ? payload["cognito:groups"].join(", ") : "no groups";
  emailSpan.textContent = `Signed in as ${email} (${groups})`;
}

// Enter sends the message; Shift+Enter inserts a newline (the textarea's own
// default behavior, left untouched). requestSubmit() re-enters the normal
// submit path (handleSend) rather than duplicating it.
function handlePromptKeydown(event) {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    document.getElementById("composer").requestSubmit();
  }
}

async function handleSend(event) {
  event.preventDefault();
  if (state.sending) {
    return;
  }

  const input = document.getElementById("prompt-input");
  const prompt = input.value.trim();
  if (!prompt) {
    return;
  }
  input.value = "";

  state.messages.push({ role: "user", text: prompt });
  renderMessages();
  setSending(true);

  try {
    const accessToken = sessionStorage.getItem(STORAGE_KEYS.accessToken);
    const { status, body } = await callAgent(state.config, accessToken, state.sessionId, prompt);

    if (status >= 200 && status < 300 && body && typeof body.answer === "string") {
      state.messages.push({
        role: "assistant",
        text: body.answer,
        actions: Array.isArray(body.actions) ? body.actions : [],
        sessionId: body.session_id,
        traceId: body.trace_id,
      });
    } else {
      state.messages.push({ role: "error", text: extractErrorMessage(status, body) });
    }
  } catch (err) {
    state.messages.push({ role: "error", text: NETWORK_ERROR_MESSAGE });
  } finally {
    setSending(false);
    renderMessages();
  }
}

// ---------------------------------------------------------------------------
// 9. Wiring and startup
// ---------------------------------------------------------------------------

async function main() {
  const config = await loadConfig();
  state.config = config;

  // The sign-in gate MUST run and complete before anything below can call
  // config.invocationUrl. If it returns false, it has either just redirected
  // the page away or failed a /callback exchange; either way, startup stops
  // here and no agent call is possible.
  const signedIn = await ensureSignedIn(config);
  if (!signedIn) {
    return;
  }

  state.sessionId = newSessionId();
  renderSignInBanner();
  renderMessages();

  document.getElementById("composer").addEventListener("submit", handleSend);
  document.getElementById("new-conversation-btn").addEventListener("click", startNewConversation);
  document.getElementById("signout-btn").addEventListener("click", () => signOut(config));
  document.getElementById("prompt-input").addEventListener("keydown", handlePromptKeydown);
}

document.addEventListener("DOMContentLoaded", () => {
  main().catch((err) => {
    const emailSpan = document.getElementById("signin-email");
    if (emailSpan) {
      emailSpan.textContent = "Unable to load the application.";
    }
  });
});
