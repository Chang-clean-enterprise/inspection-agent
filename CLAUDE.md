# inspection-agent

Demo of an AI agent that answers questions about manufacturing inspection data. Users sign in, ask questions in natural language, and get answers that respect what each user is allowed to see.

All data is synthetic. It contains no real company, customer, or personal data. All code, comments, docs, and UI text are in English.

## Non-negotiable rules

- Permissions are enforced in code at the tool layer, using the verified user identity. They are never enforced only by instructions in the model prompt.
- The agent is read-only. No tool creates, updates, or deletes data.
- The agent has no free-form SQL tool.
- The model never supplies the user identity as a tool argument. The tool layer takes the user identity only from the verified user identity.
- IAM permissions follow least privilege.
- The repository contains no Secrets (credentials, passwords, API keys, access keys, tokens, private keys, or account-specific identifiers that grant access).

## Testing policy

- Do not create test files, test suites, test fixtures, eval harnesses, or test/verification scripts. No `tests/` folder, no pytest files, no CI test step.
- Validate each task locally and by hand: run the code, call the function, deploy and invoke.
- Acceptance criteria are verified manually, not with automated tests.
- Operational scripts (see `.claude/rules/scripts.md`) are allowed.
- `cfn-lint` and `ruff` are the only quality checks. CI runs lint only.

## Personas and demo questions

Personas:

- Line A inspector (`line-a`)
- Line B inspector (`line-b`)
- Quality supervisor (`supervisors`)

Demo questions:

1. List reports for a line, part, and period.
2. Is there an out-of-tolerance trend for a characteristic?
3. Summarize the findings of a lot.
4. Ask for data from the other line and get a denial.
5. Resume context in a new session.

This list is the only source of the five demo questions. `data/STORIES.md` holds the IDs and expected answers behind them and refers to each question by its number, 1 to 5.

## Stack and targets

- Strands Agents
- Amazon Bedrock AgentCore Runtime
- Claude models on Amazon Bedrock
- PostgreSQL on Amazon RDS (the only data store; DynamoDB is not used)
- Amazon Cognito (sign-in)
- AWS CloudFormation (all infrastructure, see `.claude/rules/infra.md`)
- AWS region: `us-west-2`
- Python version: `3.12`

## Layout

The shared core, the agent, the MCP server, the UI, and the infrastructure live in five separate folders. No folder holds two of them.

- `infra/`: CloudFormation templates, one per Component.
- `src/inspection_core/`: the shared Python package for database access, authorization, and tool functions.
- `src/inspection_agent/`: the Strands agent and the AgentCore entrypoint.
- `src/inspection_mcp/`: the MCP server.
- `data/`: the database schema, the data generator, the generated seed files, and the stories file `data/STORIES.md`.
- `ui/`: the static site.
- `scripts/`: Operational_Scripts only (see `.claude/rules/scripts.md`).
- `docs/`: project documentation, including `docs/cloudformation-conventions.md`.

## Specs and workflow

Every new spec starts in plan mode. No workflow or skill is used; keep it simple.

Agents and models:

- Main session (planning, asking the user, AWS work): Opus 5. Managed settings pin the default model and `opusplan` is not available, so no project setting selects the model.
- `explorer` (`.claude/agents/explorer.md`, Haiku, read-only): use it instead of the built-in Explore agent when planning or searching the repo.
- `implementer` (`.claude/agents/implementer.md`, Sonnet): implements one `[implementer]` task at a time. It is configured as `sonnet`; the 1M-context variant is not verified for subagents.

Spec location and naming (same convention as Kiro):

- Folder: `.kiro/specs/<NN>-<slug>/`. `<NN>` is the GitHub issue number as two digits (`01` to `99`). `<slug>` is lowercase kebab-case, 1 to 40 characters. The next spec is `10-<slug>`.
- `design.md`: the detailed implementation plan. The first line of its Overview is `GitHub issue: #<issue-number>`.
- `tasks.md`: the tracker. Use the format of existing specs: `- [ ] 1.1 Task` with `_Requirements: ..._` references where they apply.
- `requirements.md`: optional, only when the plan needs it.
- Do not create `.config.kiro` or `tasks.meta.json`. They are Kiro internals.

Task tags in `tasks.md`. Every top-level task or sub-task carries one tag, agreed with the user when the plan is approved:

- `[implementer]`: needs only files and local commands (Python, CloudFormation templates, docs, `ruff`, `cfn-lint`). No AWS access, no credentials, no user input. When in doubt, use `[main]`.
- `[main]`: done in the main session. Anything that touches AWS (deploy, invoke, seed, teardown, credentials, `aws login`), needs the user to run a command or answer a question, or is risky or ambiguous.

Flow:

1. In plan mode, produce the plan, including the `[implementer]`/`[main]` split. Write nothing to the repo.
2. After approval, write `design.md` and `tasks.md` to the spec folder.
3. Execute following `tasks.md`, in order.
   - `[implementer]` task: launch the `implementer` subagent in the foreground with the spec folder path and the task number. If it returns `BLOCKED: ...`, relay the question to the user and send the answer back to the same subagent. If it returns `DONE`, review the diff and re-run the cheap checks (`ruff`, `cfn-lint`) before accepting.
   - `[main]` task: do it in the main session. Ask the user, or give them a `! command`, whenever their input or action is needed.
4. Tick each checkbox as soon as its task is verified, not in batches. Only the main session ticks.
5. Verification tasks are manual (see the testing policy). Record what was checked and the real result in a note under the task, as in `.kiro/specs/09-agentcore-runtime-stack/tasks.md`.

## Repository gotchas

- The only ruff configuration is `ruff.toml` at the repository root. Do not add `[tool.ruff]` to a `pyproject.toml`.
- Build output goes to `build/`, which is ignored by Git.
- The inherited `.gitignore` ignores folders named `lib/`, `var/`, `env/`, `target/`, and `downloads/`. Do not use those names for folders that hold tracked code.
