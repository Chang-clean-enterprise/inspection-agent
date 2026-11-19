# Implementation Plan: Repo Bootstrap

## Overview

GitHub issue: #1

This plan creates the repository skeleton from the design: area READMEs, `.gitignore` additions and lint configuration, the three Kiro steering files, the two convention documents, the deploy and teardown entry point (`scripts/deploy.sh`, `scripts/teardown.sh`, `Makefile`), the lint-only CI workflow, and the rewritten root README. Languages are Markdown, YAML, TOML, Bash (3.2-compatible), and GNU Make 3.81.

Project testing policy (`.kiro/steering/tech.md`): no automated tests. Every place a test task would appear is a manual verification step instead. Each one names the action to run by hand and the observable pass result. Record what was checked, and the result, as a sub-bullet under that task (the task notes).

No task creates AWS resources or runs a real deploy against AWS. The demo-question wording is not repeated here; it lives only in `.kiro/steering/product.md` (Requirement 2.10).

## Tasks

- [x] 1. Create the repository layout
  - [x] 1.1 Create the 8 area READMEs
    - Create `infra/README.md`, `src/inspection_core/README.md`, `src/inspection_agent/README.md`, `src/inspection_mcp/README.md`, `data/README.md`, `ui/README.md`, `scripts/README.md`, and `docs/README.md` with the content in design section 12
    - Each is English, at most 50 lines, with a one-line purpose, a "Contents" list, and a link to `.kiro/steering/structure.md`
    - `infra/README.md` lists the 8 Components and the rule `infra/<component>.yaml`, and links `docs/cloudformation-conventions.md`
    - `data/README.md` names `data/STORIES.md` and states that all data is synthetic
    - `scripts/README.md` lists the 10 Operational_Scripts
    - Keep all 8 folder names; no rename (Requirements 1.10 and 1.11 do not trigger)
    - Create no `.py` files and no other files under `infra/` or `data/`
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12_

  - [x] 1.2 Manual verification: layout (design Property 1)
    - Run `git add -N` on the new files, then `git ls-files '*/README.md' 'src/*/README.md'`. Pass: exactly the 8 area READMEs are listed, plus the root README.
    - Run `wc -l infra/README.md src/*/README.md data/README.md ui/README.md scripts/README.md docs/README.md`. Pass: every count is 50 or less.
    - Read each README against Requirements 1.3 to 1.9. Pass: every required statement and list is present.
    - Run `git ls-files '*.py' 'infra/*' 'data/*'`. Pass: only `infra/README.md` and `data/README.md` are listed.
    - Record what was checked and the results in the task notes.
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.12_
    - Task notes (verified by hand):
      - `git add -N` on infra, data, ui, scripts, docs, src, then `git ls-files '*/README.md' 'src/*/README.md'`: PASS. Lists exactly the 8 area READMEs (data, docs, infra, scripts, src/inspection_agent, src/inspection_core, src/inspection_mcp, ui). `git ls-files README.md` lists the root README (the `*/README.md` glob does not match a root file).
      - `wc -l`: PASS. infra 22, inspection_core 11, inspection_agent 10, inspection_mcp 9, data 14, ui 9, scripts 20, docs 10. All are 50 or less.
      - Read each README against Requirements 1.3 to 1.9: PASS. infra lists the 8 Components and states one template per Component; inspection_core states database access, authorization, and tool functions; inspection_agent states the Strands agent and AgentCore entrypoint; inspection_mcp states the MCP server and that a later spec adds it; data states schema, generator, seed files, and names `data/STORIES.md`; ui states static site; scripts states Operational_Scripts only and lists all 10.
      - `git ls-files '*.py' 'infra/*' 'data/*'`: PASS. Only `data/README.md` and `infra/README.md`.

- [x] 2. Add ignore rules and lint configuration
  - [x] 2.1 Append the inspection-agent block to `.gitignore`
    - Append the block from design section 11 at the end of the file (Node artifacts, `.env.*` with `!.env.example`, `packaged*.yaml`)
    - Leave every existing line unchanged; add lines only
    - Do not create `.env.example` in this spec
    - _Requirements: 10.2, 10.3, 10.4, 10.5, 10.8_

  - [x] 2.2 Create `ruff.toml` and `.cfnlintrc.yaml` at the repository root
    - `ruff.toml` with `target-version = "py312"`, `line-length = 100`, and `[lint] select = ["E", "F", "W", "I", "B", "UP"]` (design section 10)
    - `.cfnlintrc.yaml` with `regions: [us-west-2]`
    - Add no `pyproject.toml` and no other ruff configuration
    - _Requirements: 9.6, 5.7_

  - [x] 2.3 Manual verification: ignore rules and lint config (design Property 9)
    - Run `git check-ignore -v build/ dist/ x.egg-info/ __pycache__/ x.pyc .venv/ venv/ .pytest_cache/ .mypy_cache/ .ruff_cache/`. Pass: a matching rule is printed for every path.
    - Run `git check-ignore -v node_modules/ sub/node_modules/ npm-debug.log yarn-error.log`. Pass: a matching rule is printed for every path.
    - Run `git check-ignore -v package.json package-lock.json`. Pass: nothing is printed and the exit code is 1.
    - Run `git check-ignore -v .env .env.local .env.dev .env.prod sub/.env sub/.env.local .env.example`. Pass: every `.env` path matches an ignore rule, and `.env.example` matches only the `!.env.example` rule.
    - Run `git diff -- .gitignore`. Pass: only added (`+`) lines, no removed lines.
    - Run `ruff check .`. Pass: exit code 0 (no Python files yet).
    - Run `git ls-files --others --exclude-standard | grep -E 'ruff\.toml|pyproject\.toml'` and `git ls-files | grep -E 'ruff\.toml|pyproject\.toml'`. Pass: `ruff.toml` is the only match across both.
    - Record what was checked and the results in the task notes.
    - _Requirements: 9.6, 9.7, 10.2, 10.3, 10.5, 10.8_
    - Task notes (verified by hand):
      - `git check-ignore -v build/ dist/ x.egg-info/ __pycache__/ x.pyc .venv/ venv/ .pytest_cache/ .mypy_cache/ .ruff_cache/`: PASS. A rule printed for all 10 paths, exit 0.
      - `git check-ignore -v node_modules/ sub/node_modules/ npm-debug.log yarn-error.log`: PASS. Rules at `.gitignore` lines 227 to 229 matched all 4 paths, exit 0.
      - `git check-ignore -v package.json package-lock.json`: PASS. Nothing printed, exit 1.
      - `git check-ignore -v .env .env.local .env.dev .env.prod sub/.env sub/.env.local .env.example`: PASS. `.env` and `sub/.env` match `.env` (line 153). `.env.local`, `.env.dev`, `.env.prod`, and `sub/.env.local` match `.env.*` (line 232). `.env.example` matches only `!.env.example` (line 233).
      - `git diff -- .gitignore`: PASS. One hunk of 13 added lines (`+`), no removed lines.
      - `ruff check .`: PASS. `ruff` was not on PATH, so I ran `uvx ruff check .` (ruff 0.17.5). Output "All checks passed!", exit 0.
      - `git ls-files --others --exclude-standard | grep -E 'ruff\.toml|pyproject\.toml'` and `git ls-files | grep ...`: PASS. `ruff.toml` is the only match (untracked at check time). No `pyproject.toml` exists. `.cfnlintrc.yaml` is also present at the root.

- [x] 3. Write the Kiro steering files
  - [x] 3.1 Create `.kiro/steering/product.md`
    - Front matter `inclusion: always`
    - Sections in the order of design section 5: purpose first, the 3 Personas with their Cognito groups, the 5 Demo_Questions as a numbered list copied from Requirement 2.3, the statement that this file is the only source of the questions and that `data/STORIES.md` holds IDs and expected answers by question number, synthetic data, English only, and the non-negotiable rules
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.12_

  - [x] 3.2 Create `.kiro/steering/tech.md`
    - Front matter `inclusion: always`
    - Sections from design section 5: stack names exactly as in Requirement 3.1, region `us-west-2`, Python `3.12`, RDS for PostgreSQL as the only data store, IaC rules with a reference to `docs/cloudformation-conventions.md`, naming rules, the 5 security baseline statements (a) to (e), the 5 testing policy rules copied as written, and tooling (cfn-lint and ruff only, CI runs lint only)
    - No Secrets, and no statement naming DynamoDB, AWS CDK, Terraform, or JSON templates as used or allowed
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.9, 3.10, 3.11_

  - [x] 3.3 Create `.kiro/steering/structure.md`
    - Front matter `inclusion: always`
    - Sections from design section 5: one entry per Layout folder (8 entries) with a statement that no folder was renamed, the one-template-per-Component rule with the 8 file names, the Stack_Name and SSM_Key rules each with a filled-in example, the placeholder definitions (`<env>` referencing `docs/cloudformation-conventions.md`, `<component>`, `<NN>`, `<slug>`, `<key>`), the spec folder rule with an example and a reference to `docs/kiro-workflow.md`, the scripts/ rule listing all 10 Operational_Scripts, and the repository gotchas
    - _Requirements: 1.10, 1.11, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8_

  - [x] 3.4 Manual verification: steering files (design Properties 2 and 3)
    - Run `head -3 .kiro/steering/*.md`. Pass: each file shows `---`, `inclusion: always`, `---`.
    - Read each file against the outline in design section 5 and the criteria in Requirements 2, 3, and 4. Pass: every listed statement is present, and structure.md has exactly 8 folder entries and 8 template names.
    - For each of the 5 questions in `.kiro/steering/product.md`, run `grep -rin --exclude-dir=.git "<question wording>" .`. Pass: matches appear only in `.kiro/steering/product.md` and `.kiro/specs/01-repo-bootstrap/requirements.md`.
    - Run `grep -niE 'dynamodb|cdk|terraform|json' .kiro/steering/tech.md`. Pass: every match is a "not used" statement.
    - Record what was checked and the results in the task notes.
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 2.12, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.9, 3.10, 3.11, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8_
    - Task notes (verified by hand):
      - `head -3 .kiro/steering/*.md`: PASS. product.md, tech.md, and structure.md each show `---`, `inclusion: always`, `---`.
      - Read each file against design section 5 and Requirements 2, 3, 4: PASS. product.md has purpose first, 3 personas with groups, 5 numbered questions, the only-source statement with `data/STORIES.md`, synthetic data, English, and the 4 non-negotiable rules. tech.md has the 6 stack names, `us-west-2`, `3.12`, RDS as the only store, YAML-only IaC with the conventions path, naming, the 5 security statements, the 5 testing rules, and tooling. structure.md has exactly 8 Layout entries with the no-rename statement, 8 template names (`infra/network.yaml` to `infra/mcp.yaml`), Stack_Name and SSM_Key rules with examples, 5 placeholder definitions, the spec rule with example and `docs/kiro-workflow.md`, the 10 Operational_Scripts, and the gotchas.
      - Question wording search, `grep -rilF --exclude-dir=.git` for each of the 5 questions: PASS. Each matches only `.kiro/steering/product.md` and `.kiro/specs/01-repo-bootstrap/requirements.md`.
      - `grep -niE 'dynamodb|cdk|terraform|json' .kiro/steering/tech.md`: PASS. 3 matches, all "not used" statements (lines 23, 28, 29). No `json` match.

- [x] 4. Write the convention documents
  - [x] 4.1 Create `docs/cloudformation-conventions.md`
    - Rules 1 to 10 from design section 6, each separately numbered with a compliant YAML snippet
    - Rule 7 gives the command `cfn-lint infra/<component>.yaml` and notes that the region comes from `.cfnlintrc.yaml`
    - Rule 9 gives the Env parameter block with `Default: demo` and `AllowedPattern: ^[a-z][a-z0-9]{0,9}$`
    - Rule 10 shows an `AWS::SSM::Parameter` producer and an SSM consumer, and states that Export and `Fn::ImportValue` are not used
    - Snippets use placeholders and `!Sub` with pseudo parameters, never literal account IDs, regions, or `arn:` strings outside a `!Sub`
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11_

  - [x] 4.2 Create `docs/kiro-workflow.md`
    - Sections 1 to 8 from design section 7: issue-to-spec mapping, `<NN>` and `<slug>` definitions with the example `01-repo-bootstrap`, the `GitHub issue: #<issue-number>` line in design.md, commit and pull request rules with examples, the rule that task lists have no automated test tasks and use manual verification steps (action plus pass result, with an example), and a reference to `.kiro/steering/tech.md`
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9_

  - [x] 4.3 Manual verification: convention documents
    - Read `docs/cloudformation-conventions.md` one rule at a time against Requirements 5.1 to 5.10. Pass: 10 numbered rules, each with a YAML snippet that complies with its rule.
    - Run `grep -nE '[0-9]{12}|us-(east|west)-[0-9]|"?arn:' docs/cloudformation-conventions.md`. Pass: matches appear only inside `!Sub` expressions or in the `.cfnlintrc.yaml` snippet of rule 7.
    - Read `docs/kiro-workflow.md` from start to finish. Pass: a matching statement is found for each of Requirements 8.1 to 8.8.
    - Record what was checked and the results in the task notes.
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9_
    - Task notes (verified by hand):
      - Read `docs/cloudformation-conventions.md` one rule at a time against Requirements 5.1 to 5.10: PASS. It has 10 numbered rules in order (YAML only, parameters, outputs, tags, IAM least privilege, no literals, cfn-lint, stack names, Env parameter, SSM cross-stack), each with a YAML snippet that complies with its rule. Rule 7 gives `cfn-lint infra/<component>.yaml` and notes the region comes from `.cfnlintrc.yaml`. Rule 9 has `Default: demo` and `AllowedPattern: ^[a-z][a-z0-9]{0,9}$`. Rule 10 has an `AWS::SSM::Parameter` producer and an SSM parameter-type consumer, and states Export and `Fn::ImportValue` are not used. The Rule 5 wildcard Resource has a comment directly above its statement.
      - `grep -nE '[0-9]{12}|us-(east|west)-[0-9]|"?arn:' docs/cloudformation-conventions.md`: PASS. 3 matches: lines 70 and 83 are inside `!Sub` expressions (`arn:${AWS::Partition}:...`), and line 98 is `us-west-2` in the `.cfnlintrc.yaml` snippet of rule 7.
      - Read `docs/kiro-workflow.md` start to finish against Requirements 8.1 to 8.8: PASS. 8.1 section 1 (one issue to one spec folder, both directions); 8.2 section 2 (`<NN>` two digits, `01` to `99`); 8.3 section 3 (`<slug>` rules, example `01-repo-bootstrap`); 8.4 section 4 (`GitHub issue: #<issue-number>`); 8.5 section 5 (example `Add steering files and conventions docs (#1)`); 8.6 section 6 (title `Repo bootstrap (#1)`, description `Closes #1`); 8.7 section 7 (test tasks replaced by manual verification steps with action and pass result, with an example); 8.8 section 8 (`.kiro/steering/tech.md`). 8.9 holds, since each statement was found by reading alone.

- [x] 5. Checkpoint - Confirm manual verification results
  - Confirm that tasks 1.2, 2.3, 3.4, and 4.3 passed and are recorded in the task notes, ask the user if questions arise.

- [x] 6. Build the deploy and teardown entry point
  - [x] 6.1 Create `scripts/deploy.sh`
    - `#!/usr/bin/env bash`, `set -euo pipefail`, bash 3.2 compatible (no associative arrays, no `mapfile`, no `${var,,}`); mark executable
    - Commands `deploy-all`, `deploy <component>`, `delete <component>`; flags `--env` (default `demo`) and `--region` (default `us-west-2`)
    - Validation before any AWS CLI call, in design order: arguments (exit 2 with usage), Env_Rule, component name, template file (all 8 up front for `deploy-all`), `aws` on PATH; exact messages from design section 2
    - Helpers `stack_name`, `stack_status`, `deploy_stack`, `delete_stack`, `read_ssm`, `require_param`, `fail`, and an `ERR` trap that reports step and Stack_Name
    - `deploy_stack` uses the `aws cloudformation deploy` command from the design with `--no-fail-on-empty-changeset`, fails on `ROLLBACK_COMPLETE` before deploying, and checks for `CREATE_COMPLETE` or `UPDATE_COMPLETE` after
    - `deploy-all` runs the 10 Deploy_Sequence steps with `==> Step N/10: <Stack_Name>`, `"MemoryId="` at step 4, the SSM reads and `require_param` at steps 6 and 9, and both step 9 reads before the auth update
    - Every AWS CLI call passes `--region "$REGION"`; all values are double-quoted; no literal Secrets or account IDs
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.10, 6.11, 6.12, 6.13, 6.14, 6.15, 10.6_

  - [x] 6.2 Create `scripts/teardown.sh`
    - Same shell rules and flags as `scripts/deploy.sh`; mark executable
    - Validate Env, then loop over `mcp ui observability memory runtime database auth network`, print `==> Teardown: <Stack_Name>`, and call `scripts/deploy.sh --env "$ENV" --region "$REGION" delete <c>`
    - Stop on the first failure; absent stacks are skipped by `delete_stack`
    - _Requirements: 6.9, 6.10, 6.11, 6.12, 6.15_

  - [x] 6.3 Create the root `Makefile`
    - GNU Make 3.81 compatible; `ENV ?= demo`, `REGION ?= us-west-2`
    - Targets from design section 1: `help` (default), `deploy`, pattern rules `deploy-%` and `delete-%`, `teardown`, and `lint` (cfn-lint on templates under `infra/` if any, then `ruff check .`)
    - Targets pass `--env "$(ENV)" --region "$(REGION)"` and hold no other logic
    - _Requirements: 6.1, 6.3, 6.4, 6.9, 6.10, 6.12, 6.13_

  - [x] 6.4 Manual verification: entry point without AWS (design Properties 5 and 6)
    - Before running anything, run `ls infra/`. Pass: only `README.md` exists, so no command below can reach a real deploy. Do not run any `delete-<component>` or `teardown` target, because delete skips the template check and would call AWS.
    - Run `bash -n scripts/deploy.sh scripts/teardown.sh`, and `shellcheck scripts/*.sh` if installed. Pass: no output and exit code 0.
    - Run `/bin/bash scripts/deploy.sh --env Demo deploy network` on macOS. Pass: it runs under bash 3.2 and prints the Env_Rule message.
    - Run `make help`. Pass: lists all targets, `ENV` default `demo`, and `REGION` default `us-west-2`.
    - Run `make -n deploy`, `make -n deploy-network`, `make -n delete-network`, and `make -n teardown`. Pass: each prints one delegation to the expected script and command with `--env "demo" --region "us-west-2"`; `make -n deploy REGION=eu-west-1 ENV=dev1` shows the overrides.
    - With AWS credentials unset (`env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN`), run `make deploy ENV=Demo`, `make deploy ENV=1demo`, `make deploy ENV=demo-1`, `make deploy ENV=abcdefghijk`, and `make deploy ENV=`. Pass: each exits non-zero and prints the Env_Rule message, not an AWS error.
    - Run `make deploy-foo` and `make delete-foo`. Pass: each exits non-zero and prints the 8 valid Component names.
    - Run `make deploy-network` and `make deploy`. Pass: each exits non-zero with `Template not found: infra/network.yaml`, not an AWS error.
    - Read `deploy-all` in `scripts/deploy.sh`. Pass: steps 1 to 10 follow the Deploy_Sequence, each with its `==> Step N/10` line, `"MemoryId="` at step 4, and the SSM paths and `require_param` checks at steps 6 and 9. Read `scripts/teardown.sh`. Pass: the loop follows the Teardown_Sequence.
    - Run `git status --porcelain` after the runs above. Pass: no new untracked files.
    - Deferred: the no-change redeploy, delete of an absent stack, and the step 6 and step 9 parameter read-back with `aws cloudformation describe-stacks` (design Property 7, Requirements 6.2, 6.3, 6.6, 6.7) need real templates. Record in the task notes that these checks run in the first spec that adds templates under `infra/`.
    - Record what was checked and the results in the task notes.
    - _Requirements: 6.4, 6.5, 6.6, 6.7, 6.8, 6.9, 6.10, 6.11, 6.12, 6.13, 6.14, 6.15, 10.4_
    - Task notes (verified by hand, no AWS call made):
      - `ls infra/`: PASS. Only `README.md`, so no command could reach a real deploy. No `delete-<component>` or `teardown` target was run; they were checked with `make -n` only.
      - `bash -n scripts/deploy.sh scripts/teardown.sh`: PASS, no output, exit 0. `shellcheck` is not installed, so it was skipped. Both scripts are executable (`-rwxr-xr-x`).
      - `/bin/bash scripts/deploy.sh --env Demo deploy network` (GNU bash 3.2.57, macOS): PASS. Prints the Env_Rule message, exit 1.
      - `make help`: PASS. Lists `help`, `deploy`, `deploy-<component>`, `delete-<component>`, `teardown`, `lint`, the 8 components, `ENV` default `demo`, and `REGION` default `us-west-2`.
      - `make -n`: PASS. `deploy` prints `scripts/deploy.sh --env "demo" --region "us-west-2" deploy-all`. `deploy-network` prints the same prefix with `deploy "network"`. `delete-network` prints it with `delete "network"`. `teardown` prints `scripts/teardown.sh --env "demo" --region "us-west-2"`. `make -n deploy REGION=eu-west-1 ENV=dev1` prints `--env "dev1" --region "eu-west-1" deploy-all`. `make -n delete-foo` prints only the delegation line (not run for real).
      - With `env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN`, `make deploy ENV=` set to `Demo`, `1demo`, `demo-1`, `abcdefghijk`, and empty: PASS. Each exits non-zero (make exit 2) and prints `Invalid Env '<value>': ... (pattern ^[a-z][a-z0-9]{0,9}$).` No AWS error.
      - `make deploy-foo`: PASS. Exit non-zero, prints `Unknown component 'foo'. Valid components: network auth database runtime memory observability ui mcp`. `make delete-foo` was not run for real because delete targets are `make -n` only. In `scripts/deploy.sh` the component check applies to both `deploy` and `delete` and runs before the `aws` check, which is how Requirement 6.13 holds for delete.
      - `make deploy-network` and `make deploy`: PASS. Both exit non-zero with `Template not found: infra/network.yaml`, no AWS error.
      - Read `deploy_all` in `scripts/deploy.sh`: PASS. Steps 1 to 10 follow the Deploy_Sequence (network, auth, database, runtime, memory, runtime, observability, ui, auth, mcp). Each starts with the `step N <component>` helper, which prints `==> Step N/10: <Stack_Name>`. Step 4 passes `"MemoryId="`. Step 6 reads `/inspection-agent/$ENV/memory/memory-id`, deploys with `MemoryId=$id`, then `require_param runtime MemoryId`. Step 9 reads `/inspection-agent/$ENV/ui/callback-url` and `/logout-url` before the auth update, then runs `require_param` for `CallbackUrl` and `LogoutUrl`. `read_ssm` prints `Missing SSM parameter: <path>` and the `ERR` trap stops the run.
      - Read `scripts/teardown.sh`: PASS. The loop is `mcp ui observability memory runtime database auth network`, prints `==> Teardown: inspection-agent-<env>-<c>`, calls `deploy.sh delete <c>`, and exits 1 on the first failure.
      - `git status --porcelain` before and after the runs: PASS. Identical, no new untracked files.
      - Deferred: the no-change redeploy, delete of an absent stack, and the step 6 and step 9 parameter read-back with `aws cloudformation describe-stacks` (design Property 7, Requirements 6.2, 6.3, 6.6, 6.7) need real templates. These checks run in the first spec that adds templates under `infra/`.

- [x] 7. Add the lint-only CI workflow
  - [x] 7.1 Create `.github/workflows/lint.yml`
    - Use the workflow from design section 9: `pull_request` with `opened`, `reopened`, `synchronize` and no branch filter; `permissions: contents: read`; Python 3.12
    - Pin `cfn-lint` and `ruff` to their latest releases at implementation time
    - cfn-lint step uses `nullglob` and `globstar` over `infra/**/*.yaml`, `infra/**/*.yml`, `infra/**/*.json` and exits 0 with a message when no files match
    - ruff step runs `ruff check --output-format=github .`
    - No `secrets.*` references, no AWS credential steps, no test step
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.7, 9.8, 3.8_

  - [x] 7.2 Manual verification: CI workflow (design Properties 4 and 8)
    - Run `grep -nE 'secrets\.|aws-actions|AWS_' .github/workflows/lint.yml`. Pass: nothing is printed.
    - Read `.github/workflows/lint.yml`. Pass: the only quality-check steps are cfn-lint and ruff, and there is no `branches` filter.
    - Run the cfn-lint step's script locally with `bash -c` from the repository root. Pass: it prints the "No templates under infra/" message and exits 0.
    - Run `make lint`. Pass: exit code 0.
    - Record what was checked and the results in the task notes; the green run on the bootstrap pull request is checked in task 9.
    - _Requirements: 3.8, 9.1, 9.2, 9.3, 9.4, 9.5, 9.7_
    - Task notes (verified by hand, no AWS call made):
      - `grep -nE 'secrets\.|aws-actions|AWS_' .github/workflows/lint.yml`: PASS. Nothing printed, exit 1.
      - Read `.github/workflows/lint.yml`: PASS. Trigger is `pull_request` with `opened`, `reopened`, `synchronize` and no `branches` filter (`grep -n branches` prints nothing). `permissions: contents: read`. The only quality-check steps are `cfn-lint` and `ruff`. There is no test step and no credentials step. Tools are pinned to `cfn-lint==1.60.1` and `ruff==0.17.5`.
      - cfn-lint step script, local bash is GNU bash 3.2.57, which has no `globstar` (`shopt -s nullglob globstar` fails with "invalid shell option name"). No bash 4+ exists on the host (no Homebrew bash). I ran the exact step script under bash 5.3.20 in Docker (`docker run --rm -v "$PWD":/w -w /w bash:5 bash -c '<script>'`) from the repository root. PASS. It printed "No templates under infra/; nothing to lint." and exited 0. `infra/` holds only `README.md`. The script has no templates to pass to cfn-lint here, so cfn-lint itself was not run by that step. GitHub's `ubuntu-latest` ships bash 5, so the step is expected to behave the same on the runner.
      - `make lint`: PASS, exit 0. `ruff` and `cfn-lint` are not on the host PATH, so I installed the pinned versions into a temporary venv outside the repository (`/tmp/lintenv`, `ruff 0.17.5`, `cfn-lint 1.60.1`) and ran `PATH=/tmp/lintenv/bin:$PATH make lint`. Make skipped cfn-lint (no templates) and `ruff check .` printed "All checks passed!".
      - `git status --porcelain` after the runs: no files added by these checks (the Docker run mounted the repository read-write but wrote nothing).
      - Pending: the green lint workflow run on the bootstrap pull request (design Property 8, Requirements 9.1, 9.2, 9.5, 9.7). It needs a GitHub run and is checked in task 9.

- [x] 8. Rewrite the root README
  - [x] 8.1 Replace `README.md` with the Root_README
    - Sections in the order of design section 8: purpose (at most 5 sentences) first, the Mermaid architecture diagram from the design (7 required nodes, all connected, no parentheses inside square-bracket labels), demo links to [`.kiro/steering/product.md`] and [`data/STORIES.md`] as relative links with no question text, the synthetic data statement, prerequisites (AWS CLI v2 with credentials, Python 3.12, AWS account with us-west-2 access, Bedrock Claude model access in us-west-2, GNU Make and bash), inputs `ENV` and `REGION` with defaults, the 10 deploy steps with steps 4, 6, and 9 explained and a note that `make deploy` runs all 10, the 8 per-Component deploy and delete commands, the 8 teardown steps plus `make teardown`, layout with links to both convention docs, and license
    - Use only placeholders such as `<ACCOUNT_ID>` for account-specific values
    - _Requirements: 6.16, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 7.10, 7.11, 2.11_

  - [x] 8.2 Manual verification: root README
    - Read `README.md` against Requirements 6.16 and 7.1 to 7.11. Pass: purpose is the first section, prerequisites come before deploy steps, there are exactly 10 deploy steps and 8 teardown steps in the required order, and all 8 deploy and delete commands appear.
    - Open the README in a Markdown preview that renders Mermaid (local editor preview now, GitHub preview on the pull request). Pass: the diagram renders with no syntax error and shows all 7 required nodes connected.
    - For each question in `.kiro/steering/product.md`, repeat the `grep -rin --exclude-dir=.git` check from task 3.4. Pass: no match in `README.md`.
    - Run `grep -nE '[0-9]{12}|AKIA[0-9A-Z]{16}' README.md`. Pass: nothing is printed.
    - Record what was checked and the results in the task notes.
    - _Requirements: 2.10, 2.11, 6.16, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 7.10, 7.11_
    - Task notes (verified by hand):
      - Read `README.md` against Requirements 6.16 and 7.1 to 7.11: PASS. Section order is purpose (3 sentences, no heading before the Architecture section), Architecture, Demo, Prerequisites, Inputs, Deploy, Teardown, Repository layout, License. Prerequisites (line 27) come before Deploy (line 46). It has 4 required prerequisites plus GNU Make and bash. The Deploy list has exactly 10 numbered steps in Deploy_Sequence order, and the Teardown list has exactly 8 in Teardown_Sequence order (18 numbered items in total). Step 4 states the empty `MemoryId`, step 6 states `MemoryId` is the value produced by step 5, and step 9 states auth is updated with the callback and logout URLs produced by step 8. The per-component table lists all 8 deploy and 8 delete commands. Inputs `ENV` (`demo`) and `REGION` (`us-west-2`) are documented, and the AWS CLI with credentials is a prerequisite. The synthetic-data sentence is present. The Demo section links `.kiro/steering/product.md` and `data/STORIES.md` relatively and quotes no question.
      - Mermaid syntax check: PASS. I extracted the fenced `mermaid` block (11 lines) to `/tmp/mmd8/d.mmd`, outside the repository, and ran `npx -y @mermaid-js/mermaid-cli -i d.mmd -o d.svg`. It exited 0 and wrote an SVG with no parse error. The SVG contains a label for each of the 7 required nodes (UI, Amazon Cognito, AgentCore Runtime agent, Claude on Amazon Bedrock, AgentCore Memory, Amazon RDS for PostgreSQL, MCP server). Reading the source confirms each of those nodes has at least one edge, and no square-bracket label contains parentheses (the `[(...)]` form on `rds` is Mermaid cylinder syntax). The GitHub preview check remains for the pull request in task 9.
      - Question wording search (`grep -rilF --exclude-dir=.git`) for each of the 5 questions: PASS. Each matches only `.kiro/steering/product.md` and `.kiro/specs/01-repo-bootstrap/requirements.md`; `README.md` is not listed.
      - `grep -nE '[0-9]{12}|AKIA[0-9A-Z]{16}' README.md`: PASS. Nothing printed, exit 1. The only account placeholder is `<ACCOUNT_ID>`.
      - Cleanup: the temp directory is outside the repository, and `git status --porcelain` shows no new files from this check.

- [x] 9. Final checkpoint - Confirm repository-wide manual checks
  - Run `git ls-files --cached --others --exclude-standard | grep -E '(^|/)(tests?/|conftest\.py$|pytest\.ini$|test_[^/]*\.py$|[^/]*_test\.py$)'`. Pass: nothing is printed (design Property 4, Requirement 3.8).
  - Run `git ls-files --cached --others --exclude-standard '*.py' 'infra/*' 'data/*'`. Pass: only `infra/README.md` and `data/README.md` (Requirement 1.12).
  - Read the output of `git ls-files` and `git log -p --all`, and the diff of all new files. Pass: no account IDs, access keys, passwords, tokens, or private key blocks (design Property 10, Requirements 3.10, 7.11, 10.1, 10.6).
  - After the bootstrap pull request is opened, check the lint workflow run. Pass: it is green (design Property 8, Requirements 9.1, 9.2, 9.5, 9.7).
  - Confirm tasks 6.4, 7.2, and 8.2 passed and are recorded in the task notes, ask the user if questions arise.
  - Task notes (verified by hand, nothing pushed, no PR opened):
    - Test-artifact search, `git ls-files --cached --others --exclude-standard | grep -E '(^|/)(tests?/|conftest\.py$|pytest\.ini$|test_[^/]*\.py$|[^/]*_test\.py$)'`: PASS. Nothing printed, exit 1. No `tests/` folder exists. `.github/workflows/lint.yml` has only the cfn-lint and ruff steps (checked in 7.2).
    - `git ls-files --cached --others --exclude-standard '*.py' 'infra/*' 'data/*'`: PASS. Only `data/README.md` and `infra/README.md`.
    - Secrets: the repository has one commit (`4c7d8ad Initial commit`, the template files). I scanned all 26 tracked or untracked-not-ignored files (excluding LICENSE) with a regex for AWS access key IDs (`AKIA`/`ASIA`), private key blocks, 12-digit numbers, GitHub and Slack tokens, and `aws_secret`/`secret_access_key`. PASS. No match. A scan of `git log -p --all` for `AKIA`, private key blocks, and 12-digit numbers also found nothing. A word search for password, secret, token, and api key found only 3 harmless lines: the Secret definition in `.kiro/steering/tech.md:45`, a `secretsmanager` ARN built with `!Sub` pseudo parameters in `docs/cloudformation-conventions.md:83`, and the inherited `.streamlit/secrets.toml` ignore rule in `.gitignore:223`. No literal account ID appears anywhere; `README.md` uses `<ACCOUNT_ID>`.
    - Working tree state: new files are still uncommitted (area READMEs and the README edit are staged with `git add -N`/modified; the rest are untracked), so the history scan covers only the initial commit. Re-run the secret scan on the commit diff before the PR is opened.
    - Tasks 6.4, 7.2, and 8.2: PASS. Each has its task notes recorded above with results.
    - PENDING (for the user): the green lint workflow run on the bootstrap pull request (design Property 8, Requirements 9.1, 9.2, 9.5, 9.7), and the GitHub Mermaid preview check of the root README diagram. Both need the PR to be pushed and opened, which was not done here. The deferred AWS checks from 6.4 (no-change redeploy, delete of an absent stack, step 6 and 9 read-back) stay deferred to the first spec that adds templates.

## Notes

- No task writes automated tests, test files, fixtures, or verification scripts; manual verification steps replace them, as `.kiro/steering/tech.md` requires.
- No task creates AWS resources. Checks that need real stacks are deferred to the first spec that adds templates (see task 6.4).
- Commit messages and the pull request reference `#1` (`docs/kiro-workflow.md`).
- Each task references requirement clauses for traceability; design Properties 1 to 10 map to the manual verification steps.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "2.2"] },
    { "id": 1, "tasks": ["1.2", "3.1", "3.2", "3.3"] },
    { "id": 2, "tasks": ["2.3", "4.1", "4.2", "6.1"] },
    { "id": 3, "tasks": ["3.4", "6.2", "7.1"] },
    { "id": 4, "tasks": ["4.3", "6.3"] },
    { "id": 5, "tasks": ["6.4", "8.1"] },
    { "id": 6, "tasks": ["7.2"] },
    { "id": 7, "tasks": ["8.2"] }
  ]
}
```
