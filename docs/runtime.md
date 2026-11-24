# AgentCore runtime

This document covers two stacks, deployed in this order:

- `inspection-agent-<env>-pre-runtime` (`infra/pre-runtime.yaml`): the artifact bucket, the execution role, and the model and memory SSM parameters.
- `inspection-agent-<env>-runtime` (`infra/runtime.yaml`): the AgentCore runtime.

The stacks deploy the Strands agent (`src/inspection_agent/` with `src/inspection_core/`) to Amazon Bedrock AgentCore Runtime. They use the code-in-S3 artifact option, VPC network mode, and a custom JWT authorizer backed by the Cognito user pool from the auth stack.

The split exists because `AWS::BedrockAgentCore::Runtime` needs the code package to exist in S3 when it is created, and the bucket must exist before the package can be uploaded. The bucket lives in `pre-runtime`, the package is uploaded between the two deploys, and `runtime` reads everything it needs from SSM.

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

Every parameter has a constraint. Pass overrides with `scripts/deploy.sh deploy <component> --param Key=Value`.

### pre-runtime

| Name | Default | Constraint | Notes |
|---|---|---|---|
| `Env` | `demo` | `^[a-z][a-z0-9]{0,9}$` | Set by `--env`. |
| `ModelId` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | `^(us\|global)\.[a-z0-9-]+\.[a-z0-9][a-z0-9:_-]*$` | Geographic (`us.`) or global (`global.`) profile ID only. Other prefixes and bare foundation model IDs are rejected. `deploy.sh` keeps the current stack value when you do not pass one. |
| `ModelScope` | `us` | `us`, `global` | Derived by `deploy.sh` from the `ModelId` prefix. Do not set it by hand. |
| `MemoryId` | empty | empty or `^[a-zA-Z][a-zA-Z0-9_-]{0,99}-[a-zA-Z0-9]{10}$` | Empty until the memory stack exists. `deploy.sh` keeps the current stack value when you do not pass one. Published to SSM as `none` when empty. |
| `EnableS3ReadFallback` | `false` | `true`, `false` | Adds `s3:GetObject` and `s3:GetObjectVersion` on `<bucket>/code/*` to the execution role. Not needed in the first deploy. |
| `EnableEniFallback` | `false` | `true`, `false` | Adds network interface permissions to the execution role. Not needed in the first deploy. |
| `RuntimeSecurityGroupId`, `DbSecretArn` | SSM paths under `network` and `database` | SSM parameter type | Used by the role statements. |

### runtime

| Name | Default | Constraint | Notes |
|---|---|---|---|
| `Env` | `demo` | `^[a-z][a-z0-9]{0,9}$` | Set by `--env`. |
| `PackageObjectKey` | none (required) | `^code/[A-Za-z0-9._-]{1,200}$` | Filled by `deploy.sh` from `build/package-location.env`. |
| `PackageObjectVersion` | none (required) | `^[A-Za-z0-9._-]{3,1024}$` | Filled by `deploy.sh`. |
| `IdleRuntimeSessionTimeout` | 900 | 60 to 28800 | The AgentCore service checks it against `MaxLifetime`. The repository does not. |
| `MaxLifetime` | 28800 | 60 to 28800 | |
| `LogLevel` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` | Applied to the `inspection_agent` and `inspection_core` loggers only. |
| `PlatformVersion` | `V1` | `V1`, `V2` | |
| SSM-typed parameters | See section 3 | SSM parameter type | Network, auth, database, and pre-runtime values. |

`ModelId` and `MemoryId` of the runtime stack are SSM-typed and read from the pre-runtime stack. `deploy.sh deploy runtime --param ModelId=...` and `--param MemoryId=...` are rejected with exit 2. Change them on `pre-runtime`, then deploy `runtime` again.

Environment variables set on the runtime: `INSPECTION_ENV`, `AWS_REGION`, `INSPECTION_MODEL_ID`, `INSPECTION_MODEL_REGION`, `INSPECTION_DB_HOST`, `INSPECTION_DB_SECRET_ARN`, `INSPECTION_LOG_LEVEL`, and `INSPECTION_MEMORY_ID` when the memory-id SSM value is not `none`. No variable holds a password, token, or user identity.

## 3. SSM parameters

Read by the pre-runtime stack (names passed as stack parameters, defaults use `demo`):

| Path | Source stack |
|---|---|
| `/inspection-agent/<env>/network/runtime-security-group-id` | network |
| `/inspection-agent/<env>/database/agent-ro-secret-arn` | database |

Published by the pre-runtime stack:

| Path | Value |
|---|---|
| `/inspection-agent/<env>/pre-runtime/artifact-bucket` | Artifact bucket name |
| `/inspection-agent/<env>/pre-runtime/execution-role-arn` | Execution role ARN |
| `/inspection-agent/<env>/pre-runtime/model-id` | The `ModelId` value |
| `/inspection-agent/<env>/pre-runtime/memory-id` | The `MemoryId` value, or `none` when it is empty (an SSM String value cannot be empty) |

Read by the runtime stack:

| Path | Source stack |
|---|---|
| `/inspection-agent/<env>/network/private-subnet-ids` | network |
| `/inspection-agent/<env>/network/runtime-security-group-id` | network |
| `/inspection-agent/<env>/auth/discovery-url` | auth |
| `/inspection-agent/<env>/auth/app-client-id` | auth |
| `/inspection-agent/<env>/database/endpoint` | database |
| `/inspection-agent/<env>/database/agent-ro-secret-arn` | database |
| `/inspection-agent/<env>/pre-runtime/artifact-bucket` | pre-runtime |
| `/inspection-agent/<env>/pre-runtime/execution-role-arn` | pre-runtime |
| `/inspection-agent/<env>/pre-runtime/model-id` | pre-runtime |
| `/inspection-agent/<env>/pre-runtime/memory-id` | pre-runtime |

Published by the runtime stack:

| Path | Value |
|---|---|
| `/inspection-agent/<env>/runtime/runtime-arn` | Runtime ARN |
| `/inspection-agent/<env>/runtime/runtime-id` | Runtime ID |
| `/inspection-agent/<env>/runtime/invocation-url` | URL pattern with the placeholder `{EncodedRuntimeArn}` |

## 4. Deploy and update

### Shell notes

The scripts need bash. They work on the macOS default bash 3.2 and on Linux. The Makefile calls them directly, so you do not need to start a bash shell yourself.

`scripts/invoke.sh --persona` reads the password from `DEMO_PASSWORD_INSPECTOR_A`, `DEMO_PASSWORD_INSPECTOR_B`, or `DEMO_PASSWORD_SUPERVISOR`, or prompts without echo. In zsh, `read -rs -p` does not work. Set the variables like this instead:

```zsh
read -rs "DEMO_PASSWORD_SUPERVISOR?Supervisor password: "; export DEMO_PASSWORD_SUPERVISOR
```

### First deploy

```bash
make deploy-network
make deploy-auth
make deploy-database
make seed
make deploy-pre-runtime   # Artifact bucket, execution role, model-id and memory-id SSM parameters.
make package              # Build the zip and upload it to the artifact bucket.
make deploy-runtime       # Creates the AgentRuntime from the package.
```

`make deploy-runtime` stops with exit 1 before it changes anything when the pre-runtime stack is missing (it names `make deploy-pre-runtime`) or when no code package is found (it names `make package`).

`make deploy` (`deploy-all`) runs the 13-step sequence in the root README, including the package step and the memory update of both stacks. It needs all 9 templates in `infra/` and works only once they exist.

### Adding the memory ID

After `make deploy-memory`, pass the memory ID to the pre-runtime stack so the role may use it, then deploy the runtime so it reads the new `memory-id` SSM value:

```bash
scripts/deploy.sh deploy pre-runtime --param MemoryId=<memory-id>
scripts/deploy.sh deploy runtime
```

`deploy-all` does both steps. Later `deploy pre-runtime` runs keep the current `MemoryId` unless you pass another. The runtime stack takes the new value from SSM, which CloudFormation resolves on each update. This resolution on update has not been verified yet (see section 10).

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

Before the first `deploy runtime`, confirm the private subnets are in supported AZs:

```bash
aws ec2 describe-subnets --subnet-ids <subnet-id> [<subnet-id> ...] \
  --query 'Subnets[].AvailabilityZoneId' --region us-west-2
```

Every value must be `usw2-az1`, `usw2-az2`, or `usw2-az3`.

## 8. Teardown

```bash
make delete-runtime
make delete-pre-runtime
```

Delete `runtime` first. `deploy.sh delete pre-runtime` deletes every object version and delete marker in the artifact bucket before it deletes the stack, because a versioned bucket is not empty after a plain `aws s3 rm`. Only build artifacts are removed, and they can be rebuilt from source. `delete runtime` empties nothing. `make teardown` runs both in the right order. To empty the bucket by hand:

```bash
aws s3api list-object-versions --bucket <bucket> --region us-west-2 \
  --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --output json
# Pass the Objects list to: aws s3api delete-objects --bucket <bucket> --delete file://<json-file>
# The call accepts up to 1000 keys. Repeat until the listing is empty.
```

To rebuild after a delete, run: `make deploy-pre-runtime`, `make package`, `make deploy-runtime`.

## 9. Global inference profiles

A `ModelId` that starts with `global.` selects the global statement set in the pre-runtime stack. `deploy.sh` sets `ModelScope=global` from the prefix. The role then holds three Bedrock statements: the profile ARN with `aws:RequestedRegion`, the in-Region foundation model, and the Region-less foundation model (`arn:<partition>:bedrock:::foundation-model/<id>`). The empty Region and account in the last ARN are intentional. Each foundation model statement is bound to the profile by `bedrock:InferenceProfileArn`.

- A global profile can route requests to Regions outside the US. The data in this project is synthetic.
- An Organizations service control policy that denies by `aws:RequestedRegion` must allow `unspecified` for the execution role. Otherwise global inference fails.
- A mismatch between `ModelId` and `ModelScope` fails closed (model calls are denied), and no other model becomes invocable.

## 10. Manual verification results

Run on 2026-11-24 in us-west-2 with `Env=demo`. No automated tests exist for these stacks. Each row was checked by hand.

These results were recorded on the earlier single-stack layout, with one `runtime` stack and a two-phase deploy (the rows call the phases Phase A and Phase B). The split into `pre-runtime` and `runtime` was made afterwards.

The split layout was first deployed on 2026-11-24, after the old single `runtime` stack was emptied and deleted:
- `make deploy-pre-runtime`: the stack was created. It published `artifact-bucket`, `execution-role-arn`, `model-id` (the `us.` Haiku 4.5 profile) and `memory-id` (`none`).
- `make package`: the package went to the new bucket with the same SHA-256 as before, and no false error line was printed.
- `make deploy-runtime`: the stack was created and published `runtime-arn`, `runtime-id` and `invocation-url`. The runtime reached `READY` with the same package key and the 7 expected environment variables, with no `INSPECTION_MEMORY_ID`.
- A supervisor invoke returned HTTP 200 from the `get_lot` tool.
- No stray `ERROR ... line N` lines appeared in the deploy or delete output.

Still open on the split layout: the `memory-id` update once a memory stack exists, a code update, and teardown of `pre-runtime` with bucket emptying.

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
2. The runtime logs a harmless urllib3 `NotOpenSSLWarning`, because Python uses AWS-LC FIPS.
