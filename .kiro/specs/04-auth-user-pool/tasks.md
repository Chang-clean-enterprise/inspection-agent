# Implementation Plan: Auth User Pool

## Overview

GitHub issue: #4

This plan builds three deliverables: `infra/auth.yaml` (stack `inspection-agent-<env>-auth`), `scripts/create-demo-users.sh`, and `docs/auth.md`. The implementation languages are CloudFormation YAML, bash 3.2, and Markdown. This spec adds no Python code, so ruff has nothing new to check.

The project testing policy forbids test files, suites, fixtures, and eval harnesses. The design has no Correctness Properties section, so no property test tasks exist. Each verification task is a manual step that names an action and an observable pass result. The step IDs V1 to V16 come from the "Testing Strategy" table in `design.md`. The only automated quality checks are `cfn-lint` and `ruff`.

Rules for every task:

- Commands use placeholders for profile and region. Passwords come from the shell environment or a prompt. Tokens stay in shell variables.
- No password, token, or account ID is written to a file.
- Each verification task records what was checked and the result in the task notes (`docs/kiro-workflow.md`, section 7).
- A commit message or pull request for this work contains `#4`.

## Tasks

- [x] 1. Write `infra/auth.yaml`
  - [x] 1.1 Add template header, parameters, and conditions
    - Create `infra/auth.yaml` in YAML only, following `docs/cloudformation-conventions.md` and the layout of `infra/network.yaml`
    - Parameters `Env`, `CallbackUrl`, `LogoutUrl`, `JwtValidityMinutes`, `RefreshValidityDays`, each with a Description of 1 to 200 characters and a constraint, using the patterns and ranges in the design section "Template parameters". The URL pattern allows only `https://` with a DNS-label host (no `*`, `@`, whitespace, `#`, or `,`) and `http://localhost`
    - Conditions `CallbackIsDefault` and `LogoutIsDefault`, with a YAML comment above each that says to keep the literal in sync with the parameter default
    - Name no parameter with "Token", "Secret", or "Password"
    - _Requirements: 1.5, 1.6, 1.10, 2.4, 2.5, 6.1, 6.3, 6.11, 10.2, 10.4_

  - [x] 1.2 Add the user pool, app client, hosted UI domain, and groups
    - `UserPool` with the properties in the design table: email sign-in alias, case-insensitive, admin-only create, password policy (minimum 8, no required character classes, with a demo-setting comment above it), temporary password validity 1 day, `MfaConfiguration: "OFF"` with the demo-setting comment on the line directly above, one recovery mechanism `verified_email`, `DeletionProtection: INACTIVE`, tier `LITE`, tags `Project` and `Env` through `UserPoolTags`, no `Schema`, no `LambdaConfig`
    - `UserPoolClient` with no secret, only the `code` flow, scopes `openid`, `email`, `profile`, auth flows `ALLOW_USER_SRP_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH`, `PreventUserExistenceErrors: ENABLED`, callback and logout lists built with `!If` on the two conditions, token validity from the two parameters, and explicit token validity units (minutes, minutes, days)
    - `UserPoolDomain` with the `!Sub` and `AWS::StackId` prefix scheme from the design section "Hosted UI domain prefix" and `ManagedLoginVersion: 1`
    - `GroupLineA`, `GroupLineB`, `GroupSupervisors` with names `line-a`, `line-b`, `supervisors` and the three persona descriptions
    - Use no literal account ID, region name, or ARN string, no IAM resource, and no reference to the UI stack
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.7, 1.8, 2.1, 2.2, 2.3, 2.7, 2.8, 2.9, 2.10, 3.1, 3.2, 3.3, 3.4, 4.7, 6.1, 6.2, 6.3, 6.4, 6.5, 6.7, 6.8, 6.9, 6.10_

  - [x] 1.3 Add SSM parameters and outputs
    - Five `AWS::SSM::Parameter` resources of type `String` with Descriptions and the `Project` and `Env` tag map, named `/inspection-agent/${Env}/auth/` plus `user-pool-id`, `app-client-id`, `issuer-url`, `discovery-url`, `hosted-ui-domain`
    - Build `issuer-url` and `discovery-url` with `!Sub` from the pool ID and `${AWS::Region}`. Build `hosted-ui-domain` as `<prefix>.auth.<region>.amazoncognito.com` with no scheme and no trailing slash
    - Five outputs `UserPoolId`, `AppClientId`, `IssuerUrl`, `DiscoveryUrl`, `HostedUiDomain`, each `!GetAtt <Parameter>.Value` with a Description
    - Use no `Export` and no `Fn::ImportValue`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 7.10, 7.11_

  - [x] 1.4 Manual verification V1: lint and static template checks
    - Run `cfn-lint infra/auth.yaml` from the repository root. Pass: exit code 0 with zero errors and zero warnings
    - Search the file for `Export`, `ImportValue`, 12-digit numbers, region names, `arn:`, `Schema`, `LambdaConfig`. Pass: no match, and no parameter name contains "Token", "Secret", or "Password"
    - Record the cfn-lint version and result in the task notes. CI pins 1.60.1 and the local copy may differ, so note any version difference
    - _Requirements: 1.4, 1.5, 1.6, 1.7, 3.3, 3.4, 7.9, 10.2, 10.3, 10.4_

- [x] 2. Write `scripts/create-demo-users.sh`
  - [x] 2.1 Implement the demo users script
    - Start with the shebang, a comment header, and `set -Eeuo pipefail` before any other command
    - Parse `--env` (default `demo`, validated with the `Env` pattern) and `--region` (default `us-west-2`) in the style of `scripts/deploy.sh`. Reject unknown options. Fail when `aws` is not on `PATH`
    - Read `/inspection-agent/<env>/auth/user-pool-id` from SSM and exit non-zero naming the parameter when the read fails
    - Read the three passwords from `DEMO_PASSWORD_INSPECTOR_A`, `DEMO_PASSWORD_INSPECTOR_B`, `DEMO_PASSWORD_SUPERVISOR`, falling back to `read -r -s` when the variable is empty and standard input is a terminal. Exit non-zero naming the variable when no value is available. Finish all input checks and the `get-group` checks for the three groups before the first change to the pool
    - For each user (loop over `label:email:group:variable` records split with `IFS=:`, indirect expansion `${!var}`): `admin-get-user`, create with `--message-action SUPPRESS` and attributes `email`, `email_verified=true`, `name` only on `UserNotFoundException`, then `admin-set-user-password --permanent`, then `admin-add-user-to-group`
    - Create a private temporary directory at startup (`umask 077`, `mktemp -d` under `${TMPDIR:-/tmp}`, `trap 'rm -rf "$tmpdir"' EXIT`). Write the JSON with `printf` to a mode-600 file there, pass it with `--cli-input-json "file://$f"`, and `rm -f "$f"` right after the call, so the password is never a command-line argument (changed after the V4 failure on AWS CLI 2.31.22, which rejects `file:///dev/stdin`). Escape `\` and `"` with `sed`. Reject a password with a control character
    - Mask the password in captured CLI error text with `${out//"$pw"/***}` before printing. Print the masked Cognito message and exit non-zero on `InvalidPasswordException` and on any other CLI failure
    - Print only `ok <label>` per user. Print no password or token. Write nothing in the repository. Unset each password after its loop iteration
    - Use bash 3.2 constructs only: no associative arrays, no `mapfile`, no `readarray`, no `${var,,}`, no `${var^^}`
    - Make the file executable (`chmod +x`)
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11, 5.12, 5.13, 5.14, 5.15, 5.16, 5.17, 10.5, 10.6, 10.8_

  - [x] 2.2 Manual verification V14: script syntax and scope
    - Run `/bin/bash -n scripts/create-demo-users.sh`. Pass: exit code 0
    - Run `head -3 scripts/create-demo-users.sh`. Pass: `set -Eeuo pipefail` appears before the first command other than the shebang
    - Run `grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)' scripts/create-demo-users.sh` and `grep -n -- '--password' scripts/create-demo-users.sh`. Pass: both print nothing
    - Run `git status` and `git diff --stat`. Pass: the only new file under `scripts/` is `create-demo-users.sh` and no existing file there changed
    - _Requirements: 5.14, 10.5, 10.6_

- [x] 3. Write `docs/auth.md`
  - [x] 3.1 Write the document
    - Write all text in English with no password, token, or account ID. Use the ten sections listed in the design section "`docs/auth.md`", in that order
    - Personas table (label, email, group), and the statement that `cognito:groups` is the only authorization input and that email, username, and custom attributes are never used
    - Group-to-line table with exactly three rows: `line-a` reads line A, `line-b` reads line B, `supervisors` reads both
    - Demo users script usage with the three variable names, the prompt alternative, the "run after step 2, once per environment, no rerun at step 9" statement
    - Deploy order table (step 2 with localhost URLs, `ui` at step 8, `auth` update at step 9 with the two `/inspection-agent/<env>/ui/` parameters) and exactly five `/inspection-agent/<env>/auth/` parameter names with one sentence each
    - Numbered steps for a token through the hosted UI with PKCE (`openssl` verifier and challenge, `/oauth2/authorize`, `curl` to `/oauth2/token`, token kept in a shell variable), and the statement that PKCE is required because the client has no secret
    - Local group claim inspection (`cut`, `base64`, `jq` or a `python3 -c` one-liner) with the statement that tokens never go to a third-party service
    - Numbered steps for a scripted token with `pycognito` in a throwaway virtual environment outside the repository, password from `getpass` or an environment variable, never an argument. Note that the result of the `scripts/invoke` choice belongs to a later spec
    - Handling rules (no committed tokens, no tokens in issues, no password on a command line), the MFA-off demo statement, token lifetime defaults, and common failure causes (wrong client ID, expired token, missing `Authorization` header allowlist)
    - Leave a clearly marked placeholder line for the result of V7 (token claim for a user with no group), to be filled in by task 3.2
    - _Requirements: 2.11, 3.5, 3.6, 8.5, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10, 10.1_

  - [x] 3.2 Record the V7 result in `docs/auth.md`
    - Replace the placeholder line with the observed behavior from task 6.3 (claim absent or empty array) and state that the tool layer treats both as no access
    - Pass: `grep -n -i 'placeholder' docs/auth.md` prints nothing
    - _Requirements: 3.8, 4.2_

  - [x] 3.3 Manual verification V15: secrets scan and document review
    - Run `git grep -n -i -E 'password|secret|token|AKIA' -- infra/auth.yaml scripts/create-demo-users.sh docs/auth.md` and read each hit. Pass: every hit is a variable name, a description, or a placeholder, and none is a value
    - Read `docs/auth.md` against Requirement 9, item by item. Pass: three persona entries, a group table with exactly three rows, the three variable names, exactly five SSM names, numbered browser and script token steps, the PKCE statement, the MFA statement, and the deploy order are all present
    - Confirm the spec task list holds no task that creates a test file, suite, fixture, or harness
    - _Requirements: 2.11, 3.5, 3.6, 8.5, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10, 10.1, 10.7_

- [x] 4. Checkpoint: static checks pass
  - Run `cfn-lint infra/auth.yaml` and `ruff check .`. Pass: both exit 0
  - Ask the user if questions arise before deploying

- [x] 5. Deploy and inspect the stack
  - [x] 5.1 Manual verification V2: deploy and inspect
    - Run `make deploy-auth`, then `aws cloudformation describe-stacks`, `aws cognito-idp describe-user-pool`, `describe-user-pool-client`, `describe-user-pool-domain`, `list-groups`, and `aws ssm get-parameters-by-path --path /inspection-agent/demo/auth/ --recursive` with `--region us-west-2`
    - Pass: stack `CREATE_COMPLETE`. Pool has `UsernameAttributes=[email]`, `MfaConfiguration=OFF`, admin-create-only, password minimum 8, no character classes, temporary password validity 1, one recovery mechanism `verified_email`, no `LambdaConfig` entries, no `custom:` attribute, tier `LITE`, and the tags `Project` and `Env`
    - Pass: client has no secret, flows `[code]`, scopes `[openid,email,profile]`, auth flows `[ALLOW_USER_SRP_AUTH, ALLOW_REFRESH_TOKEN_AUTH]`, `PreventUserExistenceErrors=ENABLED`, validity 60/60/1 with units minutes/minutes/days, exactly one callback URL and one logout URL, each starting with `http://localhost`
    - Pass: one domain `inspection-agent-demo-<8 hex>` with version 1, exactly three groups with descriptions of 1 to 200 characters, exactly five SSM parameters of type `String` each with the `Project` and `Env` tags, five stack outputs with descriptions, each SSM value equal to the output of the same name, `hosted-ui-domain` with no scheme and no trailing slash
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.9, 2.10, 3.1, 3.2, 3.3, 3.4, 6.1, 6.2, 6.3, 6.4, 6.5, 6.7, 6.8, 6.9, 6.10, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.8, 7.10, 8.1_

  - [x] 5.2 Manual verification V9: parameter validation rejects bad values
    - Run `aws cloudformation deploy` directly against the existing stack, once for each of `Env=Demo`, `CallbackUrl=ftp://x.example.com`, `CallbackUrl=http://localhost.example.com`, `LogoutUrl=http://example.com/`, `CallbackUrl=https://*.example.com/callback`, a `CallbackUrl` of 1025 characters, `JwtValidityMinutes=30`, `JwtValidityMinutes=1441`, `RefreshValidityDays=0`
    - Pass: each call fails at change set creation with a parameter validation error naming the parameter, `describe-stacks` shows the stack status and parameters unchanged, and `describe-user-pool-client` shows unchanged URLs
    - _Requirements: 1.10, 2.5, 2.6, 6.11_

- [x] 6. Verify demo users, tokens, and sign-up
  - [x] 6.1 Manual verification V3: script fails before changing the pool
    - Unset the three password variables and run `scripts/create-demo-users.sh </dev/null`, then `aws cognito-idp list-users`
    - Pass: exit code non-zero, the message names a password variable, and `list-users` shows zero users
    - Run `scripts/create-demo-users.sh --env nope1`. Pass: exit code non-zero and the message names `/inspection-agent/nope1/auth/user-pool-id`
    - _Requirements: 5.7, 5.12, 5.15_

  - [x] 6.2 Manual verification V4 and V5: create users, rerun, and policy failure
    - Export the three variables (read with `read -s`), run `scripts/create-demo-users.sh`, then `aws cognito-idp list-users` and `admin-list-groups-for-user` for each email
    - Pass (V4): exit code 0, exactly three users named by email, status `CONFIRMED`, `email_verified=true`, `name` equal to the label, each in exactly its one group, and no password in the script output. The call succeeds with the temporary-file input (`file://$f`) and no file remains in the temporary directory afterward (changed after the first V4 run failed with `file:///dev/stdin`)
    - Run the script a second time with the same inputs and repeat the queries. Pass (V5): exit 0 and the same three users, groups, and status
    - Run it once with a password that breaks the policy (for example 6 lowercase letters, which is below the 8-character minimum), then restore the correct value and rerun. Pass: the broken run exits non-zero with a policy failure message that does not contain the password text, and the restoring run exits 0
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.8, 5.9, 5.10, 5.11, 5.13, 5.14, 5.17, 10.8_

  - [x] 6.3 Manual verification V6, V7, V8: tokens, ungrouped user, and sign-up
    - V6: for each demo user, sign in with SRP from a Python session in a throwaway virtual environment outside the repository (`pycognito`, password from `getpass`) and decode both tokens locally. Pass: access token has `token_use=access`, `client_id` equal to the `app-client-id` parameter, `iss` equal to the `issuer-url` parameter, and `cognito:groups` equal to exactly the user's one group. ID token has `aud` equal to the client ID and the same group list. `exp - iat` equals 3600. An unknown email and a wrong password return the same error type and message. Nothing is written to a file
    - V7: create a temporary user with no group (`admin-create-user`, `admin-set-user-password --permanent`, password from the environment), sign in as in V6, decode the access token, then `admin-delete-user`. Pass: the access token has no `cognito:groups` claim or an empty array, the result is noted for task 3.2, and `list-users` shows three users again
    - V8: run `aws cognito-idp sign-up` with the app client ID, a new email, and a throwaway value from `openssl rand`. Pass: the call fails with `NotAuthorizedException` and `list-users` still shows three users
    - If `pycognito` cannot sign in with this client, record the failure and ask the user before changing requirement 2.9
    - _Requirements: 2.10, 3.7, 3.8, 4.1, 4.2, 6.1, 6.2, 6.5, 6.6, 9.6_

  - [x] 6.4 Manual verification V13: hosted UI sign-in with PKCE
    - Open `https://<hosted-ui-domain>/login?client_id=<id>&response_type=code&scope=openid+email+profile&redirect_uri=http://localhost:3000/callback`, then follow the PKCE steps in `docs/auth.md` as `inspector-a` and decode the access token locally
    - Pass: the page loads over HTTPS and has no sign-up link. After sign-in the browser redirects to the localhost URL with a `code`. The token exchange returns an access token with `cognito:groups` equal to `["line-a"]` and `client_id` equal to the app client ID
    - If a step in `docs/auth.md` does not work as written, fix the document and repeat
    - _Requirements: 2.2, 2.3, 6.5, 9.4, 9.5_

- [x] 7. Verify the update flow and failure paths
  - [x] 7.1 Manual verification V10 and V11: URL update, previous values, and rollback
    - V10: record the pool ID, client ID, and domain. Run `aws cloudformation deploy` with `CallbackUrl=https://d111111abcdef8.cloudfront.net/callback` and `LogoutUrl=https://d111111abcdef8.cloudfront.net/` (a placeholder host). Pass: stack `UPDATE_COMPLETE`, the three IDs unchanged, the client lists two callback URLs and two logout URLs, three users remain, and the change set shows no replacement
    - V11a: run `make deploy-auth` with no overrides. Pass: `UPDATE_COMPLETE` or no changes, and the client still lists the CloudFront URLs
    - V11b: start an update that changes the URLs (for example `LogoutUrl=https://d111111abcdef8.cloudfront.net/logout`) and, while the stack is `UPDATE_IN_PROGRESS`, run `aws cloudformation cancel-update-stack --stack-name inspection-agent-demo-auth`. Pass: the stack ends in `UPDATE_ROLLBACK_COMPLETE`, the client URLs equal the values before the update, three users remain, and the pool, client, and domain IDs are unchanged
    - _Requirements: 2.7, 8.2, 8.3, 8.4_

  - [x] 7.2 Manual verification V12: domain failure leaves no pool
    - Run `aws cloudformation deploy --stack-name inspection-agent-aws-auth --template-file infra/auth.yaml --parameter-overrides Env=aws`, then `describe-stack-events` and `aws cognito-idp list-user-pools`, then `make delete-auth ENV=aws`
    - Pass: the stack ends in `ROLLBACK_COMPLETE`, the events show `UserPoolDomain` as `CREATE_FAILED` with an InvalidRequest error (Cognito returns a generic message for the reserved word), no pool named `inspection-agent-aws` remains, and after the delete the stack is gone
    - _Requirements: 1.9_

- [x] 8. README touch-ups
  - [x] 8.1 Check `scripts/README.md` and change nothing unless required
    - Run `grep -n -i 'create' scripts/README.md`. Pass: the file already lists the create demo users script, so no edit is made. Requirement 10.5 allows a change to `scripts/README.md` only when it lists the script by file name. If it lists the script by a different name, change only that line to `create-demo-users.sh`
    - Make no change to the root `README.md`, `infra/README.md`, or the Makefile, since no requirement asks for one
    - Run `git diff --stat`. Pass: the changed files are limited to `infra/auth.yaml`, `scripts/create-demo-users.sh`, `docs/auth.md`, the files under `.kiro/specs/04-auth-user-pool/`, and at most `scripts/README.md`
    - _Requirements: 10.5_

- [x] 9. Teardown verification
  - [x] 9.1 Manual verification V16: delete the stack
    - Run `make delete-auth`, then `describe-stacks`, `describe-user-pool-domain` for the old prefix, `list-user-pools`, and `aws ssm get-parameters-by-path --path /inspection-agent/demo/auth/`
    - Pass: the stack is gone, the domain query returns no domain, no pool named `inspection-agent-demo` remains, and zero SSM parameters remain
    - To restore the environment afterward, rerun `make deploy-auth` and task 6.2
    - _Requirements: 1.8, 7.11_

- [x] 10. Final checkpoint: all manual checks recorded
  - Run `cfn-lint infra/auth.yaml` and `ruff check .`. Pass: both exit 0
  - Confirm that the task notes hold a result for each of V1 to V16
  - Ask the user if questions arise

## Notes

- No test file, test suite, fixture, or eval harness is created. Each verification task is a manual step with a named action and an observable pass result.
- The design has no Correctness Properties section, so no property test tasks exist.
- This spec adds no Python code. `ruff check .` runs only to confirm nothing else broke.
- Verification tasks 5 to 9 need AWS credentials for region `us-west-2`. They deploy and delete real resources. Cognito's free tier covers the cost.
- Out of scope, handled by later specs: the AgentCore Runtime authorizer (`allowedClients`, header allowlist), tool-layer group checks, the UI sign-in with the real CloudFront URL, and the token choice for `scripts/invoke`.
- Task 3.2 depends on the V7 result from task 6.3.

### Task notes: 2.2 (V14, script syntax and scope)

- `/bin/bash -n scripts/create-demo-users.sh`: exit code 0. Pass.
- `head -3`: shows the shebang and two comment lines. The header comment runs to line 17, and `set -Eeuo pipefail` is on line 17, the first non-comment line, before any command. Pass.
- `grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)'`: no output (grep exit 1). Pass.
- `grep -n -- '--password'`: no output (grep exit 1). Pass.
- `git status --short`: the only new file under `scripts/` is `create-demo-users.sh`. `git diff --stat` prints nothing, so no tracked file changed, including `scripts/deploy.sh`, `scripts/teardown.sh`, and `scripts/README.md`. Pass.
- The script was not run against AWS. No fix was needed.

### Task notes: 1.4 (V1, lint and static template checks)

- `cfn-lint infra/auth.yaml` from the repository root: local cfn-lint 1.46.0, exit code 0, no errors, no warnings. Pass. CI pins 1.60.1, so the local version is older than CI. Rerun with 1.60.1 if a CI difference appears.
- Case-insensitive search of `infra/auth.yaml` for `Export`, `ImportValue`, 12-digit numbers, region names (`us-`, `eu-`, `ap-` followed by a direction and digit), `arn:`, `Schema`, `LambdaConfig`: no match. Pass.
- No parameter name contains "Token", "Secret", or "Password". Pass.
- No template change was needed.

### Task notes: 5.1 (V2, deploy and inspect)

- The user ran `make deploy-auth` beforehand. This check ran only read-only AWS CLI calls in `us-west-2`. Nothing was deployed or changed.
- Stack `inspection-agent-demo-auth`: `CREATE_COMPLETE`. Parameters are the defaults (localhost callback and logout URLs, 60 minutes, 1 day, `Env=demo`). Pass.
- Pool: `UsernameAttributes=[email]`, `MfaConfiguration=OFF`, `AllowAdminCreateUserOnly=true`, password minimum 8 with no character classes required, `TemporaryPasswordValidityDays=1`, one recovery mechanism `verified_email`, `LambdaConfig` empty, no custom schema attribute, tier `LITE`, tags `Project=inspection-agent` and `Env=demo` (plus the `aws:cloudformation:*` tags). Pass.
- Client: no `ClientSecret` field, `AllowedOAuthFlows=[code]`, scopes `[email, openid, profile]`, auth flows `[ALLOW_REFRESH_TOKEN_AUTH, ALLOW_USER_SRP_AUTH]`, `PreventUserExistenceErrors=ENABLED`, validity 60/60/1 with units minutes/minutes/days, one callback URL (`http://localhost:3000/callback`) and one logout URL (`http://localhost:3000/`). Pass.
- Domain: `inspection-agent-demo-<8 hex>`, `ManagedLoginVersion=1`, status `ACTIVE`. Pass.
- Groups: `line-a`, `line-b`, `supervisors`, with descriptions of 66, 66, and 75 characters. Pass.
- SSM: five parameters of type `String` under `/inspection-agent/demo/auth/` (`user-pool-id`, `app-client-id`, `issuer-url`, `discovery-url`, `hosted-ui-domain`), each with tags `Project=inspection-agent` and `Env=demo`. Pass.
- Outputs: five (`UserPoolId`, `AppClientId`, `IssuerUrl`, `DiscoveryUrl`, `HostedUiDomain`), each with a description. Each SSM value equals the output of the same name. `hosted-ui-domain` is `<prefix>.auth.us-west-2.amazoncognito.com` with no scheme and no trailing slash. Pass.
- Account IDs and resource IDs are not recorded here.
- Command note: the shell is zsh, so an unquoted `$R="--region us-west-2"` variable is not word-split. Use `AWS_DEFAULT_REGION` or write the flag out.

### Task notes: 6.1 (V3, script fails before changing the pool)

- Ran in `us-west-2` with the three `DEMO_PASSWORD_*` variables unset and no password set at any point.
- `scripts/create-demo-users.sh </dev/null`: exit code 1. Message: `Missing password: set environment variable DEMO_PASSWORD_INSPECTOR_A (or run from a terminal to be prompted).` It names a password variable. Pass.
- `aws cognito-idp list-users` for the pool (ID read from SSM `/inspection-agent/demo/auth/user-pool-id`): zero users. Pass.
- `scripts/create-demo-users.sh --env nope1 </dev/null`: exit code 1. Message: `Cannot read SSM parameter /inspection-agent/nope1/auth/user-pool-id:` followed by the AWS `ParameterNotFound` error. It names the parameter. Pass.
- No script change was needed. Pool and account IDs are not recorded here.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "3.1"] },
    { "id": 1, "tasks": ["1.2", "2.2"] },
    { "id": 2, "tasks": ["1.3"] },
    { "id": 3, "tasks": ["1.4"] },
    { "id": 4, "tasks": ["4"] },
    { "id": 5, "tasks": ["5.1"] },
    { "id": 6, "tasks": ["5.2", "6.1"] },
    { "id": 7, "tasks": ["6.2"] },
    { "id": 8, "tasks": ["6.3"] },
    { "id": 9, "tasks": ["3.2", "6.4"] },
    { "id": 10, "tasks": ["3.3", "7.1", "8.1"] },
    { "id": 11, "tasks": ["7.2"] },
    { "id": 12, "tasks": ["9.1"] },
    { "id": 13, "tasks": ["10"] }
  ]
}
```

### Task notes: 6.2 (V4 and V5, create users, rerun, and policy failure)

- Failure: on AWS CLI 2.31.22 (macOS, bash 3.2), `--cli-input-json file:///dev/stdin` with piped JSON failed with "Error parsing parameter 'cli-input-json': Invalid JSON received." Process substitution `file://<(...)` failed the same way. A regular file path works.
- Cause: the CLI does not read the JSON from a pipe or device path in this version, so the stdin design from task 2.1 cannot work here.
- Fix (chosen by the user): `scripts/create-demo-users.sh` creates a private temporary directory (`umask 077`, `mktemp -d` under `${TMPDIR:-/tmp}`, `trap ... EXIT`), writes each user's JSON with `printf` to a mode-600 file, passes `file://$f`, and deletes the file right after the call. Requirements 5.13, 5.14, and 10.8, design.md, and task 2.1 were amended to match. No other call in the script used `file:///dev/stdin`. `docs/auth.md` has no `/dev/stdin` use for the script.
- Checks done after the fix: `/bin/bash -n` passes. The V14 greps find no `declare -A`, `mapfile`, `readarray`, case conversion, or `--password`. `shellcheck` is not installed, so it was not run.
- Pending (superseded by the user-reported V4 and V5 results below; task 6.2 passed): the live V4 and V5 rerun is for the user to run, because the passwords come from their terminal. Task 6.2 stays in progress.
- First rerun after the fix: the script reached `admin-set-user-password` and Cognito returned `InvalidPasswordException` "Password not long enough". The script printed the masked Cognito message and exited 1, which matches the 5.8 behavior. The user then relaxed the password policy for the demo (minimum 8, no required character classes). `infra/auth.yaml`, Requirement 6.8, design.md, tasks 1.2 and 5.1, and `docs/auth.md` were updated. The user redeploys the stack and reruns V4 and V5.
- Results reported by the user (live steps run in their own terminal, passwords entered at prompts; nothing run by this agent):
  - Redeploy: the user redeployed the auth stack with the relaxed policy (MinimumLength 8, no character classes).
  - Policy failure (5.8): a 6-character password was rejected with `InvalidPasswordException` "Password not long enough". The script printed the Cognito message without the password and exited 1. The script stops at the first failure, so `inspector-a` existed with no group and the other two users did not exist yet.
  - V4: after rerunning with valid passwords, the script printed `ok inspector-a`, `ok inspector-b`, `ok supervisor` and exited 0. The user reported three CONFIRMED users with `email_verified` true, `name` equal to the label, and each in exactly its own group. The temp-file mechanism for `--cli-input-json` worked on AWS CLI 2.31.22.
  - V5: a second run with the same passwords printed the three `ok` lines, exited 0, and `list-users` returned 3.
- Result: 6.2 passes (user-reported). No test files were created.

### Task notes: 7.1 (V10 and V11, update flow and rollback)

- V10 passed (user-reported): the update to `https://d111111abcdef8.cloudfront.net/callback` and `https://d111111abcdef8.cloudfront.net/` reached `UPDATE_COMPLETE`. Pool, client, and domain IDs unchanged, two callback URLs and two logout URLs, three users.
- V11a passed (user-reported): plain `make deploy-auth` kept the CloudFront URLs.
- V11b failed its premise: deploying `CallbackUrl=https://*.example.com/callback` passed the AllowedPattern and Cognito accepted it. The stack reached `UPDATE_COMPLETE` (only `UserPoolClient` updated) and the client then listed `http://localhost:3000/callback` and `https://*.example.com/callback`. The design assumed Cognito rejects wildcards. A wildcard redirect URI is a security weakness.
- Fix (user approved): the `CallbackUrl` and `LogoutUrl` AllowedPattern in `infra/auth.yaml` now accepts only `https://` with a DNS-label host (letters, digits, hyphens, dots) and `http://localhost`. The path excludes whitespace, `#`, `,`, and `*`. Requirement 2.5, the design (parameter table, change note, V9, V11b, G8), tasks 1.1, 5.2, and 7.1, and `docs/auth.md` were updated. A local regex check accepted both defaults and both CloudFront URLs, and rejected `https://*.example.com/callback`, `ftp://x.example.com`, `http://localhost.example.com`, `http://example.com/`, `https://user@evil.com/`, and `https://a.com/#x`. `cfn-lint infra/auth.yaml` (local version) exit 0, no warnings.
- Redeploy (user-reported): the user redeployed with `CallbackUrl=https://d111111abcdef8.cloudfront.net/callback` and `LogoutUrl=https://d111111abcdef8.cloudfront.net/`, which removed the wildcard URL. The stack reached `UPDATE_COMPLETE`.
- New V11b passed (user-reported run, orchestrator read-only check): the user started an update changing `LogoutUrl` to `.../logout` and ran `cancel-update-stack` while the stack was `UPDATE_IN_PROGRESS`. The background deploy exited 255. Stack events went `UPDATE_IN_PROGRESS` -> `UPDATE_ROLLBACK_IN_PROGRESS` -> `UPDATE_ROLLBACK_COMPLETE`. The client URLs equalled the pre-update values (localhost and the CloudFront callback; localhost and the CloudFront root logout URL; no `/logout`). `list-users` showed 3 users.
- V10, V11a, V11b pass.
- Result: 7.1 passes. No test files were created.

### Task notes: 5.2 (V9, invalid parameters rejected)

- The tool layer blocked sub-agent deploys, so the user ran V9 in their own terminal. No AWS command was run by the agent.
- User-reported: all eight original bad values failed at change set creation, and the stack status and client URLs stayed unchanged:
  - `Env=Demo`
  - `CallbackUrl=ftp://x.example.com`
  - `CallbackUrl=http://localhost.example.com`
  - `LogoutUrl=http://example.com/`
  - a 1025-character `CallbackUrl`
  - `JwtValidityMinutes=30`
  - `JwtValidityMinutes=1441`
  - `RefreshValidityDays=0`
- The wildcard value `https://*.example.com/callback` was added after the V11b finding. The user ran it against the tightened pattern. `CreateChangeSet` failed with `ValidationError` "Parameter 'CallbackUrl' must match pattern ...", exit code 254.
- Result: pass (user-reported). No test files were created.

### Task notes: 6.3 (V6, V7, V8: tokens, ungrouped user, and sign-up)

- The user ran V6, V7, and V8 in their own zsh terminal and reported that all checks passed as listed in the task. No AWS command was run by the agent. The user used the pycognito SRP helper in `/tmp/auth-venv` (outside the repository). The password came from `getpass` and only claims were printed. Nothing was written into the repository.
- V6: pycognito SRP sign-in works with this app client, so requirement 2.9 needs no change. Access token: `token_use=access`, `client_id` equal to the app client ID, `iss` equal to the issuer URL, `cognito:groups` equal to the user's one group. ID token: `aud` equal to the client ID. Token lifetime (`exp - iat`) is 3600.
- V7: the temporary user with no group had no group entries in `cognito:groups`. The user did not report whether the claim was absent or an empty array, so the result is recorded as "absent or empty (exact form not recorded)". The tool layer treats both as no access. The user was deleted and the user count returned to 3.
  - Command differences: the user was created with the temp-file JSON variant of `--cli-input-json`, because `file:///dev/stdin` is not accepted by AWS CLI 2.31.22. The password prompt used zsh `read -rs "VAR?prompt"`, because zsh `read -p` means coprocess.
- V8: self-service sign-up was rejected with `NotAuthorizedException`, and the user count stayed 3.
- Result: 6.3 passes (user-reported). No test files were created.

### Task notes: 6.4 (V13, hosted UI sign-in with PKCE)

- The user ran V13 in their own zsh terminal. No AWS command was run by the agent.
- First attempt failed: the token endpoint returned no `access_token` (the script raised `KeyError`), because `VERIFIER` had been unset by an earlier run of the same block.
- Second attempt failed: in zsh, `read -p` means coprocess, not a prompt, so `CODE` stayed empty.
- Fix: a two-step flow.
  - Step 1 generates `VERIFIER` and `CHALLENGE` and prints the authorize URL.
  - Step 2 sets `CODE="PASTE_CODE_HERE"` by pasting the value, exchanges it at `/oauth2/token`, prints the endpoint error if there is no `access_token`, and otherwise prints only `cognito:groups` and `client_id`.
- Observed with the two-step flow (user-reported):
  - The hosted UI page loaded over HTTPS and showed no sign-up link.
  - After sign-in the browser redirected to the localhost callback URL with a `code`.
  - The access token had `cognito:groups` equal to `['line-a']` and `client_id` equal to the app client ID.
- `docs/auth.md` is updated to the two-step flow, and the task 3.2 steps use zsh-compatible `read` syntax.
- Result: pass (user-reported). No test files were created.

### Task notes: 3.3 (V15, secrets scan and document review)

- Files are untracked, so `grep -n -i -E 'password|secret|token|AKIA'` ran over `infra/auth.yaml`, `scripts/create-demo-users.sh`, and `docs/auth.md`, and each hit was read. No AWS command was run and no test file was created.
- `infra/auth.yaml` hits: the `PasswordPolicy` and `TemporaryPasswordValidityDays` property names, `GenerateSecret: false`, `ALLOW_REFRESH_TOKEN_AUTH`, the `AccessTokenValidity`, `IdTokenValidity`, `RefreshTokenValidity`, and `TokenValidityUnits` properties, comments, and descriptions. Pass: none is a value.
- `scripts/create-demo-users.sh` hits: comments, the three variable names `DEMO_PASSWORD_INSPECTOR_A`, `DEMO_PASSWORD_INSPECTOR_B`, `DEMO_PASSWORD_SUPERVISOR`, error messages, and the `printf` JSON template whose `Password` value is the shell variable `$esc`. Pass: none is a value.
- `docs/auth.md` hits: prose, the three variable names, `read` prompts, `PASTE_CODE_HERE` (a placeholder), `ACCESS_TOKEN` and `RESPONSE` shell variables, and the `getpass` prompt. Pass: none is a value.
- Other scans over `infra/auth.yaml`, `scripts/`, `docs/`, `README.md`, `Makefile`, and `.kiro/specs/04-auth-user-pool/`: no `AKIA`, no `eyJ`, no `us-west-2_` followed by a pool ID, no 12-digit number, and no 26-character client-ID-shaped string in the three deliverables. Pass.
- The string `qwerty` (the trial password typed in chat) appears in no file in the repository (searched everything outside `.git` and `.ruff_cache`). Pass.
- One real identifier was found and removed: the hosted UI domain prefix in the task notes for 5.1 is now `inspection-agent-demo-<8 hex>`. It granted no access, but the rest of the notes keep deployment IDs out. The host `d111111abcdef8.cloudfront.net` is a placeholder in the tasks and design.
- `docs/auth.md` against Requirement 9, all present:
  - 9.1: three personas in section 1 (`line-a`/`inspector-a`, `line-b`/`inspector-b`, `supervisors`/`supervisor`).
  - 9.2: section 2 group table with exactly three rows (`line-a` is line A only, `line-b` is line B only, `supervisors` is both).
  - 9.3: section 3 names the three variables and holds no password value.
  - 9.4: section 5 has the numbered browser steps (Step 1, Step 2) with the PKCE statement, which says PKCE is required because the client has no secret (Req 2.11).
  - 9.5: section 6 inspects claims locally with `jq` or `python3` and says never to use a third-party service.
  - 9.6: section 7 has four numbered script steps with `pycognito`, a password from `getpass` or an environment variable, and a note that `scripts/invoke` is decided in a later spec.
  - 9.7: section 8 says tokens are never committed or pasted into issues.
  - 9.8: section 4 lists exactly five SSM names with one sentence each.
  - 9.9: section 9 says MFA is off for the demo only and must be enabled for any non-demo use.
  - 9.10: all text is English.
  - Also present: the deploy order (steps 2, 8, 9) and the run-once statement for the script (8.5, 8.6), and the Group_Claim-only statement (3.6).
- No placeholder line remains (`grep -n -i placeholder docs/auth.md` prints nothing, checked in this task; `PASTE_CODE_HERE` is a user fill-in for the auth code). No defect was found, so `docs/auth.md` was not changed.
- Task list check: no task creates a test file, suite, fixture, or harness. The only matches for these words are the policy statements and the "No test files were created" notes. Pass.
- Result: 3.3 passes.

### Task notes: 7.2 (V12, domain failure leaves no pool)

- The user deployed `inspection-agent-aws-auth` with `Env=aws`. `aws cloudformation deploy` reported a failed create. No AWS command was run by the agent. The orchestrator made a read-only check of the events of the deleted stack.
- Events: the stack ended in `ROLLBACK_COMPLETE`. `UserPoolDomain` was `CREATE_FAILED` with "Invalid request provided: AWS::Cognito::UserPoolDomain" (HandlerErrorCode `InvalidRequest`). The other in-flight resources show "Resource creation cancelled". Pass.
- Wording difference: the Cognito message is generic. It is not an explicit reserved-word message as the pass criterion expected. The cause is the `aws` substring in the domain prefix. The 7.2 pass criterion was reworded to "an InvalidRequest error (Cognito returns a generic message for the reserved word)".
- No user pool whose name starts with `inspection-agent` remained after the failed create. `make delete-auth ENV=aws` deleted the stack.
- Result: pass, with the wording difference noted. No test files were created.

### Task notes: 8.1 (README touch-ups)

- `grep` for `create` in `scripts/README.md` found only line 12, "- create demo users". The file lists scripts by descriptive name and names no file, so no edit was needed (Requirement 10.5).
- The root `README.md`, `infra/README.md`, and the Makefile were not touched.
- `git status` showed only these untracked paths: `.kiro/specs/04-auth-user-pool/`, `docs/auth.md`, `infra/auth.yaml`, and `scripts/create-demo-users.sh`. `git diff --stat` printed nothing.
- Result: pass. No test files were created.

### Task notes: 9.1 (V16, delete the stack)

- The user ran `make delete-auth`. No AWS command was run by the agent.
- `make delete-auth` printed "Stack inspection-agent-demo-auth deleted."
- `describe-stacks` returned "Stack with id inspection-agent-demo-auth does not exist".
- The `describe-user-pool-domain` query and the `list-user-pools` query printed nothing. No pool whose name starts with `inspection-agent` remained, confirmed by a read-only `list-user-pools` run by the orchestrator.
- `aws ssm get-parameters-by-path --path /inspection-agent/demo/auth/` returned 0 parameters.
- Result: pass (user-reported). No test files were created.
- The environment was left deleted on purpose. A later spec that needs it recreates it with `make deploy-auth` (or step 2 of `deploy-all`), then runs `scripts/create-demo-users.sh`.

### Task notes: 10 (final checkpoint)

- `cfn-lint infra/auth.yaml` (local 1.46.0; CI pins 1.60.1): exit 0, no output. Pass.
- `uvx ruff check .` (ruff 0.17.6): "All checks passed!", exit 0. Pass.
- `/bin/bash -n scripts/create-demo-users.sh`: exit 0. Pass.
- Task notes hold a result for every verification step. None is missing:
  - V1 in 1.4, V2 in 5.1, V3 in 6.1, V4 and V5 in 6.2, V6, V7, V8 in 6.3, V9 in 5.2, V10 and V11 in 7.1, V12 in 7.2, V13 in 6.4, V14 in 2.2, V15 in 3.3, V16 in 9.1.
- Tidy: the "Pending" line in the 6.2 notes was marked superseded by the later recorded V4 and V5 pass. No history was deleted.
- Caveat: V7 recorded the claim as "absent or empty (exact form not recorded)" in the 6.3 notes.
- No AWS command was run and no test file was created.
