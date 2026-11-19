#!/usr/bin/env bash
# Deploy and delete inspection-agent CloudFormation stacks with the AWS CLI.
#
# Usage:
#   scripts/deploy.sh [--env <env>] [--region <region>] deploy-all
#   scripts/deploy.sh [--env <env>] [--region <region>] deploy <component>
#   scripts/deploy.sh [--env <env>] [--region <region>] delete <component>
#
# Compatible with bash 3.2 (macOS default).
set -Eeuo pipefail

COMPONENTS="network auth database runtime memory observability ui mcp"
ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"
COMMAND=""
COMPONENT=""

# Context reported by the ERR trap.
CURRENT_STEP="startup"
CURRENT_STACK="-"

usage() {
  cat >&2 <<EOF
Usage:
  $0 [--env <env>] [--region <region>] deploy-all
  $0 [--env <env>] [--region <region>] deploy <component>
  $0 [--env <env>] [--region <region>] delete <component>

Options:
  --env <env>        Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --region <region>  AWS region (default: $DEFAULT_REGION)

Components: $COMPONENTS
EOF
}

# fail <step> <stack> <message>
fail() {
  echo "ERROR in step $1 ($2): $3" >&2
  exit 1
}

# die <message>: validation error, no step context.
die() {
  echo "$1" >&2
  exit 1
}

on_err() {
  local code=$? line=$1
  trap - ERR
  echo "ERROR in step $CURRENT_STEP ($CURRENT_STACK): command failed with exit code $code (line $line)" >&2
  exit 1
}

stack_name() {
  echo "inspection-agent-$ENV-$1"
}

# Echo the stack status, or ABSENT when the stack does not exist.
stack_status() {
  local out
  if out=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$(stack_name "$1")" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>&1); then
    echo "$out"
  elif [[ "$out" == *"does not exist"* ]]; then
    echo "ABSENT"
  else
    echo "$out" >&2
    return 1
  fi
}

# deploy_stack <component> [Key=Value ...]
deploy_stack() {
  local c="$1"
  shift
  local name status
  name=$(stack_name "$c")
  CURRENT_STACK="$name"

  status=$(stack_status "$c")
  if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
    fail "$CURRENT_STEP" "$name" "Stack $name is in ROLLBACK_COMPLETE; run make delete-$c first."
  fi

  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$name" \
    --template-file "infra/$c.yaml" \
    --parameter-overrides "Env=$ENV" "$@" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags "Project=inspection-agent" "Env=$ENV" \
    --no-fail-on-empty-changeset

  status=$(stack_status "$c")
  if [[ "$status" != "CREATE_COMPLETE" && "$status" != "UPDATE_COMPLETE" ]]; then
    fail "$CURRENT_STEP" "$name" "unexpected stack status $status"
  fi
}

# delete_stack <component>
delete_stack() {
  local c="$1"
  local name status
  name=$(stack_name "$c")
  CURRENT_STACK="$name"

  status=$(stack_status "$c")
  if [[ "$status" == "ABSENT" ]]; then
    echo "Stack $name does not exist; skipping."
    return 0
  fi

  aws cloudformation delete-stack --region "$REGION" --stack-name "$name"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$name"
  echo "Stack $name deleted."
}

# read_ssm <path>: print the parameter value, or stop if it is missing.
read_ssm() {
  local out
  if ! out=$(aws ssm get-parameter \
    --region "$REGION" \
    --name "$1" \
    --query Parameter.Value \
    --output text 2>&1); then
    if [[ "$out" == *"ParameterNotFound"* ]]; then
      echo "Missing SSM parameter: $1" >&2
    else
      echo "$out" >&2
    fi
    return 1
  fi
  echo "$out"
}

# require_param <component> <Key> <expected>
require_param() {
  local c="$1" key="$2" expected="$3" actual
  actual=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$(stack_name "$c")" \
    --query "Stacks[0].Parameters[?ParameterKey=='$key'].ParameterValue | [0]" \
    --output text)
  if [[ "$actual" != "$expected" ]]; then
    fail "$CURRENT_STEP" "$(stack_name "$c")" \
      "parameter $key mismatch: expected '$expected', actual '$actual'"
  fi
}

step() {
  CURRENT_STEP="$1"
  CURRENT_STACK=$(stack_name "$2")
  echo "==> Step $1/10: $CURRENT_STACK"
}

deploy_all() {
  local id cb lo

  step 1 network
  deploy_stack network

  step 2 auth
  deploy_stack auth

  step 3 database
  deploy_stack database

  step 4 runtime
  deploy_stack runtime "MemoryId="

  step 5 memory
  deploy_stack memory

  step 6 runtime
  id=$(read_ssm "/inspection-agent/$ENV/memory/memory-id")
  deploy_stack runtime "MemoryId=$id"
  require_param runtime MemoryId "$id"

  step 7 observability
  deploy_stack observability

  step 8 ui
  deploy_stack ui

  step 9 auth
  cb=$(read_ssm "/inspection-agent/$ENV/ui/callback-url")
  lo=$(read_ssm "/inspection-agent/$ENV/ui/logout-url")
  deploy_stack auth "CallbackUrl=$cb" "LogoutUrl=$lo"
  require_param auth CallbackUrl "$cb"
  require_param auth LogoutUrl "$lo"

  step 10 mcp
  deploy_stack mcp

  echo "Deploy complete."
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
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ -z "$COMMAND" ]; then
        COMMAND="$1"
      elif [ -z "$COMPONENT" ]; then
        COMPONENT="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

case "$COMMAND" in
  deploy-all)
    [ -z "$COMPONENT" ] || { usage; exit 2; }
    ;;
  deploy | delete)
    [ -n "$COMPONENT" ] || { usage; exit 2; }
    ;;
  *)
    usage
    exit 2
    ;;
esac

# --- Validation (before any AWS CLI call) -----------------------------------

if ! [[ "$ENV" =~ $ENV_PATTERN ]]; then
  die "Invalid Env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)."
fi

if [ "$COMMAND" != "deploy-all" ]; then
  valid=0
  for c in $COMPONENTS; do
    if [ "$c" = "$COMPONENT" ]; then
      valid=1
    fi
  done
  if [ "$valid" -ne 1 ]; then
    die "Unknown component '$COMPONENT'. Valid components: $COMPONENTS"
  fi
fi

if [ "$COMMAND" = "deploy-all" ]; then
  for c in $COMPONENTS; do
    [ -f "infra/$c.yaml" ] || die "Template not found: infra/$c.yaml"
  done
elif [ "$COMMAND" = "deploy" ]; then
  [ -f "infra/$COMPONENT.yaml" ] || die "Template not found: infra/$COMPONENT.yaml"
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH"

# --- Run --------------------------------------------------------------------

trap 'on_err $LINENO' ERR

case "$COMMAND" in
  deploy-all)
    deploy_all
    ;;
  deploy)
    CURRENT_STEP="deploy $COMPONENT"
    deploy_stack "$COMPONENT"
    ;;
  delete)
    CURRENT_STEP="delete $COMPONENT"
    delete_stack "$COMPONENT"
    ;;
esac
