#!/usr/bin/env bash
# Delete all inspection-agent CloudFormation stacks in Teardown_Sequence order.
# Each stack is deleted through scripts/deploy.sh, which skips absent stacks.
#
# Usage:
#   scripts/teardown.sh [--env <env>] [--region <region>]
#
# Compatible with bash 3.2 (macOS default).
set -Eeuo pipefail

TEARDOWN_SEQUENCE="mcp ui observability memory runtime pre-runtime database auth network"
ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy.sh"

usage() {
  cat >&2 <<EOF
Usage:
  $0 [--env <env>] [--region <region>]

Options:
  --env <env>        Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --region <region>  AWS region (default: $DEFAULT_REGION)

Deletes stacks in this order: $TEARDOWN_SEQUENCE
EOF
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
  echo "Invalid Env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)." >&2
  exit 1
fi

# --- Run --------------------------------------------------------------------

for c in $TEARDOWN_SEQUENCE; do
  echo "==> Teardown: inspection-agent-$ENV-$c"
  if ! "$DEPLOY_SCRIPT" --env "$ENV" --region "$REGION" delete "$c"; then
    echo "ERROR in step teardown $c (inspection-agent-$ENV-$c): delete failed; later stacks were not deleted." >&2
    exit 1
  fi
done

echo "Teardown complete."
