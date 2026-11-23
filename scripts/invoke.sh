#!/usr/bin/env bash
# Send one prompt to the deployed inspection-agent runtime and print the response body.
#
# Usage:
#   scripts/invoke.sh --prompt <text> [--env <env>] [--session-id <id>] [--region <region>]
#
# The Cognito access token is read only from the environment variable
# AGENT_ACCESS_TOKEN (see docs/auth.md). No option accepts a token, a password,
# or an identity. The token is never printed and never written to a file. It
# reaches curl on standard input (-H @-), so it is not on the command line or in
# the process list.
#
# The runtime ARN is read from SSM /inspection-agent/<env>/runtime/runtime-arn.
# The session header needs at least 33 characters. A given --session-id that is
# long enough is used as is. Otherwise the script generates one.
#
# Exit codes: 0 success, 1 other failure, 2 usage error or AGENT_ACCESS_TOKEN not set,
# 3 runtime ARN parameter not found.
# Needs aws, curl, and python3. Compatible with bash 3.2 (macOS default).
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

usage() {
  cat >&2 <<EOF
Usage:
  $0 --prompt <text> [--env <env>] [--session-id <id>] [--region <region>]

Options:
  --prompt <text>      Question for the agent (required)
  --env <env>          Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --session-id <id>    Session ID to reuse (at least $MIN_SESSION_CHARS characters; otherwise one is generated)
  --region <region>    AWS region (default: $DEFAULT_REGION)

Environment:
  AGENT_ACCESS_TOKEN   Cognito access token of the caller (required)
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

if [ -z "${AGENT_ACCESS_TOKEN:-}" ]; then
  echo "AGENT_ACCESS_TOKEN is not set" >&2
  exit 2
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
printf 'Authorization: Bearer %s\n' "$AGENT_ACCESS_TOKEN" | curl -sS -X POST "$URL" \
  -H @- \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  --data-binary "$BODY"
echo
