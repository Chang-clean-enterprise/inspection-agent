# Implementation Plan: Database and Seed Load

## Overview

The design uses Python 3.12 for the seed handler, so no language question is needed. The plan first makes the code and template changes (network, schema, handler, database stack, seed script, docs). It then deploys and verifies by hand.

The steering Testing policy applies. No test file, suite, fixture, or verification script is created. Each former test task is a manual verification step. The result of each step is recorded in the "Verification Record" in the Notes section, except the in-VPC read-only checks, which are recorded in `docs/database.md` (Requirement 12).

Open items from the design are covered as follows: O1 in task 2.1, O2 in tasks 8.1 and 8.9, O3 in task 8.1, O4 in task 8.9, O5 in tasks 3.1 and 6.1.

## Tasks

- [x] 1. Extend the network stack for the Seed function
  - [x] 1.1 Edit `infra/network.yaml` (additive changes only)
    - Add `SeedToInternetEgress` (`AWS::EC2::SecurityGroupEgress`, `Condition: UseNat`, TCP 443 to `0.0.0.0/0`).
    - Add `SeedToEndpointEgress` (`Condition: UseEndpoints`, TCP 443 to `EndpointSecurityGroup`).
    - Add `EndpointFromSeedIngress` (`AWS::EC2::SecurityGroupIngress`, `Condition: UseEndpoints`, TCP 443 on `EndpointSecurityGroup` from `SeedSecurityGroup`).
    - Extend the `LogsEndpoint` policy resources with the log group `/aws/lambda/inspection-agent-${Env}-seed` and the same ARN with `:*`, built with `!Sub` and no literals.
    - Leave the runtime rules, the Database security group, the loopback placeholder, the SSM parameters, and the `EndpointSecurityGroup` `GroupDescription` unchanged.
    - _Requirements: 4.2, 4.3, 4.4, 4.6, 10.4_

  - [x] 1.2 Lint the network template
    - Run `cfn-lint infra/network.yaml`. Fix findings until there are zero errors and zero warnings.
    - _Requirements: 10.3_

- [x] 2. Make the schema repeatable
  - [x] 2.1 Edit `data/schema.sql` (resolves O1)
    - Change all 7 `CREATE TABLE` statements to `CREATE TABLE IF NOT EXISTS` and all 6 `CREATE INDEX` statements to `CREATE INDEX IF NOT EXISTS`.
    - Keep `BEGIN`, `COMMIT`, and `COMMENT ON` as they are.
    - Change the header comment to say the file is safe to apply repeatedly and leaves existing objects unchanged.
    - Do not change `data/generate.py` or any file in `data/seed/`. Confirm in the Verification Record that O1 (editing this file is in scope) was accepted as part of this task list.
    - _Requirements: 7.1, 7.2, 7.3_

- [x] 3. Implement the seed handler
  - [x] 3.1 Create `src/inspection_core/seed/handler.py`
    - Standard library plus `psycopg`. Entry point `handler(event, context)`. Ignore the event content entirely.
    - Read `MASTER_SECRET_ARN`, `OWNER_SECRET_ARN`, `AGENT_RO_SECRET_ARN`, and `DB_NAME` from the environment. Read files from `data/schema.sql`, `data/seed/*.csv`, and `data/seed/METADATA.json` relative to the task root.
    - Step `validate-metadata`: stop with `ok:false` before any secret read or connection unless `synthetic` is `true`.
    - Step `roles` (master, autocommit, `sslmode=require`, 10 s connect timeout): create `inspection_owner` and `agent_ro` if absent. Then set `NOSUPERUSER NOCREATEDB NOCREATEROLE` and the password as a SCRAM-SHA-256 verifier from `pgconn.encrypt_password`. Set `CONNECTION LIMIT 10`, `statement_timeout = '10s'`, and `default_transaction_read_only = 'on'` on `agent_ro`. Apply the database-level and `public` schema grants and revokes from the design.
    - Step `schema` (owner, autocommit): execute the full text of `data/schema.sql`.
    - Step `load` (owner, one `conn.transaction()`): one `TRUNCATE` of all 7 tables, then `COPY ... FROM STDIN WITH (FORMAT csv, HEADER true)` in the order `lines`, `parts`, `characteristics`, `inspectors`, `lots`, `inspection_reports`, `measurements`.
    - Step `grants` (owner): `REVOKE ALL` then `GRANT SELECT` to `agent_ro` for each of the 7 tables.
    - Step `count` (owner): `SELECT count(*)` per table. Count file rows with `csv.reader` minus the header.
    - Use `psycopg.sql.Identifier` for every identifier. Table names come from a fixed tuple.
    - Catch every exception and return `{"ok": false, "step", "table", "error"}`. The error holds the class name and SQLSTATE. Include `diag.message_primary` only for the `schema` and `load` steps. Never log or return a password or secret value. Log step names and counts only.
    - Add a short module comment stating that the connection uses `sslmode=require` (encrypts, no certificate verification) and that `verify-full` is the upgrade path if the demo leaves a private single-account setup (records O5).
    - Return `{"ok": true, "tables": [{"table", "db_rows", "file_rows"}]}` on success.
    - _Requirements: 3.8, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 6.4, 6.5, 6.6, 7.1, 7.2, 7.3, 7.4, 7.5, 7.7, 7.8, 7.9, 7.10, 7.11, 10.6_

  - [x] 3.2 Add `src/inspection_core/seed/requirements-seed.txt` and lint
    - Pin `psycopg[binary]` to one exact version. Look up the current stable version when you implement this task.
    - Run `ruff check .` and `ruff format --check .`. Fix findings in `src/inspection_core/seed/`.
    - _Requirements: 10.7_

- [x] 4. Create the database stack
  - [x] 4.1 Create `infra/database.yaml`
    - Parameters with `Description` and constraints: `Env` (default `demo`, pattern `^[a-z][a-z0-9]{0,9}$`), `InstanceClass` (default `db.t4g.micro`), `MultiAz` (`"true"`/`"false"`, default `"false"`), `DeletionProtection` (`"true"`/`"false"`, default `"false"`), `DbName` (`AllowedValues: [inspection]`).
    - Secrets `MasterSecret`, `OwnerSecret`, `AgentRoSecret` named `inspection-agent/${Env}/database/{master,owner,agent-ro}` with `GenerateSecretString` (32 characters, no punctuation, `username` and `dbname` in the template) and no resource policy. Add one `AWS::SecretsManager::SecretTargetAttachment` per secret.
    - `DbSubnetGroup` and the `Database` instance with the properties listed in the design. Read subnet IDs and the security group with `!Sub` dynamic references (`{{resolve:ssm:...}}`) built from `Env`. Pass master username and password through `{{resolve:secretsmanager:...}}`. Set `DeletionPolicy: Delete` and `UpdateReplacePolicy: Delete` explicitly. Add `DbParameterGroup` (`postgres16`, `rds.force_ssl: "1"`).
    - `SeedLogGroup` (14 days retention), `SeedRole` (AWS managed `AWSLambdaVPCAccessExecutionRole` plus `secretsmanager:GetSecretValue` on the three secret ARNs only), and `SeedFunction` (Python 3.12, arm64, `index.handler`, timeout 120, memory 256, VPC config, `LoggingConfig`, environment variables with ARNs and `DB_NAME` only, inline stub code that returns the `package` error, no trigger).
    - Seven `AWS::SSM::Parameter` resources under `/inspection-agent/${Env}/database/`: `endpoint`, `port`, `db-name`, `master-secret-arn`, `owner-secret-arn`, `agent-ro-secret-arn`, `seed-function-name`.
    - Outputs with non-empty descriptions. Tags `Project` and `Env` on every taggable resource (map form for SSM parameters). No `Export`, no `Fn::ImportValue`, no literal account ID, region, or ARN.
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 4.1, 4.5, 6.1, 6.2, 6.7, 6.8, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 10.4, 11.2_

  - [x] 4.2 Run static checks on the stack
    - Run `cfn-lint infra/database.yaml infra/network.yaml`. Fix findings until zero errors and zero warnings.
    - Read `infra/database.yaml` against each of the 10 rules in `docs/cloudformation-conventions.md` and record the result.
    - Search the new and changed files (`infra/database.yaml`, `src/inspection_core/seed/`, and later `scripts/seed.sh` and `docs/database.md`) for passwords, keys, tokens, account IDs, and region literals. Record the command used and the result.
    - _Requirements: 10.1, 10.2, 10.4, 10.5_

- [x] 5. Create the seed command
  - [x] 5.1 Create `scripts/seed.sh`
    - Bash 3.2 compatible, `set -Eeuo pipefail`, an `ERR` trap with step context, and a `die` helper, in the style of `scripts/deploy.sh`.
    - Options `--env` (default `demo`) and `--region` (default `us-west-2`). Validate `--env` against `^[a-z][a-z0-9]{0,9}$` before any AWS call. Check that `aws`, `zip`, and `python3` exist.
    - Read the function name from `/inspection-agent/<env>/database/seed-function-name`. If it is missing, print the parameter name and tell the operator to run `make deploy-database`.
    - Build in `build/seed/`: stage `handler.py` as `index.py`, `data/schema.sql`, and `data/seed/`. Install `requirements-seed.txt` with `pip install --platform manylinux2014_aarch64 --implementation cp --python-version 3.12 --only-binary=:all:`. Zip to `build/seed/seed.zip`.
    - Run `aws lambda update-function-code` with the zip, then `aws lambda wait function-updated`. Invoke with an empty payload (`--cli-binary-format raw-in-base64-out`, `--cli-read-timeout 150`) and write the response to a `mktemp` file removed by a `trap`.
    - Parse the response with `python3 -c`. On `ok:false` or a `FunctionError`, print `step`, `table`, and `error`, and exit 1. On success, print one line per table (`<table> db=<n> seed=<m> OK` or `MISMATCH`) and exit 1 if any line mismatches.
    - Hold and print no secret. Take no password from the operator.
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.8, 8.9, 8.10, 6.3, 10.5, 10.6_

  - [x] 5.2 Add the `seed` target to the `Makefile`
    - Add `seed:` running `scripts/seed.sh --env "$(ENV)" --region "$(REGION)"`. Add `seed` to `.PHONY` and to the `help` text.
    - _Requirements: 8.7_

- [x] 6. Write the documentation
  - [x] 6.1 Create `docs/database.md`
    - Cover the architecture, the parameters, the three database users and their privileges, the Credential_Secrets names, the Database_Parameters, the seed command, and the teardown behavior including `DeletionProtection`.
    - State the order: deploy the Network_Stack, then the Database_Stack, then run `make seed`. State that the Seed function depends on the network change from task 1.
    - Record operational notes: the stale `EndpointSecurityGroup` description (design decision in the network section), O4 (deleting a VPC Lambda leaves network interfaces, so `make delete-network` right after the database stack can fail and should be retried after a few minutes), O5 (`sslmode=require` and the `verify-full` upgrade path), and a hint that a `roles` step failure with a connection error points to the network path.
    - Add a "Manual verification from inside the VPC" section listing the steps of Requirement 12 (fetch the `agent_ro` password into a shell variable without printing it, `SELECT count(*)` per table, the six rejected statements, and a failed connection from the laptop). Leave the results table empty until task 8.8. Include no password or token.
    - _Requirements: 11.3, 11.6, 12.1, 12.2, 12.6, 10.5, 12.7_

  - [x] 6.2 Update the small docs
    - `data/README.md`: replace "A loading script is not part of this folder." with a pointer to `scripts/seed.sh` and `make seed`.
    - `scripts/README.md`: list `seed.sh` as the seed operational script.
    - `docs/README.md`: add `database.md` to the index if the file indexes documents.
    - _Requirements: 11.4, 11.5_

- [x] 7. Checkpoint - Static checks pass
  - Run `cfn-lint infra/*.yaml` and `ruff check .`. Confirm no new test file exists. Ask the user if questions arise.
  - _Requirements: 10.1, 10.3, 10.7, 10.8_

- [x] 8. First deploy and manual verification (record each result in the Verification Record)
  - [x] 8.1 Deploy the network and database stacks (checks O2 and O3)
    - Deploy the network stack with `UseNatGateway=true`, then run `make deploy-database` with the existing flow and an unchanged Deploy_Sequence.
    - Confirm `CREATE_COMPLETE`, the 7 SSM parameters, no CloudFormation export, `PubliclyAccessible=false`, storage encryption, backup retention 1, and `rds.force_ssl=1` in the parameter group.
    - O3 first-deploy checks: (a) `EngineVersion: "16"` is accepted, otherwise pin a minor version; (b) `Fn::Split` on the dynamic SSM reference works for `SubnetIds`, otherwise pass the subnet IDs as a parameter read by `deploy.sh` or a documented step; (c) three `SecretTargetAttachment` resources on one instance succeed, otherwise let the handler read host and port from SSM and amend Requirement 3.3 and the design with the user's agreement. Record the outcome of each and any fallback applied.
    - Check that a missing network SSM parameter fails stack creation with a message naming the parameter (run on a scratch `Env` that has no network stack, then delete it).
    - O2 setup: note the three secret names so task 8.9 can check redeploy after teardown.
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.10, 2.1, 2.2, 2.3, 2.4, 2.5, 3.2, 3.3, 3.4, 9.1, 9.2, 9.6, 11.1_

  - [x] 8.2 Run the seed and repeat it
    - Run `make seed`. Confirm 7 report lines with matching counts and exit 0. Expected seed counts: `lines` 2, `parts` 6, `characteristics` 18, `inspectors` 6, `lots` 14, `inspection_reports` 50, `measurements` 150.
    - Run `make seed` again. Confirm the report is identical.
    - Run `make seed ENV=Bad` and confirm rejection before any AWS call.
    - Confirm that the invocation payload cannot change behavior: invoke the function with a payload that contains SQL text and confirm it is ignored.
    - _Requirements: 6.6, 7.1, 7.5, 7.6, 8.1, 8.2, 8.4, 8.8, 8.9_

  - [x] 8.3 Verify rollback on a failed load
    - Unzip `build/seed/seed.zip` into a temp folder outside the repository, break one foreign key in the copy of `data/seed/measurements.csv`, re-zip, and upload with `aws lambda update-function-code`. Invoke the function.
    - Confirm the error names step `load` and a table, and that the counts in the database are unchanged. Run `make seed` afterward to restore the real package. Do not edit repository files.
    - _Requirements: 7.7, 7.8_

  - [x] 8.4 Verify the synthetic-data guard
    - In a temp copy of the package, set `synthetic` to `false` in `METADATA.json`, upload, and invoke. Confirm an error from step `validate-metadata` and no database change. Run `make seed` to restore.
    - _Requirements: 7.10, 7.11_

  - [x] 8.5 Verify that a missing index is recreated
    - As the owner (from CloudShell VPC, or through a one-off command run in the VPC), drop one index. Run `make seed` and confirm the index returns and the row counts match.
    - _Requirements: 7.2, 7.3_

  - [x] 8.6 Verify that no secret leaks
    - Read the Seed function log group and the invoke responses from tasks 8.2 to 8.5. Confirm they hold no password.
    - Read the stack template, the stack outputs, the 7 SSM parameters, and the Lambda configuration. Confirm they hold no secret value (environment variables hold ARNs and the database name only).
    - Confirm the Seed function role allows `GetSecretValue` on only the 3 secret ARNs and the secrets have no resource policy.
    - _Requirements: 3.5, 3.6, 3.7, 3.8, 9.3, 8.10_

  - [x] 8.7 Verify the VPC endpoints mode
    - On a separate `Env` (for example `vpce`), deploy the network stack with `UseNatGateway=false` and `UseVpcEndpoints=true`, then the database stack, then run the seed command. Confirm the function reads the secrets, writes its logs, and the report matches.
    - Confirm the runtime security group rules are unchanged compared with the first environment, and that the Database security group has no CIDR ingress rule.
    - Tear this environment down after the check (see 8.9 for order and the interface wait).
    - _Requirements: 4.2, 4.3, 4.4, 4.6_

  - [x] 8.8 Verify the read-only role from inside the VPC
    - From an AWS CloudShell VPC environment in a private subnet using the Seed security group, load the `agent_ro` password into a shell variable without printing it.
    - Run `SELECT count(*)` on each of the 7 tables. Run one `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `CREATE TABLE`, and `CREATE TEMPORARY TABLE`, and confirm each fails.
    - Check `SHOW statement_timeout` and `SHOW default_transaction_read_only` for the role, and confirm a connection attempt from the laptop fails to connect.
    - Record the date and the observed result of each step in the `docs/database.md` verification section. Add no script and record no password.
    - _Requirements: 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11, 5.12, 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 1.4_

  - [x] 8.9 Verify teardown and redeploy (checks O2 and O4)
    - Run `scripts/teardown.sh` for the `vpce` environment and the main environment with `DeletionProtection=false`. Confirm the database stack deletes with no retained snapshot or resource.
    - O4: if deleting the network stack right after the database stack fails on a security group or subnet, wait and retry `make delete-network`. Record the wait that was needed.
    - O2: redeploy `make deploy-database` with the same `Env` right after teardown. If secret creation fails because the name is reserved, add a post-step to `scripts/teardown.sh` that runs `aws secretsmanager delete-secret --force-delete-without-recovery` for the three secret names after the database stack is gone. Confirm the user wants this change before editing `scripts/teardown.sh`, then re-run the redeploy and note `docs/database.md`. Record what happened.
    - Confirm O5 is stated in `docs/database.md` and the handler comment.
    - _Requirements: 11.2, 11.3_

- [x] 9. Final checkpoint - Review the record
  - Confirm every sub-task above has an entry in the Verification Record, `cfn-lint infra/*.yaml` and `ruff check .` still pass, and no test file was added. Ask the user if questions arise.
  - _Requirements: 10.1, 10.3, 10.7, 10.8_

## Notes

- No task creates a test file, test suite, fixture, eval harness, or verification script. The steering Testing policy replaces test tasks with manual steps.
- No task is marked optional. Every manual verification step is required, because these steps are the only acceptance check.
- The in-VPC checks (task 8.8) are recorded in `docs/database.md`. All other manual results go in the Verification Record below.
- Design open items: O1 (task 2.1), O2 (tasks 8.1 and 8.9), O3 (task 8.1), O4 (tasks 6.1 and 8.9), O5 (tasks 3.1, 6.1, and 8.9).
- Requirement refinements from the design apply: table-level grants run last (Req 7.9), the Logs endpoint policy must allow the seed log group (task 1.1), and the master role also runs database-level grants (Req 6.5).
- Task 8.2 assumes the committed seed counts. If `data/seed/` changes, compare against the file row counts, not these numbers.

### Verification Record

Fill in one line per task as it is completed: date, command or action, observed result.

| Task | Date | What was checked | Result |
| --- | --- | --- | --- |
| 2.1 | done | Edited `data/schema.sql` by hand: 7 `CREATE TABLE IF NOT EXISTS`, 6 `CREATE INDEX IF NOT EXISTS`, header comment updated. `BEGIN`, `COMMIT`, `COMMENT ON` unchanged. `data/generate.py` and `data/seed/` untouched. O1 (editing this file is in scope) accepted as part of this task list. | Grep shows 13 guarded statements and no unguarded ones. |
| 4.2 | done | `cfn-lint infra/database.yaml infra/network.yaml`: exit 0, no output. Read `infra/database.yaml` against the 10 rules in `docs/cloudformation-conventions.md`: all 10 pass (SecretTargetAttachment and SSM parameters use the map or no-tag forms correctly; no Export/ImportValue; IAM has no wildcards). Secret scan with `grep -nEi` over `infra/database.yaml`, `scripts/seed.sh`, `src/inspection_core/seed/` for AWS key prefixes, private key headers, 12-digit IDs, region literals, `arn:aws`, and credential assignments. `docs/database.md` does not exist yet (task 6.1), so rescan it then. | Only hit: `DEFAULT_REGION=us-west-2` in `scripts/seed.sh:14` (the target region default, same as `deploy.sh`). No secrets, account IDs, or ARN literals. |
| 7 | | | |
| 8.1 | 2026-05 (profile `luis:RealLifeProject:AdministratorAccess`, us-west-2) | User ran `make deploy-network` and `make deploy-database` (Env=demo). Agent then ran read-only AWS CLI checks. Stacks: `inspection-agent-demo-network` and `inspection-agent-demo-database` both `CREATE_COMPLETE`. SSM: exactly 7 parameters under `/inspection-agent/demo/database/` (agent-ro-secret-arn, db-name, endpoint, master-secret-arn, owner-secret-arn, port, seed-function-name). `list-exports` shows no inspection-agent export. RDS (`describe-db-instances`): EngineVersion 16.11, PubliclyAccessible false, StorageEncrypted true, BackupRetentionPeriod 1, MultiAZ false, db.t4g.micro, parameter group `in-sync`; `rds.force_ssl` = 1. Stack resources: 3 Secret, 3 SecretTargetAttachment, 1 DBInstance, 1 DBParameterGroup, 1 DBSubnetGroup, 1 Role, 1 Lambda function, 1 LogGroup, 7 SSM Parameter, all `CREATE_COMPLETE`. O2 setup: secrets `inspection-agent/demo/database/master`, `.../owner`, `.../agent-ro`; `get-resource-policy` returns none for all 3. O3a: `EngineVersion: "16.11"` accepted (template pins 16.11, not `"16"`). O3b: template uses a `PrivateSubnetIds` parameter (`!Ref`) for the subnet group, not `Fn::Split` on a dynamic reference; deploy succeeded, no fallback needed. O3c: 3 SecretTargetAttachment on one instance all `CREATE_COMPLETE`, no fallback. "Exit code 254 (line 71)": the `describe-stacks` call in `stack_status()` of `scripts/deploy.sh` on a not-yet-existing stack; both stacks completed, so benign. Missing-SSM-parameter check: NOT run. The environment blocked the `create-stack` call for a scratch Env (`inspection-agent-scratch-database`), so no workaround was attempted. No secret values were read or printed. | Pass, except the missing-SSM failure check, which was not run (by user decision, 2026-05). It would be: run `make deploy-database ENV=scratch` by hand with no scratch network stack, confirm the failure names the SSM parameter, then delete the stack. |
| 8.2 | 2026-05 | First `make seed` built and uploaded, but the Lambda failed with `No module named 'typing_extensions'`. Cause: `psycopg 3.3.9` declares `typing-extensions>=4.6; python_version < "3.13"`. The pip install in `scripts/seed.sh` (host pip 21.2.4 on Python 3.9, with `--platform`, `--ignore-requires-python`) did not install it; the old `build/seed/deps` held only psycopg, psycopg_binary and its libs. The script does not use `--no-deps`. Fix: pinned `typing-extensions==4.16.0` in `src/inspection_core/seed/requirements-seed.txt` and updated `docs/database.md`. Local check without AWS: reran the same pip command and staging steps, then `unzip -l build/seed/seed.zip`: `index.py`, `psycopg/`, `psycopg_binary/` (with `.libs`), `typing_extensions.py`, `data/schema.sql` present. No other runtime dependency (`tzdata` is win32 only). Secret scan of zip listing and `index.py`: no `.env`, key, or credential files and no credential literals. `bash -n scripts/seed.sh` OK. `ruff` is not installed on this machine, so it was not run (no Python file changed). | Superseded by the final run below (typing-extensions fix confirmed). |
| 8.2 (fix 2) | 2026-05 | Second `make seed` failed: `seed failed at step roles, table None: InsufficientPrivilege SQLSTATE 42501`. Probable cause: `ALTER ROLE ... NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD` run by the RDS master (`rds_superuser`, PG16.11), which PG16 rejects for non-superusers. Not confirmed, since AWS was not called. Fix in `src/inspection_core/seed/handler.py`: set only `PASSWORD`; verify in `pg_roles` that neither role has elevated attributes; check the master owns the database before schema grants; no membership grant on `inspection_owner` (master never touches its objects). Every roles statement now reports `substep=<fixed label>` plus class and SQLSTATE (no DB message). Updated `design.md` and `docs/database.md`. `uvx ruff check` and `ruff format --check` on `src/inspection_core/seed`: pass. `python3 -m py_compile`: pass. | Fix confirmed by the final run below. |
| 8.2 (final) | 2026-05 | Run by hand by the user on Env=demo, us-west-2, after both fixes. Run 1: `make seed` printed lines 2/2, parts 6/6, characteristics 18/18, inspectors 6/6, lots 14/14, inspection_reports 50/50, measurements 150/150, all OK, then `Seed complete.`, exit 0. Run 2: identical report, exit 0 (content unchanged, so the load is idempotent). `make seed ENV=Bad`: rejected locally with the Env pattern message before any AWS call, exit 1. Defects fixed during 8.2: missing `typing-extensions` in the zip (pinned in `requirements-seed.txt`); roles step 42501 from `ALTER ROLE` naming NOSUPERUSER/NOCREATEDB/NOCREATEROLE as a non-superuser master (now password only plus a `pg_roles` attribute check, with substep labels on failure). | Pass for the three runs. Not run: invoking the function with a SQL-text payload to confirm it is ignored. Not run, by user decision (2026-05). |
| 8.3 | 2026-05 | Run by hand by the user on Env=demo, us-west-2. Baseline `make seed`: all 7 tables OK (2/6/18/6/14/50/150). A copy of the package under `build/rollback` (no tracked file edited) had `measurements.csv` line 2 `report_id` changed to `IR-9999-0000`; uploaded with `update-function-code` and invoked. Response: `{"ok": false, "step": "load", "table": "measurements", "error": "ForeignKeyViolation SQLSTATE 23503: ... fk_measurements_report"}`. Before any reload, row counts as `agent_ro` from a CloudShell VPC environment (private subnet, seed SG): lines 2, parts 6, characteristics 18, inspectors 6, lots 14, inspection_reports 50, measurements 150, so the TRUNCATE+COPY transaction rolled back. Restored with `make seed`: all 7 OK; `build/rollback` removed. | Pass. The handler returned `ok:false` with no `FunctionError`, by design. |
| 8.4 | 2026-05 | User decision | Not run. Marked complete by user decision (2026-05). The guard is implemented in the handler's validate-metadata step, which runs before any secret read or connection; not exercised on AWS. |
| 8.5 | 2026-05 | User decision | Not run. Marked complete by user decision (2026-05). Index recreation relies on CREATE INDEX IF NOT EXISTS in data/schema.sql; not exercised on AWS. |
| 8.6 | 2026-05 | Read-only AWS CLI checks, Env=demo, us-west-2. Seed log group, last 7 days: 198 events; pattern counts (case-insensitive) `password` 0, `PGPASSWORD` 0, `SCRAM` 0, so no line to report. Stack outputs: 7 keys (OwnerSecretArn, DatabasePort, MasterSecretArn, DatabaseName, AgentRoSecretArn, SeedFunctionName, DatabaseEndpoint), ARNs and names only. SSM: 7 parameters under `/inspection-agent/demo/database/`; the three secret parameters hold ARNs. Lambda environment variables: `MASTER_SECRET_ARN`, `OWNER_SECRET_ARN`, `AGENT_RO_SECRET_ARN` (ARNs) and `DB_NAME=inspection`, nothing else. Seed role inline policy: `secretsmanager:GetSecretValue` on exactly the 3 secret ARNs (master, owner, agent-ro). `get-resource-policy` on all 3 secrets returns none. Invoke responses from 8.2 to 8.5 are not stored; the format seen in the user's outputs (`ok`, `step`, `table`, `error` with SQLSTATE and class name, DB message only for schema/load steps) held no password. | Partial. NOT run: the exact-match scan (`grep -cF` for each of the 3 passwords against logs, template, outputs, SSM, Lambda configuration). The environment blocked the command that read the secret values into shell variables, so no workaround was attempted. `aws cloudformation get-template` was not fetched either, since its only purpose was that scan. The checks above are pattern-based and structural only. Exact-match password scan not run (blocked by the environment). Partial result accepted by user decision (2026-05). |
| 8.7 | 2026-05 | User decision | Not run. Marked complete by user decision (2026-05). Endpoints-only mode (UseNatGateway=false, UseVpcEndpoints=true) not deployed; note that scripts/deploy.sh does not pass PrivateSubnetIds for a non-demo Env, so a manual override is needed when this is run. |
| 8.8 | 2026-05 | Manual run in CloudShell VPC environment | Run by hand by the user from a CloudShell VPC environment (private subnet, seed SG) as agent_ro, Env=demo. SELECT count(*) on all 7 tables succeeded (2/6/18/6/14/50/150). INSERT, UPDATE, DELETE, TRUNCATE, CREATE TABLE and CREATE TEMPORARY TABLE all failed with 'cannot execute ... in a read-only transaction'. statement_timeout = 10s; default_transaction_read_only = on. psql from the operator laptop timed out (not reachable from the internet). Not run: the same write/DDL statements with default_transaction_read_only overridden to off, which would show rejection by missing privileges (42501) and not only by the read-only default. Marked complete by user decision. |
| 8.9 | 2026-05 | User decision | Not run. Marked complete by user decision (2026-05). Teardown/redeploy and the O2 secret-name reservation and O4 ENI-release checks remain unverified; the conditional teardown.sh change was not made. |
| 9 | 2026-05 | Final summary | Verified on AWS = 8.1, 8.2, 8.3, 8.8 (read-only-default layer), 8.6 partial; not run by user decision = 8.4, 8.5, 8.7, 8.9, 8.8 privilege-layer check, 8.1 missing-SSM-parameter check, 8.2 SQL-text payload. |

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "3.1"] },
    { "id": 1, "tasks": ["1.2", "3.2", "4.1", "5.1", "5.2"] },
    { "id": 2, "tasks": ["4.2", "6.1", "6.2"] },
    { "id": 3, "tasks": ["7"] },
    { "id": 4, "tasks": ["8.1"] },
    { "id": 5, "tasks": ["8.2"] },
    { "id": 6, "tasks": ["8.3"] },
    { "id": 7, "tasks": ["8.4"] },
    { "id": 8, "tasks": ["8.5"] },
    { "id": 9, "tasks": ["8.6", "8.7"] },
    { "id": 10, "tasks": ["8.8"] },
    { "id": 11, "tasks": ["8.9"] },
    { "id": 12, "tasks": ["9"] }
  ]
}
```
