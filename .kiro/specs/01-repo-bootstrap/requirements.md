# Requirements Document

## Introduction

This spec bootstraps the "inspection-agent" repository. inspection-agent is a demo of an AI agent that answers questions about manufacturing inspection data. The stack is Strands Agents (Python 3.12) on Amazon Bedrock AgentCore Runtime, Claude models on Amazon Bedrock, PostgreSQL on Amazon RDS, Amazon Cognito for sign-in, and AWS CloudFormation (YAML only) for all infrastructure, in region us-west-2. All data is synthetic. All code, comments, docs, and UI text are in English.

The goal is to create the repository skeleton, shared conventions, and Kiro steering files so that every later spec starts from the same decisions. This spec maps to GitHub issue 1 and the spec folder `.kiro/specs/01-repo-bootstrap/`.

Out of scope: any AWS resource, application code, or data. This spec creates no CloudFormation templates, no Python application logic, and no seed data.

Project testing policy: this project forbids automated tests. Every acceptance criterion below is verified manually by inspecting files or running commands by hand.

## Glossary

- **Repository**: The inspection-agent Git repository rooted at the workspace root.
- **Layout**: The set of top-level folders defined in Requirement 1 (infra/, src/inspection_core/, src/inspection_agent/, src/inspection_mcp/, data/, ui/, scripts/, docs/).
- **Area_README**: A README.md file placed at the root of one Layout folder that states the purpose and contents of that folder.
- **Steering_Files**: The three Kiro steering documents `.kiro/steering/product.md`, `.kiro/steering/tech.md`, and `.kiro/steering/structure.md`.
- **Product_Steering**: The file `.kiro/steering/product.md`.
- **Tech_Steering**: The file `.kiro/steering/tech.md`.
- **Structure_Steering**: The file `.kiro/steering/structure.md`.
- **Stories_File**: The file `data/STORIES.md`, which holds the data IDs and expected answers behind the five Demo_Questions.
- **Demo_Questions**: The five demo questions: (1) list reports for a line, part, and period; (2) is there an out-of-tolerance trend for a characteristic; (3) summarize the findings of a lot; (4) ask for data from the other line and get a denial; (5) resume context in a new session.
- **Personas**: The three demo users: line A inspector, line B inspector, and quality supervisor, mapped to the Cognito groups `line-a`, `line-b`, and `supervisors`.
- **Component**: One infrastructure unit with its own CloudFormation template. The Components are network, auth, database, runtime, memory, observability, ui, and mcp.
- **Stack_Name**: The CloudFormation stack name for a Component, in the form `inspection-agent-<env>-<component>`.
- **Env**: The CloudFormation parameter that names the deployment environment. The default value is `demo`.
- **Env_Rule**: The single validity rule for Env values: 1 to 10 characters, starts with a lowercase letter, and contains only lowercase letters and digits (AllowedPattern `^[a-z][a-z0-9]{0,9}$`), with the default `demo`.
- **SSM_Key**: An AWS Systems Manager Parameter Store path in the form `/inspection-agent/<env>/<component>/<key>`, used to publish cross-stack values.
- **CFN_Conventions_Doc**: The file `docs/cloudformation-conventions.md`.
- **Kiro_Workflow_Doc**: The file `docs/kiro-workflow.md`.
- **Root_README**: The file `README.md` at the Repository root.
- **Entry_Point**: The single Makefile or shell script that deploys, updates, and deletes Component stacks with the AWS CLI.
- **Deploy_Sequence**: The ordered list of Entry_Point steps: (1) network, (2) auth, (3) database, (4) runtime with an empty MemoryId, (5) memory, (6) runtime update that sets MemoryId, (7) observability, (8) ui, (9) auth update that adds the CloudFront callback and logout URLs, (10) mcp.
- **Teardown_Sequence**: The reverse stack deletion order: mcp, ui, observability, memory, runtime, database, auth, network.
- **CI_Workflow**: The GitHub Actions workflow file under `.github/workflows/` that lints the Repository.
- **Operational_Scripts**: The scripts allowed under scripts/: deploy, package, seed, create demo users, invoke, smoke test, demo reset, demo warmup, memory inspect, and teardown. A single one of these scripts is called an Operational_Script.
- **Secret**: Any credential, password, API key, access key, token, private key, or account-specific identifier that grants access to a system.

## Requirements

### Requirement 1: Repository layout

**User Story:** As a developer, I want a fixed repository layout with a short README in each area, so that every later spec places files in the same, predictable locations.

#### Acceptance Criteria

1. THE Repository SHALL contain, tracked in Git, the folders infra/, src/inspection_core/, src/inspection_agent/, src/inspection_mcp/, data/, ui/, scripts/, and docs/, at those exact lowercase paths relative to the Repository root.
2. THE Repository SHALL contain exactly one Area_README, named README.md, directly at the root of each Layout folder. Each Area_README SHALL be written in English and SHALL be no longer than 50 lines.
3. THE Area_README for infra/ SHALL state that infra/ holds the CloudFormation templates, one template per Component. It SHALL list the eight Components by name: network, auth, database, runtime, memory, observability, ui, and mcp.
4. THE Area_README for src/inspection_core/ SHALL state that the folder holds the shared Python package for database access, authorization, and tool functions.
5. THE Area_README for src/inspection_agent/ SHALL state that the folder holds the Strands agent and the AgentCore entrypoint.
6. THE Area_README for src/inspection_mcp/ SHALL state that the folder holds the MCP server and that a later spec adds the MCP server.
7. THE Area_README for data/ SHALL state that the folder holds the database schema, the data generator, the generated seed files, and the Stories_File. It SHALL name the Stories_File by its path data/STORIES.md.
8. THE Area_README for ui/ SHALL state that the folder holds the static site.
9. THE Area_README for scripts/ SHALL state that the folder holds Operational_Scripts only. It SHALL list the ten Operational_Scripts by name: deploy, package, seed, create demo users, invoke, smoke test, demo reset, demo warmup, memory inspect, and teardown.
10. WHERE the design renames a Layout folder, THE Structure_Steering SHALL record the original folder name, the new folder name, and the reason for the rename. The renamed folder SHALL contain the Area_README that the original folder would have contained.
11. WHERE the design renames a Layout folder, THE Layout SHALL keep the shared core, the agent, the MCP server, the UI, and the infrastructure in five separate folders, and no one folder SHALL hold two of them.
12. WHEN all tasks of this spec are complete, THE Repository SHALL contain no file with the .py extension, no file under infra/ other than its Area_README, and no file under data/ other than its Area_README, counting only files tracked in Git.

### Requirement 2: Product steering

**User Story:** As a developer using Kiro, I want a product steering file, so that every later spec uses the same purpose, personas, demo questions, and constraints without asking again.

#### Acceptance Criteria

1. THE Product_Steering SHALL state, in its first section, that inspection-agent is a demo of an AI agent that answers questions about manufacturing inspection data.
2. THE Product_Steering SHALL list exactly three Personas, one list item per Persona, and each list item SHALL name the Persona together with its Cognito group written exactly as follows: line A inspector (`line-a`), line B inspector (`line-b`), and quality supervisor (`supervisors`).
3. THE Product_Steering SHALL list exactly five Demo_Questions as a numbered list from 1 to 5, in this order: (1) list reports for a line, part, and period; (2) is there an out-of-tolerance trend for a characteristic; (3) summarize the findings of a lot; (4) ask for data from the other line and get a denial; (5) resume context in a new session.
4. THE Product_Steering SHALL state that Product_Steering is the only source of the five Demo_Questions, and that the Stories_File at `data/STORIES.md` holds the IDs and expected answers behind the Demo_Questions. The Stories_File refers to each Demo_Question by its number from 1 to 5.
5. THE Product_Steering SHALL state that all data is synthetic and that the data contains no real company, customer, or personal data.
6. THE Product_Steering SHALL state that all code, comments, docs, and UI text are in English.
7. THE Product_Steering SHALL state that permissions are enforced in code at the tool layer using the verified user identity, and that permissions are never enforced only by instructions in the model prompt.
8. THE Product_Steering SHALL state that the agent is read-only, meaning no tool creates, updates, or deletes data, and that the agent has no free-form SQL tool.
9. THE Product_Steering SHALL state that the model never supplies the user identity as a tool argument, and that the tool layer takes the user identity only from the verified user identity.
10. THE Repository SHALL contain the full wording of the five Demo_Questions only in Product_Steering. A reviewer checks this by running a case-insensitive text search of the repository for the wording of each Demo_Question and confirming that every match is in Product_Steering. The only allowed exception is the file `.kiro/specs/01-repo-bootstrap/requirements.md`.
11. WHEN a document other than Product_Steering mentions the Demo_Questions, THE document SHALL reference Product_Steering by the path `.kiro/steering/product.md` and the Stories_File by the path `data/STORIES.md`.
12. THE Product_Steering SHALL use Kiro's "always" inclusion mode, so that Kiro loads it into every session and every spec without the developer attaching it by hand.

### Requirement 3: Technology steering

**User Story:** As a developer using Kiro, I want a technology steering file, so that every later spec uses the same stack, region, Python version, IaC rules, security baseline, and testing policy.

#### Acceptance Criteria

1. THE Tech_Steering SHALL list each of the following stack components by these exact names: Strands Agents, Amazon Bedrock AgentCore Runtime, Claude models on Amazon Bedrock, PostgreSQL on Amazon RDS, Amazon Cognito (for sign-in), and AWS CloudFormation (for all infrastructure).
2. THE Tech_Steering SHALL state the AWS region as the literal value `us-west-2` and the Python version as the literal value `3.12`, and SHALL name no other AWS region or Python version as a target.
3. THE Tech_Steering SHALL state that the only data store is Amazon RDS for PostgreSQL and that DynamoDB is not used, and SHALL name no other database or data store as part of the stack.
4. THE Tech_Steering SHALL state the IaC rules as: CloudFormation templates are written in YAML only, AWS CDK is not used, and Terraform is not used; and SHALL reference the CFN_Conventions_Doc by the literal repository-relative path `docs/cloudformation-conventions.md` as the source of the full conventions.
5. THE Tech_Steering SHALL state that stacks are named with the pattern `inspection-agent-<env>-<component>`, that the CloudFormation parameter `Env` defaults to `demo`, and that cross-stack values are published as SSM parameters under the path pattern `/inspection-agent/<env>/<component>/<key>`.
6. THE Tech_Steering SHALL state a security baseline that includes each of these five items as a separate statement: (a) permissions are enforced in code at the tool layer using the verified user identity; (b) the agent is read-only and has no free-form SQL tool; (c) the model never supplies the user identity as a tool argument; (d) IAM permissions follow least privilege; (e) the Repository contains no Secrets.
7. THE Tech_Steering SHALL contain the testing policy with the following five rules as written:
   - Do not create test files, test suites, test fixtures, eval harnesses, or test/verification scripts. No tests/ folder, no pytest files, no CI test step.
   - Validate each task locally and by hand: run the code, call the function, deploy and invoke.
   - When a spec's task list would include writing tests, replace that task with a short manual verification step and record what was checked in the task notes.
   - Acceptance criteria are verified manually, not with automated tests.
   - Operational scripts (deploy, package, seed, create demo users, invoke, teardown, smoke test, demo reset, demo warmup, memory inspect) are allowed.
8. THE Repository SHALL contain no directory named `tests` or `test`, no file named `conftest.py`, `pytest.ini`, or matching `test_*.py` or `*_test.py`, and no CI workflow step that runs tests. The operational scripts listed in criterion 7, including smoke test scripts, are not test files under this criterion.
9. THE Tech_Steering SHALL exist as a Markdown file at the path `.kiro/steering/tech.md` and SHALL be included in every Kiro session. It meets this when it has no front matter or its front matter declares `inclusion: always`.
10. THE Tech_Steering SHALL contain no Secrets.
11. THE Tech_Steering SHALL contain no statement that contradicts criteria 1–7, such as naming DynamoDB, AWS CDK, Terraform, or JSON-format CloudFormation templates as used or allowed.

### Requirement 4: Structure steering

**User Story:** As a developer using Kiro, I want a structure steering file, so that every later spec follows the same layout and naming rules.

#### Acceptance Criteria

1. THE Structure_Steering SHALL contain exactly one entry for each of the 8 Layout folders (infra/, src/inspection_core/, src/inspection_agent/, src/inspection_mcp/, data/, ui/, scripts/, docs/). Each entry SHALL give the folder path and at least one sentence naming the kind of content that belongs in that folder, so that a reviewer can tick off all 8 folders from the file alone.
2. THE Structure_Steering SHALL state that infra/ holds exactly one CloudFormation template per Component, for a total of 8 templates (network, auth, database, runtime, memory, observability, ui, mcp), and that no Component has more than one template.
3. THE Structure_Steering SHALL state the template file naming rule as a pattern containing the `<component>` placeholder, and SHALL list the resulting file name for each of the 8 Components, so that a reviewer can check every listed name against the pattern.
4. THE Structure_Steering SHALL state the Stack_Name rule `inspection-agent-<env>-<component>` and the SSM_Key rule `/inspection-agent/<env>/<component>/<key>`. Each rule SHALL be written character-for-character as shown and SHALL be followed by at least one concrete example in which every placeholder is filled in.
5. THE Structure_Steering SHALL define every placeholder used in its naming rules (`<env>`, `<component>`, `<key>`, `<NN>`, `<slug>`) as follows:
   - `<env>` SHALL be defined by the Env_Rule (1 to 10 characters, starts with a lowercase letter, lowercase letters and digits only, default `demo`), and the definition SHALL reference `docs/cloudformation-conventions.md`.
   - `<component>` SHALL be limited to the 8 Component names.
   - `<NN>` SHALL be a two-digit, zero-padded number from 01 to 99.
   - `<slug>` and `<key>` SHALL be limited to lowercase letters, digits, and hyphens.
6. THE Structure_Steering SHALL state the spec folder rule `.kiro/specs/<NN>-<slug>/` with at least one concrete example, and SHALL reference the Kiro_Workflow_Doc by its exact path `docs/kiro-workflow.md`.
7. THE Structure_Steering SHALL state that scripts/ holds Operational_Scripts only. It SHALL list all 10 Operational_Scripts (deploy, package, seed, create demo users, invoke, smoke test, demo reset, demo warmup, memory inspect, teardown), and SHALL state that application code and library modules belong under src/ and not in scripts/.
8. THE Structure_Steering SHALL be located at `.kiro/steering/structure.md` and SHALL be configured for inclusion in every Kiro interaction, so that later specs load it without a manual reference.

### Requirement 5: CloudFormation conventions

**User Story:** As a developer writing infrastructure in later specs, I want one written set of CloudFormation conventions, so that every template follows the same rules.

#### Acceptance Criteria

1. THE CFN_Conventions_Doc SHALL state that templates are written in YAML only, saved with the `.yaml` file extension, and that JSON templates, CDK, and Terraform are not used.
2. THE CFN_Conventions_Doc SHALL state that every template parameter has a non-empty Description and at least one constraint from this list: AllowedValues, AllowedPattern, MinLength/MaxLength, MinValue/MaxValue, or an AWS-specific parameter type (for example `AWS::EC2::VPC::Id` or `AWS::SSM::Parameter::Value<String>`).
3. THE CFN_Conventions_Doc SHALL state that every template declares an Outputs section with one output for each resource identifier, name, or ARN that another stack or an operator consumes, and that every output has a non-empty Description.
4. THE CFN_Conventions_Doc SHALL state that every resource type supporting the Tags property carries the mandatory tag `Project` with the value `inspection-agent` and the mandatory tag `Env` with the value of the Env parameter (via `!Ref Env`).
5. THE CFN_Conventions_Doc SHALL state that IAM policy statements follow least privilege, meaning no statement uses `*` as a full Action value or as a service-level action wildcard (for example `s3:*`), and no statement uses `*` in a Resource value unless a YAML comment on the line directly above that statement gives the reason the wildcard is needed.
6. THE CFN_Conventions_Doc SHALL state that templates contain no literal 12-digit account IDs, no literal region names, and no literal strings beginning with `arn:`, and that such values are built with `!Sub` or `!Join` from the pseudo parameters `AWS::AccountId`, `AWS::Region`, and `AWS::Partition`, from template parameters, or from SSM_Keys.
7. THE CFN_Conventions_Doc SHALL state that every template passes cfn-lint with zero errors and zero warnings before it is committed, and SHALL give the exact cfn-lint command a developer runs to check one template.
8. THE CFN_Conventions_Doc SHALL state that every stack is deployed with a Stack_Name of the form `inspection-agent-<env>-<component>`, where `<env>` is the Env parameter value and `<component>` contains only lowercase letters, digits, and hyphens.
9. THE CFN_Conventions_Doc SHALL state that every template declares an Env parameter of type String with the default value `demo` and the AllowedPattern `^[a-z][a-z0-9]{0,9}$`, which implements the Env_Rule: 1 to 10 characters, starting with a lowercase letter, and containing only lowercase letters and digits.
10. THE CFN_Conventions_Doc SHALL state that values shared across stacks are published and read as SSM parameters named by the SSM_Key form `/inspection-agent/<env>/<component>/<key>`, where `<component>` is the producing stack's component, and that CloudFormation Export and `Fn::ImportValue` are not used for cross-stack values.
11. THE CFN_Conventions_Doc SHALL present each convention in criteria 1 to 10 as a separately numbered rule, each with a YAML snippet showing compliant usage, so that a reviewer can check a template against the document one rule at a time.

### Requirement 6: Deploy and teardown entry point

**User Story:** As a developer, I want one entry point that deploys, updates, and deletes each stack in dependency order, so that I can stand up and remove the demo without remembering the order.

#### Acceptance Criteria

1. THE Entry_Point SHALL provide a command for each of the 8 Components that, using the AWS CLI, creates that Component's stack if it does not exist or updates it if it exists, and returns only after the stack reaches CREATE_COMPLETE or UPDATE_COMPLETE status.
2. WHEN a per-Component deploy command runs against an existing stack and the template and parameters have not changed, THE Entry_Point SHALL report that the stack has no changes and exit with code 0, leaving the stack unchanged.
3. THE Entry_Point SHALL provide a command for each of the 8 Components that, using the AWS CLI, deletes that Component's stack and returns only after the stack reaches DELETE_COMPLETE status. IF the stack does not exist, THEN the command SHALL report that the stack is absent and exit with code 0.
4. WHEN the full deploy command runs, THE Entry_Point SHALL run the 10 steps of the Deploy_Sequence in order. Before each step, it SHALL print the step number (1–10) and the Stack_Name. It SHALL start a step only after the previous step's stack has reached CREATE_COMPLETE or UPDATE_COMPLETE status.
5. WHEN the Entry_Point deploys the runtime stack in step 4 of the Deploy_Sequence, THE Entry_Point SHALL pass an empty string as the MemoryId parameter value.
6. WHEN the Entry_Point runs step 6 of the Deploy_Sequence, THE Entry_Point SHALL read the MemoryId from the SSM parameter that the memory stack publishes under `/inspection-agent/<env>/memory/` and SHALL update the runtime stack with that value as the MemoryId parameter. After the update, the runtime stack's MemoryId parameter (checked with `aws cloudformation describe-stacks`) SHALL equal the SSM parameter value.
7. WHEN the Entry_Point runs step 9 of the Deploy_Sequence, THE Entry_Point SHALL read the CloudFront callback URL and logout URL from the SSM parameters that the ui stack publishes under `/inspection-agent/<env>/ui/` and SHALL update the auth stack with both values. After the update, the auth stack's parameters (checked with `aws cloudformation describe-stacks`) SHALL contain both values.
8. IF a cross-stack SSM parameter that step 6 or step 9 of the Deploy_Sequence needs does not exist, THEN THE Entry_Point SHALL stop with a non-zero exit code and an error message naming the missing parameter path, without updating the target stack.
9. WHEN the teardown command runs, THE Entry_Point SHALL delete the 8 stacks in Teardown_Sequence order and print each Stack_Name before deleting it. It SHALL wait for each stack to reach DELETE_COMPLETE status before deleting the next one. It SHALL skip any stack that does not exist, with a message naming that stack, and continue with the next stack in the sequence.
10. THE Entry_Point SHALL name every stack `inspection-agent-<env>-<component>`, where `<component>` is one of the 8 Component names. It SHALL accept Env as an input and use `demo` when Env is not supplied.
11. IF the supplied Env is not 1 to 10 characters long, does not start with a lowercase letter, or contains characters other than lowercase letters and digits (the Env_Rule, pattern `^[a-z][a-z0-9]{0,9}$`), THEN THE Entry_Point SHALL stop with a non-zero exit code and an error message stating the Env_Rule, before making any AWS CLI call.
12. THE Entry_Point SHALL target region us-west-2 when no region input is supplied. It SHALL accept a region input that overrides this default for every AWS CLI call in the same run.
13. IF a per-Component command is given a name that is not one of the 8 Components, THEN THE Entry_Point SHALL stop with a non-zero exit code and an error message that lists the 8 valid Component names, before making any AWS CLI call.
14. IF the template file for a requested Component does not exist, THEN THE Entry_Point SHALL stop with a non-zero exit code and an error message naming the missing file, before making any AWS CLI call for that Component.
15. IF an AWS CLI call in the Entry_Point returns a non-zero exit code, or a stack ends in a status other than CREATE_COMPLETE, UPDATE_COMPLETE, or DELETE_COMPLETE, THEN THE Entry_Point SHALL stop with a non-zero exit code and an error message naming the failed step and Stack_Name. It SHALL run none of the remaining steps.
16. THE Root_README SHALL describe how to run the full deploy command, the 8 per-Component deploy commands, the 8 per-Component delete commands, and the teardown command. It SHALL also describe how to supply the Env and region inputs, their defaults (`demo` and us-west-2), and that the AWS CLI must be installed with credentials configured.

### Requirement 7: Root README

**User Story:** As a developer opening the repository for the first time, I want a README that explains the project, so that I understand what it is and how to deploy and remove it.

#### Acceptance Criteria

1. WHEN a developer opens the Root_README, THE Root_README SHALL show, before every other section, a purpose statement of at most 5 sentences that says what inspection-agent does and who it is for.
2. WHEN a developer opens the Root_README, THE Root_README SHALL show an architecture diagram inside a fenced code block tagged `mermaid`. The diagram SHALL render without a syntax error in the GitHub Markdown preview.
3. WHEN a developer opens the Root_README, THE Root_README SHALL show each of these 7 components as a separately labeled node in the architecture diagram, with every node connected to at least one other node: the UI, Amazon Cognito, the AgentCore Runtime agent, Claude on Amazon Bedrock, AgentCore Memory, Amazon RDS for PostgreSQL, and the MCP server.
4. WHEN a developer opens the Root_README, THE Root_README SHALL show a prerequisites list, placed before the deployment steps, that contains at least these 4 items: the AWS CLI, Python 3.12, an AWS account with access to region us-west-2, and Amazon Bedrock model access enabled for Claude models in us-west-2.
5. WHEN a developer opens the Root_README, THE Root_README SHALL show the Deploy_Sequence as a numbered list of exactly 10 steps in Deploy_Sequence order. Each step SHALL name its component and the command or action the developer runs.
6. WHEN a developer opens the Root_README, THE Root_README SHALL state 3 things in the deployment steps: step 4 deploys the runtime with an empty MemoryId; step 6 updates the runtime so that MemoryId is the value produced by step 5; and step 9 updates auth to add the CloudFront callback URL and logout URL produced by step 8.
7. WHEN a developer opens the Root_README, THE Root_README SHALL show the teardown steps as a numbered list of exactly 8 steps in Teardown_Sequence order: mcp, ui, observability, memory, runtime, database, auth, network. Each step SHALL name its component and the command or action the developer runs.
8. WHEN a developer opens the Root_README, THE Root_README SHALL state in at least one sentence that all data in the Repository and in the demo is synthetic and contains no real persons, customers, or inspection records.
9. THE Root_README SHALL reference Product_Steering for the Demo_Questions through a relative Markdown link, and SHALL NOT contain the text of any Demo_Question copied from Product_Steering.
10. THE Root_README SHALL reference Stories_File through a relative Markdown link as the location of the synthetic stories used by the demo.
11. THE Root_README SHALL NOT contain any real AWS account ID, access key, secret key, password, or Cognito client secret. Placeholders in angle brackets (for example `<ACCOUNT_ID>`) SHALL stand in for account-specific values.

### Requirement 8: Kiro workflow documentation

**User Story:** As a developer, I want the Kiro workflow written down, so that every GitHub issue, spec, commit, and pull request can be traced to each other.

#### Acceptance Criteria

1. THE Kiro_Workflow_Doc SHALL exist as a Markdown file at `docs/kiro-workflow.md` and SHALL state that each GitHub issue maps to exactly one spec folder at `.kiro/specs/<NN>-<slug>/`, and that each spec folder maps to exactly one GitHub issue.
2. THE Kiro_Workflow_Doc SHALL define `<NN>` as the issue sequence number written as exactly two digits, zero-padded, in the range `01` to `99`.
3. THE Kiro_Workflow_Doc SHALL define `<slug>` as a lowercase kebab-case short name of 1 to 40 characters. The slug SHALL contain only the characters `a`–`z`, `0`–`9`, and `-`, and SHALL NOT start or end with `-` or contain two `-` in a row. The doc SHALL give `01-repo-bootstrap` as the example of a complete folder name.
4. THE Kiro_Workflow_Doc SHALL state that each spec folder records the number of the GitHub issue it maps to, written in the form `#<issue-number>`, so that a reader can get from the spec to the issue without relying on `<NN>`.
5. THE Kiro_Workflow_Doc SHALL state that every commit message contains the GitHub issue number in the form `#<issue-number>`, and SHALL include at least one example commit message that shows this form.
6. THE Kiro_Workflow_Doc SHALL state that every pull request title or description contains the GitHub issue number in the form `#<issue-number>`, and SHALL include at least one example that shows this form.
7. THE Kiro_Workflow_Doc SHALL state that spec task lists contain no automated test tasks, and that each test task is replaced by a manual verification step. Each manual verification step SHALL name the action to perform and the observable result that counts as a pass.
8. THE Kiro_Workflow_Doc SHALL reference the testing policy by the literal path `.kiro/steering/tech.md`.
9. WHEN a reviewer reads the Kiro_Workflow_Doc from start to finish, THE Kiro_Workflow_Doc SHALL let the reviewer confirm each of criteria 1–8 by finding a matching statement in the doc, with no tooling or automated tests required.

### Requirement 9: Continuous integration

**User Story:** As a developer, I want a CI workflow that lints templates and Python code on every pull request, so that convention errors are caught without AWS credentials.

#### Acceptance Criteria

1. WHEN a pull request targeting any branch of the Repository is opened, reopened, or receives a new commit, THE CI_Workflow SHALL run cfn-lint on every file with a `.yaml`, `.yml`, or `.json` extension located anywhere under infra/, including its subdirectories.
2. WHEN a pull request targeting any branch of the Repository is opened, reopened, or receives a new commit, THE CI_Workflow SHALL run ruff on every file with a `.py` extension in the Repository, using the ruff configuration defined in criterion 6.
3. THE CI_Workflow SHALL contain no reference to repository or organization secrets and no step that configures or supplies AWS credentials, so that every step completes without access to an AWS account.
4. THE CI_Workflow SHALL contain no step that runs a test runner, test suite, or test command; its only quality-check steps SHALL be the cfn-lint step and the ruff step.
5. WHILE infra/ does not exist or contains no file with a `.yaml`, `.yml`, or `.json` extension, THE CI_Workflow SHALL complete the cfn-lint step with a success status.
6. THE Repository SHALL contain exactly one ruff configuration at the Repository root, and that configuration SHALL set the target Python version to 3.12.
7. WHILE the Repository contains no file with a `.py` extension, THE CI_Workflow SHALL complete the ruff step with a success status.
8. IF cfn-lint reports at least one error for any template file, or ruff reports at least one violation in any Python file, THEN THE CI_Workflow SHALL end the workflow run with a failure status that appears on the pull request, and the log of the failing step SHALL name each offending file.

### Requirement 10: Secrets and ignored files

**User Story:** As a developer, I want the repository to exclude secrets and generated files, so that no credential or build artifact is committed.

#### Acceptance Criteria

1. THE Repository SHALL contain no Secrets in any tracked file at the current commit or in any file of any earlier commit reachable from any branch. A reviewer verifies this by manually inspecting the output of `git ls-files` and `git log -p --all` and finding no literal Secret values, including account IDs, access key IDs, secret access keys, passwords for demo users, tokens, and private key blocks.
2. THE .gitignore SHALL exclude Python build artifacts, virtual environments, and caches, so that `git check-ignore -v` reports a matching rule for each of these paths: `build/`, `dist/`, `x.egg-info/`, `__pycache__/`, `x.pyc`, `.venv/`, `venv/`, `.pytest_cache/`, `.mypy_cache/`, and `.ruff_cache/`.
3. THE .gitignore SHALL exclude Node artifacts, so that `git check-ignore -v` reports a matching rule for `node_modules/` at the repository root, `node_modules/` in any subdirectory, `npm-debug.log`, and `yarn-error.log`, and reports no matching rule for `package.json` or `package-lock.json`.
4. WHERE an Operational_Script exists, WHEN a developer runs that Operational_Script once from a clean working tree (where `git status --porcelain` prints nothing), THE Repository SHALL show no untracked files produced by that script in the output of `git status --porcelain` afterward. This covers build output, packaging archives, generated deployment templates, and downloaded dependencies.
5. THE .gitignore SHALL exclude `.env` and every file whose name starts with `.env.`, except `.env.example`, so that `git check-ignore -v` reports a matching rule for `.env`, `.env.local`, `.env.dev`, and `.env.prod` in the repository root and in any subdirectory, and reports no matching rule (or only a negating `!` rule) for `.env.example`, which stays tracked as described in criterion 8. Every line of the existing Python .gitignore SHALL stay present and unchanged, and new entries SHALL only be appended.
6. THE Operational_Scripts SHALL get every Secret and account-specific identifier from environment variables or from files that the .gitignore excludes, and SHALL contain no literal Secret values in their source.
7. IF a Secret that an Operational_Script needs is missing from the environment when the script runs, THEN THE Operational_Script SHALL stop before making any change to external resources, exit with a non-zero exit status, and print an error message naming the missing variable without printing any Secret value.
8. WHERE the Repository includes an environment template file named `.env.example`, THE .gitignore SHALL not exclude that file, and THE file SHALL contain only variable names with empty or clearly placeholder values (for example `<your-value>`). A reviewer verifies this by reading the file and finding no real Secret.
