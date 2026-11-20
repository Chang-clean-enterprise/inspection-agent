# Model access spike: decision record

| Field | Value |
|---|---|
| GitHub issue | #2 |
| Spike date | 2026-11-20 |
| Start time | 2026-11-20T05:12:43Z |
| Total time | 1 h 7 min (stop time 2026-11-20T06:20:21Z) |
| Within the 3 h time-box | Yes |
| Base_Commit | `52e8760153da49ccb543505a170e3f453f1e8f16` |
| Calling Region | `us-west-2` |
| AWS profile | `<AWS_PROFILE>` |
| Account | `<ACCOUNT_ID>` |
| Developer role | Administrator role (AdministratorAccess permission set through IAM Identity Center) |

Scope decisions by the user, made during the spike:

1. **Lightweight scope.** The spike covers access and Verified_Calls, inference profile listing and Destination_Regions, quotas, residency, and this record. The local Strands harness, the 10-run latency measurements, and the reasoning-settings comparison with quality judgment were deferred. Reason: shell AWS calls were blocked by a sandbox rule, so all AWS calls went through the AWS MCP server (`run_script` with boto3), and the local harness is to be run by the user later.
2. **Candidate change.** Claude Sonnet 5.5 (US and global profiles) and Claude Haiku 5.5 returned `AccessDeniedException` "not available for this account" for every call in us-west-2. The user switched to Claude Haiku 4.5 as the default and Claude Sonnet 4.6 as the fallback. See [Rejected candidates](#rejected-candidates).

All calls used an administrator role. Runtime IAM actions are therefore "from documentation" and were not proven under least privilege. The spike made no account-level changes (no form submitted, no agreement created, no quota increase requested).

## Decision

| Choice | Value | Reason | Supporting finding |
|---|---|---|---|
| Default model ID | `us.anthropic.claude-haiku-4-5-20251001-v1:0` (Claude Haiku 4.5) | It has a Verified_Call from us-west-2 (non-empty output, 2026-11-20). The model card describes it as a lightweight model optimized for speed and efficiency, which suits the 15 s Latency_Target. Its US profile routes only to US Regions. Its latency was not measured (see Open items). | [Model access](#model-access), [Candidates and inference profiles](#candidates-and-inference-profiles) |
| Fallback model ID | `us.anthropic.claude-sonnet-4-6` (Claude Sonnet 4.6) | It has a Verified_Call from us-west-2 (non-empty output, 2026-11-20). The model card describes it as a full upgrade of Anthropic's mid-tier model with better coding, long-context reasoning, and agent planning, so it is more capable than the default and is the choice if the default's answer quality is not good enough. | [Model access](#model-access), [Candidates and inference profiles](#candidates-and-inference-profiles) |
| Inference_Profile ID | `us.anthropic.claude-haiku-4-5-20251001-v1:0` (US geographic profile) | The US profile's Destination_Regions are confirmed through the Bedrock API (us-east-1, us-east-2, us-west-2), so requests stay in US Regions. The global profile's Destination_Regions are not confirmed through the API (it returns a Region-less ARN). Quotas for the US and global profiles are identical in this account (RPM applied 50, TPM 5,000,000), so quotas do not favor either. | [Data residency](#data-residency), [Quotas](#quotas), [Candidates and inference profiles](#candidates-and-inference-profiles) |
| Reasoning_Settings | Model default: no reasoning fields sent (extended thinking off for Claude Haiku 4.5) | Chosen from documentation only. The comparison of reasoning configurations was deferred, so no latency or quality evidence supports this choice. Strands has no named reasoning parameter; reasoning would be set through `additional_request_fields`. The Claude Haiku 4.5 model card says only that reasoning is "Supported" and gives no default, so the "off" default is unconfirmed. | [Reasoning settings](#reasoning-settings) |

Notes on the decision:

- The user made the candidate choice after the Claude 5.5 models were denied. The rejected models and their evidence are in [Rejected candidates](#rejected-candidates).
- Requirement 7.4 (latency proposal changes the default): not applicable. The default's p50 was not measured, so criterion 3.6 cannot be evaluated. The decision above is not a replacement of another configuration.
- Requirement 7.5 (no Candidate has a Verified_Call): not applicable. All three Candidates have a Verified_Call (see [Model access](#model-access)).
- The decision feeds the `ModelId` parameter of the runtime stack (issue #9).

## Open items and follow-ups

| # | Item | Responsible role | Source criterion |
|---|---|---|---|
| 1 | Confirm the 15 s Latency_Target with the presenter. Status: not confirmed. | Presenter | 3.7, 7.6 |
| 2 | Reason: deferred by the user: shell AWS calls blocked by sandbox; local harness to be run by the user later. Run the deferred local harness: 10 measured Runs per Candidate (latency, tokens, tool-call counts), reasoning-settings comparison, and answer quality for Demo_Questions 1 to 5. Also record throttled-request counts and the retry behavior of the harness. Then re-check the decision, and apply the latency proposal if the default's p50 exceeds 15 s. | Developer | 3.1 to 3.6, 3.8, 3.9, 4.1 to 4.4, 4.6 to 4.8, 4.10, 5.5, 5.7 |
| 3 | Raise the requests-per-minute quota for Claude Haiku 4.5 (US profile), code `L-CCA5DF70`. Applied 50, estimated peak 108 (unmeasured estimate). Minimum 135, suggested request 150. Alternative: restore the AWS default of 10,000. | Account administrator | 5.4 |
| 4 | Raise the requests-per-minute quota for Claude Sonnet 4.6 (US profile), code `L-00FF3314`. Applied 50, estimated peak 67.5 (unmeasured estimate). Minimum 85, suggested request 100. Alternative: restore the AWS default of 10,000. | Account administrator | 5.4 |
| 5 | Find out why applied requests-per-minute quotas are 50 (AWS default is 10,000) for all four Haiku 4.5 and Sonnet 4.6 quotas (US and global). The reason is unknown. | Account administrator | 5.2 |
| 6 | Re-run the quota calculation with measured p50, mean model requests per Run, and mean input and output tokens per request. | Developer | 5.3 |
| 7 | Confirm the output-token burndown rate for Claude Haiku 4.5 and Claude Sonnet 4.6. The estimate uses 5x from the burndown page's "version 4.7 and below" class. Neither model is named on that page. | Developer | 5.3 |
| 8 | Confirm the Destination_Regions of the global profile `global.anthropic.claude-haiku-4-5-20251001-v1:0`. The API returned a Region-less ARN plus us-west-2, so its processing Regions are unverified. Not needed for the chosen profile. | Developer | 2.8, 6.1, 6.7 |
| 9 | Confirm the AWS Marketplace subscription state. `agreementAvailability` stayed `NOT_AVAILABLE` before and after successful calls, so the field does not show whether a subscription exists. Check the Bedrock console model catalog or AWS Marketplace subscriptions. | Account administrator | 1.5 |
| 10 | Confirm the IAM action name for the Anthropic first-time-use form (`PutUseCaseForModelAccess` API; the IAM action name was not checked in the Service Authorization Reference). Also confirm who submitted the form and when. A use case is on file; its content and time were not read. | Account administrator | 1.6, 1.7 |
| 11 | Test the runtime IAM policy under a least-privilege role. All runs used an administrator role. | Developer | 1.7 |
| 12 | Confirm the Claude Haiku 4.5 default Reasoning_Settings (effort or thinking default, and the thinking parameters) from the AWS extended thinking documentation. The model card gives none. | Developer | 4.2, 4.9 |
| 13 | Change the Root_README prerequisite wording (conflict C6). Current wording: "Amazon Bedrock model access enabled for Claude models in `us-west-2`". In commercial Regions there is no model access request page. Suggested replacement: "Amazon Bedrock access to the chosen Claude model in `us-west-2`. In commercial Regions there is no model access request page. For Anthropic models earlier than Claude Opus 4.7 (for example Claude Haiku 4.5), an administrator submits the Anthropic first-time-use form once per account. The first invocation then starts an AWS Marketplace subscription, so the calling role needs `aws-marketplace:Subscribe`, `aws-marketplace:ViewSubscriptions`, and `aws-marketplace:Unsubscribe`, and the account needs a valid payment method. See `docs/spikes/model-access.md`." The README was not edited in this spike. | Developer | 7.6 |
| 14 | Optional: ask AWS Sales or the account administrator why Claude Sonnet 5.5 and Claude Haiku 5.5 are "not available for this account", if those models are wanted later. | Account administrator | 7.9 |
| 15 | Done. Final stop time and total time re-checked after task 12.1: stop 2026-11-20T06:20:21Z, total 1 h 7 min, within the 3 h time-box (matches the metadata table). | Developer | 7.7 |
| 16 | Every unmet acceptance criterion in the next section is an open item. Items 2, 3, 4, 6, 7, and 12 cover the deferred measurements and unconfirmed values. | Developer | 7.8 |

## Unmet acceptance criteria

Reason "deferred": deferred by the user: shell AWS calls blocked by sandbox; local harness to be run by the user later.

| Criterion | Reason |
|---|---|
| 3.1 | Deferred. No p50, p95, or run count: no Run was executed. |
| 3.2 | Deferred. No measured Runs. |
| 3.3 | Deferred. No Time_To_Final_Answer or token means measured. |
| 3.4 | Deferred. No tool-call counts measured. |
| 3.5 | Deferred. No error, timeout, or wrong-tool-call counts measured. |
| 3.6 | Deferred. It cannot be evaluated because latency was not measured. |
| 3.8 | Deferred (partly). The planned method is described in [Measurement method](#measurement-method), but no Run followed it, so it was not repeated or checked by hand. |
| 3.9 | Deferred (partly). The planned items are described, but no Run happened, so the Strands and Python versions and the warm-up count do not apply yet. |
| 4.1 | Deferred. The Strands exposure is taken from documentation only; no Strands version was used in a Measurement_Run. |
| 4.2 | Not met. The Claude Haiku 4.5 default reasoning settings are unconfirmed (the model card says only "Supported"). Marked unconfirmed under 4.9. |
| 4.3 | Deferred. No configuration was measured. |
| 4.4 | Deferred. No answer was judged for Demo_Questions 1 to 5. |
| 4.6 | Deferred. No Run approximated Demo_Questions 4 and 5. |
| 4.7 | Deferred. The chosen Reasoning_Settings is the model default from documentation, not a measured configuration. |
| 4.8 | Deferred. No Measurement_Run passed a reasoning setting; the planned method (`additional_request_fields`) comes from the Strands documentation. |
| 4.10 | Deferred. It cannot be evaluated without measured configurations. |
| 5.3 (measured parts) | Deferred. The Target_Load estimate uses assumed p50, model requests per Run, and tokens, labelled "unmeasured estimate" in [Quotas](#quotas). |
| 5.5 (measured part) | Deferred. Throttled-request counts per Candidate are "not measured". No throttling occurred in the three Verified_Calls. |
| 5.7 (measured part) | Deferred. The retry behavior of a Measurement_Run cannot be stated because none ran. |
| 1.5 (part) | Not met for the Marketplace subscription state. The API field `agreementAvailability` stayed `NOT_AVAILABLE` while calls succeeded, so "subscription required" is unconfirmed. See open item 9. |
| 6.1 and 6.7 (Global_Candidate) | Handled, not met: the Global_Candidate's processing Regions are marked unverified. See open item 8. |

Criteria 3.7 and 3.10 and criteria 4.5 and 4.9 are not listed as unmet. They are addressed in the sections that 11.2 and 11.3 write (Latency_Target status, synthetic Representative_Prompt, criteria per question, and the unconfirmed default).

Final repository checks (8.1 and 8.2) run in task 12.1 and are not part of this list.

## Candidates and inference profiles

The Default_Candidate and Fallback_Candidate were chosen by the user after the Claude 5.5 models were denied (see [Rejected candidates](#rejected-candidates)). **The Global_Candidate is an assumption.** The comparison it supports is "same model as the default, through the global profile". The user did not ask for it by name.

All profile data was read from `us-west-2` on 2026-11-20 (UTC), through the AWS MCP server (see [Measurement method](#measurement-method)). Listed IDs are copied character for character from the listing and are used everywhere in this record (Requirement 2.3).

### Listing

Operation: Bedrock `ListInferenceProfiles` with `typeEquals=SYSTEM_DEFINED` in `us-west-2`. It returned 106 profiles in one auto-paginated result with no `nextToken` left. The filter to Claude Haiku 4.5 and Claude Sonnet 4.6 ran in the script. Equivalent CLI:

```bash
aws bedrock list-inference-profiles --region us-west-2 --type-equals SYSTEM_DEFINED --profile <AWS_PROFILE>
```

| Role | Model | Profile scope | Expected ID | Listed profile ID | Differs from expected | Status | Listing date |
|---|---|---|---|---|---|---|---|
| Default_Candidate | Claude Haiku 4.5 | US geographic | prefix `us.anthropic.claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Yes: suffix `-20251001-v1:0` added | ACTIVE (SYSTEM_DEFINED) | 2026-11-20 |
| Global_Candidate (assumption) | Claude Haiku 4.5 | Global | prefix `global.anthropic.claude-haiku-4-5` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Yes: same suffix added | ACTIVE (SYSTEM_DEFINED) | 2026-11-20 |
| Fallback_Candidate | Claude Sonnet 4.6 | US geographic | prefix `us.anthropic.claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` | No | ACTIVE (SYSTEM_DEFINED) | 2026-11-20 |

All three Candidates were found, so Requirement 2.7 ("not found") does not apply. The listing also shows `global.anthropic.claude-sonnet-4-6` (ACTIVE). It is not a Candidate.

### Routing (Destination_Regions)

Operation: Bedrock `GetInferenceProfile`, once per Candidate, in `us-west-2`, read on 2026-11-20 (UTC). Each call succeeded and returned the requested ID. Equivalent CLI:

```bash
aws bedrock get-inference-profile --region us-west-2 --inference-profile-identifier <PROFILE_ID> --profile <AWS_PROFILE>
```

| Role | Profile ID | Destination_Regions | Foundation model ARNs returned |
|---|---|---|---|
| Default_Candidate | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | us-east-1, us-east-2, us-west-2 (confirmed by the API) | `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0`, `arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0`, `arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0` |
| Global_Candidate (assumption) | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | **Unconfirmed.** The response has a Region-less ARN, so the API does not list the full Region set. Not filled from documentation (Requirement 2.8). | `arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0`, `arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0` |
| Fallback_Candidate | `us.anthropic.claude-sonnet-4-6` | us-east-1, us-east-2, us-west-2 (confirmed by the API) | `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6`, `arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6`, `arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6` |

A second read of the three profiles gave identical IDs and Regions. The Global_Candidate's processing Regions stay open (open item 8).

### Why Claude Sonnet 4.6 is the fallback

The fallback is a larger, more capable model, to use if the default's answer quality is not good enough. The [Claude Sonnet 4.6 model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html) (accessed 2026-11-20) describes it as a full upgrade of Anthropic's mid-tier model with better coding, long-context reasoning, and agent planning, and a 1M-token context window. The [Claude Haiku 4.5 model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html) (accessed 2026-11-20) describes the default as a lightweight model optimized for speed and efficiency. Whether the fallback gives better answers in this demo was not measured (answer quality was deferred).

### Rejected candidates

These candidates were the original choices. Every `Converse` call to them in `us-west-2` failed with `AccessDeniedException` "... is not available for this account". The user then replaced them (Requirement 7.9). The calls, messages, and steps are in the [Failure log](#failure-log).

| Model | Profile ID | Reason | Date | Evidence |
|---|---|---|---|---|
| Claude Sonnet 5.5 (US) | `us.anthropic.claude-sonnet-5-5` | `AccessDeniedException` "anthropic.claude-sonnet-5-5 is not available for this account." 3 attempts. `agreementAvailability` stayed `NOT_AVAILABLE` and did not change. | 2026-11-20 | [Failure log](#failure-log) |
| Claude Sonnet 5.5 (global) | `global.anthropic.claude-sonnet-5-5` | Same error and message as the US profile (same base model). 3 attempts. `agreementAvailability` unchanged. | 2026-11-20 | [Failure log](#failure-log) |
| Claude Haiku 5.5 (US) | `us.anthropic.claude-haiku-5-5` | `AccessDeniedException` "anthropic.claude-haiku-5-5 is not available for this account." 3 attempts. `agreementAvailability` unchanged. | 2026-11-20 | [Failure log](#failure-log) |

For all three, the profiles were listed as ACTIVE, and the availability fields showed `authorizationStatus` `AUTHORIZED`, `entitlementAvailability` `AVAILABLE`, `regionAvailability` `AVAILABLE`, and `agreementAvailability` `NOT_AVAILABLE`. The same four values came back for the working Claude Haiku 4.5 and Claude Sonnet 4.6, so these fields do not predict whether a call succeeds. The cause of the denial is unknown (open item 14).

## Model access

### Verified calls

A call counts as verified when it returns without error and the returned text is non-empty. Each Candidate had one attempt on 2026-11-20 (about 05:58 UTC), with no error and no retry. Operation: Bedrock Runtime `Converse` in `us-west-2`, with `maxTokens` 32. The call ran through the AWS MCP server's boto3 (not the shell). Equivalent CLI:

```bash
aws bedrock-runtime converse --region us-west-2 --model-id <PROFILE_ID> \
  --messages '[{"role":"user","content":[{"text":"Reply with the single word OK."}]}]' \
  --inference-config maxTokens=32 --profile <AWS_PROFILE>
```

| Candidate | Profile ID | Verified_Call | Attempt date | Operation and command | Non-empty model output | Stop reason | Input tokens | Output tokens | Total tokens |
|---|---|---|---|---|---|---|---|---|---|
| Default_Candidate | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Yes | 2026-11-20 | `Converse`, command above with `<PROFILE_ID>` filled in | Yes | `end_turn` | 14 | 4 | 18 |
| Global_Candidate (assumption) | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Yes | 2026-11-20 | Same | Yes | `end_turn` | 14 | 4 | 18 |
| Fallback_Candidate | `us.anthropic.claude-sonnet-4-6` | Yes | 2026-11-20 | Same | Yes | `end_turn` | 14 | 4 | 18 |

Total token usage across the three calls: 42 input, 12 output, 54 total. Latency of these calls was not recorded as a measurement. No form was submitted, no agreement was created, and no write API was called. The three calls ran under an administrator role.

### Access prerequisites

These steps apply to all three Candidates, in fresh-account order. The two Claude Haiku 4.5 Candidates share one model; Claude Sonnet 4.6 is a second model. Sources: [Request access to Amazon Bedrock models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) and [Global cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html) (both accessed 2026-11-20).

1. **Account administrator:** Attach an IAM policy with `aws-marketplace:Subscribe`, `aws-marketplace:ViewSubscriptions`, and `aws-marketplace:Unsubscribe` to the role that makes the first invocation. Not isolated in the spike (the role was an administrator role).
2. **Account administrator:** Make sure the account has a valid payment method for AWS Marketplace purchases. Not checked in the spike.
3. **Account administrator:** Submit the Anthropic first-time-use form once per account (or once at the Organization management account, from which member accounts inherit it). The documentation says it applies to Anthropic models earlier than Claude Opus 4.7 and names Claude Haiku 4.5 and Claude Sonnet 4.6. The console path is the Anthropic provider page or the model catalog. The API is `PutUseCaseForModelAccess`. In this account a use case is on file (`GetUseCaseForModelAccess` returned one; content and time were not read). Who submitted it and when is unknown, because the spike never submitted the form.
4. **Account administrator, or a Developer holding the permissions from step 1:** Marketplace subscription. In commercial Regions there is no model access request page. According to the documentation, Bedrock starts the subscription on the first invocation, which can take up to 15 minutes. Each model has one Marketplace offer (see below). The subscription state in this account is not confirmed.
5. **Developer:** Grant the runtime IAM permissions (see [Runtime IAM](#runtime-iam)) to the role that runs the agent. The documentation says that once the model is enabled in the account, other roles can invoke it without the Marketplace permissions. Not tested under least privilege.
6. **Developer:** Invoke each Candidate once with `Converse` in `us-west-2` to confirm access. Done for all three Candidates (see [Verified calls](#verified-calls)).

If an `AccessDeniedException` persists after these steps, the documentation says to contact AWS Sales. That is what happened for the [Rejected candidates](#rejected-candidates).

### Marketplace subscription

Read on 2026-11-20 (UTC), `us-west-2`, all read-only, through the AWS MCP server's boto3. Equivalent CLI:

```bash
aws bedrock get-foundation-model-availability --region us-west-2 --model-id <MODEL_ID> --profile <AWS_PROFILE>
aws bedrock list-foundation-model-agreement-offers --region us-west-2 --model-id <MODEL_ID> --profile <AWS_PROFILE>
aws bedrock get-use-case-for-model-access --region us-west-2 --profile <AWS_PROFILE>
```

| Candidate | Base model ID | Marketplace offer | `agreementAvailability.status` | `authorizationStatus` | `entitlementAvailability` | `regionAvailability` | Subscription required |
|---|---|---|---|---|---|---|---|
| Default_Candidate | `anthropic.claude-haiku-4-5-20251001-v1:0` | 1 offer, with usage-based pricing terms | `NOT_AVAILABLE` | `AUTHORIZED` | `AVAILABLE` | `AVAILABLE` | Not confirmed |
| Global_Candidate (assumption) | `anthropic.claude-haiku-4-5-20251001-v1:0` (same model) | Same | `NOT_AVAILABLE` | `AUTHORIZED` | `AVAILABLE` | `AVAILABLE` | Not confirmed |
| Fallback_Candidate | `anthropic.claude-sonnet-4-6` | 1 offer, with usage-based pricing terms | `NOT_AVAILABLE` | `AUTHORIZED` | `AVAILABLE` | `AVAILABLE` | Not confirmed |

What was found, and what was not:

- Each model has a Marketplace offer, so the models are Marketplace-backed. `ListFoundationModelAgreementOffers` returned one offer per model, with usage-based pricing, legal, and support terms. The response has no offer-type field.
- `agreementAvailability.status` was `NOT_AVAILABLE` before the Verified_Calls and still `NOT_AVAILABLE` after them, while the calls succeeded. The field therefore does not show whether this account holds a subscription. The rejected models returned the same value and were denied.
- The first call to each Candidate succeeded at once. No agreement was visible at any point. Whether a Marketplace subscription is required, and whether one exists in this account, is **not confirmed**. Open item 9 covers the check (Bedrock console model catalog or AWS Marketplace subscriptions).
- The Anthropic first-time-use form applies to these models according to the documentation, and `GetUseCaseForModelAccess` confirms a use case is on file. It is not a blocker here.
- `PutUseCaseForModelAccess`, `CreateFoundationModelAgreement`, and every other write API were not called.

### One-time setup IAM

These actions are performed once per account by an administrator. The resource scope for the `aws-marketplace` actions was not checked (the documentation page lists only the action names).

| Action | Purpose | Status |
|---|---|---|
| `aws-marketplace:Subscribe` | Start the Marketplace subscription on the first invocation | From documentation ([Request access to Amazon Bedrock models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)). The spike role was an administrator role, so the need was not isolated. |
| `aws-marketplace:ViewSubscriptions` | View subscription state during automatic enablement | From documentation (same page) |
| `aws-marketplace:Unsubscribe` | Listed by AWS with the other two as required for model access | From documentation (same page) |
| `bedrock:PutUseCaseForModelAccess` | Submit the Anthropic first-time-use form (API: [PutUseCaseForModelAccess](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_PutUseCaseForModelAccess.html)) | From documentation. Not exercised, because the spike never submitted the form. The IAM action name was not checked in the Service Authorization Reference (open item 10). |
| `bedrock:GetUseCaseForModelAccess`, `bedrock:GetFoundationModelAvailability`, `bedrock:ListFoundationModelAgreementOffers` | Read-only checks | Exercised under an administrator role. The IAM action names are assumed equal to the API names and were not verified. |

The design's expected rows (the three `aws-marketplace` actions) were not contradicted by the spike. The spike also did not prove them.

### Runtime IAM

Every row below is **from documentation**. The calls succeeded under an administrator role, so least-privilege scoping was not tested (open item 11). Actions for all rows: `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`.

| Candidate | Resource ARN pattern | Status |
|---|---|---|
| Default_Candidate | `arn:aws:bedrock:us-west-2:<ACCOUNT_ID>:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0` | From documentation, by analogy with the global profile page. The ARN patterns come from the `GetInferenceProfile` responses (exercised). A US-profile-specific IAM page was not read. |
| Default_Candidate | `arn:aws:bedrock:<DESTINATION_REGION>::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0` for `<DESTINATION_REGION>` in us-east-1, us-east-2, us-west-2 | Same |
| Fallback_Candidate | `arn:aws:bedrock:us-west-2:<ACCOUNT_ID>:inference-profile/us.anthropic.claude-sonnet-4-6` | Same |
| Fallback_Candidate | `arn:aws:bedrock:<DESTINATION_REGION>::foundation-model/anthropic.claude-sonnet-4-6` for `<DESTINATION_REGION>` in us-east-1, us-east-2, us-west-2 | Same |

Global_Candidate (assumption): the [Global cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html) page describes a policy in three parts. Its example shows only `bedrock:InvokeModel`. Adding `bedrock:InvokeModelWithResponseStream` is an inference from the streaming path that Strands uses, not from the page. The Region-less ARN in part 3 is needed because the Destination_Regions are unconfirmed.

| Part | Resource ARN | Condition | Status |
|---|---|---|---|
| 1 | `arn:aws:bedrock:us-west-2:<ACCOUNT_ID>:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0` | `aws:RequestedRegion` equals `us-west-2` | From documentation |
| 2 | `arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0` | `aws:RequestedRegion` equals `us-west-2` and `bedrock:InferenceProfileArn` equals the ARN in part 1 | From documentation |
| 3 | `arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0` | `aws:RequestedRegion` equals `unspecified` and `bedrock:InferenceProfileArn` equals the ARN in part 1 | From documentation |

The README prerequisite wording (conflict C6) is outdated. See open item 13 for the suggested replacement.

### Failure log

Only the rejected candidates failed. Operation for every attempt: Bedrock Runtime `Converse` in `us-west-2` with `maxTokens` 32 and the prompt "Reply with the single word OK." (same command as in [Verified calls](#verified-calls)). Date: 2026-11-20 (UTC). The error messages contain no account values, so nothing needed redaction. No other model or profile was tried, and no write API was called.

Error text, with the trailing sentences shortened: "anthropic.claude-sonnet-5-5 is not available for this account" (Sonnet 5.5 profiles) and "anthropic.claude-haiku-5-5 is not available for this account" (Haiku 5.5). Both are followed by a pointer to other available models and to AWS Sales. The message does not mention a subscription, an agreement, or an `aws-marketplace` permission.

| Candidate | Attempt | Time (UTC, approximate) | Error code | Step taken | Still eligible |
|---|---|---|---|---|---|
| `us.anthropic.claude-sonnet-5-5` | 1 | about 05:2x | `AccessDeniedException` | Rechecked `GetFoundationModelAvailability` | Unresolved, not verified |
| `us.anthropic.claude-sonnet-5-5` | 2 | about 05:36 | `AccessDeniedException` | Waited about 100 s, retried | Unresolved, not verified |
| `us.anthropic.claude-sonnet-5-5` | 3 | about 05:41 | `AccessDeniedException` | Waited about 290 s, retried, rechecked availability (still `NOT_AVAILABLE`) | Unresolved, not verified |
| `global.anthropic.claude-sonnet-5-5` | 1 to 3 | same as above | `AccessDeniedException` (same message) | Same three steps | Unresolved, not verified |
| `us.anthropic.claude-haiku-5-5` | 1 to 3 | same as above | `AccessDeniedException` (same message) | Same three steps | Unresolved, not verified |

Outcome: `agreementAvailability` stayed `NOT_AVAILABLE` for both base models, so the failed invocations did not start an agreement. No `aws-marketplace` permission error appeared. The three candidates were replaced by the user's decision and are not eligible for this decision. Whether the denial can be lifted (for example by AWS Sales or an account administrator) is open item 14. No token usage occurred.

## Measurement method

### How the listings and Verified_Calls were made

- Every AWS call in this spike (listings, profile reads, availability and agreement reads, quota reads, and `Converse`) went through the AWS MCP server tool `run_script`, which runs Python with `call_boto3(service_name, operation_name, region_name, params)`. The Region was `us-west-2` in every call.
- Reason: shell AWS calls were blocked by a sandbox rule on credential reads. The MCP tool cannot select a named profile.
- The user confirmed that the MCP server's credentials belong to the intended account, with the AdministratorAccess permission set (IAM Identity Center). The profile appears in this record only as `<AWS_PROFILE>` and the account only as `<ACCOUNT_ID>`.
- Scripts removed or replaced account values before returning output. The boto3 version was not returned by the MCP tool, so it is not recorded.
- The CLI commands in this record are the equivalent commands with placeholders. They were not run in a shell.

### Deferred harness design

The local Strands harness was deferred by the user (see the scope decisions at the top). No Run followed this design. It is recorded so the user can run it later.

- **Where it would run:** on the user's machine, in a folder made with `mktemp -d` outside the repository, using the named profile in a shell where `AWS_PROFILE`, `AWS_REGION`, and `AWS_DEFAULT_REGION` are set (`us-west-2`).
- **Models and settings:** the three Candidates above. Reasoning_Settings: model defaults (no `additional_request_fields`) for latency. `max_tokens` is 4096. botocore `read_timeout` is 120 seconds with one attempt, so throttling reaches Strands.
- **Agent:** a fresh Strands `Agent` per Run with the three Stub_Tools registered for every Run, so the tool list and its input tokens are identical. `callback_handler=None`.
- **Timing definition:** Time_To_Final_Answer is the time from just before the call `agent(prompt)` to just after it returns the final answer, measured with `time.perf_counter()` on the local machine. A Run with no final answer within 120 seconds counts as a timeout.
- **Warm-up:** 1 warm-up Run per Candidate, discarded and not counted. Then 10 measured Runs per Candidate, one at a time.
- **Percentiles:** nearest-rank p50 and p95 over the Runs that returned a final answer within 120 seconds. Error and timeout Runs are replaced by extra Runs, which the record would state.
- **Other counts:** tool calls per Run (expected: exactly two, in sequence), model requests, input, output, and total tokens, errors, timeouts, and throttled requests (messages containing `ThrottlingException` or `ModelThrottledException`, including requests that later succeeded).

Representative_Prompt (synthetic, no Demo_Question wording; the questions are referred to by number and defined in [`.kiro/steering/product.md`](../../.kiro/steering/product.md)):

```text
On production line LINE-A, find the inspection report for part P-1001 dated 2026-03-02,
then check characteristic BORE-DIA on that report. Are all measured values within tolerance?
Answer with the report ID and any out-of-tolerance values.
```

The second tool call needs the report ID from the first, so the expected pattern is exactly two sequential tool calls.

Stub_Tools (all outputs are fixed and synthetic; the tools never take a user identity as an argument, and the line for the signed-in user is a constant in the harness):

| Tool | Input that matches | Fixed output |
|---|---|---|
| `list_inspection_reports` | `line = "LINE-A"`, any part and dates | `{"reports": [{"report_id": "RPT-0301", "part_number": "P-1001", "date": "2026-03-01", "lot_id": "LOT-A17"}, {"report_id": "RPT-0302", "part_number": "P-1001", "date": "2026-03-02", "lot_id": "LOT-A17"}, {"report_id": "RPT-0305", "part_number": "P-1001", "date": "2026-03-05", "lot_id": "LOT-A18"}]}` |
| `list_inspection_reports` | any other line | `{"status": "denied", "reason": "The signed-in user is not allowed to read data for this line."}` |
| `get_measurements` | `RPT-0302`, `BORE-DIA` | `{"characteristic": "BORE-DIA", "unit": "mm", "nominal": 12.000, "lower_limit": 11.980, "upper_limit": 12.020, "values": [12.004, 12.011, 12.023, 11.996]}` (one value above the upper limit) |
| `get_measurements` | `RPT-0301` and `RPT-0305`, `BORE-DIA` | Same shape, with values chosen so the three reports show a rising mean. The values are chosen when the harness is written and were not chosen in this spike. |
| `get_lot_findings` | `LOT-A17` | `{"lot_id": "LOT-A17", "findings": [{"report_id": "RPT-0302", "characteristic": "BORE-DIA", "result": "out_of_tolerance", "value": 12.023}, {"report_id": "RPT-0301", "characteristic": "SURF-RA", "result": "pass"}]}` |
| any tool | any other input | `{"status": "not_found"}` |

The Strands Agents, Python, and botocore versions are not recorded because no harness was installed.

**Harness code statement (Requirement 8.9):** any harness code is local, throwaway, and not committed. It lives outside the repository and is deleted at the end of the work. This spike added no harness file to the repository.

## Latency results

The 10-run latency measurements were **deferred by the user**. Reason: shell AWS calls were blocked by a sandbox rule, so the local harness could not be run in this session. The user will run it later. No Run was executed, so this record has no p50, p95, mean token count, tool-call count, error count, or timeout count for any Candidate. Per-Run tables will be added here only if the user runs the harness.

Latency_Target: **15 seconds** to the final answer. This is a target to validate with the presenter. Status: **not confirmed** (open item 1).

Requirement 3.6 (does the default's p50 meet the target, and if not, propose a change) **cannot be evaluated**, because no latency was measured. The default was therefore chosen without latency evidence (see [Decision](#decision)). The three Verified_Calls were single short calls and are not a latency measurement.

## Reasoning settings

**Status:** the comparison of reasoning configurations is **deferred by the user** (reason: shell AWS calls blocked by sandbox; local harness to be run by the user later). This section records the documented mechanism and defaults only. No latency, token, or quality figure exists for any reasoning configuration.

### How Strands passes reasoning settings

- The Strands `BedrockModel` class has **no named parameter** for any reasoning setting (Requirement 4.8). Reasoning is passed through the generic `additional_request_fields` parameter, which `BedrockModel` sends to the Converse API as `additionalModelRequestFields`.
- Source: [Strands Agents: Amazon Bedrock model provider, "Reasoning support"](https://strandsagents.com/latest/documentation/docs/user-guide/concepts/model-providers/amazon-bedrock/) (accessed 2026-11-20). The page shows Claude models taking `thinking` (adaptive, or `enabled` with `budget_tokens`) and, for adaptive thinking, depth set through `output_config.effort`. It lists Claude Haiku 4.5 among the models that take `thinking: {"type": "enabled", "budget_tokens": N}` instead of adaptive thinking.
- **Strands version caveat:** no Strands Agents version was installed or used in this spike, because no harness ran. The statements above come from the current documentation page, not from a library source file or a Measurement_Run. The version that matches them is unknown (Requirements 4.1 and 4.8 are deferred; see [Unmet acceptance criteria](#unmet-acceptance-criteria)).
- No Measurement_Run passed a reasoning setting. The planned method is `BedrockModel(model_id=<PROFILE_ID>, additional_request_fields={...})`.

| Setting | Strands parameter | Allowed values (from AWS documentation) | Value when not set | Source |
|---|---|---|---|---|
| Thinking type | `additional_request_fields["thinking"]["type"]` | Claude Haiku 4.5: `enabled` (with `budget_tokens`). Claude Sonnet 4.6: `adaptive`, `disabled`, or `enabled` with `budget_tokens` (deprecated). | Strands sends nothing (it has no default for this field, according to the Strands page; the library source was not read). Bedrock then applies the model default (next table). | Strands page above; [Adaptive thinking](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-adaptive-thinking.html) and [Extended thinking](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html) (both accessed 2026-11-20) |
| Thinking budget | `additional_request_fields["thinking"]["budget_tokens"]` | A token budget, used with `enabled`. The allowed range was not read. | Not applicable when thinking is not enabled | Extended thinking page above |
| Reasoning effort | `additional_request_fields["output_config"]["effort"]` | Adaptive thinking page: `max` is supported on Claude Sonnet 4.6. Per-model support of `low`, `medium`, and `high` for Sonnet 4.6 was not confirmed, and no effort support is documented for Claude Haiku 4.5. Effort goes in `output_config`, not inside `thinking`. | Strands sends nothing. The page says `high` is the default "on most models"; whether that applies to Sonnet 4.6 was not confirmed. | Adaptive thinking page above |

### Bedrock defaults for the two models

| Model | Default when no `thinking` field is sent | Adaptive thinking | Default effort | Status | Source |
|---|---|---|---|---|---|
| Claude Sonnet 4.6 (Fallback_Candidate) | Thinking off | Supported, and recommended by the model card. Not on by default (it is on by default only on Claude 5 and later models). | Not confirmed for this model | Documented | [Adaptive thinking](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-adaptive-thinking.html), table "Thinking configuration by model", and [Claude Sonnet 4.6 model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html) (accessed 2026-11-20) |
| Claude Haiku 4.5 (Default_Candidate and Global_Candidate) | Thinking off (**unconfirmed**) | Not supported: the adaptive thinking page says earlier models such as Claude Sonnet 4.5 and Claude Opus 4.5 do not support adaptive thinking, and does not list Claude Haiku 4.5 among the adaptive models | Not documented | **Unconfirmed** (Requirement 4.9) | [Claude Haiku 4.5 model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html), [Extended thinking](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html), and the Strands page (all accessed 2026-11-20) |

How the Claude Haiku 4.5 default was inferred: the model card says only that reasoning is "Supported" and gives no default. The Extended thinking page lists Claude Haiku 4.5 among the supported models and describes thinking as something the caller enables with a token budget. The Strands page says this model takes `thinking: {"type": "enabled", "budget_tokens": N}`. From this the default appears to be "thinking off", with no default effort value. No page states the default for Claude Haiku 4.5 directly, so the value stays unconfirmed. It is open item 12.

### Comparison results

Deferred. No configuration was measured (no p50, p95, token means, or ratings). The configurations planned for the Default_Candidate are C1 (no reasoning fields) and C2 (extended thinking on with a small `budget_tokens`, exact value to be chosen from the Extended thinking page before running). The Global_Candidate and Fallback_Candidate are planned with C1 only.

### Chosen configuration

**Model default: no reasoning fields sent**, on the Default_Candidate, as stated in the [Decision](#decision). The reason is documented model properties only: the model is chosen for speed, and extended thinking adds output tokens and latency (the Extended thinking page warns of longer response times). Requirement 4.7 requires a measured configuration, so it is unmet. Requirement 4.10 cannot be evaluated without p50 and ratings. Both stay open under open items 2 and 12.

## Answer quality

**Status:** answer quality judgment is **deferred by the user** (reason: shell AWS calls blocked by sandbox; local harness to be run by the user later). No agent answer was produced or rated for any Demo_Question, so there is no rating matrix. The criteria below are fixed in advance so the user can rate answers by hand later.

The Demo_Questions are referred to by number only (1 to 5). Their wording is in [`.kiro/steering/product.md`](../../.kiro/steering/product.md). The rating scale is Pass, Partial, or Fail. Each rating is a manual judgment by the Developer; there is no scoring code and no committed fixture.

### Criteria per Demo_Question

Every criterion is an observable property of the answer, checked against the Stub_Tools output in [Measurement method](#measurement-method).

| Demo_Question | Pass | Partial | Fail |
|---|---|---|---|
| 1 | Addresses the request for the chosen line, part, and date range. Lists every report the stub returned for them, with report IDs and dates equal to the stub output. Invents no report. | Lists reports but omits one, or adds a detail that is not in the stub output. | No list, wrong reports, or an invented report. |
| 2 | States whether the values across the reports trend out of tolerance, cites values that appear in the stub output, and names the out-of-tolerance value. | States a trend but cites no values, or misreads one value. | Wrong conclusion, an invented value, or no tool call. |
| 3 | Covers every finding the stub returned for the lot, with the correct result and value for each. | Misses a finding or misstates a result. | Invents a finding, uses the wrong lot, or gives no overview of the findings. |
| 4 | Reports that access to the data of the other line was denied, and shows no data for that line. | Reports the denial but speculates about the other line's data. | Shows or invents data for the other line, or does not mention the denial. |
| 5 | Uses the earlier-session context correctly (for example, refers to the right report or lot) without asking the user to repeat it. | Uses the context but mixes up a detail, or asks for confirmation it already had. | Ignores the context, or invents earlier-session facts. |

### Approximations for Demo_Questions 4 and 5

These are the planned approximations (Requirement 4.6). No Run applied them.

- **Demo_Question 4:** the concrete prompt asks about the other line. The harness constant for the signed-in user's line is the first line, so `list_inspection_reports` returns the fixed denial result from the Stub_Tools table: `{"status": "denied", "reason": "The signed-in user is not allowed to read data for this line."}`.
- **Demo_Question 5:** the Developer builds a new agent with no message history, and the earlier context is supplied as a short synthetic summary of an earlier session at the end of the system prompt.
- **These approximations show neither tool-layer permission enforcement based on the verified user identity nor AgentCore Memory behavior.** The denial comes from a constant in a stub, and the earlier context is text in the prompt. Both are still to be built and checked in later specs.

Rating matrix (configuration by Demo_Question, with the number of answers judged and a note of 1 to 3 sentences): deferred, not filled. Requirements 4.3, 4.4, and 4.6 are unmet for this reason (see [Unmet acceptance criteria](#unmet-acceptance-criteria)). Requirement 4.5 (the criteria) is met by the table above.

## Quotas

**Verdict:** an increase is **required for the requests-per-minute quotas** of the two chosen profiles, based on an **unmeasured estimate**. No tokens-per-minute increase is required. The estimate uses assumed latency and token sizes because the harness was deferred (see [Target_Load estimate](#target_load-estimate)).

| Profile | Quota to raise | Code | Applied | Estimated peak | Minimum request (peak / 0.8, rounded up) | Suggested request | Requester |
|---|---|---|---|---|---|---|---|
| Default (Claude Haiku 4.5, US profile) | Requests per minute | `L-CCA5DF70` | 50 | 108 (unmeasured estimate) | 135 | 150 | Account administrator |
| Fallback (Claude Sonnet 4.6, US profile) | Requests per minute | `L-00FF3314` | 50 | 67.5 (unmeasured estimate) | 85 | 100 | Account administrator |

An alternative to both requests is to ask the account administrator to restore the AWS default of 10,000 (both estimated peaks would be about 1.1 % and 0.7 % of it). The applied value of 50 is far below the AWS default of 10,000 for all four requests-per-minute quotas. The reason is unknown (open item 5). Nothing was requested in this spike.

### Quota values read

Read on 2026-11-20 (UTC) in `us-west-2`, read-only, through the AWS MCP server's `run_script` with boto3. Operations: Service Quotas `ListServiceQuotas` (applied values) and `ListAWSDefaultServiceQuotas` (AWS defaults), both with service code `bedrock`. Each returned 1,061 quotas over two pages (1,000 then 61, continued with `NextToken`), which the script filtered to names containing "Haiku 4.5" or "Sonnet 4.6". Equivalent CLI:

```bash
aws service-quotas list-service-quotas --region us-west-2 --service-code bedrock --profile <AWS_PROFILE>
aws service-quotas list-aws-default-service-quotas --region us-west-2 --service-code bedrock --profile <AWS_PROFILE>
aws service-quotas get-service-quota --region us-west-2 --service-code bedrock --quota-code <QUOTA_CODE> --profile <AWS_PROFILE>
```

The Service Quotas console page for the Amazon Bedrock service shows the same values. All eight quotas are adjustable. In-Region "On-demand" quotas for these two models did not appear in the list. Batch-inference quotas for both models also matched the filter; they are at the AWS default and are not relevant to the demo.

| Profile | Quota name | Code | Applied | AWS default | Default or adjusted | Read date |
|---|---|---|---|---|---|---|
| Default (Claude Haiku 4.5, US) | Cross-region model inference requests per minute for Anthropic Claude Haiku 4.5 | `L-CCA5DF70` | 50 | 10,000 | Adjusted (below the default) | 2026-11-20 |
| Default (Claude Haiku 4.5, US) | Cross-region model inference tokens per minute for Anthropic Claude Haiku 4.5 | `L-58BE175A` | 5,000,000 | 5,000,000 | AWS default | 2026-11-20 |
| Global (Claude Haiku 4.5) | Global cross-region model inference requests per minute for Anthropic Claude Haiku 4.5 | `L-E5084BBA` | 50 | 10,000 | Adjusted (below the default) | 2026-11-20 |
| Global (Claude Haiku 4.5) | Global cross-region model inference tokens per minute for Anthropic Claude Haiku 4.5 | `L-9A11C666` | 5,000,000 | 5,000,000 | AWS default | 2026-11-20 |
| Fallback (Claude Sonnet 4.6, US) | Cross-region model inference requests per minute for Anthropic Claude Sonnet 4.6 | `L-00FF3314` | 50 | 10,000 | Adjusted (below the default) | 2026-11-20 |
| Fallback (Claude Sonnet 4.6, US) | Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.6 | `L-15B8E632` | 6,000,000 | 6,000,000 | AWS default | 2026-11-20 |
| Global (Claude Sonnet 4.6, not a Candidate) | Global cross-region model inference requests per minute for Anthropic Claude Sonnet 4.6 | `L-F6E116D7` | 50 | 10,000 | Adjusted (below the default) | 2026-11-20 |
| Global (Claude Sonnet 4.6, not a Candidate) | Global cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.6 | `L-7BEE40FB` | 6,000,000 | 6,000,000 | AWS default | 2026-11-20 |

Every applied value was readable, so Requirement 5.8 does not apply. The Global_Candidate's quotas equal the Default_Candidate's, so quotas do not favor either profile.

### Target_Load estimate

**Every value in this subsection is an unmeasured estimate.** No Run happened, so there is no measured p50, model request count, or token usage (Requirement 5.3 is met only as an estimate with every input stated; see [Unmet acceptance criteria](#unmet-acceptance-criteria)). No AWS call was made for the estimate.

Formulas (S, R, Q, I, O, and B are defined in the table below):

```text
peak RPM                  = S x R x Q
peak TPM (billed)         = S x R x Q x (I + O)
peak TPM (quota, settled) = S x R x Q x (I + B x O)
reserved at request start = I + max_tokens
```

| Symbol | Meaning | Haiku 4.5 (Default) | Sonnet 4.6 (Fallback) | Basis |
|---|---|---|---|---|
| S | Concurrent sessions | 3 | 3 | 2 demo users plus 1 rehearsal session (design default) |
| p50 | Time to final answer | 5 s (assumed) | 8 s (assumed) | Placeholder. A low value gives a high peak, so the 80 percent check errs on the safe side. 5 s for a Run with three model requests and two tool calls is optimistic. |
| R | Runs per minute per session | 12 (60 / 5) | 7.5 (60 / 8) | Each session starts a new Run the moment the last one ends (worst case, no think time) |
| Q | Model requests per Run | 3 | 3 | Two tool calls need three requests (assumed, not a measured mean) |
| I | Input tokens per request, mean | 2,300 | 2,300 | Assumed sizes: system prompt and tool schemas about 1,500, question about 100, each tool call about 100, each tool result about 600. Request 1 is 1,600, request 2 is 2,300, request 3 is 3,000, mean 2,300. Earlier-session history is not included. |
| O | Output tokens per request, mean | 150 | 200 | Assumed: about 80, 80, and 250 for the two tool-call requests and a short final answer, rounded up (Haiku). Sonnet is assumed more verbose. |
| B | Output-token burndown rate | 5 (unconfirmed) | 5 (unconfirmed) | See below |
| max_tokens | Output limit per request | 4,096 | 4,096 | Set explicitly by the planned harness. The production agent value is not set yet. |

Burndown: the [Quota token burndown page](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-token-burndown.html) (accessed 2026-11-20) gives a 5x output-token rate for Claude Fable 5 and for Anthropic models of version 4.7 and below. **Neither Claude Haiku 4.5 nor Claude Sonnet 4.6 is named on the page, so 5x is unconfirmed for both** (open item 7). The page also says that, at request start, input tokens plus `max_tokens` are deducted from the quota, and that at the end the deduction is settled to input plus output times the burndown rate, with the unused part returned. Billing uses actual tokens only.

| Quantity | Haiku 4.5 (Default) | Sonnet 4.6 (Fallback) |
|---|---|---|
| Peak requests per minute | 3 x 12 x 3 = 108 | 3 x 7.5 x 3 = 67.5 |
| Peak tokens per minute, billed | 108 x (2,300 + 150) = 264,600 | 67.5 x (2,300 + 200) = 168,750 |
| Peak tokens per minute, quota (settled) | 108 x (2,300 + 5 x 150) = 329,400 | 67.5 x (2,300 + 5 x 200) = 222,750 |
| Reservation-based upper bound | 108 x (2,300 + 4,096) = 690,768 | 67.5 x (2,300 + 4,096) = 431,730 |
| RPM as percent of applied (50) | 216.0 % | 135.0 % |
| TPM, billed, as percent of applied | 264,600 / 5,000,000 = 5.29 % | 168,750 / 6,000,000 = 2.81 % |
| TPM, settled, as percent of applied | 329,400 / 5,000,000 = 6.59 % | 222,750 / 6,000,000 = 3.71 % |
| TPM, reservation upper bound, as percent of applied | 690,768 / 5,000,000 = 13.82 % | 431,730 / 6,000,000 = 7.20 % |
| Result | RPM over 80 %: increase required. TPM under 80 %: none. | RPM over 80 %: increase required. TPM under 80 %: none. |

The reservation-based figure holds every request's reservation at once. Real reservations settle as each request finishes, so it is an upper bound.

Requirement 5.4 applies to the two requests-per-minute quotas only. Haiku 4.5: raise `L-CCA5DF70` to at least 135 (108 / 0.8 = 135); suggested 150. Sonnet 4.6: raise `L-00FF3314` to at least 85 (67.5 / 0.8 = 84.375, rounded up); suggested 100. Requester: account administrator. No increase is required for `L-58BE175A` or `L-15B8E632`. The Global_Candidate uses the same model and the same estimate as the Default_Candidate. Its requests-per-minute quota `L-E5084BBA` is also 50, but it is not the chosen profile, so no request is made for it.

Sensitivity: peak RPM equals S x Q x 60 / p50, which is 540 / p50 for both profiles. The estimate stays at or under 80 percent of 50 (that is 40) only if p50 is 13.5 s or more. The requests-per-minute verdict therefore depends on a latency that was not measured. The tokens-per-minute verdict is robust: at 10 times the assumed token sizes, the settled figure is 3.29 million of 5 million (65.9 %) for Haiku 4.5 and 2.23 million of 6 million (37.1 %) for Sonnet 4.6. It would flip only above about 12 times (Haiku 4.5) or 21 times (Sonnet 4.6). Open item 6 re-runs the calculation with measured values.

### Throttling

- **Definition:** a throttled request is a model request for which Amazon Bedrock returned a throttling error (`ThrottlingException` or `ModelThrottledException`).
- **Count per Candidate:** Default_Candidate **not measured**. Global_Candidate **not measured**. Fallback_Candidate **not measured**. No Measurement_Run took place.
- **Observed:** no throttling was seen in the three Verified_Calls (each returned without error on its first attempt). Three calls are not a load test.
- **Retries:** the retry behavior of a Measurement_Run cannot be stated, because none ran. The planned harness allows one attempt, so a throttling error would reach Strands without an automatic retry, and the count would then contain no request that succeeded after a retry. This is a plan, not a result (Requirement 5.7, measured part, is deferred).

## Data residency

The calling Region is `us-west-2`. Processing Regions come from the Destination_Regions read with Bedrock `GetInferenceProfile` on 2026-11-20 (UTC); see [Routing (Destination_Regions)](#routing-destination_regions) for the operation and the CLI.

### Processing Regions per Candidate

| Candidate | Profile ID | Regions where a request sent from `us-west-2` may be processed |
|---|---|---|
| Default_Candidate (Claude Haiku 4.5, US) | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | us-east-1, us-east-2, us-west-2 |
| Global_Candidate (assumption) | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | **Unverified.** The API returned a Region-less ARN plus us-west-2, so it does not list the full Region set (Requirement 2.8). The Regions were not filled from documentation. Open item 8. |
| Fallback_Candidate (Claude Sonnet 4.6, US) | `us.anthropic.claude-sonnet-4-6` | us-east-1, us-east-2, us-west-2 |

The chosen profile is the Default_Candidate's US profile. All three of its Regions are in the United States, so Requirement 6.5 (Region outside the United States) does not apply and Requirement 6.6 does.

### Residency statement (chosen profile)

> The demo sends every model request to Amazon Bedrock in us-west-2. Through the chosen US inference profile, Bedrock may process each request in us-east-1, us-east-2, or us-west-2, all of which are United States Regions. Requests sent from us-west-2 through this profile are processed only in United States Regions. Prompts and outputs may leave us-west-2 during processing, and any data Bedrock stores for abuse detection is stored in the Region that processed the request.

### Trace

| Sentence | Source |
|---|---|
| 1 | The profile reads and the Verified_Calls used `us-west-2` as the calling Region (see [Routing (Destination_Regions)](#routing-destination_regions) and [Verified calls](#verified-calls)). |
| 2 | The `GetInferenceProfile` result for the Default_Candidate: us-east-1, us-east-2, us-west-2. The Region codes us-east-1, us-east-2, and us-west-2 are United States Regions. |
| 3 | The same `GetInferenceProfile` result (all three Regions are in the United States), and the AWS page [Geographic cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html), which says requests to a profile tied to a geography such as the US stay within that geography. |
| 4 | The same AWS page: prompts and outputs may move outside the source Region during cross-Region inference, and data stored for abuse detection is stored in the destination Region. |

Claims that Bedrock does not store prompts or outputs, and claims about where logs or CloudTrail events are kept, are left out because no cited page was checked for them. The optional check of the CloudTrail `inferenceRegion` field was not done.

### Citations

| Title | URL | Accessed | Used for |
|---|---|---|---|
| Geographic cross-Region inference | https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html | 2026-11-20 | Statement sentences 3 and 4 |
| Supported Regions and models for inference profiles | https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference-support.html | 2026-11-20 | Related reading only; no statement claim rests on it |

## Condition checklist

One row per conditional ("IF") acceptance criterion. "Triggered" means the condition was true in this spike.

| Criterion | Condition | Triggered | Where the record handles it |
|---|---|---|---|
| 1.9 | A Verified_Call failed | Yes, for the rejected candidates only. The three chosen Candidates had no failed call. | [Failure log](#failure-log), [Rejected candidates](#rejected-candidates) |
| 1.10 | No Verified_Call for the Default or Fallback Candidate | No. Both have one. | [Verified calls](#verified-calls), [Decision](#decision) |
| 2.3 | Listed ID differs from the expected ID | Yes, for the Default_Candidate and Global_Candidate (suffix `-20251001-v1:0` added). | [Listing](#listing) |
| 2.7 | No matching profile in the listing | No. All three were found. | [Listing](#listing) |
| 2.8 | No Destination_Regions returned, or the listing failed | Yes, for the Global_Candidate (Region-less ARN). Marked unconfirmed. | [Routing (Destination_Regions)](#routing-destination_regions), [Processing Regions per Candidate](#processing-regions-per-candidate) |
| 3.5 | A Run errored, timed out, or made a wrong number of tool calls | Cannot be evaluated (deferred): no Run was executed. | [Latency results](#latency-results), [Unmet acceptance criteria](#unmet-acceptance-criteria) |
| 3.6 | The default's p50 exceeds 15 s | Cannot be evaluated (deferred): latency was not measured. | [Latency results](#latency-results), [Open items and follow-ups](#open-items-and-follow-ups) |
| 4.8 | `BedrockModel` has no named parameter for a reasoning setting | Yes. Reasoning goes through `additional_request_fields`. Documented only; no Measurement_Run passed it. | [How Strands passes reasoning settings](#how-strands-passes-reasoning-settings) |
| 4.9 | No documentation source for a default reasoning setting | Yes, for Claude Haiku 4.5. Marked unconfirmed. | [Bedrock defaults for the two models](#bedrock-defaults-for-the-two-models), open item 12 |
| 4.10 | No measured configuration meets p50 of 15 s or less with Pass for Demo_Questions 1, 2, and 3 | Cannot be evaluated (deferred): no configuration was measured. | [Chosen configuration](#chosen-configuration), [Unmet acceptance criteria](#unmet-acceptance-criteria) |
| 5.4 | Estimated peak exceeds 80 percent of an applied quota | Yes, for both requests-per-minute quotas (unmeasured estimate). Not for tokens per minute. | [Quotas](#quotas), [Target_Load estimate](#target_load-estimate) |
| 5.6 | Estimated peak at or below 80 percent of every applied quota | No. Both requests-per-minute quotas are over 80 percent. | [Target_Load estimate](#target_load-estimate) |
| 5.8 | An applied quota value could not be read | No. All eight values were read. | [Quota values read](#quota-values-read) |
| 6.5 | A Destination_Region of the chosen profile is outside the United States | No. us-east-1, us-east-2, and us-west-2 are United States Regions. | [Residency statement (chosen profile)](#residency-statement-chosen-profile) |
| 6.6 | All Destination_Regions of the chosen profile are inside the United States | Yes. | [Residency statement (chosen profile)](#residency-statement-chosen-profile) |
| 6.7 | Destination_Regions of a Candidate could not be read through the API | Yes, for the Global_Candidate. Marked unverified. | [Processing Regions per Candidate](#processing-regions-per-candidate), open item 8 |
| 7.4 | The latency proposal changes the default or switches to the fallback | No. Not applicable because 3.6 cannot be evaluated. | [Decision](#decision) |
| 7.5 | No Candidate has a Verified_Call | No. All three have one. | [Decision](#decision), [Verified calls](#verified-calls) |
| 7.8 | Criteria remain unmet when the spike ends | Yes. Each unmet criterion is listed with a reason and as an open item. | [Unmet acceptance criteria](#unmet-acceptance-criteria), [Open items and follow-ups](#open-items-and-follow-ups) |

No other criterion in the requirements starts with IF or WHERE. Criteria 1.1, 8.1, and 8.2 start with WHEN and are checked at the end of the spike (task 12.1), not in this table.

## Sources

Every page cited in this record. All were accessed on 2026-11-20.

| # | Title | URL | Accessed |
|---|---|---|---|
| 1 | Claude Sonnet 4.6 model card (Amazon Bedrock User Guide) | https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html | 2026-11-20 |
| 2 | Claude Haiku 4.5 model card (Amazon Bedrock User Guide) | https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html | 2026-11-20 |
| 3 | Request access to Amazon Bedrock models | https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html | 2026-11-20 |
| 4 | Global cross-Region inference | https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html | 2026-11-20 |
| 5 | PutUseCaseForModelAccess (Amazon Bedrock API Reference) | https://docs.aws.amazon.com/bedrock/latest/APIReference/API_PutUseCaseForModelAccess.html | 2026-11-20 |
| 6 | Strands Agents: Amazon Bedrock model provider | https://strandsagents.com/latest/documentation/docs/user-guide/concepts/model-providers/amazon-bedrock/ | 2026-11-20 |
| 7 | Adaptive thinking (Amazon Bedrock User Guide) | https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-adaptive-thinking.html | 2026-11-20 |
| 8 | Extended thinking (Amazon Bedrock User Guide) | https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html | 2026-11-20 |
| 9 | Quota token burndown (Amazon Bedrock User Guide) | https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-token-burndown.html | 2026-11-20 |
| 10 | Geographic cross-Region inference | https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html | 2026-11-20 |
| 11 | Supported Regions and models for inference profiles | https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference-support.html | 2026-11-20 |
