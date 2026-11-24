# Requirements Document

## Introduction

This feature deploys the Strands agent (`src/inspection_agent/` with `src/inspection_core/`) to Amazon Bedrock AgentCore Runtime with CloudFormation. It adds the template `infra/runtime.yaml`, the packaging script `scripts/package-agent.sh`, an extension of the existing `scripts/invoke.sh`, and the document `docs/runtime.md`.

The runtime uses the code-in-S3 artifact option. A packaging script builds a reproducible zip of the agent, the core package, and their dependencies, and uploads it to a versioned S3 bucket. The runtime runs in VPC mode, using the private subnets and the runtime security group published by the network stack. Inbound requests are authenticated by a custom JWT authorizer that uses the Cognito discovery URL and app client published by the auth stack. The request header allowlist contains `Authorization`, so the validated token reaches the entrypoint, which builds the verified user identity from it (spec 08).

The execution role follows least privilege. It can invoke only the configured inference profile and the foundation models in its destination Regions, read only the read-only database secret, write logs and traces, and, when a memory ID is set, use only that memory resource.

Out of scope: the memory stack (`infra/memory.yaml`), the observability stack, the UI, and the MCP server.

Facts found in the repository while writing these requirements (the design confirms them):

- `scripts/invoke.sh` already exists (spec 08). It takes the Cognito access token only from the environment variable `AGENT_ACCESS_TOKEN`, reads the runtime ARN from `/inspection-agent/<env>/runtime/runtime-arn`, and calls the HTTPS invocation URL. This spec extends it with persona sign-in. It does not create a new script.
- `scripts/deploy.sh` already deploys the `runtime` stack twice (step 4 with `MemoryId=` empty, step 6 with the memory ID). It passes only `Env` and `MemoryId`, so it needs a change to pass the code package location.
- `src/inspection_core/db.py` reads the secret named `inspection-agent/<env>/database/agent-ro` and takes the environment name from `INSPECTION_ENV` and the Region from `AWS_REGION`. It reads no host or secret ARN variable today.
- The tech rule forbids test files. Every acceptance criterion in this document is verified by hand (deploy, invoke, inspect).
- The default model is `us.anthropic.claude-haiku-4-5-20251001-v1:0` with Destination_Regions us-east-1, us-east-2, and us-west-2 (`docs/spikes/model-access.md`).

## Glossary

- **Runtime_Stack**: The CloudFormation stack `inspection-agent-<env>-runtime`, defined in `infra/runtime.yaml`.
- **Agent_Runtime**: The `AWS::BedrockAgentCore::Runtime` resource in the Runtime_Stack.
- **Runtime_Template**: The file `infra/runtime.yaml`.
- **Package_Script**: The script `scripts/package-agent.sh`.
- **Invoke_Script**: The existing script `scripts/invoke.sh`.
- **Deploy_Script**: The existing script `scripts/deploy.sh`.
- **Code_Package**: The zip file that holds `src/inspection_agent/`, `src/inspection_core/`, and their Python dependencies, built for the platform and Python version that AgentCore code deployment requires.
- **Artifact_Bucket**: The versioned S3 bucket that holds Code_Packages. It is created by the Runtime_Stack unless the design chooses a shared artifacts bucket.
- **Package_Location**: The S3 bucket name, object key, and object version ID of one uploaded Code_Package.
- **Execution_Role**: The IAM role that the Agent_Runtime assumes.
- **Inference_Profile**: The Amazon Bedrock inference profile named by the ModelId parameter.
- **Destination_Regions**: The AWS Regions to which a geographic Inference_Profile (prefix `us.`) can route a request. A global Inference_Profile (prefix `global.`) has no fixed Destination_Regions. Its routing is evaluated with the request Region `unspecified`.
- **JWT_Authorizer**: The custom JWT inbound authorizer of the Agent_Runtime, configured with the Cognito discovery URL and the allowed client ID.
- **Header_Allowlist**: The request header allowlist of the Agent_Runtime. It lists the HTTP request headers that the runtime forwards to the agent code.
- **Network_Parameters**: The SSM parameters `/inspection-agent/<env>/network/private-subnet-ids` and `/inspection-agent/<env>/network/runtime-security-group-id`.
- **Auth_Parameters**: The SSM parameters `/inspection-agent/<env>/auth/discovery-url` and `/inspection-agent/<env>/auth/app-client-id`.
- **Database_Parameters**: The SSM parameters `/inspection-agent/<env>/database/endpoint` and `/inspection-agent/<env>/database/agent-ro-secret-arn`.
- **Read_Only_Secret**: The Secrets Manager secret `inspection-agent/<env>/database/agent-ro`, whose ARN is in the Database_Parameters.
- **MemoryId_Parameter**: The CloudFormation parameter `MemoryId` of the Runtime_Stack. It is empty until the memory stack exists.
- **Invocation_URL**: The HTTPS URL `https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<URL-encoded runtime ARN>/invocations?qualifier=DEFAULT`.
- **Session_ID**: The value of the header `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id`. It has at least 33 characters.
- **Persona**: One of `inspector-a`, `inspector-b`, and `supervisor` as defined in `docs/auth.md`.
- **Demo_Prompt**: One of the demo questions in `.kiro/steering/product.md`, with the expected answers in `data/STORIES.md`.
- **Runtime_Doc**: The document `docs/runtime.md`.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: Reproducible code package

**User Story:** As a developer, I want one script that builds and uploads the agent code package, so that I can deploy the same code again from the same source.

#### Acceptance Criteria

1. WHEN the Package_Script runs, THE Package_Script SHALL build a Code_Package that contains `inspection_agent`, `inspection_core`, and every dependency pinned in `src/inspection_agent/requirements.txt`.
2. THE Package_Script SHALL download dependency wheels for the Python version that the AgentCore code deployment documentation requires and for an arm64 Linux platform tag that the design records and that Amazon Linux 2023 supports.
3. WHEN the Package_Script runs twice on the same source tree and the same dependency versions, THE Package_Script SHALL produce two Code_Packages with the same SHA-256 digest.
4. WHEN the Package_Script finishes, THE Package_Script SHALL write the Code_Package under `build/` and upload it to the Artifact_Bucket.
5. WHEN the upload finishes, THE Package_Script SHALL print the Package_Location and the SHA-256 digest of the Code_Package.
6. WHEN the Package_Script is given `--env` and `--region`, THE Package_Script SHALL use them, with the defaults `demo` and `us-west-2`.
7. IF `--env` does not match the pattern `^[a-z][a-z0-9]{0,9}$`, THEN THE Package_Script SHALL exit with a non-zero status before any AWS call.
8. IF the Artifact_Bucket does not exist, THEN THE Package_Script SHALL exit with a non-zero status and name the stack to deploy first.
9. THE Package_Script SHALL contain no secret and print no secret.
10. THE Package_Script SHALL be compatible with bash 3.2, the default shell version on macOS.

### Requirement 2: Documented platform requirements

**User Story:** As a developer, I want the platform and Python requirements of AgentCore code deployment recorded, so that the package builds for the right target.

#### Acceptance Criteria

1. THE design document SHALL record, with a link to the AgentCore documentation and the date it was read, the CPU architecture, the Python version, the maximum package size, the entry point format, and the archive layout that AgentCore code deployment requires.
2. THE Runtime_Doc SHALL state the same platform and Python version values as the design document.
3. THE design document SHALL record whether the Code_Package includes the agent system prompt file and whether the dependency set fits the maximum package size.

### Requirement 3: Artifact bucket and package versions

**User Story:** As a developer, I want the packages stored in a versioned bucket, so that a code update is a new uploaded object and a stack update.

#### Acceptance Criteria

1. THE Runtime_Stack SHALL create the Artifact_Bucket with S3 versioning enabled.
2. THE Artifact_Bucket SHALL block all public access and use server-side encryption.
3. THE Artifact_Bucket SHALL deny requests that do not use TLS.
4. THE Runtime_Stack SHALL output the Artifact_Bucket name and publish it at `/inspection-agent/<env>/runtime/artifact-bucket`.
5. WHEN the Runtime_Stack is deleted, THE Runtime_Stack SHALL leave no Artifact_Bucket content that blocks the deletion of the bucket, or the Runtime_Doc SHALL state the manual step that empties the bucket first.
6. THE Runtime_Template SHALL have parameters for the Package_Location: the object key and the object version ID. The Artifact_Bucket is the bucket that the Runtime_Stack owns, so the template has no bucket-name parameter.
7. WHEN the object key or the object version ID parameter changes, THE Runtime_Stack SHALL update the Agent_Runtime to the new Code_Package.

### Requirement 4: Runtime resource

**User Story:** As a developer, I want the Agent_Runtime created from the S3 code package, so that I can deploy the agent without a container image.

#### Acceptance Criteria

1. THE Runtime_Stack SHALL create one Agent_Runtime whose artifact is the Code_Package at the Package_Location.
2. THE Agent_Runtime SHALL use the entry point `main.py`, a root-level file that the Package_Script generates and that imports the application from `inspection_agent.entrypoint`, and the Python version recorded in the design document.
3. THE Runtime_Template SHALL declare the parameter `Env` with the default `demo` and the allowed pattern `^[a-z][a-z0-9]{0,9}$`.
4. THE Runtime_Template SHALL declare the parameter `ModelId` with the default `us.anthropic.claude-haiku-4-5-20251001-v1:0` and an allowed pattern that accepts only geographic inference profile IDs that start with `us.` and global inference profile IDs that start with `global.`. The parameter does not accept bare foundation model IDs or other geographic prefixes.
5. THE Runtime_Template SHALL declare the parameter `IdleRuntimeSessionTimeout` with the default 900 and the allowed range 60 to 28800 seconds.
6. THE Runtime_Template SHALL declare the parameter `MaxLifetime` with the default 28800 and an allowed range whose lower bound is 60 seconds and whose upper bound is 28800 seconds.
7. THE Runtime_Template SHALL declare the parameter `LogLevel` with the allowed values `DEBUG`, `INFO`, `WARNING`, and `ERROR`, and the default `INFO`.
8. THE Runtime_Template SHALL declare the parameter `MemoryId` with the default empty string and a pattern that accepts the empty string or a valid AgentCore memory ID.
9. THE Runtime_Template SHALL apply the tags `Project` with the value `inspection-agent` and `Env` with the value of the `Env` parameter to every resource that supports tags.
10. THE Runtime_Template and the Deploy_Script SHALL NOT enforce an order between `IdleRuntimeSessionTimeout` and `MaxLifetime`. IF the two values form a combination that AgentCore rejects, THEN the AgentCore service validation SHALL reject the stack operation, and CloudFormation SHALL roll the Agent_Runtime back to its previous configuration.
11. WHEN only `IdleRuntimeSessionTimeout` changes, THE Runtime_Stack SHALL update the Agent_Runtime in place with no change to the Code_Package.

### Requirement 5: Runtime environment variables

**User Story:** As a developer, I want the runtime configured through environment variables from SSM, so that the agent finds its database and model without code changes.

#### Acceptance Criteria

1. THE Agent_Runtime SHALL receive the environment variables `INSPECTION_ENV` with the value of the `Env` parameter, `AWS_REGION` with the stack Region, and `INSPECTION_MODEL_ID` with the value of the `ModelId` parameter.
2. THE Agent_Runtime SHALL receive the environment variable `INSPECTION_MODEL_REGION` with the stack Region.
3. THE Agent_Runtime SHALL receive environment variables for the database host and the Read_Only_Secret ARN, with values from the Database_Parameters.
4. THE Agent_Runtime SHALL receive an environment variable for the log level with the value of the `LogLevel` parameter.
5. WHERE the `MemoryId` parameter is not empty, THE Agent_Runtime SHALL receive an environment variable that holds the memory ID.
6. WHILE the `MemoryId` parameter is empty, THE Agent_Runtime SHALL receive no memory ID environment variable and the Runtime_Stack SHALL create without error.
7. THE Runtime_Template SHALL read the Database_Parameters through parameters of type `AWS::SSM::Parameter::Value<String>`.
8. THE Agent_Runtime SHALL receive no environment variable that holds a password, a token, or a user identity.

### Requirement 6: VPC mode

**User Story:** As a platform engineer, I want the runtime to run inside the VPC, so that the database stays private and the network stack controls traffic.

#### Acceptance Criteria

1. THE Agent_Runtime SHALL use VPC network mode with the private subnets and the runtime security group from the Network_Parameters.
2. THE Runtime_Template SHALL read the Network_Parameters through parameters of type `AWS::SSM::Parameter::Value<List<String>>` and `AWS::SSM::Parameter::Value<String>`.
3. THE Execution_Role SHALL hold no EC2 network interface permission unless the first-deploy verification in Requirement 13 shows that the Agent_Runtime needs one. AgentCore creates the network interfaces through its service-linked role, which the design records.
4. IF the network stack has no private subnet in an Availability Zone that AgentCore supports, THEN THE Runtime_Doc SHALL name the check that the Reviewer runs before deployment.

### Requirement 7: Inbound JWT authentication

**User Story:** As a security engineer, I want the runtime to reject requests without a valid Cognito token before the agent code runs, so that only signed-in users reach the agent.

#### Acceptance Criteria

1. THE Agent_Runtime SHALL use a JWT_Authorizer with the discovery URL from the Auth_Parameters.
2. THE JWT_Authorizer SHALL allow only the client ID from the Auth_Parameters.
3. THE Runtime_Template SHALL read the Auth_Parameters through parameters of type `AWS::SSM::Parameter::Value<String>`.
4. THE Header_Allowlist SHALL contain `Authorization`.
5. THE Header_Allowlist SHALL contain no header other than `Authorization`.
6. WHEN a request arrives with no `Authorization` header, an expired token, a token signed by another issuer, or a token of another app client, THE Agent_Runtime SHALL reject the request with an HTTP 401 or 403 status before the agent code runs.
7. WHEN a request arrives with a valid access token, THE Agent_Runtime SHALL forward the `Authorization` header to the entrypoint.

### Requirement 8: Execution role, least privilege

**User Story:** As a security engineer, I want an execution role that grants only what the agent needs, so that a defect in the agent cannot reach other models, secrets, or memory.

#### Acceptance Criteria

1. THE Execution_Role SHALL trust only the AgentCore service principal, restricted with a condition on the source account and the runtime ARN pattern of this stack.
2. THE Execution_Role SHALL allow `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` only on the Inference_Profile ARN in the stack Region, on the foundation model ARN of the configured model in each Destination_Region of a geographic Inference_Profile, and, for a global Inference_Profile, on the foundation model ARN of the configured model in the stack Region and on the Region-less global foundation model ARN of the configured model. Each foundation model statement SHALL carry a `bedrock:InferenceProfileArn` condition that equals the Inference_Profile ARN, and each statement for a global Inference_Profile SHALL also carry an `aws:RequestedRegion` condition.
3. THE Execution_Role SHALL NOT allow `bedrock:InvokeModel` or `bedrock:InvokeModelWithResponseStream` on any model, profile, or ARN pattern other than those in criterion 2.
4. WHEN the `ModelId` parameter holds a geographic or global inference profile ID, THE Runtime_Template SHALL derive the foundation model ID from that profile ID, and, for a geographic profile ID, the Destination_Regions.
5. IF the `ModelId` parameter holds an ID that is not a `us.` or `global.` inference profile ID, THEN THE Runtime_Template SHALL reject the stack operation before any resource changes.
6. THE Execution_Role SHALL allow `secretsmanager:GetSecretValue` only on the Read_Only_Secret.
7. THE Execution_Role SHALL hold no S3 permission unless the first-deploy verification in Requirement 13 shows that the Agent_Runtime needs one. The identity that calls the AgentCore create and update operations reads the Code_Package. IF the Execution_Role needs an S3 permission, THEN the permission SHALL be limited to `s3:GetObject` and `s3:GetObjectVersion` on the package prefix of the Artifact_Bucket.
8. THE Execution_Role SHALL allow writing logs only to the log group of the Agent_Runtime and the actions for traces that the AgentCore documentation lists.
9. WHERE the `MemoryId` parameter is not empty, THE Execution_Role SHALL allow AgentCore memory actions only on the memory resource with that ID.
10. WHILE the `MemoryId` parameter is empty, THE Execution_Role SHALL allow no AgentCore memory action.
11. THE Execution_Role SHALL allow no action on the master secret or the owner secret.
12. THE Runtime_Template SHALL follow Rule 5 and Rule 6 of `docs/cloudformation-conventions.md`: no service-level wildcard action, a YAML comment above every statement that uses `*` as a resource, and no literal account ID, Region, or ARN string.

### Requirement 9: Outputs and SSM parameters

**User Story:** As an operator, I want the runtime identifiers published, so that scripts and later stacks find the runtime without reading the stack.

#### Acceptance Criteria

1. THE Runtime_Stack SHALL output the Execution_Role ARN, the Artifact_Bucket name, and the Invocation_URL pattern, and, once a Code_Package is configured, the Agent_Runtime ARN and the Agent_Runtime ID, each with a non-empty description.
2. THE Runtime_Stack SHALL publish the Agent_Runtime ARN at `/inspection-agent/<env>/runtime/runtime-arn`.
3. THE Runtime_Stack SHALL publish the Invocation_URL pattern at `/inspection-agent/<env>/runtime/invocation-url`.
4. THE Runtime_Stack SHALL publish the Agent_Runtime ID at `/inspection-agent/<env>/runtime/runtime-id` and the Execution_Role ARN at `/inspection-agent/<env>/runtime/execution-role-arn`.
5. THE Runtime_Stack SHALL use no CloudFormation export for these values.
6. THE Runtime_Template SHALL pass `cfn-lint infra/runtime.yaml` with zero errors and zero warnings.

### Requirement 10: Deploy sequence integration

**User Story:** As a developer, I want `make deploy` to pass the package location to the runtime stack, so that the full deploy works with the code-in-S3 option.

#### Acceptance Criteria

1. THE Deploy_Script SHALL pass the Package_Location parameters, the SSM parameter names for `<env>`, and the derived profile scope of `ModelId` to the Runtime_Stack in step 4 and in step 6 of the Deploy_Sequence, and SHALL accept `--param Key=Value` overrides for one component.
2. IF no Code_Package exists in the Artifact_Bucket when the Deploy_Script needs it, THEN THE Deploy_Script SHALL exit with a non-zero status and name the Package_Script.
3. THE design document SHALL state how the first deploy handles the dependency between the Artifact_Bucket, which the Runtime_Stack creates, and the first Code_Package upload.
4. WHEN the Reviewer runs `scripts/deploy.sh deploy runtime` again with the same parameters, THE Deploy_Script SHALL finish with no resource change.

### Requirement 11: Invoke script with persona sign-in

**User Story:** As a Reviewer, I want `scripts/invoke.sh` to sign in as a persona and call the runtime, so that I can check every acceptance criterion from the command line.

#### Acceptance Criteria

1. WHERE the option `--persona` is given with `inspector-a`, `inspector-b`, or `supervisor`, THE Invoke_Script SHALL sign in as that Persona with the method in section 7 of `docs/auth.md` and use the returned access token.
2. WHERE `AGENT_ACCESS_TOKEN` is set and `--persona` is not given, THE Invoke_Script SHALL use `AGENT_ACCESS_TOKEN`, as it does today.
3. IF both `--persona` and `AGENT_ACCESS_TOKEN` are present, THEN THE Invoke_Script SHALL exit with status 2 and name both.
4. WHEN the Invoke_Script signs in, THE Invoke_Script SHALL read the Persona password from the variable `DEMO_PASSWORD_INSPECTOR_A`, `DEMO_PASSWORD_INSPECTOR_B`, or `DEMO_PASSWORD_SUPERVISOR`, or from a prompt that does not echo.
5. THE Invoke_Script SHALL accept no option that carries a password, a token, or a user identity, and SHALL never print or write the token or the password.
6. WHEN the Invoke_Script calls the runtime, THE Invoke_Script SHALL send the Invocation_URL request over HTTPS with the `Authorization: Bearer` header and a Session_ID.
7. WHERE `--session-id` is not given or is shorter than 33 characters, THE Invoke_Script SHALL generate a fresh Session_ID.
8. WHEN the call finishes, THE Invoke_Script SHALL print the HTTP status code and the response body.
9. IF the HTTP status is not 2xx, THEN THE Invoke_Script SHALL print the status and the body and exit with a non-zero status.
10. THE Invoke_Script SHALL keep its current exit codes: 2 for a usage error or a missing token, and 3 for a missing runtime ARN parameter.
11. WHERE the sign-in needs a Python library, THE Invoke_Script SHALL install it in a temporary virtual environment outside the repository and remove the environment when it finishes.
12. THE Invoke_Script SHALL be compatible with bash 3.2.

### Requirement 12: Runtime document

**User Story:** As a developer, I want a document that explains how the runtime is deployed and updated, so that I do not expect a code update to change a running session.

#### Acceptance Criteria

1. THE Runtime_Doc SHALL state that each session runs the code that was deployed when the microVM of that session was created, and that a code update applies to new sessions.
2. THE Runtime_Doc SHALL state that a session keeps running the old code until the session ends by idle timeout, by MaxLifetime, or by being stopped, and SHALL name the Session_ID change that starts a new session.
3. THE Runtime_Doc SHALL describe the update procedure: run the Package_Script, then update the Runtime_Stack with the new Package_Location, then invoke with a fresh Session_ID.
4. THE Runtime_Doc SHALL describe each Runtime_Template parameter with its default and allowed range.
5. THE Runtime_Doc SHALL record the platform and Python version values from Requirement 2.
6. THE Runtime_Doc SHALL list the SSM parameters that the Runtime_Stack reads and publishes.
7. THE Runtime_Doc SHALL describe the manual verification of each acceptance criterion in Requirement 13.
8. THE Runtime_Doc SHALL be written in English.

### Requirement 13: Manual verification of the deployed behavior

**User Story:** As a Reviewer, I want each deployed behavior checked by hand, so that the acceptance criteria are verified without automated tests.

#### Acceptance Criteria

1. WHEN a request arrives without a valid JWT, THE Agent_Runtime SHALL reject the request before the agent code runs, and the Reviewer SHALL confirm that no entrypoint log line exists for that request.
2. WHEN the supervisor Persona asks a Demo_Prompt, THE Agent_Runtime SHALL return an answer produced with tool calls against the database, and the `actions` list in the response SHALL hold at least one entry.
3. WHEN the `inspector-b` Persona asks for line A data, THE Agent_Runtime SHALL return a response that contains a denial and no line A content.
4. WHEN the `IdleRuntimeSessionTimeout` parameter changes and the Runtime_Stack updates, THE Agent_Runtime SHALL update with no change to the Code_Package, and the Reviewer SHALL confirm the new value in the Agent_Runtime configuration.
5. WHEN a new Code_Package is uploaded and the Runtime_Stack updates, THE Agent_Runtime SHALL use the new code for a session started with a fresh Session_ID.
6. THE Execution_Role SHALL NOT allow invoking any model other than the configured Inference_Profile and its foundation model, for both a `us.` and a `global.` profile, and the Reviewer SHALL confirm this by reading the deployed role policy and by a failed `bedrock:InvokeModel` simulation for another model ID.
7. THE task list of this spec SHALL contain manual verification steps and no test files, test suites, fixtures, or evaluation harnesses.
8. WHEN the Agent_Runtime is first deployed, THE Reviewer SHALL invoke the Agent_Runtime and confirm that it starts. IF startup fails with an S3 or network interface permission error, THEN the Reviewer SHALL add only the fallback statements that the design documents for that error, and SHALL NOT add them otherwise.
9. WHEN the first-deploy path (Phase A, package upload, Phase B) is run, THE Reviewer SHALL record whether the Agent_Runtime created without a fallback, and IF it did not, THE Reviewer SHALL switch to the fallback that the design names.
