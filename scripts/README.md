# scripts

Operational scripts only. Application code and library modules belong under `src/`.

## Contents

The 10 Operational_Scripts are:

- deploy
- package
- seed (`seed.sh`, also `make seed`: packages the schema and seed files, invokes the in-VPC seed function, and prints row counts)
- create demo users
- invoke
- smoke test
- demo reset
- demo warmup
- memory inspect
- teardown

See [.kiro/steering/structure.md](../.kiro/steering/structure.md) for the repository layout and naming rules.
