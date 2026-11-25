# docs

Project documentation.

## Contents

- [cloudformation-conventions.md](cloudformation-conventions.md): rules every CloudFormation template follows
- [database.md](database.md): RDS database, credential secrets, seed load, and read-only role checks
- [database.md](database.md): the RDS database, its users and secrets, the seed command, and teardown
- [evals.md](evals.md): manual checklist of prompts, expected tool calls, and decisions for the deployed agent
- [inspection-tools.md](inspection-tools.md): the four read-only inspection tools, the result schema, authorization rules, and audit event
- [runtime.md](runtime.md): AgentCore runtime stacks (`pre-runtime` and `runtime`), deploy order, code update procedure, session behavior, and manual verification results
- [memory.md](memory.md): AgentCore Memory stack, actor and session keys, namespaces, what is written as an event, the extraction delay and the demo flow it implies, `memory-inspect`, and known gaps
- [kiro-workflow.md](kiro-workflow.md): how GitHub issues, specs, commits, and pull requests map to each other

Data artifacts: [data/STORIES.md](../data/STORIES.md) lists the IDs and expected answers behind the demo questions.

See [.kiro/steering/structure.md](../.kiro/steering/structure.md) for the repository layout and naming rules.
