#!/usr/bin/env bash
# Deploy and delete inspection-agent CloudFormation stacks with the AWS CLI.
#
# Usage:
#   scripts/deploy.sh [--env <env>] [--region <region>] deploy-all
#   scripts/deploy.sh [--env <env>] [--region <region>] deploy <component> [--param Key=Value ...]
#   scripts/deploy.sh [--env <env>] [--region <region>] delete <component>
#
# --param passes a parameter override to one component (repeatable). It is
# rejected by deploy-all and delete.
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
PARAM_OVERRIDES=()

# Set by runtime_parameters: 1 when no code package is known for the runtime stack.
NO_PACKAGE=0

# Context reported by the ERR trap.
CURRENT_STEP="startup"
CURRENT_STACK="-"

usage() {
  cat >&2 <<EOF
Usage:
  $0 [--env <env>] [--region <region>] deploy-all
  $0 [--env <env>] [--region <region>] deploy <component> [--param Key=Value ...]
  $0 [--env <env>] [--region <region>] delete <component>

Options:
  --env <env>        Environment name (default: $DEFAULT_ENV). Pattern: $ENV_PATTERN
  --region <region>  AWS region (default: $DEFAULT_REGION)
  --param Key=Value  Parameter override for one component (repeatable, deploy only)

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

# stack_param <component> <Key>: print the current stack parameter value,
# or nothing when the stack or the parameter does not exist.
stack_param() {
  local status out
  status=$(stack_status "$1")
  if [[ "$status" == "ABSENT" ]]; then
    return 0
  fi
  out=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$(stack_name "$1")" \
    --query "Stacks[0].Parameters[?ParameterKey=='$2'].ParameterValue | [0]" \
    --output text)
  if [[ "$out" != "None" ]]; then
    echo "$out"
  fi
}

# template_default <component> <Key>: print the Default of a template parameter.
template_default() {
  awk -v k="$2" '
    $0 == "  " k ":" { f = 1; next }
    f && /^  [A-Za-z]/ { exit }
    f && /^    Default:/ { sub(/^    Default: */, ""); print; exit }
  ' "infra/$1.yaml"
}

# override_value <Key>: print the last value given for Key in RT_OVER; return 1 when absent.
override_value() {
  local kv found=1 val=""
  for kv in ${RT_OVER[@]+"${RT_OVER[@]}"}; do
    if [[ "${kv%%=*}" == "$1" ]]; then
      val="${kv#*=}"
      found=0
    fi
  done
  echo "$val"
  return $found
}

# resolve_package: set PKG_KEY and PKG_VERSION (both "none" when no package is known).
# Rule 1: build/package-location.env, when it matches env and Region and the object exists.
# Rule 2: the package parameters of the current runtime stack.
# Rule 3: no package.
resolve_package() {
  local f=build/package-location.env penv preg pbucket pkey pver sbucket key ver
  PKG_KEY=none
  PKG_VERSION=none

  if [ -f "$f" ]; then
    penv=$(grep -m1 '^PACKAGE_ENV=' "$f" | cut -d= -f2- || true)
    preg=$(grep -m1 '^PACKAGE_REGION=' "$f" | cut -d= -f2- || true)
    pbucket=$(grep -m1 '^PACKAGE_BUCKET=' "$f" | cut -d= -f2- || true)
    pkey=$(grep -m1 '^PACKAGE_KEY=' "$f" | cut -d= -f2- || true)
    pver=$(grep -m1 '^PACKAGE_VERSION_ID=' "$f" | cut -d= -f2- || true)
    sbucket=""
    if [ "$penv" = "$ENV" ] && [ "$preg" = "$REGION" ]; then
      sbucket=$(read_ssm "/inspection-agent/$ENV/runtime/artifact-bucket" 2>/dev/null || true)
    fi
    if [ -n "$sbucket" ] && [ "$pbucket" = "$sbucket" ] \
      && [[ "$pkey" =~ ^code/[A-Za-z0-9._-]{1,200}$ ]] \
      && [[ "$pver" =~ ^[A-Za-z0-9._-]+$ ]] \
      && [ "${#pver}" -ge 3 ] && [ "${#pver}" -le 1024 ] \
      && aws s3api head-object --region "$REGION" --bucket "$pbucket" \
        --key "$pkey" --version-id "$pver" >/dev/null 2>&1; then
      PKG_KEY="$pkey"
      PKG_VERSION="$pver"
      return 0
    fi
  fi

  key=$(stack_param runtime PackageObjectKey)
  ver=$(stack_param runtime PackageObjectVersion)
  if [ -n "$key" ] && [ "$key" != "none" ] && [ -n "$ver" ] && [ "$ver" != "none" ]; then
    PKG_KEY="$key"
    PKG_VERSION="$ver"
  fi
  return 0
}

# runtime_parameters [Key=Value ...]: build RUNTIME_ARGS for the runtime stack.
# Explicit arguments and --param overrides replace the computed defaults.
runtime_parameters() {
  local model prefix kv d key
  local defaults=()
  RT_OVER=("$@" ${PARAM_OVERRIDES[@]+"${PARAM_OVERRIDES[@]}"})
  RUNTIME_ARGS=()
  NO_PACKAGE=0

  if override_value ModelScope >/dev/null; then
    echo "ModelScope is derived from ModelId and cannot be set with --param." >&2
    exit 2
  fi

  # Effective ModelId: override, then current stack parameter, then template default.
  if ! model=$(override_value ModelId); then
    model=$(stack_param runtime ModelId)
    if [ -z "$model" ]; then
      model=$(template_default runtime ModelId)
    fi
  fi
  prefix="${model%%.*}"
  if [ "$prefix" != "us" ] && [ "$prefix" != "global" ]; then
    echo "Invalid ModelId '$model': the prefix must be 'us' or 'global'." >&2
    exit 2
  fi

  if override_value PackageObjectKey >/dev/null || override_value PackageObjectVersion >/dev/null; then
    key=$(override_value PackageObjectKey || true)
    if [ -z "$key" ] || [ "$key" = "none" ]; then
      NO_PACKAGE=1
    fi
  else
    resolve_package
    defaults+=("PackageObjectKey=$PKG_KEY" "PackageObjectVersion=$PKG_VERSION")
    if [ "$PKG_KEY" = "none" ]; then
      NO_PACKAGE=1
    fi
  fi

  defaults+=(
    "ModelId=$model"
    "ModelScope=$prefix"
    "PrivateSubnetIds=/inspection-agent/$ENV/network/private-subnet-ids"
    "RuntimeSecurityGroupId=/inspection-agent/$ENV/network/runtime-security-group-id"
    "DiscoveryUrl=/inspection-agent/$ENV/auth/discovery-url"
    "AppClientId=/inspection-agent/$ENV/auth/app-client-id"
    "DbEndpoint=/inspection-agent/$ENV/database/endpoint"
    "DbSecretArn=/inspection-agent/$ENV/database/agent-ro-secret-arn"
  )

  for d in "${defaults[@]}"; do
    if ! override_value "${d%%=*}" >/dev/null; then
      RUNTIME_ARGS+=("$d")
    fi
  done
  for kv in ${RT_OVER[@]+"${RT_OVER[@]}"}; do
    RUNTIME_ARGS+=("$kv")
  done
}

# deploy_stack <component> [Key=Value ...]
deploy_stack() {
  local c="$1"
  shift
  local name status
  local extra=()
  name=$(stack_name "$c")
  CURRENT_STACK="$name"

  status=$(stack_status "$c")
  if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
    fail "$CURRENT_STEP" "$name" "Stack $name is in ROLLBACK_COMPLETE; run make delete-$c first."
  fi

  if [ "$c" = "runtime" ]; then
    runtime_parameters "$@"
    extra=("${RUNTIME_ARGS[@]}")
  else
    extra=("$@" ${PARAM_OVERRIDES[@]+"${PARAM_OVERRIDES[@]}"})
  fi

  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$name" \
    --template-file "infra/$c.yaml" \
    --parameter-overrides "Env=$ENV" ${extra[@]+"${extra[@]}"} \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags "Project=inspection-agent" "Env=$ENV" \
    --no-fail-on-empty-changeset

  status=$(stack_status "$c")
  if [[ "$status" != "CREATE_COMPLETE" && "$status" != "UPDATE_COMPLETE" ]]; then
    fail "$CURRENT_STEP" "$name" "unexpected stack status $status"
  fi
}

# empty_artifact_bucket: delete every object version and delete marker in the
# runtime stack's artifact bucket, so the stack delete can remove the bucket.
# Skips quietly when the bucket is not known or no longer exists.
empty_artifact_bucket() {
  local bucket listing batch errors count=0
  command -v python3 >/dev/null 2>&1 || fail "$CURRENT_STEP" "$CURRENT_STACK" "python3 not found on PATH"

  bucket=$(aws cloudformation describe-stack-resource \
    --region "$REGION" \
    --stack-name "$(stack_name runtime)" \
    --logical-resource-id ArtifactBucket \
    --query StackResourceDetail.PhysicalResourceId \
    --output text 2>/dev/null || true)
  if [ -z "$bucket" ] || [ "$bucket" = "None" ]; then
    echo "No artifact bucket found in the runtime stack; nothing to empty."
    return 0
  fi
  if ! aws s3api head-bucket --region "$REGION" --bucket "$bucket" >/dev/null 2>&1; then
    echo "Artifact bucket $bucket does not exist or is not accessible; skipping."
    return 0
  fi

  echo "Emptying artifact bucket $bucket (all versions and delete markers)."
  while true; do
    listing=$(aws s3api list-object-versions \
      --region "$REGION" \
      --bucket "$bucket" \
      --max-items 1000 \
      --output json)
    batch=$(printf '%s' "$listing" | python3 -c '
import json, sys
data = json.load(sys.stdin) or {}
objs = [
    {"Key": o["Key"], "VersionId": o["VersionId"]}
    for o in (data.get("Versions") or []) + (data.get("DeleteMarkers") or [])
]
print(json.dumps({"Objects": objs, "Quiet": True}) if objs else "")
')
    if [ -z "$batch" ]; then
      break
    fi
    errors=$(aws s3api delete-objects \
      --region "$REGION" \
      --bucket "$bucket" \
      --delete "$batch" \
      --query 'Errors[0].Code' \
      --output text)
    if [ -n "$errors" ] && [ "$errors" != "None" ]; then
      fail "$CURRENT_STEP" "$CURRENT_STACK" "could not delete objects from $bucket: $errors"
    fi
    count=$((count + 1))
  done
  echo "Artifact bucket $bucket emptied ($count batch(es))."
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

  if [ "$c" = "runtime" ]; then
    empty_artifact_bucket
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
  # Phase A: with no known package this creates only the bucket, role and SSM parameters.
  deploy_stack runtime "MemoryId="
  if [ "$NO_PACKAGE" = "1" ]; then
    echo "==> Phase A deployed. Packaging the agent code."
    CURRENT_STACK="scripts/package-agent.sh"
    bash scripts/package-agent.sh --env "$ENV" --region "$REGION"
    # Phase B: adds the AgentRuntime using the package in build/package-location.env.
    CURRENT_STACK=$(stack_name runtime)
    deploy_stack runtime "MemoryId="
    if [ "$NO_PACKAGE" = "1" ]; then
      fail "$CURRENT_STEP" "$CURRENT_STACK" "no code package found after running scripts/package-agent.sh"
    fi
  fi

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
    --param)
      [ $# -ge 2 ] || { usage; exit 2; }
      if ! [[ "$2" =~ ^[A-Za-z][A-Za-z0-9]*=.*$ ]]; then
        echo "Invalid --param '$2': expected Key=Value." >&2
        exit 2
      fi
      if [ "${2%%=*}" = "Env" ]; then
        echo "Use --env to set Env; --param Env=... is not allowed." >&2
        exit 2
      fi
      PARAM_OVERRIDES+=("$2")
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
    if [ ${#PARAM_OVERRIDES[@]} -gt 0 ]; then
      echo "--param is not supported with deploy-all. Use: deploy <component> --param Key=Value" >&2
      exit 2
    fi
    ;;
  deploy | delete)
    [ -n "$COMPONENT" ] || { usage; exit 2; }
    if [ "$COMMAND" = "delete" ] && [ ${#PARAM_OVERRIDES[@]} -gt 0 ]; then
      echo "--param is only supported with deploy." >&2
      exit 2
    fi
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

for kv in ${PARAM_OVERRIDES[@]+"${PARAM_OVERRIDES[@]}"}; do
  if [ "${kv%%=*}" = "ModelScope" ]; then
    echo "ModelScope is derived from ModelId and cannot be set with --param." >&2
    exit 2
  fi
  if [ "${kv%%=*}" = "ModelId" ] && [ "$COMPONENT" = "runtime" ]; then
    case "${kv#*=}" in
      us.* | global.*) ;;
      *)
        echo "Invalid ModelId '${kv#*=}': the prefix must be 'us' or 'global'." >&2
        exit 2
        ;;
    esac
  fi
done

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
    if [ "$COMPONENT" = "runtime" ] && [ "$NO_PACKAGE" = "1" ]; then
      fail "$CURRENT_STEP" "$CURRENT_STACK" \
        "No code package found. Phase A is deployed. Run scripts/package-agent.sh --env $ENV --region $REGION, then deploy runtime again."
    fi
    ;;
  delete)
    CURRENT_STEP="delete $COMPONENT"
    delete_stack "$COMPONENT"
    ;;
esac
