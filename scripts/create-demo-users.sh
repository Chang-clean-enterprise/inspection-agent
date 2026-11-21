#!/usr/bin/env bash
# Create the three demo users in the Cognito user pool of an inspection-agent
# environment, mark their email as verified, set permanent passwords, and add
# each user to its group. Safe to run more than once.
#
# Usage:
#   scripts/create-demo-users.sh [--env <env>] [--region <region>]
#
# Passwords are read from these environment variables. When a variable is empty
# and standard input is a terminal, the script prompts without echo:
#   DEMO_PASSWORD_INSPECTOR_A   inspector-a@example.com (group line-a)
#   DEMO_PASSWORD_INSPECTOR_B   inspector-b@example.com (group line-b)
#   DEMO_PASSWORD_SUPERVISOR    supervisor@example.com  (group supervisors)
#
# The script prints no password and no token, and writes nothing in the repository.
# Each password is written for a moment to a mode-600 file in a private temporary
# directory under ${TMPDIR:-/tmp}, deleted right after the CLI call and on exit.
# Compatible with bash 3.2 (macOS default).
set -Eeuo pipefail

ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2

# Records: label:email:group:password-variable
USERS="inspector-a:inspector-a@example.com:line-a:DEMO_PASSWORD_INSPECTOR_A
inspector-b:inspector-b@example.com:line-b:DEMO_PASSWORD_INSPECTOR_B
supervisor:supervisor@example.com:supervisors:DEMO_PASSWORD_SUPERVISOR"

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"
POOL_ID=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 [--env <env>] [--region <region>]

Options:
  --env <env>        Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --region <region>  AWS region (default: $DEFAULT_REGION)

Password variables: DEMO_PASSWORD_INSPECTOR_A, DEMO_PASSWORD_INSPECTOR_B,
DEMO_PASSWORD_SUPERVISOR
EOF
}

die() {
  echo "$1" >&2
  exit 1
}

# fail_masked <context> <output> [secret]: print the output with the secret removed, then exit.
fail_masked() {
  local out="$2" pw="${3:-}"
  if [ -n "$pw" ]; then
    out=${out//"$pw"/***}
  fi
  echo "ERROR: $1: $out" >&2
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
  die "Invalid Env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)."
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH"

# Private temporary directory (mode 700) outside the repository, removed on exit.
umask 077
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/demo-users.XXXXXX") || die "Cannot create a temporary directory"
trap 'rm -rf "$tmpdir"' EXIT

# --- Input checks (no change to the pool yet) -------------------------------

PARAM_NAME="/inspection-agent/$ENV/auth/user-pool-id"
if ! out=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$PARAM_NAME" \
  --query Parameter.Value \
  --output text 2>&1); then
  echo "Cannot read SSM parameter $PARAM_NAME: $out" >&2
  exit 1
fi
POOL_ID="$out"
[ -n "$POOL_ID" ] || die "SSM parameter $PARAM_NAME is empty"

for rec in $USERS; do
  old_ifs=$IFS
  IFS=:
  set -- $rec
  IFS=$old_ifs
  var="$4"

  pw="${!var:-}"
  if [ -z "$pw" ] && [ -t 0 ]; then
    read -r -s -p "Password for $2 ($var): " pw || pw=""
    echo >&2
  fi
  if [ -z "$pw" ]; then
    die "Missing password: set environment variable $var (or run from a terminal to be prompted)."
  fi
  if [[ "$pw" == *[[:cntrl:]]* ]]; then
    die "Invalid password in $var: control characters are not allowed."
  fi
  printf -v "$var" '%s' "$pw"
  pw=""
done

for rec in $USERS; do
  old_ifs=$IFS
  IFS=:
  set -- $rec
  IFS=$old_ifs
  if ! out=$(aws cognito-idp get-group \
    --region "$REGION" \
    --user-pool-id "$POOL_ID" \
    --group-name "$3" 2>&1); then
    if [[ "$out" == *"ResourceNotFoundException"* ]]; then
      die "Group not found in user pool: $3"
    fi
    die "Cannot read group $3: $out"
  fi
done

# --- Create or update users -------------------------------------------------

for rec in $USERS; do
  old_ifs=$IFS
  IFS=:
  set -- $rec
  IFS=$old_ifs
  label="$1"
  email="$2"
  group="$3"
  var="$4"
  pw="${!var}"

  if ! out=$(aws cognito-idp admin-get-user \
    --region "$REGION" \
    --user-pool-id "$POOL_ID" \
    --username "$email" 2>&1); then
    if [[ "$out" != *"UserNotFoundException"* ]]; then
      fail_masked "admin-get-user for $label" "$out" "$pw"
    fi
    if ! out=$(aws cognito-idp admin-create-user \
      --region "$REGION" \
      --user-pool-id "$POOL_ID" \
      --username "$email" \
      --message-action SUPPRESS \
      --user-attributes "Name=email,Value=$email" "Name=email_verified,Value=true" "Name=name,Value=$label" 2>&1); then
      fail_masked "admin-create-user for $label" "$out" "$pw"
    fi
  fi

  # The password goes to the CLI as JSON in a short-lived mode-600 file inside the
  # private temporary directory (outside the repository), never as an argument.
  # (AWS CLI 2.31.22 rejects file:///dev/stdin and process substitution.)
  # printf is a builtin, so the password does not show in the process list.
  # The file is deleted right after the call, and the directory again on exit.
  esc=$(printf '%s' "$pw" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  f="$tmpdir/$label.json"
  printf '{"UserPoolId":"%s","Username":"%s","Password":"%s","Permanent":true}' "$POOL_ID" "$email" "$esc" >"$f"
  set +e
  out=$(aws cognito-idp admin-set-user-password \
    --region "$REGION" \
    --cli-input-json "file://$f" 2>&1)
  rc=$?
  set -e
  rm -f "$f"
  if [ "$rc" -ne 0 ]; then
    fail_masked "admin-set-user-password for $label" "$out" "$pw"
  fi

  if ! out=$(aws cognito-idp admin-add-user-to-group \
    --region "$REGION" \
    --user-pool-id "$POOL_ID" \
    --username "$email" \
    --group-name "$group" 2>&1); then
    fail_masked "admin-add-user-to-group for $label" "$out" "$pw"
  fi

  echo "ok $label"
  unset pw esc f out rc
  unset "$var"
done
