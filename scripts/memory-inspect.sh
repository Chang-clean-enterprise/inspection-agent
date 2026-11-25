#!/usr/bin/env bash
# Print one actor's AgentCore Memory contents: short-term session events and
# long-term memory records. Operational_Script 9 (memory inspect). Read only:
# it calls no create, update, or delete operation, and it asserts nothing.
#
# Usage:
#   scripts/memory-inspect.sh (--persona inspector-a|inspector-b|supervisor | --actor <actor-id>)
#                              [--env <env>] [--region <region>]
#                              [--session <id>] [--query <text>] [--max-events <n>]
#
# Exactly one of --persona and --actor is required. --persona signs in no one;
# it only resolves the Cognito sub of the fixed demo email with
# `aws cognito-idp admin-get-user`, run under the operator's own AWS identity
# (docs/auth.md section 7, same persona table as scripts/invoke.sh).
#
# The memory ID comes from SSM /inspection-agent/<env>/memory/memory-id,
# published by the memory stack. The script then runs, per actor:
#   - short-term: `list-sessions` (or the single --session given), then
#     `list-events --include-payloads` per session, printing timestamp, role,
#     and a truncated message for every USER/ASSISTANT entry.
#   - long-term: `retrieve-memory-records --namespace`, once for
#     /facts/<actor>/ and once per session for /summaries/<actor>/<session>/.
#     The exact --namespace form is used, not --namespace-path: the installed
#     AWS CLI (2.31.22 at the time this was written) does not expose
#     --namespace-path on retrieve-memory-records.
# A closing summary line reports the actor, the session count, the event
# count, and the record count per namespace.
#
# Run it once per persona and compare the two outputs to check isolation
# (demo question 5, Requirement 5).
#
# Exit codes: 0 success, 1 other failure (actor resolution failed, or the
# memory-id parameter holds the literal "none", meaning the memory stack is
# not deployed for this env), 2 usage error, 3 the memory-id SSM parameter
# was not found.
# Needs aws and python3. Compatible with bash 3.2 (macOS default).
set -Eeuo pipefail

ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
ACTOR_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
# Matches the service SessionId pattern [a-zA-Z0-9][a-zA-Z0-9-_]* (max 100).
# The hyphen is required: scripts/invoke.sh generates session IDs with uuidgen,
# which produces hyphenated values.
SESSION_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2
DEFAULT_QUERY="inspection reports and parts discussed"
DEFAULT_MAX_EVENTS=20
TEXT_TRUNCATE_CHARS=200
TOP_K=5

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"
PERSONA=""
ACTOR=""
SESSION_ID=""
QUERY_TEXT="$DEFAULT_QUERY"
MAX_EVENTS="$DEFAULT_MAX_EVENTS"

usage() {
  cat >&2 <<EOF
Usage:
  $0 (--persona inspector-a|inspector-b|supervisor | --actor <actor-id>)
     [--env <env>] [--region <region>]
     [--session <id>] [--query <text>] [--max-events <n>]

Options:
  --persona <persona>  Resolve the actor from a demo email (docs/auth.md section 7).
                       Not allowed together with --actor
  --actor <actor-id>   Use this actor ID (the Cognito sub) as given.
                       Not allowed together with --persona
  --env <env>          Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --region <region>    AWS region (default: $DEFAULT_REGION)
  --session <id>       Inspect only this session instead of listing every session
  --query <text>       Search text for long-term retrieval (default: "$DEFAULT_QUERY")
  --max-events <n>     Max events listed per session (default: $DEFAULT_MAX_EVENTS)

Exactly one of --persona and --actor is required.
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
    --region)
      [ $# -ge 2 ] || { usage; exit 2; }
      REGION="$2"
      shift 2
      ;;
    --persona)
      [ $# -ge 2 ] || { usage; exit 2; }
      PERSONA="$2"
      shift 2
      ;;
    --actor)
      [ $# -ge 2 ] || { usage; exit 2; }
      ACTOR="$2"
      shift 2
      ;;
    --session)
      [ $# -ge 2 ] || { usage; exit 2; }
      SESSION_ID="$2"
      shift 2
      ;;
    --query)
      [ $# -ge 2 ] || { usage; exit 2; }
      QUERY_TEXT="$2"
      shift 2
      ;;
    --max-events)
      [ $# -ge 2 ] || { usage; exit 2; }
      MAX_EVENTS="$2"
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

# --- Validation (before any AWS CLI call) -----------------------------------

if ! [[ "$ENV" =~ $ENV_PATTERN ]]; then
  echo "Invalid --env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)." >&2
  exit 2
fi

if [ -n "$PERSONA" ] && [ -n "$ACTOR" ]; then
  echo "Both --persona and --actor are present. Use exactly one of them." >&2
  usage
  exit 2
fi

if [ -z "$PERSONA" ] && [ -z "$ACTOR" ]; then
  echo "Exactly one of --persona or --actor is required." >&2
  usage
  exit 2
fi

if [ -n "$ACTOR" ] && ! [[ "$ACTOR" =~ $ACTOR_ID_PATTERN ]]; then
  echo "Invalid --actor '$ACTOR': must match pattern $ACTOR_ID_PATTERN." >&2
  exit 2
fi

if [ -n "$SESSION_ID" ] && ! [[ "$SESSION_ID" =~ $SESSION_ID_PATTERN ]]; then
  echo "Invalid --session '$SESSION_ID': must match pattern $SESSION_ID_PATTERN." >&2
  exit 2
fi

if ! [[ "$MAX_EVENTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid --max-events '$MAX_EVENTS': must be a positive integer." >&2
  exit 2
fi

# Persona table: fixed demo email, same as scripts/invoke.sh. No password is
# needed; only the Cognito sub of the email is resolved, with the operator's
# own AWS identity.
PERSONA_EMAIL=""
if [ -n "$PERSONA" ]; then
  case "$PERSONA" in
    inspector-a)
      PERSONA_EMAIL="inspector-a@example.com"
      ;;
    inspector-b)
      PERSONA_EMAIL="inspector-b@example.com"
      ;;
    supervisor)
      PERSONA_EMAIL="supervisor@example.com"
      ;;
    *)
      echo "Invalid --persona '$PERSONA': must be inspector-a, inspector-b, or supervisor." >&2
      usage
      exit 2
      ;;
  esac
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

# --- Memory ID ---------------------------------------------------------------

MEMORY_PARAM="/inspection-agent/$ENV/memory/memory-id"
if ! MEMORY_ID=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$MEMORY_PARAM" \
  --query Parameter.Value \
  --output text 2>/dev/null) || [ -z "$MEMORY_ID" ] || [ "$MEMORY_ID" = "None" ]; then
  echo "SSM parameter $MEMORY_PARAM not found" >&2
  exit 3
fi

if [ "$MEMORY_ID" = "none" ]; then
  echo "Memory is not deployed for env '$ENV' (memory-id is 'none'). Run: make deploy-memory" >&2
  exit 1
fi

# --- Resolve the actor ---------------------------------------------------------

if [ -n "$PERSONA" ]; then
  POOL_ID=$(aws ssm get-parameter --region "$REGION" \
    --name "/inspection-agent/$ENV/auth/user-pool-id" \
    --query Parameter.Value --output text 2>/dev/null) || die "Could not read the user pool ID"
  { [ -n "$POOL_ID" ] && [ "$POOL_ID" != "None" ]; } || die "Could not read the user pool ID"

  ACTOR=$(aws cognito-idp admin-get-user --region "$REGION" \
    --user-pool-id "$POOL_ID" \
    --username "$PERSONA_EMAIL" \
    --query 'UserAttributes[?Name==`sub`].Value | [0]' \
    --output text 2>/dev/null) || die "Could not resolve the actor for persona $PERSONA"
  { [ -n "$ACTOR" ] && [ "$ACTOR" != "None" ]; } || die "Could not resolve the actor for persona $PERSONA"
fi

echo "Actor: $ACTOR" >&2

# --- Short-term: sessions and events -----------------------------------------

echo "=== Short-term events ==="

if [ -n "$SESSION_ID" ]; then
  SESSION_LIST="$SESSION_ID"
else
  SESSION_LIST=$(aws bedrock-agentcore list-sessions --region "$REGION" \
    --memory-id "$MEMORY_ID" \
    --actor-id "$ACTOR" \
    --query 'sessionSummaries[].sessionId' \
    --output text 2>/dev/null) || SESSION_LIST=""
fi

SESSION_ARR=()
if [ -n "$SESSION_LIST" ]; then
  for s in $SESSION_LIST; do
    SESSION_ARR+=("$s")
  done
fi

SESSION_COUNT=${#SESSION_ARR[@]}
MESSAGE_COUNT=0

if [ "$SESSION_COUNT" -eq 0 ]; then
  echo "(no sessions found)"
fi

for s in ${SESSION_ARR[@]+"${SESSION_ARR[@]}"}; do
  echo "--- session $s ---"
  EVENTS_JSON=$(aws bedrock-agentcore list-events --region "$REGION" \
    --memory-id "$MEMORY_ID" \
    --actor-id "$ACTOR" \
    --session-id "$s" \
    --include-payloads \
    --max-items "$MAX_EVENTS" \
    --output json 2>/dev/null) || EVENTS_JSON='{"events": []}'

  EVENT_LINES=$(TRUNCATE="$TEXT_TRUNCATE_CHARS" python3 -c '
import json, os, sys

truncate = int(os.environ["TRUNCATE"])
data = json.loads(sys.argv[1])
for event in data.get("events", []):
    timestamp = event.get("eventTimestamp", "")
    for item in event.get("payload", []):
        conv = item.get("conversational")
        if not conv:
            continue
        role = conv.get("role", "")
        text = (conv.get("content", {}) or {}).get("text", "") or ""
        text = " ".join(text.split())
        if len(text) > truncate:
            text = text[: truncate - 3] + "..."
        print(f"{timestamp}\t{role}\t{text}")
' "$EVENTS_JSON")

  # One line per conversational message, so this counts messages, not events.
  # A turn writes two messages, so a healthy session shows an even number.
  if [ -n "$EVENT_LINES" ]; then
    printf '%s\n' "$EVENT_LINES"
    THIS_MESSAGE_COUNT=$(printf '%s\n' "$EVENT_LINES" | wc -l | tr -d ' ')
  else
    echo "(no events)"
    THIS_MESSAGE_COUNT=0
  fi
  MESSAGE_COUNT=$((MESSAGE_COUNT + THIS_MESSAGE_COUNT))
done

# --- Long-term: memory records ------------------------------------------------

echo
echo "=== Long-term records ==="

SEARCH_CRITERIA=$(TOP_K="$TOP_K" python3 -c '
import json, os, sys
print(json.dumps({"searchQuery": sys.argv[1], "topK": int(os.environ["TOP_K"])}))
' "$QUERY_TEXT")

print_records() {
  # $1: namespace, $2: records JSON. Prints one line per record and returns
  # the record count on stdout as the only line that follows "__COUNT__ ".
  TRUNCATE="$TEXT_TRUNCATE_CHARS" python3 -c '
import json, os, sys

truncate = int(os.environ["TRUNCATE"])
namespace = sys.argv[1]
data = json.loads(sys.argv[2])
count = 0
for record in data.get("memoryRecordSummaries", []):
    text = (record.get("content", {}) or {}).get("text", "") or ""
    text = " ".join(text.split())
    if len(text) > truncate:
        text = text[: truncate - 3] + "..."
    print(f"{namespace}\t{text}")
    count += 1
print(f"__COUNT__ {count}")
' "$1" "$2"
}

FACTS_NAMESPACE="/facts/$ACTOR/"
FACTS_JSON=$(aws bedrock-agentcore retrieve-memory-records --region "$REGION" \
  --memory-id "$MEMORY_ID" \
  --namespace "$FACTS_NAMESPACE" \
  --search-criteria "$SEARCH_CRITERIA" \
  --output json 2>/dev/null) || FACTS_JSON='{"memoryRecordSummaries": []}'

echo "--- namespace $FACTS_NAMESPACE ---"
FACTS_OUT=$(print_records "$FACTS_NAMESPACE" "$FACTS_JSON")
FACTS_COUNT=$(printf '%s\n' "$FACTS_OUT" | awk '/^__COUNT__ /{print $2}')
FACTS_LINES=$(printf '%s\n' "$FACTS_OUT" | grep -v '^__COUNT__ ' || true)
if [ -n "$FACTS_LINES" ]; then
  printf '%s\n' "$FACTS_LINES"
else
  echo "(no records)"
fi

SUMMARIES_COUNT=0
if [ "$SESSION_COUNT" -eq 0 ]; then
  echo "(no sessions, so no /summaries/ namespace to query)"
else
  for s in "${SESSION_ARR[@]}"; do
    SUMMARY_NAMESPACE="/summaries/$ACTOR/$s/"
    SUMMARY_JSON=$(aws bedrock-agentcore retrieve-memory-records --region "$REGION" \
      --memory-id "$MEMORY_ID" \
      --namespace "$SUMMARY_NAMESPACE" \
      --search-criteria "$SEARCH_CRITERIA" \
      --output json 2>/dev/null) || SUMMARY_JSON='{"memoryRecordSummaries": []}'

    echo "--- namespace $SUMMARY_NAMESPACE ---"
    SUMMARY_OUT=$(print_records "$SUMMARY_NAMESPACE" "$SUMMARY_JSON")
    THIS_SUMMARY_COUNT=$(printf '%s\n' "$SUMMARY_OUT" | awk '/^__COUNT__ /{print $2}')
    SUMMARY_LINES=$(printf '%s\n' "$SUMMARY_OUT" | grep -v '^__COUNT__ ' || true)
    if [ -n "$SUMMARY_LINES" ]; then
      printf '%s\n' "$SUMMARY_LINES"
    else
      echo "(no records)"
    fi
    SUMMARIES_COUNT=$((SUMMARIES_COUNT + THIS_SUMMARY_COUNT))
  done
fi

# --- Summary -------------------------------------------------------------------

echo
echo "=== Summary ==="
echo "actor=$ACTOR sessions=$SESSION_COUNT messages=$MESSAGE_COUNT facts_records=$FACTS_COUNT summaries_records=$SUMMARIES_COUNT"
