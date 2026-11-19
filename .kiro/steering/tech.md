---
inclusion: always
---

# Technology

## Stack

- Strands Agents
- Amazon Bedrock AgentCore Runtime
- Claude models on Amazon Bedrock
- PostgreSQL on Amazon RDS
- Amazon Cognito (for sign-in)
- AWS CloudFormation (for all infrastructure)

## Targets

- AWS region: `us-west-2`
- Python version: `3.12`

## Data store

Amazon RDS for PostgreSQL is the only data store. DynamoDB is not used.

## Infrastructure as code rules

- CloudFormation templates are written in YAML only.
- AWS CDK is not used.
- Terraform is not used.

The full conventions are in `docs/cloudformation-conventions.md`.

## Naming

- Stacks are named `inspection-agent-<env>-<component>`.
- The CloudFormation parameter `Env` defaults to `demo`.
- Cross-stack values are published as SSM parameters under the path pattern `/inspection-agent/<env>/<component>/<key>`.

## Security baseline

- Permissions are enforced in code at the tool layer using the verified user identity.
- The agent is read-only and has no free-form SQL tool.
- The model never supplies the user identity as a tool argument.
- IAM permissions follow least privilege.
- The repository contains no Secrets (credentials, passwords, API keys, access keys, tokens, private keys, or account-specific identifiers that grant access).

## Testing policy

- Do not create test files, test suites, test fixtures, eval harnesses, or test/verification scripts. No tests/ folder, no pytest files, no CI test step.
- Validate each task locally and by hand: run the code, call the function, deploy and invoke.
- When a spec's task list would include writing tests, replace that task with a short manual verification step and record what was checked in the task notes.
- Acceptance criteria are verified manually, not with automated tests.
- Operational scripts (deploy, package, seed, create demo users, invoke, teardown, smoke test, demo reset, demo warmup, memory inspect) are allowed.

## Tooling

- cfn-lint and ruff are the only quality checks.
- CI runs lint only.
