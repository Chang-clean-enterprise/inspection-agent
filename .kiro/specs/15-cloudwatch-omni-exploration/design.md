# Design Document

## Overview

GitHub issue: #15

This design determines whether CloudWatch Omni adds value to the demo beyond what spec 11 already built
(`docs/observability.md`), and documents how. It produces one new document, `docs/omni.md`, and
screenshots under `docs/omni/`. It changes no code, template, or script: Omni is a console-created,
account-level resource, the same way Transaction Search is in spec 11, and it reads the demo's existing
telemetry without re-instrumentation.

Deliverables:

| File | Change |
|---|---|
| `docs/omni.md` | New. Availability finding, setup walkthrough with screenshots, demo-query reproduction, decision record. |
| `docs/omni/*.png` | New. Screenshots captured by the user. |
| `docs/README.md` | Changed (small). Index entry for `docs/omni.md`. |

Out of scope: infrastructure as code for Omni, alarms, cost allocation, operating the AWS console by
browser automation.

### Key decisions

| # | Decision | Reason |
|---|---|---|
| 1 | Availability is answered from AWS documentation before spending the 1-hour time-box on anything else: `us-west-2` is one of 12 supported Regions. | Confirmed via `omni-supported-regions.html` during planning. The time-box is better spent confirming the account can actually create a domain/space than re-deriving a fact already published. |
| 2 | The Omni_Domain and Omni_Space are **not CloudFormation resources** and are **not torn down** at the end of this issue. | Same reasoning as Transaction Search in spec 11: both are account-level, console-managed settings, and a stack that owned them would risk disabling them for other workloads on delete. The user chose to keep them for potential reuse, which this design records as a deliberate, scoped decision rather than scope creep. |
| 3 | No telemetry or instrumentation change. Task 2 (design, below) is "does the existing Dataset get discovered," not a code change. | Omni's own documentation states it reads existing CloudWatch log groups, metrics, and traces with no re-instrumentation. The agent already sends everything spec 11 needed; Omni either surfaces it or it doesn't. |
| 4 | Screenshots and all console actions are captured by the user, not by browser automation. | Agreed with the user this session. Keeps the AWS console interaction, including domain/space creation (which may need account- or org-level permissions), in the hands of the person who already holds those credentials. |
| 5 | Every task is tagged `[main]`. | Every task depends on either an AWS console action, a user decision, or the user's own screenshot/report — there is no file-only step independent of that input, so delegating to the `implementer` subagent would only add a handoff. |
| 6 | **No screenshots.** `docs/omni.md` is written narratively from the user's reports, with no images under `docs/omni/`. | Agreed with the user during task 2: given the issue's own "extra, second item to cut" priority, the time cost of capturing and wiring in screenshots isn't worth it for this pass. Deviates from the issue's literal "document each step with screenshots," recorded here as a deliberate, scoped-down choice rather than an oversight. |

## Research record

Pages read on 2026-11-26.

| Topic | Finding | Source |
|---|---|---|
| Region availability | CloudWatch Omni is available in 12 Regions, including `us-west-2`. A space is created in one Region and its data stays there. | `omni-supported-regions.html` |
| What Omni needs from existing telemetry | "Telemetry you already send to CloudWatch appears in Omni with nothing to reconfigure." Enabling Omni creates one Dataset per space from the account's existing CloudWatch data stores; existing console pages, alarms, and Logs Insights queries keep working unchanged. | `cloudwatch-omni.html` |
| Structure | Three concepts: Domain (org-wide sign-in URL), Space (one account + Region, controls access), Dataset (correlates logs/metrics/traces, one per space). | `cloudwatch-omni.html` |
| AI agent monitoring surface | Traces, sessions, and topology are visible in both the Omni web UI (production, aggregate/fleet views) and an IDE extension (VS Code, Kiro, Cursor; local dev loop). Evaluators can score agent responses for quality, not just latency/errors. | `omni-monitor-ai-agents.html` |
| API surface | botocore ships a `cloudwatchomni` service (`CreateDomain`, `CreateSpace`, `GetDomain`, `GetSpace`, …) but it is not yet wired into this machine's `aws` CLI (2.31.22) command table. The console is the practical path for this issue. | local botocore inspection, `aws-cli/2.31.22` |

## Verification approach

Per the testing policy, every task below is verified by hand and recorded as a task note with the real
result — the same pattern spec 11 used. There is no test file, harness, or script added for this spec.
