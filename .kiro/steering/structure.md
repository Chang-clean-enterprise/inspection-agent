---
inclusion: always
---

# Structure

## Layout

The repository has 8 top-level folders. No folder was renamed from the original layout.

- `infra/`: CloudFormation templates, one per Component.
- `src/inspection_core/`: the shared Python package for database access, authorization, and tool functions.
- `src/inspection_agent/`: the Strands agent and the AgentCore entrypoint.
- `src/inspection_mcp/`: the MCP server. A later spec adds it.
- `data/`: the database schema, the data generator, the generated seed files, and the stories file `data/STORIES.md`.
- `ui/`: the static site.
- `scripts/`: Operational_Scripts only (see "Scripts" below).
- `docs/`: project documentation, including `docs/cloudformation-conventions.md` and `docs/kiro-workflow.md`.

The shared core, the agent, the MCP server, the UI, and the infrastructure live in five separate folders. No folder holds two of them.

## Infrastructure templates

`infra/` holds exactly one CloudFormation template per Component, 8 templates in total. No Component has more than one template.

File naming rule: `infra/<component>.yaml`

- `infra/network.yaml`
- `infra/auth.yaml`
- `infra/database.yaml`
- `infra/runtime.yaml`
- `infra/memory.yaml`
- `infra/observability.yaml`
- `infra/ui.yaml`
- `infra/mcp.yaml`

## Naming rules

Stack name: `inspection-agent-<env>-<component>`

Example: `inspection-agent-demo-runtime`

SSM parameter key: `/inspection-agent/<env>/<component>/<key>`

Example: `/inspection-agent/demo/memory/memory-id`

## Placeholders

- `<env>`: the value of the `Env` parameter. It is 1 to 10 characters, starts with a lowercase letter, and contains only lowercase letters and digits (pattern `^[a-z][a-z0-9]{0,9}$`). The default is `demo`. See `docs/cloudformation-conventions.md`.
- `<component>`: one of `network`, `auth`, `database`, `runtime`, `memory`, `observability`, `ui`, `mcp`. No other value is allowed.
- `<NN>`: a two-digit, zero-padded number from `01` to `99`.
- `<slug>`: lowercase letters, digits, and hyphens only.
- `<key>`: lowercase letters, digits, and hyphens only.

## Specs

Spec folder rule: `.kiro/specs/<NN>-<slug>/`

Example: `.kiro/specs/01-repo-bootstrap/`

The full workflow is in `docs/kiro-workflow.md`.

## Scripts

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

## Repository gotchas

- The only ruff configuration is `ruff.toml` at the repository root. Do not add `[tool.ruff]` to a `pyproject.toml`.
- Build output goes to `build/`, which is ignored by Git.
- The inherited `.gitignore` ignores folders named `lib/`, `var/`, `env/`, `target/`, and `downloads/`. Do not use those names for folders that hold tracked code.
