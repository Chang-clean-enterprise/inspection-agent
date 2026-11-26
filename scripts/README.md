# scripts

Operational scripts only. Application code and library modules belong under `src/`.

## Contents

The 10 Operational_Scripts are:

- deploy (`deploy.sh`, also `make deploy` and `make deploy-<component>`: deploys the 9 stacks; `deploy runtime` needs a code package from `make package` and the `pre-runtime` stack)
- package (`package-agent.sh`, also `make package`: builds the reproducible arm64 zip and uploads it to the artifact bucket named in SSM `/inspection-agent/<env>/pre-runtime/artifact-bucket`)
- seed (`seed.sh`, also `make seed`: packages the schema and seed files, invokes the in-VPC seed function, and prints row counts)
- create demo users (`create-demo-users.sh`, no Makefile target: creates the three demo users in the Cognito user pool, verifies each email, sets a permanent password, and adds each user to its group; safe to run more than once. Users:
  - `inspector-a@example.com`, group `line-a`, password from `DEMO_PASSWORD_INSPECTOR_A`
  - `inspector-b@example.com`, group `line-b`, password from `DEMO_PASSWORD_INSPECTOR_B`
  - `supervisor@example.com`, group `supervisors`, password from `DEMO_PASSWORD_SUPERVISOR`

  Each password variable is read from the environment, or prompted without echo when empty and standard input is a terminal. No password or token is ever printed.)
- invoke (`invoke.sh`: sends one prompt to the deployed runtime with `curl`; the Cognito access token comes only from `AGENT_ACCESS_TOKEN`, and the runtime ARN from SSM `/inspection-agent/<env>/runtime/runtime-arn`, published by the runtime stack)
- smoke test
- demo reset
- demo warmup
- memory inspect (`memory-inspect.sh`, also `make memory-inspect ARGS="..."`: lists one actor's short-term session events and long-term memory records; the actor is resolved from `--persona inspector-a|inspector-b|supervisor` or given with `--actor`; the memory ID comes from SSM `/inspection-agent/<env>/memory/memory-id`, published by the memory stack; read only, no create, update, or delete call)
- teardown

See [.kiro/steering/structure.md](../.kiro/steering/structure.md) for the repository layout and naming rules.
