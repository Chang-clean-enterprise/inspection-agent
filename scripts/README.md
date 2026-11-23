# scripts

Operational scripts only. Application code and library modules belong under `src/`.

## Contents

The 10 Operational_Scripts are:

- deploy
- package
- seed (`seed.sh`, also `make seed`: packages the schema and seed files, invokes the in-VPC seed function, and prints row counts)
- create demo users
- invoke (`invoke.sh`: sends one prompt to the deployed runtime with `curl`; the Cognito access token comes only from `AGENT_ACCESS_TOKEN`, and the runtime ARN from SSM `/inspection-agent/<env>/runtime/runtime-arn`)
- smoke test
- demo reset
- demo warmup
- memory inspect
- teardown

See [.kiro/steering/structure.md](../.kiro/steering/structure.md) for the repository layout and naming rules.
