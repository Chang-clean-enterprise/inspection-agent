# Implementation Plan: CloudWatch Omni exploration of AgentCore traces

## Overview

This plan documents whether CloudWatch Omni adds value to the demo, in one new file (`docs/omni.md`)
and screenshots (`docs/omni/`). No code, template, or script changes. Every task is tagged `[main]`:
each one needs either an AWS console action, a user decision, or the user's own report of what they saw,
so there is no file-only step for the `implementer` subagent to run independently.

The workspace testing policy forbids test files, suites, fixtures, eval harnesses, and verification
scripts. Every verification task below is manual. Each one ends with a note recording what was checked
and the real result, written in this file and, where the acceptance criterion names it, in
`docs/omni.md` itself.

**Task 1 is a hard gate on tasks 2–4.** Per the issue, if Omni is not available or not usable, write the
finding and stop.

## Tasks

- [x] 1. [main] Availability and account check
  - Cite the region-availability finding already recorded in `design.md` (`us-west-2` is supported).
  - Ask the user to open the Omni console settings link for `us-west-2`
    (`https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#settings:/omni`) and
    confirm they can reach domain creation (no account-level block, no missing permission).
  - Write `docs/omni.md` with a first section recording: Region, date, availability result, and the
    documentation source cited.
  - **Gate:** if the user reports a block, record it and stop; do not start task 2.
  - _Requirements: 1.1, 1.2, 1.3_

  Note (2026-11-26, us-west-2): confirmed both ways. AWS docs list `us-west-2` as supported
  (`omni-supported-regions.html`). User opened the console Omni settings page and reported domain
  creation is reachable, no block. Gate passed; proceeding to task 2. Recorded in `docs/omni.md` §1.

- [x] 2. [main] Create the domain and space; connect telemetry
  - User created an Account domain and a space in `us-west-2` (single-account setup path: domain and
    space created together), with all recommended capabilities (CloudWatch Dataset integration, OTel
    span ingestion, OTel metrics enrichment) plus the optional AgentCore evaluation role. Domain/space
    names withheld from the doc by the user's choice.
  - Generated real traffic for the space to discover: 13 invocations of the deployed runtime via
    `scripts/invoke.sh`, spread across all three personas (`inspector-a`, `inspector-b`, `supervisor`),
    covering all three authorization decisions (`allowed`, `restricted`, `forbidden`) and `list_reports`,
    `characteristic_trend`, and `get_lot` tool calls, plus one two-turn same-session exchange. All
    returned HTTP 200 with non-empty `trace_id`s.
  - User confirmed the agent's service appears in the space and that opening a trace shows the
    `execute_tool` spans with `inspection.decision` on them, with no re-instrumentation.
  - No screenshots: user decided to skip them for this pass (see `design.md` decision 6).
  - _Requirements: 2.1, 2.2, 2.3, 2.4_

  Note (2026-11-26, us-west-2): domain and space created, all recommended capabilities plus the optional
  AgentCore evaluation role. 13 real invocations sent across all three personas and all three
  authorization decisions. User confirmed in the console: the agent's service is discovered and
  `execute_tool` spans carry `inspection.decision`, same as the Runbook's trace view, with zero change to
  `infra/`, `src/`, or `scripts/`. No screenshots captured, by the user's choice. Drafted in
  `docs/omni.md` §2.

- [ ] 2. [main] Create the domain and space; connect telemetry
  - User creates an Omni_Domain (choosing a sign-in domain name) and an Omni_Space in `us-west-2`,
    following AWS's own setup guide.
  - User confirms the space's Omni_Dataset discovers the agent's existing service, traces, and logs
    without any change to `infra/`, `src/`, or `scripts/`, and reports what appeared.
  - User captures a screenshot for each step to `docs/omni/` (suggested names: `01-domain.png`,
    `02-space.png`, `03-dataset.png`).
  - User checks whether AgentCore-specific spans look different from the Runbook's known quirk
    (`docs/observability.md` §10: the top span is `POST /invocations`, not
    `AgentCore.Runtime.Invoke`) and reports it.
  - Draft `docs/omni.md` section 2 from the user's report, referencing each screenshot.
  - _Requirements: 2.1, 2.2, 2.3, 2.4_

- [x] 3. [main] Reproduce the three demo queries
  - For each of `actions-by-user`, `forbidden-decisions`, and `lot-access` (`docs/observability.md` §6):
    user runs the equivalent in Omni's query/explore or natural-language-ask feature and reports whether
    it matches the Runbook's known-good answer. No screenshots (design decision 6).
  - For any query Omni cannot reproduce, record why.
  - Draft `docs/omni.md` section 3 from the user's reports.
  - _Requirements: 3.1, 3.2_

  Note (2026-11-26): user reproduced all three against the traffic generated in task 2 and reported all
  three match the Runbook's known-good answers, with no query Omni couldn't reproduce. Drafted in
  `docs/omni.md` §3.

- [x] 4. [main] Decision record
  - From tasks 2–3's results, write a one-page section in `docs/omni.md`: what Omni shows better than
    the existing trace view and dashboard, what it shows worse, and exactly one recommendation — include
    it live, show it as a screenshot only, or leave it out.
  - _Requirements: 4.1, 4.2, 4.3_

  Note (2026-11-26): written in `docs/omni.md` §4. Recommendation: screenshot/brief mention only, not a
  live second demo surface — the context switch to a second sign-in URL costs more presenter time than
  the natural-language-query convenience saves back, given the existing Runbook already covers the five
  demo questions in one place.

- [x] 5. [main] Wrap-up
  - Add the `docs/README.md` index entry for `docs/omni.md`, matching the existing one-line style.
  - Record in `docs/omni.md` that the Omni_Domain and Omni_Space are being kept (not deleted), per the
    user's choice, and that deleting them later is expected to leave every other stack unaffected since
    nothing outside Omni's own console-managed resources was touched.
  - Confirm with `git status` / `git diff` that no file under `infra/`, `src/`, or `scripts/` changed
    anywhere in this spec.
  - _Requirements: 5.1, 5.2_

  Note (2026-11-26): `docs/README.md` index entry added. `docs/omni.md` §5 records the keep decision.
  `git status --porcelain` shows only `docs/README.md` (modified), `docs/omni.md` (new), and the spec
  folder (new) — nothing under `infra/`, `src/`, or `scripts/`. Spec 15 is complete.

## Notes

- No task creates a test file, suite, fixture, eval harness, or verification script.
- Deploying or changing nothing in `infra/`, `src/`, or `scripts/` is itself part of the acceptance
  criteria (Requirement 5), not an oversight — confirm it rather than assume it.
- Task 1 is a hard gate: do not start task 2 before the account-level check in task 1 succeeds.
