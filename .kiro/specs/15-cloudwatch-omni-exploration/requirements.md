# Requirements Document

## Introduction

This feature determines whether CloudWatch Omni, AWS's newer unified observability experience, adds
value to the demo by letting a presenter explore the agent's telemetry in one place, and documents how.
It depends on spec 11 (`docs/observability.md`), which is complete: the deployed agent is instrumented
with ADOT, Transaction Search is `ACTIVE` at 100% indexing, and every request's spans and audit log lines
land in one runtime log group.

Omni spaces are created from the AWS Management Console, not CloudFormation. This feature produces
`docs/omni.md` and screenshots under `docs/omni/`; it adds nothing to `infra/`, `src/`, or `scripts/`.

Facts found while writing these requirements:

- **CloudWatch Omni is available in `us-west-2`.** It is one of 12 supported Regions. Source:
  `https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/omni-supported-regions.html`, read
  2026-11-26.
- Omni is built on existing CloudWatch data stores (log groups, metrics, X-Ray/Transaction Search
  traces) and requires **no re-instrumentation** of telemetry already being sent. Source:
  `https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch-omni.html`.
- A domain is an organization-wide sign-in entry point; a space is scoped to one AWS account and Region
  and holds one Dataset. Neither is a CloudFormation resource, the same way Transaction Search (spec 11)
  is an account-level setting outside CloudFormation.
- The user has decided to **keep** the domain/space after this issue is documented, rather than delete
  it, since it may be reused in the live demo or by other projects in the account.
- The user drives the AWS console directly (domain/space creation, connecting the dataset, running
  queries, capturing screenshots) and reports results back; nothing here is done by browser automation.

## Glossary

- **Omni_Domain**: The organization-wide CloudWatch Omni sign-in entry point, reachable at
  `https://<domain-name>.cloudwatch-omni.global.app.aws`.
- **Omni_Space**: A CloudWatch Omni space created inside the Omni_Domain, scoped to one AWS account and
  Region (`us-west-2` for this project).
- **Omni_Dataset**: The CloudWatch Dataset Omni creates per space, correlating the account's existing
  logs, metrics, and traces.
- **Runbook**: The existing document `docs/observability.md`, produced by spec 11.
- **Omni_Doc**: The new document `docs/omni.md`.
- **Demo_Queries**: The three saved Logs Insights queries documented in Runbook §6:
  `actions-by-user`, `forbidden-decisions`, `lot-access`.
- **Decision_Record**: The one-page comparison and recommendation section of Omni_Doc.

## Requirements

### Requirement 1: Availability check

**User Story:** As the person deciding whether to spend further time on this issue, I want the
availability question answered first and time-boxed, so that no further work happens if Omni turns out
to be unusable in this account.

#### Acceptance Criteria

1. THE Omni_Doc SHALL state the Region (`us-west-2`), the date, and whether CloudWatch Omni is available
   and usable in the account, citing the AWS documentation consulted.
2. IF Omni is not available or not usable in the account, THEN the Omni_Doc SHALL record the finding and
   no further requirement in this document SHALL be pursued.
3. THE availability check SHALL be time-boxed to one hour of work.

### Requirement 2: Domain, space, and dataset

**User Story:** As a presenter, I want to see the demo's existing telemetry appear in an Omni space
without changing any instrumentation, so that I can judge whether the unified view is worth showing.

#### Acceptance Criteria

1. WHEN Requirement 1 confirms Omni is usable, THE user SHALL create an Omni_Domain and an Omni_Space in
   `us-west-2`.
2. THE Omni_Doc SHALL describe each setup step narratively, from the user's own report of what they did
   and saw. Screenshots are not required: the user decided to skip them for this pass, given the issue's
   "extra, second item to cut" priority. If one is ever added later, it goes under `docs/omni/`.
3. THE Omni_Doc SHALL record which data sources the Omni_Dataset attached (the runtime log group, its
   spans, its metrics) and SHALL record any gap, including whether AgentCore-specific spans appear
   differently than in the Runbook's trace view.
4. THE setup SHALL NOT require any change to `infra/`, `src/`, or `scripts/`.

### Requirement 3: Demo queries

**User Story:** As a presenter, I want to know whether the three saved demo queries work in Omni, so
that I don't discover a gap live.

#### Acceptance Criteria

1. THE Omni_Doc SHALL show the result of reproducing each of the three Demo_Queries in Omni, or SHALL
   state why that query is not possible there.
2. WHERE a Demo_Query result differs from the Runbook's known-good result, THE Omni_Doc SHALL record the
   difference.

### Requirement 4: Decision record

**User Story:** As the person planning the live demo, I want a clear recommendation, so that I don't
have to re-derive the comparison myself.

#### Acceptance Criteria

1. THE Decision_Record SHALL state what Omni shows better than the Runbook's trace view and dashboard.
2. THE Decision_Record SHALL state what Omni shows worse or not at all.
3. THE Decision_Record SHALL contain exactly one recommendation: include Omni in the live demo, show it
   as a screenshot only, or leave it out.

### Requirement 5: Non-interference

**User Story:** As the owner of the other demo stacks, I want this exploration to be fully additive, so
that nothing here can break the rest of the demo.

#### Acceptance Criteria

1. THE repository SHALL show no change under `infra/`, `src/`, or `scripts/` as a result of this feature.
2. WHEN the Omni_Space or Omni_Domain is deleted at any future point, THE other stacks SHALL be
   unaffected, because nothing outside Omni's own console-managed resources was touched.

Out of scope: infrastructure as code for Omni, alarms, cost allocation, and operating the AWS console by
browser automation.
