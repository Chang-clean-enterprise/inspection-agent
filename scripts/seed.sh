#!/usr/bin/env bash
# Package the seed handler, upload it to the Seed function, invoke it, and
# print the row count report.
#
# Usage:
#   scripts/seed.sh [--env <env>] [--region <region>]
#
# The script holds and prints no secret. It uses the caller's AWS credentials.
# Compatible with bash 3.2 (macOS default).
set -Eeuo pipefail

ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="build/seed"
STAGE_DIR="$BUILD_DIR/stage"
DEPS_DIR="$BUILD_DIR/deps"
ZIP_FILE="$BUILD_DIR/seed.zip"
HANDLER_SRC="src/inspection_core/seed/handler.py"
REQUIREMENTS="src/inspection_core/seed/requirements-seed.txt"

# Context reported by the ERR trap.
CURRENT_STEP="startup"
RESPONSE_FILE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 [--env <env>] [--region <region>]

Options:
  --env <env>        Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --region <region>  AWS region (default: $DEFAULT_REGION)
EOF
}

die() {
  echo "$1" >&2
  exit 1
}

on_err() {
  local code=$? line=$1
  trap - ERR
  echo "ERROR in step $CURRENT_STEP: command failed with exit code $code (line $line)" >&2
  exit 1
}

cleanup() {
  if [ -n "$RESPONSE_FILE" ]; then
    rm -f "$RESPONSE_FILE"
  fi
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
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# --- Validation (before any AWS CLI call) -----------------------------------

if ! [[ "$ENV" =~ $ENV_PATTERN ]]; then
  die "Invalid Env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)."
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH"
command -v zip >/dev/null 2>&1 || die "zip not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

cd "$REPO_ROOT"

for f in "$HANDLER_SRC" "$REQUIREMENTS" data/schema.sql data/seed/METADATA.json; do
  [ -f "$f" ] || die "Required file not found: $f"
done

trap 'on_err $LINENO' ERR
trap cleanup EXIT

# --- Find the function ------------------------------------------------------

CURRENT_STEP="read seed function name"
PARAM_NAME="/inspection-agent/$ENV/database/seed-function-name"
if ! out=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$PARAM_NAME" \
  --query Parameter.Value \
  --output text 2>&1); then
  if [[ "$out" == *"ParameterNotFound"* ]]; then
    die "Missing SSM parameter: $PARAM_NAME. Run 'make deploy-database' (ENV=$ENV) first."
  fi
  echo "$out" >&2
  exit 1
fi
FUNCTION_NAME="$out"

# --- Build the package ------------------------------------------------------

CURRENT_STEP="build package"
echo "==> Building $ZIP_FILE"
rm -rf "$STAGE_DIR" "$DEPS_DIR" "$ZIP_FILE"
mkdir -p "$STAGE_DIR/data" "$DEPS_DIR"

python3 -m pip install \
  --quiet \
  --platform manylinux_2_28_aarch64 \
  --platform manylinux2014_aarch64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --ignore-requires-python \
  --target "$DEPS_DIR" \
  -r "$REQUIREMENTS"

cp -R "$DEPS_DIR"/. "$STAGE_DIR"/
cp "$HANDLER_SRC" "$STAGE_DIR/index.py"
cp data/schema.sql "$STAGE_DIR/data/schema.sql"
cp -R data/seed "$STAGE_DIR/data/seed"

(cd "$STAGE_DIR" && zip -q -r -X "$REPO_ROOT/$ZIP_FILE" .)

# --- Upload and invoke ------------------------------------------------------

CURRENT_STEP="update function code"
echo "==> Uploading package to $FUNCTION_NAME"
aws lambda update-function-code \
  --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --zip-file "fileb://$ZIP_FILE" \
  --query LastUpdateStatus \
  --output text >/dev/null
aws lambda wait function-updated \
  --region "$REGION" \
  --function-name "$FUNCTION_NAME"

CURRENT_STEP="invoke function"
echo "==> Invoking $FUNCTION_NAME"
RESPONSE_FILE=$(mktemp)
FUNCTION_ERROR=$(aws lambda invoke \
  --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --cli-binary-format raw-in-base64-out \
  --cli-read-timeout 150 \
  --payload '{}' \
  --query FunctionError \
  --output text \
  "$RESPONSE_FILE")

if [ "$FUNCTION_ERROR" != "None" ] && [ -n "$FUNCTION_ERROR" ]; then
  echo "ERROR: the function failed with FunctionError=$FUNCTION_ERROR" >&2
  # The body of a Lambda failure holds errorType and errorMessage, no secrets.
  cat "$RESPONSE_FILE" >&2
  echo >&2
  exit 1
fi

# --- Report -----------------------------------------------------------------

CURRENT_STEP="print report"
status=0
python3 - "$RESPONSE_FILE" <<'PY' || status=$?
import json
import sys

try:
    with open(sys.argv[1]) as f:
        body = json.load(f)
except ValueError:
    print("ERROR: the function response is not valid JSON", file=sys.stderr)
    sys.exit(1)

if not isinstance(body, dict) or body.get("ok") is not True:
    body = body if isinstance(body, dict) else {}
    print(
        "ERROR: seed failed at step %s, table %s: %s"
        % (body.get("step", "-"), body.get("table", "-"), body.get("error", "unknown error")),
        file=sys.stderr,
    )
    sys.exit(1)

mismatch = False
for t in body.get("tables", []):
    ok = t.get("db_rows") == t.get("file_rows")
    mismatch = mismatch or not ok
    print(
        "%s db=%s seed=%s %s"
        % (t.get("table"), t.get("db_rows"), t.get("file_rows"), "OK" if ok else "MISMATCH")
    )
if not body.get("tables"):
    print("ERROR: the function returned no table counts", file=sys.stderr)
    sys.exit(1)
sys.exit(1 if mismatch else 0)
PY

if [ "$status" -ne 0 ]; then
  exit 1
fi
echo "Seed complete."
