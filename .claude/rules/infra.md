---
paths:
  - "infra/**"
---

# Infrastructure rules

## IaC

- CloudFormation templates are written in YAML only.
- AWS CDK is not used.
- Terraform is not used.
- Full conventions: `docs/cloudformation-conventions.md`.

## Templates

`infra/` holds exactly one CloudFormation template per Component. No Component has more than one template.

File naming rule: `infra/<component>.yaml`

- `infra/network.yaml`
- `infra/auth.yaml`
- `infra/database.yaml`
- `infra/pre-runtime.yaml`
- `infra/runtime.yaml`
- `infra/memory.yaml`
- `infra/observability.yaml`
- `infra/ui.yaml`
- `infra/mcp.yaml`

## Naming

- Stack name: `inspection-agent-<env>-<component>` (example: `inspection-agent-demo-runtime`)
- SSM parameter key: `/inspection-agent/<env>/<component>/<key>` (example: `/inspection-agent/demo/memory/memory-id`)
- Cross-stack values are published as SSM parameters under that path pattern.
- The CloudFormation parameter `Env` defaults to `demo`.

## Placeholders

- `<env>`: the value of the `Env` parameter. It is 1 to 10 characters, starts with a lowercase letter, and contains only lowercase letters and digits (pattern `^[a-z][a-z0-9]{0,9}$`). The default is `demo`.
- `<component>`: one of `network`, `auth`, `database`, `pre-runtime`, `runtime`, `memory`, `observability`, `ui`, `mcp`. No other value is allowed.
- `<key>`: lowercase letters, digits, and hyphens only.

## Quality

- Validate templates with `cfn-lint`.
- IAM permissions follow least privilege.
- No Secrets or account-specific identifiers that grant access in templates.
