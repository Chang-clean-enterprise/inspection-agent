---
paths:
  - "scripts/**"
---

# Scripts rules

`scripts/` holds Operational_Scripts only. The 10 allowed Operational_Scripts are:

1. deploy
2. package
3. seed
4. create demo users
5. invoke
6. smoke test
7. demo reset
8. demo warmup
9. memory inspect
10. teardown

Application code and library modules belong under `src/`, not in `scripts/`.

Do not add test or verification scripts here. See the testing policy in `CLAUDE.md`.
