# Implementation Plan: AgentCore Runtime Stack

## Overview

This plan deploys the Strands agent to Amazon Bedrock AgentCore Runtime. The design uses Python 3.12, bash 3.2 and CloudFormation YAML, so no language question applies. The design has no Correctness Properties section, so there are no property test tasks.

The workspace testing policy forbids test files, suites, fixtures, eval harnesses and verification scripts. Every verification task below is a manual step. Each one ends with a note that records what was checked and the result. Record those notes in this file under the task, or in `docs/runtime.md` for the first-deploy results.

Order of work: local code changes, template, packaging script, deploy script, invoke script, first deploy (two phases plus conditional fallbacks), behavior verification, then the document.

## Tasks

- [x] 1. Add runtime configuration to the Python code
  - [x] 1.1 Add database environment variables to `src/inspection_core/db.py`
    - `_secret_id()` returns `INSPECTION_DB_SECRET_ARN` when set, otherwise the derived name `inspection-agent/<env>/database/agent-ro`.
    - `connect()` uses `INSPECTION_DB_HOST` instead of `secret["host"]` when set.
    - Validate the ARN against `^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:inspection-agent/<env>/database/agent-ro-.+$` and the host against `^[A-Za-z0-9.-]{1,253}$`.
    - Raise `ValueError` with a fixed message on a bad value, like the existing `INSPECTION_ENV` check. Never log or pass a secret value.
    - _Requirements: 5.3, 5.8_

  - [x] 1.2 Add log level handling to `src/inspection_agent/entrypoint.py`
    - Add `_configure_logging()`, called at import. It reads `INSPECTION_LOG_LEVEL`, accepts only `DEBUG`, `INFO`, `WARNING`, `ERROR` (default `INFO`), and sets the level on the `inspection_agent` and `inspection_core` loggers only.
    - Do not touch the root logger.
    - _Requirements: 5.4_

  - [x] 1.3 Manual verification of the Python changes
    - Run `ruff check .`.
    - In a Python shell, call `_secret_id()` with a valid ARN, an invalid ARN and no variable. Confirm the valid value is returned, the invalid one raises `ValueError`, and the default name is used when unset.
    - Import `inspection_agent.entrypoint` with `INSPECTION_LOG_LEVEL=DEBUG` and with `LOUD`. Confirm the logger levels and that the root logger level is unchanged.
    - Record the checks and results in the task notes. Create no test file.
    - _Requirements: 5.3, 5.4, 13.7_

- [x] 2. Write the runtime CloudFormation template `infra/runtime.yaml`
  - [x] 2.1 Declare parameters, Rule, Conditions and Mappings
    - Parameters from the design table: `Env`, `ModelId`, `ModelScope`, `IdleRuntimeSessionTimeout`, `MaxLifetime`, `LogLevel`, `MemoryId`, `PackageObjectKey`, `PackageObjectVersion`, `PlatformVersion`, `EnableS3ReadFallback`, `EnableEniFallback`, and the six SSM-typed parameters for network, auth and database. Each has a `Description` and a constraint.
    - Do not compare `IdleRuntimeSessionTimeout` with `MaxLifetime` anywhere.
    - Rule `PackageBothOrNeither`. Conditions `HasPackage`, `HasMemory`, `IsGlobalModel`, `IsGeoModel`, `UseS3ReadFallback`, `UseEniFallback`. Mapping `ProfileRoutes` with the key `us`.
    - Follow `docs/cloudformation-conventions.md`.
    - _Requirements: 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.10, 5.7, 6.2, 7.3, 8.5_

  - [x] 2.2 Add the artifact bucket, bucket policy and execution role
    - `ArtifactBucket`: versioning on, `AES256`, four public-access blocks, `BucketOwnerEnforced`, tags, no fixed name.
    - `ArtifactBucketPolicy`: deny `s3:*` when `aws:SecureTransport` is false, on the bucket and its objects.
    - `ExecutionRole` named `inspection-agent-<env>-runtime-exec`. Trust policy with `aws:SourceAccount` and the `aws:SourceArn` runtime pattern. Inline policy with the Bedrock statements (geographic and global sets selected by condition, each foundation model statement bound by `bedrock:InferenceProfileArn`, global statements with `aws:RequestedRegion`), `ReadOnlySecret`, logs, X-Ray, `PutMetricData` with the namespace condition, and the `Memory` statement under `HasMemory`.
    - Add the `PackageRead` statement under `UseS3ReadFallback` and the ENI statements under `UseEniFallback`, exactly as in the design fallback section. A default deploy contains none of them.
    - A YAML comment above every `*` resource. No literal account ID, Region or ARN. `Fn::Sub` uses a variable map where `Fn::Select` is needed.
    - _Requirements: 3.1, 3.2, 3.3, 3.5, 4.9, 6.3, 8.1, 8.2, 8.3, 8.4, 8.6, 8.7, 8.8, 8.9, 8.10, 8.11, 8.12_

  - [x] 2.3 Add the runtime resource, SSM parameters and outputs
    - `AgentRuntime` under `HasPackage`: name `inspection_agent_<env>`, `PlatformVersion`, `CodeConfiguration` (`PYTHON_3_12`, `main.py`, S3 bucket, key and version), VPC network config, `CustomJWTAuthorizer` with `AllowedClients`, header allowlist `[Authorization]`, lifecycle config, environment variables from the design table (`INSPECTION_MEMORY_ID` uses `AWS::NoValue` when empty), tags.
    - SSM parameters: `artifact-bucket`, `execution-role-arn`, `invocation-url` always. `runtime-arn` and `runtime-id` under `HasPackage`.
    - Outputs with descriptions and no `Export`.
    - _Requirements: 3.4, 3.6, 3.7, 4.1, 4.2, 4.11, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 6.1, 7.1, 7.2, 7.4, 7.5, 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x] 2.4 Lint the template
    - Run `uvx --from "cfn-lint==1.60.1" cfn-lint infra/runtime.yaml`. Expect zero errors and zero warnings.
    - Build a quick table of the template against `docs/cloudformation-conventions.md` and fix gaps by hand.
    - Record the lint output in the task notes.
    - _Requirements: 9.6, 8.12_

- [x] 3. Write the packaging script `scripts/package-agent.sh`
  - [x] 3.1 Implement the script
    - Bash 3.2. Options `--env` (default `demo`) and `--region` (default `us-west-2`). Validate `--env` against `^[a-z][a-z0-9]{0,9}$` and exit 2 before any AWS call. Check that `aws`, `uv` and `python3` exist.
    - Read `/inspection-agent/<env>/runtime/artifact-bucket`. If missing, exit 1 naming `scripts/deploy.sh --env <env> deploy runtime`.
    - Recreate `build/agent-package/`. Install dependencies with `uv pip install --python-platform aarch64-manylinux_2_28 --python-version 3.12 --only-binary=:all: --target ... -r src/inspection_agent/requirements.txt`.
    - Copy `src/inspection_agent/` and `src/inspection_core/` to the zip root, excluding `__pycache__`, `*.pyc`, `*.md` and `inspection_core/seed/`. Keep `system_prompt.txt`.
    - Write the root `main.py` shim that imports `app` from `inspection_agent.entrypoint`.
    - Build `build/inspection-agent.zip` with an inline `python3` heredoc: sorted names, fixed timestamp, mode 0644 files, 0755 directories and `.so` files.
    - Enforce 250,000,000 zipped and 750,000,000 unzipped bytes. Key is `code/<sha256>.zip`. Skip the upload when `head-object` finds the key. Otherwise `put-object` with `--expected-bucket-owner` and read the `VersionId`.
    - Print bucket, key, version ID, SHA-256 and sizes. Write `build/package-location.env`. Print and read no secret.
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 2.3_

  - [x] 3.2 Manual verification of the packaging steps that need no deployment
    - Run `bash -n scripts/package-agent.sh`.
    - Run with `--env Bad!` and confirm exit 2 and no AWS call.
    - Build the zip twice with the upload step skipped or pointed at the deployed bucket after task 7.1, and compare the two SHA-256 values. Record the result and, if the digests differ, the cause.
    - Run `unzip -l build/inspection-agent.zip`. Confirm `main.py`, `inspection_agent/`, `inspection_core/`, `strands/`, `psycopg/`, `system_prompt.txt`, and no `seed/`, `__pycache__` or `*.md`.
    - Confirm every `.so` file is ELF aarch64 and the sizes are within the limits.
    - Record the checks in the task notes. The digest comparison and the upload run again in task 7.2.
    - _Requirements: 1.3, 1.7, 2.1, 2.3_

- [x] 4. Extend the deploy script `scripts/deploy.sh`
  - [x] 4.1 Pass runtime parameters, derive `ModelScope`, and support `--param`
    - For the `runtime` component, pass the package parameters, the six SSM parameter names for the current `Env`, and `ModelScope` derived from the effective `ModelId` prefix (`--param`, then current stack parameter, then template default). Exit 2 for a prefix other than `us` or `global`.
    - Add the repeatable `deploy <component> --param Key=Value` option. `deploy-all` rejects it.
    - Add `resolve_package` with the three rules from the design. It reads `build/package-location.env` with `grep` and `cut`, never `source`, and validates values against the parameter patterns. With no package, `deploy runtime` deploys Phase A, then exits 1 naming `scripts/package-agent.sh`.
    - Use `${arr[@]+"${arr[@]}"}` for possibly empty arrays.
    - _Requirements: 10.1, 10.2, 10.4, 4.4, 8.5_

  - [x] 4.2 Wire the two-phase flow into `deploy-all` and bucket emptying into `delete runtime`
    - Step 4: deploy Phase A, run `scripts/package-agent.sh`, deploy Phase B with `MemoryId=`. Step 6 takes the package parameters from the current stack.
    - `delete runtime`: delete every object version and delete marker in the artifact bucket before `delete-stack`. Build the JSON with `python3`.
    - _Requirements: 3.5, 10.1, 10.2, 10.3_

  - [x] 4.3 Manual verification of the deploy script without changing AWS
    - Run `bash -n scripts/deploy.sh`.
    - Run with an invalid `--env`, a `ModelId` with prefix `eu.`, and `deploy-all --param X=Y`. Confirm each exits non-zero before a resource changes.
    - Run `shellcheck` only if it is already installed. Install nothing for this.
    - Record the checks in the task notes.
    - _Requirements: 10.1, 8.5_

- [x] 5. Extend the invoke script `scripts/invoke.sh`
  - [x] 5.1 Add `--persona` sign-in
    - Options `--persona inspector-a|inspector-b|supervisor`. Exit 2 naming both when `--persona` and `AGENT_ACCESS_TOKEN` are present.
    - Read the pool ID and client ID from SSM. Create a virtual environment with `mktemp -d`, install `pycognito`, and run SRP authentication per `docs/auth.md` section 7. Emails come from a fixed table in the script.
    - Password from `DEMO_PASSWORD_INSPECTOR_A`, `DEMO_PASSWORD_INSPECTOR_B` or `DEMO_PASSWORD_SUPERVISOR`, or from `getpass`. Only the access token goes to stdout of the Python step, into a shell variable. An `EXIT` trap removes the virtual environment and temp files.
    - Print `Sign-in failed.` and exit 1 on failure, without the exception text. No option takes a password, token or user identity.
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.11, 11.12_

  - [x] 5.2 Add status handling and session ID generation
    - Write the body to a `chmod 600` temp file, read the code with `-w '%{http_code}'`, print `HTTP <code>` to stderr and the body to stdout. Exit 1 on a non-2xx code. Keep exit codes 2 and 3.
    - Generate a fresh Session_ID when `--session-id` is absent or shorter than 33 characters. Send the token through `printf ... | curl -H @-`.
    - _Requirements: 11.6, 11.7, 11.8, 11.9, 11.10_

- [x] 6. Checkpoint - Review the static work
  - Run `ruff check .`, `uvx --from "cfn-lint==1.60.1" cfn-lint infra/runtime.yaml`, and `bash -n` on the three scripts. Ask the user if questions arise before the first deploy.

- [x] 7. First-deploy verification
  - [x] 7.1 Deploy Phase A and inspect it
    - Run `scripts/deploy.sh deploy runtime` with no package. Expect the stack to reach `CREATE_COMPLETE` with the bucket, role and three SSM parameters, and no runtime. The script exits 1 naming the Package_Script, as designed.
    - Check `aws s3api get-bucket-versioning`, `get-public-access-block`, `get-bucket-encryption`, `get-bucket-policy`, and `aws ssm get-parameters-by-path --path /inspection-agent/demo/runtime`.
    - Read the deployed role policy and confirm no `s3:` and no `ec2:` action in a default deploy.
    - Record the results in the task notes.
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 8.7, 9.1, 9.3, 9.4, 10.2, 13.8, 13.9_

  - [x] 7.2 Run the package upload and Phase B, and record the two-phase result
    - Run `scripts/package-agent.sh`. Run it a second time and confirm the same digest and key, and that the upload is skipped.
    - Run `scripts/deploy.sh deploy runtime` with the package location. Record whether `AgentRuntime` created without a fallback, whether `Code.S3.VersionId` was needed, and whether a failure (if any) rolled back to Phase A.
    - Confirm `aws bedrock-agentcore-control get-agent-runtime` reports `READY`, `PYTHON_3_12`, entry point `main.py`, `VPC` with the SSM subnets and group, and platform `V1`.
    - Run `scripts/deploy.sh deploy runtime` again and confirm no resource change.
    - If Phase B fails for a reason other than a fixable permission or parameter error, stop and ask the user to choose between the two fallbacks in the design (shared artifacts bucket in `infra/network.yaml`, or bootstrap package). Make no change to `infra/network.yaml` without that decision.
    - If the assume-role step fails, switch the trust condition to the documented `...:${AWS::AccountId}:*` form and record it.
    - Record the results in the task notes and in `docs/runtime.md` (task 9.1).
    - _Requirements: 1.3, 1.4, 1.5, 3.7, 4.1, 4.2, 6.1, 10.3, 10.4, 13.8, 13.9_

  - [x] 7.3 Invoke the runtime for the first time
    - Create the demo users if they do not exist (`scripts/create-demo-users.sh`). Run `scripts/invoke.sh --persona supervisor --prompt "<a demo question>"`. Expect HTTP 2xx and an answer.
    - If it fails, read the CloudFormation event reason and the log group `/aws/bedrock-agentcore/runtimes/inspection_agent_demo-*`, then use the symptom table in the design. Do not apply a fallback unless a row matches.
    - Record the status code, the first-invoke result and the matched symptom (if any) in the task notes.
    - _Requirements: 11.1, 11.6, 11.8, 13.2, 13.8_

  - [x] 7.4 Conditional: enable `EnableS3ReadFallback`
    - Run this task only if task 7.2 or 7.3 fails with an S3 `AccessDenied` that names the Execution_Role as the principal. If the denied principal is the deploying identity, fix that identity instead and skip this task.
    - Run `scripts/deploy.sh deploy runtime --param EnableS3ReadFallback=true`. Confirm the role gains only `s3:GetObject` and `s3:GetObjectVersion` on `<bucket>/code/*`. Invoke with a fresh session ID and confirm the runtime starts.
    - If the task did not run, write "not needed" with the evidence from 7.2 and 7.3 in the task notes.
    - _Requirements: 8.7, 13.8_

  - [x] 7.5 Conditional: enable `EnableEniFallback`
    - Run this task only if startup fails with `ec2:` actions denied for the Execution_Role. First check that `aws iam get-role --role-name AWSServiceRoleForBedrockAgentCoreNetwork` succeeds and that the subnets are in `usw2-az1`, `usw2-az2` or `usw2-az3`. If either check fails, fix that cause and skip this task.
    - Run `scripts/deploy.sh deploy runtime --param EnableEniFallback=true`. Confirm the added statements match the design. Invoke with a fresh session ID and confirm the runtime starts.
    - If the task did not run, write "not needed" with the evidence in the task notes.
    - _Requirements: 6.3, 13.8_

- [x] 8. Verify deployed behavior by hand
  - [x] 8.1 Verify inbound authentication
    - Send requests with no token, an expired token, a token from another pool or app client. Expect 401 or 403 each time and no entrypoint log line for them. Send a valid access token and confirm an answer.
    - Confirm `get-agent-runtime` shows `Authorization` as the only allowlisted header and `AllowedClients` with the app client ID.
    - Record the checks in the task notes.
    - _Requirements: 7.1, 7.2, 7.4, 7.5, 7.6, 7.7, 13.1_

  - [x] 8.2 Verify demo behavior through the runtime
    - As `supervisor`, ask demo question 3 and confirm `actions` has at least one entry. As `inspector-b`, ask for line A data and confirm a denial with no line A content. Run `scripts/invoke.sh` with `--persona` and `AGENT_ACCESS_TOKEN` together (exit 2), a short `--session-id` (new one generated), and a broken token (non-2xx, exit 1).
    - Search the terminal output for the token and the password. Confirm the temporary virtual environment is gone.
    - Record the checks in the task notes.
    - _Requirements: 11.3, 11.5, 11.7, 11.9, 11.11, 13.2, 13.3_

  - [x] 8.3 Verify the environment variables and the execution role
    - `get-agent-runtime` `environmentVariables`: all variables from the design present, no memory ID while `MemoryId` is empty, no secret value.
    - Run `aws iam simulate-principal-policy` for `bedrock:InvokeModel` on another model ID (expect `implicitDeny`) and on the profile and foundation model ARNs (expect `allowed`). Compare the three foundation model Regions with `aws bedrock get-inference-profile`.
    - Confirm every `*` resource has a comment and no literal account, Region or ARN is in the template.
    - Record the checks in the task notes.
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.6, 5.8, 8.2, 8.3, 8.12, 13.6_

  - [x] 8.4 Verify an in-place lifecycle update and idempotent deploys
    - Run `scripts/deploy.sh deploy runtime --param IdleRuntimeSessionTimeout=600`. Read the change set: only `LifecycleConfiguration` changes. Confirm 600 and the same code location. Restore the value to 900.
    - Try an invalid `ModelId` (`eu.` prefix and a bare foundation model ID), `LogLevel` and `MemoryId`. Each must be rejected.
    - Record the checks in the task notes.
    - _Requirements: 4.4, 4.5, 4.7, 4.8, 4.11, 8.5, 10.4, 13.4_

  - [x] 8.5 Verify a code update reaches new sessions only
    - Change one visible source line, run the Package_Script, deploy the runtime stack, invoke with a fresh session ID and confirm the new code. Invoke with the old session ID and confirm the old code until that session ends. Revert the source change and redeploy.
    - Record the checks in the task notes.
    - _Requirements: 3.7, 12.1, 12.2, 13.5_

  - [x] 8.6 Verify global profile scope and bucket cleanup
    - Deploy with a `global.` profile ID for the same model. Confirm `ModelScope` is `global` in the stack parameters, the three global statements exist with their conditions, and the simulation allows only the configured model. Restore the default `us.` profile.
    - Run `scripts/deploy.sh delete runtime`, confirm the bucket is gone with its versions, then run `scripts/deploy.sh deploy-all` steps for the runtime again (or `deploy runtime` after the package step) to restore the stack.
    - Run `git status` and confirm no test file exists.
    - Record the checks in the task notes.
    - _Requirements: 3.5, 4.4, 8.2, 8.4, 13.6, 13.7_

- [x] 9. Write `docs/runtime.md`
  - [x] 9.1 Write the runtime document
    - Sections from the design outline: platform facts, parameter table, SSM parameters read and published, first deploy and update procedure, session behavior, deploying identity prerequisites, AZ check, teardown and manual bucket-emptying command, manual verification steps for Requirement 13, global profile notes.
    - Include the first-deploy results from tasks 7.1 to 7.5: whether the two-phase flow worked without a fallback, and which fallback switch (if any) was applied with its evidence.
    - Write in English. Link `docs/runtime.md` from `docs/README.md` if that file lists documents.
    - _Requirements: 2.1, 2.2, 3.5, 6.4, 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 12.8_

- [x] 10. Final checkpoint - Confirm everything is verified
  - Run `ruff check .` and cfn-lint once more. Confirm each verification task has notes. Ask the user if questions arise.

## Notes

- No task creates a test file, suite, fixture, eval harness or verification script. Verification is manual and recorded in task notes.
- Tasks 7.4 and 7.5 run only when the first deploy matches the failure described in each. Otherwise they end with a "not needed" note.
- Task 7.2 stops for a user decision if the two-phase approach fails for a reason other than a fixable permission or parameter error.
- The idle timeout versus `MaxLifetime` order is not checked in the repository. The AgentCore service validates it.
- Deploying tasks (7 and 8) change real AWS resources in `us-west-2`. Confirm the target account before running them.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "3.1", "5.1"] },
    { "id": 1, "tasks": ["1.2", "2.2", "4.1", "5.2"] },
    { "id": 2, "tasks": ["1.3", "2.3", "3.2", "4.2"] },
    { "id": 3, "tasks": ["2.4", "4.3"] },
    { "id": 4, "tasks": ["6"] },
    { "id": 5, "tasks": ["7.1"] },
    { "id": 6, "tasks": ["7.2"] },
    { "id": 7, "tasks": ["7.3"] },
    { "id": 8, "tasks": ["7.4"] },
    { "id": 9, "tasks": ["7.5"] },
    { "id": 10, "tasks": ["8.1", "8.2", "8.3"] },
    { "id": 11, "tasks": ["8.4"] },
    { "id": 12, "tasks": ["8.5"] },
    { "id": 13, "tasks": ["8.6"] },
    { "id": 14, "tasks": ["9.1"] },
    { "id": 15, "tasks": ["10"] }
  ]
}
```
