# AgentCore runtime

This document covers the `inspection-agent-<env>-runtime` stack (`infra/runtime.yaml`). The stack deploys the Strands agent (`src/inspection_agent/` with `src/inspection_core/`) to Amazon Bedrock AgentCore Runtime. It uses the code-in-S3 artifact option, VPC network mode, and a custom JWT authorizer backed by the Cognito user pool from the auth stack.

Placeholders used below: `<env>` (default `demo`), `<account-id>`, `<bucket>`, `<runtime-arn>`. Replace them with your own values. The repository contains no account-specific identifiers.

## 1. Platform facts

Facts checked on 2026-11-23 against the AWS documentation.

| Topic | Fact |
|---|---|
| CPU architecture | arm64 only. The service rejects x86_64 and Mach-O binaries. |
| Python | `PYTHON_3_12` on Amazon Linux 2023. |
| Package size | At most 250 MB zipped and 750 MB unzipped. `scripts/package-agent.sh` enforces the stricter decimal values (250,000,000 and 750,000,000 bytes). |
| Entry point | `main.py` at the zip root. The package script generates it. It imports `app` from `inspection_agent.entrypoint`, because `entrypoint.py` uses relative imports. |
| Archive layout | Agent files and dependencies at the zip root. The zip is mounted at `/var/task`. Files are mode 644, directories and `.so` files 755. No `__pycache__`. |
| Wheel platform | `uv pip install --python-platform aarch64-manylinux_2_28`. The documented `aarch64-manylinux2014` fails with this project's pins, because `psycopg-binary` ships aarch64 wheels only as `manylinux_2_27` and `manylinux_2_28`. Amazon Linux 2023 has glibc 2.34, so `manylinux_2_28` is valid. |
| Platform version | Pinned to `V1` through the `PlatformVersion` parameter. The AgentCore documents disagree on the default. `get-agent-runtime` does not return a platform version, so read it from the stack parameter. |
| Inbound auth | Custom JWT authorizer. `AllowedClients` holds the Cognito app client ID. Cognito access tokens carry `client_id` and no `aud`, so no audience is set. |
| Request headers | Allowlist is `[Authorization]`. The entrypoint reads the token from `context.request_headers`. |
| Network | VPC mode, private subnets and the runtime security group from the network stack. AgentCore creates the network interfaces with the service-linked role `AWSServiceRoleForBedrockAgentCoreNetwork`. |
| Lifecycle | `IdleRuntimeSessionTimeout` default 900 seconds, `MaxLifetime` default 28800 seconds. Range 60 to 28800 for both. |

## 2. Parameters

Every parameter has a constraint. Pass overrides with `scripts/deploy.sh deploy runtime --param Key=Value`.

| Name | Default | Constraint | Notes |
|---|---|---|---|
| `Env` | `demo` | `^[a-z][a-z0-9]{0,9}$` | Set by `--env`. |
| `ModelId` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | `^(us\|global)\.[a-z0-9-]+\.[a-z0-9][a-z0-9:_-]*$` | Geographic (`us.`) or global (`global.`) profile ID only. Other prefixes and bare foundation model IDs are rejected. |
| `ModelScope` | `us` | `us`, `global` | Derived by `deploy.sh` from the `ModelId` prefix. Do not set it by hand. |
| `IdleRuntimeSessionTimeout` | 900 | 60 to 28800 | The AgentCore service checks it against `MaxLifetime`. The repository does not. |
| `MaxLifetime` | 28800 | 60 to 28800 | |
| `LogLevel` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` | Applied to the `inspection_agent` and `inspection_core` loggers only. |
| `MemoryId` | empty | empty or `^[a-zA-Z][a-zA-Z0-9_-]{0,99}-[a-zA-Z0-9]{10}$` | Empty until the memory stack exists. `INSPECTION_MEMORY_ID` is set only when this is not empty. |
| `PackageObjectKey` | `none` | `none` or `code/<name>` | `none` means Phase A (no runtime). `deploy.sh` fills it. |
| `PackageObjectVersion` | `none` | `none` or an S3 version ID | Must be `none` exactly when `PackageObjectKey` is `none`. `deploy.sh` fills it. |
| `PlatformVersion` | `V1` | `V1`, `V2` | |
| `EnableS3ReadFallback` | `false` | `true`, `false` | Adds `s3:GetObject` and `s3:GetObjectVersion` on `<bucket>/code/*` to the execution role. Not needed in the first deploy. |
| `EnableEniFallback` | `false` | `true`, `false` | Adds network interface permissions to the execution role. Not needed in the first deploy. |

Environment variables set on the runtime: `INSPECTION_ENV`, `AWS_REGION`, `INSPECTION_MODEL_ID`, `INSPECTION_MODEL_REGION`, `INSPECTION_DB_HOST`, `INSPECTION_DB_SECRET_ARN`, `INSPECTION_LOG_LEVEL`, and `INSPECTION_MEMORY_ID` when `MemoryId` is set. No variable holds a password, token, or user identity.

## 3. SSM parameters

Read by the stack (names passed as stack parameters, defaults use `demo`):

| Path | Source stack |
|---|---|
| `/inspection-agent/<env>/network/private-subnet-ids` | network |
| `/inspection-agent/<env>/network/runtime-security-group-id` | network |
| `/inspection-agent/<env>/auth/discovery-url` | auth |
| `/inspection-agent/<env>/auth/app-client-id` | auth |
| `/inspection-agent/<env>/database/endpoint` | database |
| `/inspection-agent/<env>/database/agent-ro-secret-arn` | database |

Published by the stack:

| Path | Value | Created |
|---|---|---|
| `/inspection-agent/<env>/runtime/artifact-bucket` | Artifact bucket name | Always |
| `/inspection-agent/<env>/runtime/execution-role-arn` | Execution role ARN | Always |
| `/inspection-agent/<env>/runtime/invocation-url` | URL pattern with the placeholder `{EncodedRuntimeArn}` | Always |
| `/inspection-agent/<env>/runtime/runtime-arn` | Runtime ARN | Phase B only |
| `/inspection-agent/<env>/runtime/runtime-id` | Runtime ID | Phase B only |

## 4. Deploy and update

### Shell notes

The scripts need bash. They work on the macOS default bash 3.2 and on Linux. The Makefile calls them directly, so you do not need to start a bash shell yourself.

`scripts/invoke.sh --persona` reads the password from `DEMO_PASSWORD_INSPECTOR_A`, `DEMO_PASSWORD_INSPECTOR_B`, or `DEMO_PASSWORD_SUPERVISOR`, or prompts without echo. In zsh, `read -rs -p` does not work. Set the variables like this instead:

```zsh
read -rs "DEMO_PASSWORD_SUPERVISOR?Supervisor password: "; export DEMO_PASSWORD_SUPERVISOR
```

### First deploy

The runtime stack deploys in two phases, because `AWS::BedrockAgentCore::Runtime` needs the code package to exist in S3 at create time, and the bucket belongs to the same stack.

```bash
make deploy-network
make deploy-auth
make deploy-database
make seed
make deploy-runtime   # Phase A: bucket, role, SSM parameters. Exits 1 with "No code package found" by design.
make package          # Build the zip and upload it to the artifact bucket.
make deploy-runtime   # Phase B: creates the AgentRuntime.
```

The exit code 1 of Phase A is expected. The stack is in `CREATE_COMPLETE` with no `AgentRuntime`.

`make deploy` (`deploy-all`) runs the 10-step sequence, including both runtime phases and the package step. It needs all 8 templates in `infra/` and works only once they exist.

### Code update

```bash
make package
make deploy-runtime
```

`package-agent.sh` names the object `code/<sha256>.zip` and skips the upload when the key exists. `deploy.sh` reads `build/package-location.env`, confirms the object version, and passes it to the stack. Rebuilding unchanged source gives the same SHA-256 and key, so `deploy runtime` then changes nothing.

### Config-only change

```bash
scripts/deploy.sh deploy runtime --param IdleRuntimeSessionTimeout=600
```

The runtime updates in place and the code location stays the same. `--param` is repeatable and is rejected by `deploy-all`.

### Invoke

```bash
scripts/invoke.sh --persona supervisor --prompt "<question>"
```

Use either `--persona` or `AGENT_ACCESS_TOKEN`, not both (exit 2). The script prints `HTTP <code>` to stderr and the body to stdout. It exits 1 on a non-2xx status. A `--session-id` shorter than 33 characters is replaced by a generated one.

## 5. Session behavior

Each session keeps the code that was deployed when its microVM was created. A code update applies to new sessions only. Existing sessions keep the old code until they end, by idle timeout, `MaxLifetime`, or `StopRuntimeSession`. To see new code, invoke with a fresh session ID. This was verified in step 8.5 (see section 10).

## 6. Deploying identity prerequisites

The identity that runs `deploy.sh` needs:

- `s3:GetObject` and `s3:GetObjectVersion` on the artifact bucket. AgentCore reads the package with this identity when it creates or updates the runtime, not with the execution role.
- `iam:PassRole` on the execution role.
- `iam:CreateServiceLinkedRole` for `network.bedrock-agentcore.amazonaws.com`, on the first VPC runtime in the account.

## 7. Availability Zone check

Before the first Phase B, confirm the private subnets are in supported AZs:

```bash
aws ec2 describe-subnets --subnet-ids <subnet-id> [<subnet-id> ...] \
  --query 'Subnets[].AvailabilityZoneId' --region us-west-2
```

Every value must be `usw2-az1`, `usw2-az2`, or `usw2-az3`.

## 8. Teardown

```bash
make delete-runtime
```

`deploy.sh delete runtime` deletes every object version and delete marker in the artifact bucket before it deletes the stack. Only build artifacts are removed, and they can be rebuilt from source. To empty the bucket by hand, delete all versions and delete markers (a versioned bucket is not empty after a plain `aws s3 rm`):

```bash
aws s3api list-object-versions --bucket <bucket> --region us-west-2 \
  --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --output json
# Pass the Objects list to: aws s3api delete-objects --bucket <bucket> --delete file://<json-file>
# The call accepts up to 1000 keys. Repeat until the listing is empty.
```

To rebuild after a delete, run the three-command sequence: `make deploy-runtime`, `make package`, `make deploy-runtime`.

## 9. Global inference profiles

A `ModelId` that starts with `global.` selects the global statement set. `deploy.sh` sets `ModelScope=global` from the prefix. The role then holds three Bedrock statements: the profile ARN with `aws:RequestedRegion`, the in-Region foundation model, and the Region-less foundation model (`arn:<partition>:bedrock:::foundation-model/<id>`). The empty Region and account in the last ARN are intentional. Each foundation model statement is bound to the profile by `bedrock:InferenceProfileArn`.

- A global profile can route requests to Regions outside the US. The data in this project is synthetic.
- An Organizations service control policy that denies by `aws:RequestedRegion` must allow `unspecified` for the execution role. Otherwise global inference fails.
- A mismatch between `ModelId` and `ModelScope` fails closed (model calls are denied), and no other model becomes invocable.

## 10. Manual verification results

Run on 2026-11-24 in us-west-2 with `Env=demo`. No automated tests exist for this stack. Each row was checked by hand.

| Step | Check | Result |
|---|---|---|
| 7.1 | Phase A | The stack created the bucket (versioning Enabled, 4 public access blocks, AES256, deny policy for non-TLS requests), the role, and 3 SSM parameters (`artifact-bucket`, `execution-role-arn`, `invocation-url`). No `AgentRuntime`. The role had no `s3:` and no `ec2:` action. |
| 7.2 | Two-phase flow | Worked without any fallback. Running `package-agent.sh` twice gave the same SHA-256 and key, and the second upload was skipped. Phase B created the `AgentRuntime`: `READY`, `PYTHON_3_12`, entry point `main.py`, VPC mode with the SSM subnets and security group, JWT authorizer with the discovery URL and one allowed client, header allowlist `[Authorization]`, lifecycle 900/28800. `get-agent-runtime` does not return a platform version, so `V1` was confirmed from the stack parameter. A repeat deploy showed no changes. `Code.S3.VersionId` was used (the template passes it). Bug found and fixed: a bash regex bound `{3,1024}` failed silently on macOS (BSD regex limit `RE_DUP_MAX` is 255). It was replaced by a character regex plus a separate length check. |
| 7.3 | First invoke | As supervisor, demo question 2: HTTP 200, `characteristic_trend` tool, 5 rows, rising lot means 25.001 to 25.021. |
| 7.4, 7.5 | Fallbacks | Not needed. The runtime loaded the package from S3 and reached RDS through the VPC with the default role, which has no `s3:` or `ec2:` actions. |
| 8.1 | Inbound authentication | No `Authorization` header: HTTP 401 "Missing Authentication Token". Forged unsigned JWT without `exp`: HTTP 401 "Token has expired". That token was rejected at claim validation, so the signature check was not exercised by itself. No runtime log lines for the rejected requests. Not run: an expired real token, and a token from another pool or client. |
| 8.2 | Demo behavior | Supervisor, demo question 3: HTTP 200 with the `get_lot` tool (4 rows). `inspector-b` asking for line A: denial, tool decision `forbidden` at the tool layer, no line A content. `--persona` with `AGENT_ACCESS_TOKEN`: exit 2. Short `--session-id`: a generated UUID was used. Passwords were not found in the output. Temporary directories were removed. |
| 8.3 | Environment and role | 7 environment variables (`AWS_REGION`, `INSPECTION_DB_HOST`, `INSPECTION_DB_SECRET_ARN`, `INSPECTION_ENV`, `INSPECTION_LOG_LEVEL`, `INSPECTION_MODEL_ID`, `INSPECTION_MODEL_REGION`). No `INSPECTION_MEMORY_ID` while `MemoryId` is empty. No secret values. The profile destination Regions us-east-1, us-east-2, and us-west-2 match the role. IAM simulation: the configured profile and its 3 foundation models are allowed. Another model and another profile give `implicitDeny`. The foundation model without the profile context gives `implicitDeny`. |
| 8.4 | Lifecycle update and input checks | `IdleRuntimeSessionTimeout=600` updated only the `AgentRuntime` in place (version 2, same code location). Restoring 900 created version 3. Rejected before any change: `ModelId` with an `eu.` prefix and a bare foundation model ID (`deploy.sh` exit 2), `LogLevel=LOUD` and an invalid `MemoryId` (CloudFormation `ValidationError`). |
| 8.5 | Code update and sessions | A temporary `[v2]` marker in a fixed error message: a new session returned `[v2]`, and an existing session kept the old message. After the revert, the rebuilt package had the same SHA-256 and the upload was skipped (reproducible build). |
| 8.6 | Global profile and cleanup | `ModelId=global.anthropic.claude-haiku-4-5-20251001-v1:0` set `ModelScope` to `global` with three statements (profile with `aws:RequestedRegion`, in-Region model, and Region-less model, each model statement with `aws:RequestedRegion` and `bedrock:InferenceProfileArn`). Simulation: the global profile and the in-Region model are allowed. Sonnet and the `us.` profile give `implicitDeny`. The Region-less statement was simulated with `aws:RequestedRegion=us-west-2`, which it does not match, so the simulator did not confirm it alone. A real call through the global profile returned HTTP 200. The `us.` profile was then restored. `delete runtime` emptied the versioned bucket (all versions and delete markers), and the stack and bucket were deleted. The three-command rebuild created a new bucket and runtime that answered HTTP 200. `git status` showed no test files. |

## 11. Known gaps

These are recorded, not fixed.

1. Agent answers do not fully match `data/STORIES.md`.
   - Demo question 2 gives out-of-tolerance counts but not the values 25.022, 25.021, and 25.024.
   - Demo question 3 says the lot was accepted, although IR-2025-0024 is submitted with no disposition. It also does not name the recheck as the next step.
   - This is system prompt behavior. A later spec covers it.
2. Cosmetic noise in the scripts. Both scripts work and exit 0.
   - `deploy.sh` prints `ERROR ... (line 79/184)` lines. The ERR trap fires inside `$(...)` subshells when a lookup returns not found.
   - `package-agent.sh` prints `failed during: check for existing object` when `head-object` returns 404 for a new key.
3. The runtime logs a harmless urllib3 `NotOpenSSLWarning`, because Python uses AWS-LC FIPS.
