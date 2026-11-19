# infra

CloudFormation templates for inspection-agent, one template per Component.

## Contents

The 8 Components are:

- network
- auth
- database
- runtime
- memory
- observability
- ui
- mcp

File rule: `infra/<component>.yaml` (for example `infra/network.yaml`).

Templates follow [docs/cloudformation-conventions.md](../docs/cloudformation-conventions.md).

See [.kiro/steering/structure.md](../.kiro/steering/structure.md) for the repository layout and naming rules.
