# Requirements Document

## Introduction

This spec is a time-boxed spike for the "inspection-agent" demo. inspection-agent is a demo of an AI agent that answers questions about manufacturing inspection data. The stack is Strands Agents (Python 3.12) on Amazon Bedrock AgentCore Runtime, Claude models on Amazon Bedrock, PostgreSQL on Amazon RDS, Amazon Cognito for sign-in, and AWS CloudFormation (YAML only) for all infrastructure, in region us-west-2. All data is synthetic. All code, comments, docs, and UI text are in English.

The goal is to decide which Claude model and inference profile the demo uses, and to prove that the AWS account can call that model from a Strands agent in us-west-2 with acceptable latency. The output is one written decision record, `docs/spikes/model-access.md`. The spike produces no production code. The time-box is 3 hours.

This spec maps to the spec folder `.kiro/specs/02-model-access-spike/`. The GitHub issue number is expected to be #2; the design records the confirmed number on the first line of its Overview, as `docs/kiro-workflow.md` requires.

### Change log: candidate change (2026-11-20)

The original prompt asked for Claude Sonnet 5.5 as the default model, a Claude Sonnet 5.5 global profile for comparison, and a smaller, faster fallback (expected Claude Haiku 5.5). Tasks 2.1 to 3.2 then ran against the account. Every `Converse` call in us-west-2 for Claude Sonnet 5.5 (US and global profiles) and Claude Haiku 5.5 (US profile) returned `AccessDeniedException` with the message "<model> is not available for this account", and `agreementAvailability` stayed `NOT_AVAILABLE` (evidence in the notes of tasks 3.1 and 3.2).

The user then switched the candidates. The user's decision takes precedence over the original prompt:

- Default_Candidate: Claude Haiku 4.5 through the US geographic inference profile.
- Global_Candidate: Claude Haiku 4.5 through the global inference profile. This is an assumption of this spec: the comparison stays "same model as the default, global profile". The user has not stated it explicitly.
- Fallback_Candidate: Claude Sonnet 4.6 through the US geographic inference profile. The fallback is now a larger, more capable model, used if the default's answer quality is not good enough. It is no longer a smaller and faster model.
- Claude Sonnet 5.5 (US and global) and Claude Haiku 5.5 are recorded as rejected candidates ("not available for this account"), with the evidence from tasks 2.1 to 3.2 (Requirement 7, criterion 9).

Tasks 2.1, 2.2, 2.3, and 3.1 are re-run for the new candidates, and task 3.2 continues with the new profile IDs. The old notes stay in the task file as evidence.

Out of scope: agent logic, infrastructure templates, Operational_Scripts, and any change under `src/`, `infra/`, `scripts/`, `data/`, or `ui/`.

Project testing policy: this project forbids automated tests (`.kiro/steering/tech.md`). Every acceptance criterion below is verified manually by reading the Decision_Record and inspecting the Repository.

### Model IDs in this spec

The model IDs named in this spec are expected ID prefixes, not verified facts: `us.anthropic.claude-haiku-4-5` (Default_Candidate), `global.anthropic.claude-haiku-4-5` (Global_Candidate), and `us.anthropic.claude-sonnet-4-6` (Fallback_Candidate). The exact IDs probably carry a date or version suffix (for example `-20251001-v1:0` for Claude Haiku 4.5), and come from the us-west-2 listing. The spike confirms or corrects each ID by listing inference profiles from us-west-2 (Requirement 2). Where a listed ID differs from the expected prefix, the Decision_Record uses the listed ID.

The earlier IDs `us.anthropic.claude-sonnet-5-5`, `global.anthropic.claude-sonnet-5-5`, and `us.anthropic.claude-haiku-5-5` are rejected candidates (see the change log in the Introduction).

### Conflicts with steering

The user's prompt takes precedence over steering where they conflict. The design phase SHALL flag each item below.

1. **Testing policy and the Measurement_Run.** `.kiro/steering/tech.md` forbids test and verification scripts and eval harnesses. The user's prompt allows a throwaway local Measurement_Run with a minimal Strands agent and Stub_Tools, and says "Do not add scripts for this spike." This spec resolves the tension as follows: the Measurement_Run code lives only on the developer's machine, is never committed, is not an Operational_Script, and the only committed file is the Decision_Record (Requirement 8).
2. **Answer quality for the Demo_Questions.** Requirement 4 asks for a judgment of answer quality. This could look like an eval harness. This spec requires a manual judgment written by the developer, with no scoring code and no committed fixtures.
3. **Demo_Questions 4 and 5 need features that do not exist yet.** Question 4 (denial for the other line) depends on tool-layer permission checks, and question 5 (resume context in a new session) depends on AgentCore Memory. Neither exists in this spike. The Stub_Tools can only simulate a denial result, and session resume can only be approximated. The Decision_Record states how each question was approximated and what the result does and does not show (Requirement 4, criterion 6).
4. **Demo_Question wording.** Requirement 2 of spec 01 allows the full wording of the Demo_Questions only in `.kiro/steering/product.md`. The Decision_Record therefore refers to Demo_Questions by number and links to `.kiro/steering/product.md` (Requirement 8, criterion 6). The Representative_Prompt contains none of the full wording of any Demo_Question (Requirement 3, criterion 10). `data/STORIES.md` may not exist yet; the spike uses the question text from `.kiro/steering/product.md` directly at run time.
5. **Region.** `.kiro/steering/tech.md` names us-west-2 as the only target region. The calling region stays us-west-2, but cross-Region inference profiles may process requests in other Regions. The Decision_Record states this explicitly (Requirement 6).
6. **Root README prerequisite wording.** The Root_README prerequisite says "Amazon Bedrock model access enabled for Claude models in us-west-2". If the spike finds that access requires an AWS Marketplace subscription step instead of, or in addition to, a model access toggle, the Decision_Record states the correct step. Updating the Root_README is out of scope for this spike and is listed as a follow-up (Requirement 7, criterion 6).

## Glossary

- **Repository**: The inspection-agent Git repository rooted at the workspace root.
- **Spike**: The time-boxed investigation described by this spec, limited to 3 hours.
- **Decision_Record**: The file `docs/spikes/model-access.md`, the only deliverable of the Spike.
- **Developer**: The person who runs the Spike and writes the Decision_Record.
- **Candidate**: One model ID and inference profile pair evaluated by the Spike. The Spike has three Candidates: Default_Candidate, Global_Candidate, and Fallback_Candidate.
- **Default_Candidate**: Claude Haiku 4.5 through the US geographic inference profile, expected ID prefix `us.anthropic.claude-haiku-4-5`. The exact ID comes from the us-west-2 listing.
- **Global_Candidate**: Claude Haiku 4.5 through the global inference profile, expected ID prefix `global.anthropic.claude-haiku-4-5`, used for comparison. That the comparison uses the same model as the default is an assumption of this spec.
- **Fallback_Candidate**: Claude Sonnet 4.6 through the US geographic inference profile, expected ID prefix `us.anthropic.claude-sonnet-4-6`. It is a larger, more capable model than the Default_Candidate, used if the default's answer quality is not good enough.
- **Rejected_Candidate**: A model and inference profile that the Spike tried and found unusable for this account. The rejected candidates are Claude Sonnet 5.5 (US and global profiles) and Claude Haiku 5.5, all "not available for this account".
- **Inference_Profile**: An Amazon Bedrock inference profile that routes model requests from a source Region to one or more destination Regions.
- **Destination_Regions**: The list of AWS Regions to which an Inference_Profile may route a request, as returned by the Amazon Bedrock API for that profile.
- **Verified_Call**: A model invocation made from us-west-2 with a Candidate's model ID that returns a successful response with model output.
- **Access_Prerequisites**: The steps required before the account can invoke a Candidate, including any AWS Marketplace subscription, any Amazon Bedrock model access setting, and the IAM permissions needed for both the one-time setup and the runtime calls.
- **Measurement_Run**: The throwaway local execution of a minimal Strands agent with Stub_Tools, used to collect latency and token data. Its code is not committed.
- **Stub_Tools**: Local tool functions used only in the Measurement_Run that return fixed synthetic data without a database.
- **Representative_Prompt**: The single prompt used for latency measurement, written so that the agent makes exactly two tool calls before the final answer.
- **Run**: One execution of the Representative_Prompt from the start of the agent call to the final answer.
- **Time_To_Final_Answer**: The wall-clock time in seconds from the start of a Run to the moment the agent returns its final answer.
- **Latency_Target**: A p50 Time_To_Final_Answer of 15 seconds for the Default_Candidate (Claude Haiku 4.5) on the Representative_Prompt. The value is a target to validate with the presenter.
- **Reasoning_Settings**: The extended thinking settings of the chosen models, as exposed through the Strands `BedrockModel` class. The thinking options of Claude Haiku 4.5 and Claude Sonnet 4.6 differ from the effort and adaptive thinking options of Claude Sonnet 5.5. For example, the Claude Sonnet 4.6 model card says reasoning is off by default and recommends `thinking.type: "adaptive"`, and the Claude Haiku 4.5 model card says only "Supported". The parameter names and allowed values for each model are to be confirmed from the AWS documentation during the Spike.
- **Demo_Questions**: The five demo questions defined only in `.kiro/steering/product.md`, referred to by number 1 to 5.
- **Quotas**: The Amazon Bedrock service quotas for requests per minute and tokens per minute that apply to a Candidate's Inference_Profile in us-west-2 for the account.
- **Target_Load**: Two concurrent demo users plus rehearsal runs.
- **Base_Commit**: The Repository commit on which the Spike started, recorded in the Decision_Record and written as `<Base_Commit>` in commands.
- **Operational_Scripts**: The scripts allowed under `scripts/` by `.kiro/steering/structure.md`.
- **Root_README**: The file `README.md` at the Repository root.
- **Secret**: Any credential, password, API key, access key, token, private key, or account-specific identifier that grants access to a system, including the 12-digit AWS account ID.

## Requirements

### Requirement 1: Model access

**User Story:** As the presenter, I want to know exactly what the account needs before it can call the chosen Claude model, so that I can set up a fresh account for the demo without surprises.

#### Acceptance Criteria

1. WHEN the Spike ends, THE Decision_Record SHALL name one default model ID and one fallback model ID, each verified by a successful call from us-west-2.
2. THE Decision_Record SHALL state, for each of the three Candidates, whether a Verified_Call succeeded (yes or no) and the date of the most recent call attempt in ISO 8601 format (YYYY-MM-DD).
3. THE Decision_Record SHALL give, for each Candidate with a Verified_Call, the API operation or AWS CLI command used to make the call, with account-specific values replaced by placeholders in angle brackets, and SHALL state that the response contained non-empty model output.
4. THE Decision_Record SHALL list the Access_Prerequisites for each Candidate as a numbered list in the order a person must perform them on a fresh account.
5. THE Decision_Record SHALL state, for each Candidate, whether an AWS Marketplace subscription is required (yes or no), and SHALL name the Amazon Bedrock console page, API operation, or AWS CLI command the Developer used to confirm the subscription state.
6. THE Decision_Record SHALL list the IAM actions needed for the one-time setup (such as a Marketplace subscription) in one list, and the IAM actions the agent needs at runtime to invoke the Candidate in a separate list.
7. THE Decision_Record SHALL give, for each runtime IAM action, the resource ARN pattern the action is scoped to, with account-specific values replaced by placeholders in angle brackets, and SHALL state for each IAM action in either list whether the Spike exercised it or took it from AWS documentation, with a link to the documentation page for each action taken from documentation.
8. THE Decision_Record SHALL state, for each Access_Prerequisite, who must perform the step, named by role (for example, account administrator or Developer), with no personal names.
9. IF a Verified_Call fails for a Candidate, THEN THE Decision_Record SHALL record, for each failed attempt, the error code and error message returned with any Secret replaced by a placeholder in angle brackets, the step taken to resolve the error, and whether the Candidate remained eligible.
10. IF no Verified_Call succeeds for the Default_Candidate or for the Fallback_Candidate by the end of the Spike, THEN THE Decision_Record SHALL state which of the two has no verified model ID, and SHALL list criterion 1.1 as unmet in the open items with the last error recorded under criterion 1.9.

### Requirement 2: Candidates and inference profiles

**User Story:** As the Developer, I want the exact model IDs and their routing confirmed from the API, so that the demo uses IDs that work in us-west-2 and the routing claims in the talk are accurate.

#### Acceptance Criteria

1. THE Decision_Record SHALL name exactly three Candidates, each labeled with its role: the Default_Candidate, the Global_Candidate, and the Fallback_Candidate.
2. THE Decision_Record SHALL give, for each Candidate, the exact inference profile ID and the profile status as returned by listing inference profiles with us-west-2 as the calling Region, together with the date of the listing.
3. IF the listed inference profile ID for the Default_Candidate or the Global_Candidate differs from the expected ID in this spec, THEN THE Decision_Record SHALL record both the expected ID and the listed ID and SHALL use the listed ID everywhere else in the Decision_Record.
4. THE Decision_Record SHALL list the Destination_Regions of each profile.
5. THE Decision_Record SHALL state that the Destination_Regions were read through the Amazon Bedrock API with us-west-2 as the calling Region, SHALL give the date of the read, and SHALL give the API operation or AWS CLI command used, with account-specific values replaced by placeholders in angle brackets.
6. THE Decision_Record SHALL state the reason the Fallback_Candidate was chosen, naming the model, its inference profile ID as it appears in the us-west-2 listing, and the property that makes it a suitable fallback (it is more capable than the Default_Candidate), with a citation of the AWS or Anthropic documentation page that states the property.
7. IF no inference profile matching the expected model and routing scope (US geographic for the Default_Candidate, global for the Global_Candidate) appears in the us-west-2 listing, THEN THE Decision_Record SHALL record that the profile was not found, the date of the listing, and whether the Candidate was replaced by another listed profile (naming its ID) or marked not eligible.
8. IF the Amazon Bedrock API returns no Destination_Regions for a Candidate's profile, or the listing call fails, THEN THE Decision_Record SHALL record the error code and error message or the empty result, and SHALL mark that Candidate's Destination_Regions as unconfirmed instead of filling them from documentation.

### Requirement 3: Latency

**User Story:** As the presenter, I want measured latency for each Candidate on a prompt that looks like a real demo turn, so that I can pick a configuration that answers fast enough on stage.

#### Acceptance Criteria

1. THE Decision_Record SHALL include p50 and p95 latency per candidate and the number of runs.
2. THE Decision_Record SHALL report results from exactly 10 measured Runs of the Representative_Prompt for each Candidate, executed one at a time with no other Run in progress, using the same Representative_Prompt and the same Stub_Tools for every Candidate, and not counting any warm-up Runs among the 10.
3. THE Decision_Record SHALL report, for each Candidate, the p50 and p95 Time_To_Final_Answer in seconds rounded to one decimal place, computed with the nearest-rank method over the measured Runs (with 10 Runs, p50 is the 5th-smallest value and p95 is the largest value), and the mean input, output, and total token usage per Run as reported in the model's usage data.
4. THE Decision_Record SHALL report, for each Candidate, the number of Runs out of 10 in which the agent made exactly two tool calls before returning its final answer.
5. IF a Run returns an error, returns no final answer within 120 seconds of its start, or makes a number of tool calls other than two, THEN THE Decision_Record SHALL record, per Candidate, the count of such Runs for each of these three causes, and SHALL state whether those Runs are included in the p50 and p95 values.
6. IF the default's p50 time to final answer on the representative prompt exceeds 15 seconds, THEN THE record SHALL propose a faster configuration or switch to the fallback.
7. THE Decision_Record SHALL state that the Latency_Target of 15 seconds is a target to validate with the presenter, and SHALL record either the date on which the presenter confirmed the value or the status "not confirmed".
8. THE Decision_Record SHALL describe the measurement method (prompt, number of runs, settings) in enough detail to repeat it by hand.
9. THE Decision_Record SHALL describe the measurement method with these items: the full text of the Representative_Prompt; the names, inputs, and fixed outputs of the Stub_Tools; the Candidate model ID; the Reasoning_Settings and any other model parameters; the Strands Agents and Python versions; where the Runs were executed (local machine and calling Region); how Time_To_Final_Answer was timed, with the start defined as the moment immediately before the agent call and the end as the moment the agent call returns the final answer, both measured on the local machine's clock; and the number of warm-up Runs excluded per Candidate, or 0 if none were excluded.
10. THE Decision_Record SHALL give a Representative_Prompt and Stub_Tools outputs that contain only synthetic data, no Secrets, and none of the full wording of any Demo_Question.

### Requirement 4: Reasoning settings

**User Story:** As the Developer, I want to know how Strands exposes the reasoning settings of the Default_Candidate model and what they cost in latency and quality, so that I can choose settings for the demo on evidence.

#### Acceptance Criteria

1. THE Decision_Record SHALL state how the Strands `BedrockModel` class exposes each Reasoning_Setting. For each setting, it SHALL give the parameter name, the allowed values, and the value Strands uses when the parameter is not set. It SHALL cite the source as a Strands documentation URL or a library source file, together with the Strands Agents version used in the Measurement_Run.
2. THE Decision_Record SHALL state the default Reasoning_Settings of the Default_Candidate model on Amazon Bedrock, including the default reasoning effort value and whether adaptive thinking is on by default. It SHALL cite the URL of the AWS or Anthropic documentation page used as the source.
3. THE Decision_Record SHALL report results for at least two Reasoning_Settings configurations of the Default_Candidate, and one of them SHALL be the default configuration. For each configuration it SHALL report the exact setting values, the p50 and p95 Time_To_Final_Answer in seconds, and the mean input, output, and total tokens per Run. Each configuration SHALL be measured over 10 Runs of the Representative_Prompt, using the measurement method recorded under Requirement 3.
4. THE Decision_Record SHALL report a written judgment from the Developer for each measured Reasoning_Settings configuration and each of Demo_Questions 1 to 5. Each judgment SHALL use at least one agent answer, SHALL state how many answers were judged, SHALL give one rating from the fixed scale Pass, Partial, or Fail, and SHALL include a note of 1 to 3 sentences explaining the rating. The Decision_Record SHALL refer to each Demo_Question by its number and SHALL link to `.kiro/steering/product.md`.
5. THE Decision_Record SHALL state, for each Demo_Question, the criteria for Pass, Partial, and Fail as observable properties of the answer. Examples of such properties: the answer addresses the question asked, every value in the answer appears in the Stub_Tools output, the answer invents no data, and for Demo_Question 4 the answer reports the denial and shows no data from the other line.
6. THE Decision_Record SHALL state how the Measurement_Run approximated the missing parts for Demo_Questions 4 and 5. For Demo_Question 4, it SHALL give the fixed denial result that the Stub_Tools returned. For Demo_Question 5, it SHALL describe how the earlier context was supplied to the new session. It SHALL also state that these results show neither tool-layer permission enforcement based on the verified user identity nor AgentCore Memory behavior.
7. THE Decision_Record SHALL name the Reasoning_Settings chosen for the demo, using the exact values of one configuration measured under criterion 3. It SHALL give the reason for the choice, citing that configuration's p50 Time_To_Final_Answer against the Latency_Target and its ratings for Demo_Questions 1 to 5.
8. IF the Strands `BedrockModel` class has no named parameter for a Reasoning_Setting, THEN THE Decision_Record SHALL state how the Measurement_Run passed that setting to the model and SHALL cite the source for that method.
9. IF the Developer finds no documentation source for a default Reasoning_Setting of the Default_Candidate model on Amazon Bedrock, THEN THE Decision_Record SHALL mark that default as unconfirmed, state how the Developer inferred the value, and list it as an open item under Requirement 7.
10. IF no measured configuration has both a p50 Time_To_Final_Answer of 15 seconds or less and a Pass rating for Demo_Questions 1, 2, and 3, THEN THE Decision_Record SHALL state this and name the trade-off taken in the chosen configuration (latency or quality). It SHALL also state whether the proposal required by Requirement 3, criterion 6 applies.

### Requirement 5: Quotas

**User Story:** As the presenter, I want to know the quota limits for the chosen profile, so that two users and rehearsal runs do not hit throttling during the demo.

#### Acceptance Criteria

1. THE Decision_Record SHALL state the quota values found and whether an increase is required.
2. THE Decision_Record SHALL state, for the chosen Inference_Profile and for the Fallback_Candidate's Inference_Profile in us-west-2, the requests-per-minute and tokens-per-minute Quotas, each with its Service Quotas quota name, its applied value in the account, whether the value is the AWS default or an adjusted value, the date the value was read, and the Service Quotas console page or AWS CLI command used to read it, with account-specific values replaced by placeholders in angle brackets.
3. THE Decision_Record SHALL state the estimated peak requests per minute and tokens per minute for the Target_Load, and SHALL show the calculation from the token usage measured in Requirement 3, stating each input value used: the number of concurrent sessions assumed (at least 2, plus any rehearsal sessions assumed to run at the same time), the Runs per minute per session (taken as 60 divided by the Default_Candidate's p50 Time_To_Final_Answer in seconds, unless the Developer states and justifies a different value), the mean number of model requests per Run, and the mean input and output tokens per model request.
4. IF the estimated peak for the Target_Load exceeds 80 percent of any applied Quota value, THEN THE Decision_Record SHALL state that an increase is required, the affected Quota name, the requested value (at least the estimated peak divided by 0.8, rounded up), and who must request the increase, named by role.
5. THE Decision_Record SHALL state whether any Run in the Spike was throttled, and the count of throttled requests per Candidate.
6. IF the estimated peak for the Target_Load is at or below 80 percent of every applied Quota value, THEN THE Decision_Record SHALL state that no increase is required and SHALL give, for each Quota, the estimated peak as a percentage of the applied value.
7. THE Decision_Record SHALL define a throttled request as a model request for which Amazon Bedrock returned a throttling error, and SHALL state whether the Measurement_Run retried throttled requests automatically and whether the count in criterion 5 includes requests that succeeded after a retry.
8. IF the Developer cannot read an applied Quota value for a Candidate's Inference_Profile in us-west-2, THEN THE Decision_Record SHALL record the Quota as unknown, give the error or missing result observed, and list reading the value as an open item under Requirement 7.

### Requirement 6: Data residency

**User Story:** As the presenter, I want an exact statement of where requests may be processed for each profile, so that I can say it correctly in the talk.

#### Acceptance Criteria

1. THE Decision_Record SHALL state, for each of the three Candidates, the AWS Regions in which a request sent from us-west-2 may be processed. Each Region SHALL be given by its Region code (for example `us-east-1`), and the set of Regions SHALL be identical to the Destination_Regions recorded for that Candidate under Requirement 2, with no Region added or omitted.
2. THE Decision_Record SHALL contain a residency statement of 1 to 5 sentences for the chosen Inference_Profile. The statement SHALL name the calling Region us-west-2 and every Destination_Region of the chosen Inference_Profile by Region code, and SHALL contain no model ID, ARN, or Secret.
3. THE Decision_Record SHALL make each claim in the residency statement traceable to one of two sources: the Destination_Regions recorded under Requirement 2, or an AWS documentation page cited under criterion 4. The residency statement SHALL contain no claim that neither source supports.
4. THE Decision_Record SHALL cite the AWS documentation page used for each residency claim that the Amazon Bedrock API response does not show, such as where data is stored at rest or where it is logged. Each citation SHALL give the page title, the full URL, and the date the Developer accessed the page.
5. IF any Destination_Region of the chosen Inference_Profile is outside the United States, THEN THE Decision_Record SHALL say in the residency statement that requests may be processed outside the United States, and SHALL name those Regions by Region code.
6. IF all Destination_Regions of the chosen Inference_Profile are inside the United States, THEN THE Decision_Record SHALL say in the residency statement that requests sent from us-west-2 through that profile are processed only in United States Regions.
7. IF the Developer cannot read the Destination_Regions of a Candidate through the Amazon Bedrock API, THEN THE Decision_Record SHALL mark that Candidate's processing Regions as unverified, SHALL record the error or reason, and SHALL list the missing value as an open item under Requirement 7.

### Requirement 7: Decision

**User Story:** As a developer of later specs, I want one clear decision with its reasons, so that the runtime spec can use the chosen model ID and settings without repeating the Spike.

#### Acceptance Criteria

1. THE Decision_Record SHALL contain one section titled "Decision" that appears before every section holding the detailed findings for Requirements 1 to 6.
2. THE Decision section SHALL name exactly one default model ID, exactly one fallback model ID, exactly one chosen Inference_Profile ID, and exactly one chosen Reasoning_Settings configuration. It SHALL spell each model ID and Inference_Profile ID character for character as recorded under Requirement 2.
3. THE Decision section SHALL give, for each of the four choices named in criterion 2, a reason of at least one sentence and a Markdown link to the heading of the finding section in the Decision_Record that supports the choice.
4. IF the latency proposal under Requirement 3 criterion 6 changes the default configuration or switches to the Fallback_Candidate, THEN THE Decision section SHALL name the resulting configuration as the decision and SHALL state which configuration it replaced.
5. IF no Candidate has a Verified_Call when the Spike ends, THEN THE Decision section SHALL state that no default model ID was chosen and SHALL link to the failure details recorded under Requirement 1 criterion 9, and THE Decision_Record SHALL list choosing a default model ID as an open item.
6. THE Decision_Record SHALL contain a section titled "Open items and follow-ups". Each entry in that section SHALL describe one item and name the role responsible for it, with no personal names. The section SHALL include at least these entries: the presenter's confirmation of the Latency_Target, any Quota increase found to be required under Requirement 5 criterion 4, and any needed Root_README change found under conflict item 6.
7. THE Decision_Record SHALL state the date or dates of the Spike in ISO 8601 format (YYYY-MM-DD), the total time spent in hours and minutes, and whether the total time spent was at most 3 hours 0 minutes.
8. IF the Spike reaches the 3-hour time-box before every acceptance criterion in this spec is met, THEN THE Decision_Record SHALL list each unmet acceptance criterion as a requirement number and criterion number (for example, "3.2") with a reason of at least one sentence, and SHALL add each unmet criterion as an entry in the "Open items and follow-ups" section.

9. THE Decision_Record SHALL list each Rejected_Candidate with its model ID, the reason it was rejected, and a link to the failure details recorded under Requirement 1 criterion 9.

### Requirement 8: Committed output and repository hygiene

**User Story:** As a maintainer, I want the Spike to commit only the decision record, so that the Repository stays consistent with the testing policy and contains no throwaway code or secrets.

#### Acceptance Criteria

1. WHEN the Spike ends, THE Repository SHALL show `docs/spikes/model-access.md` as the only path outside `.kiro/specs/02-model-access-spike/` in the output of `git diff --name-only <Base_Commit>..HEAD`, where `<Base_Commit>` is the commit recorded under criterion 7.
2. WHEN the Spike ends, THE Repository SHALL show no untracked path in the output of `git status --porcelain` other than paths under `.kiro/specs/02-model-access-spike/` and `docs/spikes/model-access.md`.
3. THE Repository SHALL contain no committed or untracked Measurement_Run code, Stub_Tools code, or Run output files (raw logs, timing files, or token usage exports) resulting from the Spike, and SHALL contain no file added or changed by the Spike under `scripts/`, `src/`, `infra/`, `data/`, or `ui/`, as shown by the commands in criteria 1 and 2.
4. THE Decision_Record SHALL contain no Secret. Specifically, it SHALL contain no 12-digit numeric string, no AWS access key ID, no secret access key, no session token, and no ARN or URL that contains a literal account ID.
5. THE Decision_Record SHALL use a placeholder in angle brackets (for example `<ACCOUNT_ID>`) in place of every account-specific value in commands, ARNs, and quota identifiers.
6. THE Decision_Record SHALL not reproduce the text of any Demo_Question as written in `.kiro/steering/product.md`. It SHALL refer to each Demo_Question by its number, 1 to 5, and SHALL include at least one relative link to `.kiro/steering/product.md`.
7. THE Decision_Record SHALL record the full commit hash of `<Base_Commit>`, the commit on which the Spike started, so that a reader can run the commands in criteria 1 and 2 by hand.
8. THE Decision_Record SHALL be a single Markdown file with the `.md` extension, and all its prose, headings, tables, and code comments SHALL be in English.
9. THE Decision_Record SHALL state, in the section that describes the measurement method, that the Measurement_Run code and Stub_Tools code ran only on the Developer's local machine, were throwaway, and were not committed to the Repository.
