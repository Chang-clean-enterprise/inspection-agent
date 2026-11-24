#!/usr/bin/env bash
# Send one prompt to the deployed inspection-agent runtime and print the response body.
#
# Usage:
#   scripts/invoke.sh --prompt <text> [--persona <persona>] [--env <env>] [--session-id <id>] [--region <region>]
#
# The Cognito access token comes from one of two sources (see docs/auth.md):
#   - the environment variable AGENT_ACCESS_TOKEN, or
#   - --persona inspector-a|inspector-b|supervisor, which signs in with SRP
#     (docs/auth.md section 7). The password is read from DEMO_PASSWORD_INSPECTOR_A,
#     DEMO_PASSWORD_INSPECTOR_B, or DEMO_PASSWORD_SUPERVISOR, or from a prompt
#     that does not echo. pycognito is installed in a temporary virtual
#     environment that an EXIT trap removes.
# Giving both is a usage error. No option accepts a token, a password, or an
# identity. The token is never printed and never written to a file. It
# reaches curl on standard input (-H @-), so it is not on the command line or in
# the process list.
#
# The runtime ARN is read from SSM /inspection-agent/<env>/runtime/runtime-arn.
# The session header needs at least 33 characters. A given --session-id that is
# long enough is used as is. Otherwise the script generates one.
#
# The HTTP status line ("HTTP <code>") goes to stderr and the response body to stdout.
#
# Exit codes: 0 success (HTTP 2xx), 1 other failure or non-2xx status, 2 usage error or AGENT_ACCESS_TOKEN not set,
# 3 runtime ARN parameter not found.
# Needs aws, curl, and python3 (--persona also needs python3 -m venv and network access to PyPI). Compatible with bash 3.2 (macOS default).
set -Eeuo pipefail

ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2
MIN_SESSION_CHARS=33

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"
PROMPT=""
HAVE_PROMPT=0
SESSION_ID=""
PERSONA=""
TOKEN=""
TMP_DIR=""

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat >&2 <<EOF
Usage:
  $0 --prompt <text> [--persona <persona>] [--env <env>] [--session-id <id>] [--region <region>]

Options:
  --prompt <text>      Question for the agent (required)
  --persona <persona>  Sign in as inspector-a, inspector-b, or supervisor (docs/auth.md section 7).
                       Not allowed together with AGENT_ACCESS_TOKEN
  --env <env>          Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --session-id <id>    Session ID to reuse (at least $MIN_SESSION_CHARS characters; otherwise one is generated)
  --region <region>    AWS region (default: $DEFAULT_REGION)

Environment:
  AGENT_ACCESS_TOKEN             Cognito access token of the caller (required without --persona)
  DEMO_PASSWORD_INSPECTOR_A      Password for --persona inspector-a (otherwise prompted)
  DEMO_PASSWORD_INSPECTOR_B      Password for --persona inspector-b (otherwise prompted)
  DEMO_PASSWORD_SUPERVISOR       Password for --persona supervisor (otherwise prompted)
EOF
}

die() {
  echo "$1" >&2
  exit 1
}

# --- Argument parsing -------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --env)
      [ $# -ge 2 ] || { usage; exit 2; }
      ENV="$2"
      shift 2
      ;;
    --prompt)
      [ $# -ge 2 ] || { usage; exit 2; }
      PROMPT="$2"
      HAVE_PROMPT=1
      shift 2
      ;;
    --persona)
      [ $# -ge 2 ] || { usage; exit 2; }
      PERSONA="$2"
      shift 2
      ;;
    --session-id)
      [ $# -ge 2 ] || { usage; exit 2; }
      SESSION_ID="$2"
      shift 2
      ;;
    --region)
      [ $# -ge 2 ] || { usage; exit 2; }
      REGION="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! [[ "$ENV" =~ $ENV_PATTERN ]]; then
  echo "Invalid Env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)." >&2
  exit 2
fi

if [ "$HAVE_PROMPT" -ne 1 ] || [ -z "$PROMPT" ]; then
  echo "Missing --prompt" >&2
  usage
  exit 2
fi

# Persona table: email and password variable name. The email is never an option.
PERSONA_EMAIL=""
PERSONA_PW_VAR=""
if [ -n "$PERSONA" ]; then
  case "$PERSONA" in
    inspector-a)
      PERSONA_EMAIL="inspector-a@example.com"
      PERSONA_PW_VAR="DEMO_PASSWORD_INSPECTOR_A"
      ;;
    inspector-b)
      PERSONA_EMAIL="inspector-b@example.com"
      PERSONA_PW_VAR="DEMO_PASSWORD_INSPECTOR_B"
      ;;
    supervisor)
      PERSONA_EMAIL="supervisor@example.com"
      PERSONA_PW_VAR="DEMO_PASSWORD_SUPERVISOR"
      ;;
    *)
      echo "Invalid --persona '$PERSONA': must be inspector-a, inspector-b, or supervisor." >&2
      usage
      exit 2
      ;;
  esac
  if [ -n "${AGENT_ACCESS_TOKEN:-}" ]; then
    echo "Both --persona and AGENT_ACCESS_TOKEN are present. Use one of them." >&2
    exit 2
  fi
elif [ -z "${AGENT_ACCESS_TOKEN:-}" ]; then
  echo "AGENT_ACCESS_TOKEN is not set (or use --persona)" >&2
  exit 2
else
  TOKEN="$AGENT_ACCESS_TOKEN"
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

# --- Runtime ARN ------------------------------------------------------------

PARAM_NAME="/inspection-agent/$ENV/runtime/runtime-arn"
if ! RUNTIME_ARN=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$PARAM_NAME" \
  --query Parameter.Value \
  --output text 2>/dev/null) || [ -z "$RUNTIME_ARN" ] || [ "$RUNTIME_ARN" = "None" ]; then
  echo "SSM parameter $PARAM_NAME not found" >&2
  exit 3
fi

# --- Persona sign-in ---------------------------------------------------------

if [ -n "$PERSONA" ]; then
  signin_failed() {
    echo "Sign-in failed." >&2
    exit 1
  }

  POOL_ID=$(aws ssm get-parameter --region "$REGION" \
    --name "/inspection-agent/$ENV/auth/user-pool-id" \
    --query Parameter.Value --output text 2>/dev/null) || signin_failed
  CLIENT_ID=$(aws ssm get-parameter --region "$REGION" \
    --name "/inspection-agent/$ENV/auth/app-client-id" \
    --query Parameter.Value --output text 2>/dev/null) || signin_failed
  { [ -n "$POOL_ID" ] && [ "$POOL_ID" != "None" ] && [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "None" ]; } || signin_failed

  # Temporary virtual environment outside the repository, removed by the EXIT trap.
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/invoke-signin.XXXXXX") || signin_failed
  python3 -m venv "$TMP_DIR/venv" >/dev/null 2>&1 || signin_failed
  "$TMP_DIR/venv/bin/pip" install --quiet --disable-pip-version-check pycognito >/dev/null 2>&1 || signin_failed

  # The password comes from the variable named in the persona table, or from a
  # prompt without echo (getpass). It reaches Python only through the environment
  # of that one process, never as an argument. stderr is dropped so no exception
  # text is shown.
  PW_VALUE="${!PERSONA_PW_VAR:-}"
  TOKEN=$(POOL_ID="$POOL_ID" CLIENT_ID="$CLIENT_ID" AUTH_EMAIL="$PERSONA_EMAIL" \
    PERSONA_PASSWORD="$PW_VALUE" PERSONA_PW_VAR="$PERSONA_PW_VAR" \
    "$TMP_DIR/venv/bin/python" -c '
import getpass, os
from pycognito.aws_srp import AWSSRP

pool_id = os.environ["POOL_ID"]
password = os.environ.get("PERSONA_PASSWORD") or getpass.getpass(os.environ["PERSONA_PW_VAR"] + ": ")
srp = AWSSRP(
    username=os.environ["AUTH_EMAIL"],
    password=password,
    pool_id=pool_id,
    client_id=os.environ["CLIENT_ID"],
    pool_region=pool_id.split("_")[0],
)
print(srp.authenticate_user()["AuthenticationResult"]["AccessToken"])
' 2>/dev/null) || signin_failed
  PW_VALUE=""
  [ -n "$TOKEN" ] || signin_failed
fi

# --- Session ID, body, URL --------------------------------------------------

if [ "${#SESSION_ID}" -lt "$MIN_SESSION_CHARS" ]; then
  if command -v uuidgen >/dev/null 2>&1; then
    SESSION_ID=$(uuidgen)
  else
    SESSION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
  fi
fi

BODY=$(python3 -c 'import json, sys; print(json.dumps({"prompt": sys.argv[1], "session_id": sys.argv[2]}))' "$PROMPT" "$SESSION_ID")
ENCODED_ARN=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$RUNTIME_ARN")
URL="https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$ENCODED_ARN/invocations?qualifier=DEFAULT"

# --- Call -------------------------------------------------------------------

# printf is a builtin, so the token does not show in the process list. curl reads
# the Authorization header from standard input (-H @-).
#
# The response body goes to a temp file (mode 600, inside a directory that the
# EXIT trap removes). curl prints only the status code through -w. The status
# goes to stderr and the body to stdout.
if [ -z "$TMP_DIR" ]; then
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/invoke.XXXXXX") || die "Could not create a temporary directory"
fi
RESPONSE_FILE="$TMP_DIR/response.body"
: > "$RESPONSE_FILE"
chmod 600 "$RESPONSE_FILE"

if ! HTTP_CODE=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -sS -X POST "$URL" \
  -H @- \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  --data-binary "$BODY" \
  -o "$RESPONSE_FILE" \
  -w '%{http_code}'); then
  die "Request to the runtime failed"
fi

echo "HTTP $HTTP_CODE" >&2
cat "$RESPONSE_FILE"
echo

case "$HTTP_CODE" in
  2??) ;;
  *) exit 1 ;;
esac
