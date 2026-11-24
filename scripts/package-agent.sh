#!/usr/bin/env bash
# Build the reproducible AgentCore code package (arm64, Python 3.12), upload it to
# the versioned artifact bucket, and print the package location.
#
# Usage:
#   scripts/package-agent.sh [--env <env>] [--region <region>]
#
# The zip holds src/inspection_agent/, src/inspection_core/, every dependency
# pinned in src/inspection_agent/requirements.txt, and a generated root main.py.
# The S3 key is code/<sha256>.zip, so the same source gives the same key and the
# upload is skipped when the key already exists.
#
# Writes build/inspection-agent.zip and build/package-location.env.
# The script holds and prints no secret. It uses the caller's AWS credentials.
# Needs aws, uv, and python3 (standard library only).
# Compatible with bash 3.2 (macOS default).
#
# Exit codes: 0 success, 1 failure (including a missing artifact bucket), 2 usage error.
set -Eeuo pipefail

ENV_PATTERN='^[a-z][a-z0-9]{0,9}$'
DEFAULT_ENV=demo
DEFAULT_REGION=us-west-2

# Platform facts from the AgentCore code deployment documentation (design.md, Research record).
PYTHON_VERSION=3.12
PYTHON_PLATFORM=aarch64-manylinux_2_28
MAX_ZIPPED_BYTES=250000000
MAX_UNZIPPED_BYTES=750000000

ENV="$DEFAULT_ENV"
REGION="$DEFAULT_REGION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="build"
STAGE_DIR="$BUILD_DIR/agent-package"
ZIP_FILE="$BUILD_DIR/inspection-agent.zip"
LOCATION_FILE="$BUILD_DIR/package-location.env"
REQUIREMENTS="src/inspection_agent/requirements.txt"

CURRENT_STEP="startup"
trap 'echo "package-agent.sh failed during: $CURRENT_STEP (line $LINENO)" >&2' ERR

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
  echo "Invalid Env '$ENV': must be 1-10 characters, start with a lowercase letter, and contain only lowercase letters and digits (pattern $ENV_PATTERN)." >&2
  exit 2
fi

CURRENT_STEP="tool check"
command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH"
command -v uv >/dev/null 2>&1 || die "uv not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

cd "$REPO_ROOT"

# --- Artifact bucket --------------------------------------------------------

CURRENT_STEP="read artifact bucket parameter"
BUCKET_PARAM="/inspection-agent/$ENV/runtime/artifact-bucket"
if ! BUCKET=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$BUCKET_PARAM" \
  --query Parameter.Value \
  --output text 2>/dev/null) || [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ]; then
  echo "Artifact bucket not found (SSM parameter $BUCKET_PARAM)." >&2
  echo "Deploy the runtime stack first: scripts/deploy.sh --env $ENV deploy runtime" >&2
  exit 1
fi

CURRENT_STEP="read caller account"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "Could not read the caller account ID"

# --- Stage the package ------------------------------------------------------

CURRENT_STEP="recreate $STAGE_DIR"
rm -rf "$STAGE_DIR" "$ZIP_FILE"
mkdir -p "$STAGE_DIR"

CURRENT_STEP="install dependencies ($PYTHON_PLATFORM, Python $PYTHON_VERSION)"
echo "Installing dependencies for $PYTHON_PLATFORM, Python $PYTHON_VERSION ..."
uv pip install \
  --quiet \
  --python-platform "$PYTHON_PLATFORM" \
  --python-version "$PYTHON_VERSION" \
  --only-binary=:all: \
  --target "$STAGE_DIR" \
  -r "$REQUIREMENTS"

CURRENT_STEP="copy application packages"
python3 - "$STAGE_DIR" <<'PY'
import os
import shutil
import sys

stage = sys.argv[1]
ignore = shutil.ignore_patterns("__pycache__", "*.pyc", "*.md")
for name in ("inspection_agent", "inspection_core"):
    dest = os.path.join(stage, name)
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(os.path.join("src", name), dest, ignore=ignore)

# The seed Lambda handler is not part of the agent.
seed = os.path.join(stage, "inspection_core", "seed")
if os.path.isdir(seed):
    shutil.rmtree(seed)
PY

CURRENT_STEP="write main.py"
cat >"$STAGE_DIR/main.py" <<'PY'
from inspection_agent.entrypoint import app

if __name__ == "__main__":
    app.run()
PY

# --- Build the zip ----------------------------------------------------------

CURRENT_STEP="build zip"
# The Python step prints "<zipped bytes> <unzipped bytes>" and exits non-zero
# when a size limit is exceeded.
SIZES=$(python3 - "$STAGE_DIR" "$ZIP_FILE" "$MAX_ZIPPED_BYTES" "$MAX_UNZIPPED_BYTES" <<'PY'
import os
import shutil
import sys
import zipfile

stage, zip_path, max_zipped, max_unzipped = sys.argv[1:5]
max_zipped = int(max_zipped)
max_unzipped = int(max_unzipped)
FIXED_TIME = (1980, 1, 1, 0, 0, 0)

# Remove any __pycache__ left by the dependency install.
for root, dirs, _files in os.walk(stage):
    for d in [d for d in dirs if d == "__pycache__"]:
        shutil.rmtree(os.path.join(root, d))
        dirs.remove(d)

entries = []
for root, dirs, files in os.walk(stage):
    for name in dirs + files:
        full = os.path.join(root, name)
        rel = os.path.relpath(full, stage).replace(os.sep, "/")
        entries.append((rel, full))
entries.sort(key=lambda e: e[0])

unzipped = 0
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for rel, full in entries:
        if os.path.islink(full):
            sys.exit("Symbolic link in package: " + rel)
        if os.path.isdir(full):
            info = zipfile.ZipInfo(rel + "/", FIXED_TIME)
            info.create_system = 3
            info.external_attr = (0o040755 << 16) | 0x10
            zf.writestr(info, b"", compress_type=zipfile.ZIP_STORED)
            continue
        with open(full, "rb") as fh:
            data = fh.read()
        unzipped += len(data)
        executable = rel.endswith(".so") or ".so." in rel or os.access(full, os.X_OK)
        mode = 0o755 if executable else 0o644
        info = zipfile.ZipInfo(rel, FIXED_TIME)
        info.create_system = 3
        info.external_attr = (0o100000 | mode) << 16
        zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

zipped = os.path.getsize(zip_path)
if zipped > max_zipped:
    sys.exit("Zipped size %d exceeds %d bytes" % (zipped, max_zipped))
if unzipped > max_unzipped:
    sys.exit("Unzipped size %d exceeds %d bytes" % (unzipped, max_unzipped))
print("%d %d" % (zipped, unzipped))
PY
)
ZIPPED_BYTES="${SIZES%% *}"
UNZIPPED_BYTES="${SIZES##* }"

CURRENT_STEP="compute SHA-256"
SHA256=$(python3 - "$ZIP_FILE" <<'PY'
import hashlib
import sys

h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
)
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "Could not compute the SHA-256 digest"
KEY="code/$SHA256.zip"

# --- Upload (skipped when the key exists) -----------------------------------

CURRENT_STEP="check for existing object"
VERSION_ID=""
if VERSION_ID=$(aws s3api head-object \
  --region "$REGION" \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --query VersionId \
  --output text 2>/dev/null); then
  echo "Object $KEY already exists. Upload skipped."
else
  CURRENT_STEP="upload package"
  VERSION_ID=$(aws s3api put-object \
    --region "$REGION" \
    --bucket "$BUCKET" \
    --key "$KEY" \
    --body "$ZIP_FILE" \
    --metadata "sha256=$SHA256" \
    --expected-bucket-owner "$ACCOUNT_ID" \
    --query VersionId \
    --output text)
fi
if [ -z "$VERSION_ID" ] || [ "$VERSION_ID" = "None" ]; then
  die "The artifact bucket returned no version ID. Check that versioning is enabled on $BUCKET."
fi

# --- Report -----------------------------------------------------------------

CURRENT_STEP="write $LOCATION_FILE"
cat >"$LOCATION_FILE" <<LOC
PACKAGE_ENV=$ENV
PACKAGE_REGION=$REGION
PACKAGE_BUCKET=$BUCKET
PACKAGE_KEY=$KEY
PACKAGE_VERSION_ID=$VERSION_ID
PACKAGE_SHA256=$SHA256
LOC

echo "Package location:"
echo "  bucket:      $BUCKET"
echo "  key:         $KEY"
echo "  version-id:  $VERSION_ID"
echo "  sha256:      $SHA256"
echo "  zipped:      $ZIPPED_BYTES bytes"
echo "  unzipped:    $UNZIPPED_BYTES bytes"
echo "  zip file:    $ZIP_FILE"
echo "  env file:    $LOCATION_FILE"
