# docs

Project documentation.

## Contents

- [cloudformation-conventions.md](cloudformation-conventions.md): rules every CloudFormation template follows
- [database.md](database.md): the RDS database, its users and secrets, the seed command, read-only role checks, and teardown
- [evals.md](evals.md): manual checklist of prompts, expected tool calls, and decisions for the deployed agent
- [inspection-tools.md](inspection-tools.md): the four read-only inspection tools, the result schema, authorization rules, and audit event
- [runtime.md](runtime.md): AgentCore runtime stacks (`pre-runtime` and `runtime`), deploy order, code update procedure, session behavior, and manual verification results
- [memory.md](memory.md): AgentCore Memory stack, actor and session keys, namespaces, what is written as an event, the extraction delay and the demo flow it implies, `memory-inspect`, and known gaps
- [observability.md](observability.md): how to find and read the trace for a request, what each span and audit attribute means, the three saved queries, the auditor walkthrough, the dashboard, and the five-minute pre-demo checklist
- [kiro-workflow.md](kiro-workflow.md): how GitHub issues, specs, commits, and pull requests map to each other

Data artifacts: [data/STORIES.md](../data/STORIES.md) lists the IDs and expected answers behind the demo questions.

See [.kiro/steering/structure.md](../.kiro/steering/structure.md) for the repository layout and naming rules.
