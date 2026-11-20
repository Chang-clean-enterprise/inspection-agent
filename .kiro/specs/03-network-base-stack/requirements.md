# Requirements Document

## Introduction

This spec defines the network and shared base stack of "inspection-agent", a demo of an AI agent that answers questions about manufacturing inspection data. The stack is Strands Agents (Python 3.12) on Amazon Bedrock AgentCore Runtime, Claude models on Amazon Bedrock, PostgreSQL on Amazon RDS, Amazon Cognito for sign-in, and AWS CloudFormation (YAML only) for all infrastructure, in region us-west-2. All data is synthetic. All code, comments, docs, and UI text are in English.

The deliverable is one CloudFormation template, `infra/network.yaml`, deployed as the stack `inspection-agent-<env>-network`. It provides the private network used by the AgentCore Runtime (VPC mode) and by the PostgreSQL database, and publishes its identifiers as SSM parameters for later stacks.

This spec maps to the spec folder `.kiro/specs/03-network-base-stack/`. The design records the GitHub issue number on the first line of its Overview, as `docs/kiro-workflow.md` requires.

Out of scope: the RDS instance, the AgentCore Runtime, and the runtime's IAM role. Those belong to later specs.

Project testing policy: this project forbids automated tests (`.kiro/steering/tech.md`). Every acceptance criterion is verified manually, with cfn-lint and by inspecting the deployed stack.

### Notes for the design phase

1. **Availability Zone verification.** The AgentCore documentation is expected to list `usw2-az1`, `usw2-az2`, and `usw2-az3` as supported for VPC mode in us-west-2. The design SHALL verify this against the current documentation, record the result and the source, and explain how AZ names such as `us-west-2a` map to AZ IDs in the deploying account.
2. **Seed/migration mechanism.** The database spec does not exist yet. This spec assumes the seed/migration mechanism connects from a dedicated security group created in this stack (Requirement 3). The design SHALL flag this assumption and record how the database spec is expected to attach to that group.
3. **Conflicts with steering.** The request and steering do not appear to conflict. The design SHALL list any conflict found. Points to check: Rule 4 tags on resources that support tags, Rule 10 (SSM parameters, no `Export`), and Rule 7 (zero cfn-lint warnings, stricter than the request's "without errors"). The stricter Rule 7 applies.
4. **Runtime egress targets and VPC endpoint availability.** The design SHALL document the services the runtime must reach (Amazon Bedrock runtime, AgentCore Memory data plane, Secrets Manager, CloudWatch Logs, tracing endpoints, Amazon S3) and an alternative based on VPC endpoints. It SHALL confirm in the current documentation which of those services offer interface or gateway endpoints in us-west-2.

## Glossary

- **Network_Stack**: The CloudFormation stack `inspection-agent-<env>-network`, defined by `infra/network.yaml`.
- **Template**: The file `infra/network.yaml`.
- **Env**: The value of the `Env` template parameter, matching `^[a-z][a-z0-9]{0,9}$`, default `demo`.
- **VPC**: The Amazon VPC created by the Network_Stack.
- **Private_Subnet**: A subnet created by the Network_Stack with no route to an internet gateway.
- **Public_Subnet**: A subnet created by the Network_Stack with a route to an internet gateway. It exists only to host a NAT gateway.
- **Supported_AZ**: An Availability Zone, identified by AZ ID, that AgentCore Runtime supports in VPC mode in us-west-2, as verified in the design.
- **NAT_Gateway**: An Amazon VPC NAT gateway that gives Private_Subnets outbound internet access.
- **UseNatGateway**: A template parameter, `true` or `false`, default `true`. It controls whether the Network_Stack creates Public_Subnets, an internet gateway, and a NAT_Gateway.
- **UseVpcEndpoints**: A template parameter, `true` or `false`, default `false`. It controls whether the Network_Stack creates VPC_Endpoints.
- **VPC_Endpoint**: An interface or gateway VPC endpoint created by the Network_Stack for a service whose availability in us-west-2 is confirmed in the design.
- **Runtime_Security_Group**: The security group intended for the AgentCore Runtime network interfaces.
- **Database_Security_Group**: The security group intended for the RDS for PostgreSQL instance.
- **Seed_Security_Group**: The security group intended for the seed/migration mechanism that loads data into the database.
- **Endpoint_Security_Group**: The security group attached to interface VPC_Endpoints. It exists only when UseVpcEndpoints is `true`.
- **Network_Parameters**: The SSM parameters published by the Network_Stack under `/inspection-agent/<env>/network/`.
- **Flow_Logs**: VPC flow logs delivered to a CloudWatch Logs log group.
- **EnableFlowLogs**: A template parameter, `true` or `false`, that controls whether the Network_Stack creates Flow_Logs.
- **FlowLogRetentionDays**: A template parameter that sets the retention in days of the Flow_Logs log group.
- **cfn-lint**: The CloudFormation linter run as `cfn-lint infra/network.yaml` from the repository root.

## Requirements

### Requirement 1: Private VPC across Supported AZs

**User Story:** As a platform engineer, I want a private VPC with one private subnet per supported Availability Zone, so that the AgentCore Runtime and the database run without direct internet exposure.

#### Acceptance Criteria

1. THE Template SHALL create exactly one VPC with DNS support enabled and DNS hostnames enabled.
2. THE Template SHALL create exactly one Private_Subnet in each of N Supported_AZs, where N is at least 2 and at most 3.
3. THE Template SHALL place every subnet, including every Public_Subnet, in a Supported_AZ.
4. IF UseNatGateway is `false`, THEN THE Template SHALL create zero Public_Subnets.
5. THE Template SHALL create zero routes with an internet gateway target in any Private_Subnet route table.
6. THE Template SHALL disable auto-assignment of public IPv4 addresses on every Private_Subnet.
7. THE Template SHALL define the VPC CIDR and each subnet CIDR as separate parameters, each with a valid IPv4 CIDR default, where the VPC CIDR prefix length is between /16 and /24 inclusive, each subnet CIDR lies within the VPC CIDR, and no two subnet CIDRs overlap.
8. THE Template SHALL select the Availability Zone of each subnet by AZ ID.
9. IF fewer than 2 Supported_AZs are available in the Region, THEN THE Network_Stack SHALL fail stack creation with an error and leave no partial resources after rollback.

### Requirement 2: Outbound connectivity for the runtime

**User Story:** As a platform engineer, I want optional NAT-based internet egress and optional VPC endpoints, so that I can trade cost against connectivity for the demo.

#### Acceptance Criteria

1. THE Template SHALL create exactly one Public_Subnet in each Supported_AZ that contains a Private_Subnet.
2. THE Template SHALL create exactly one internet gateway attached to the VPC.
3. THE Template SHALL create exactly one NAT_Gateway, with one Elastic IP, in each Public_Subnet.
4. THE Template SHALL route the default route (0.0.0.0/0) of each Private_Subnet to the NAT_Gateway in the same Availability Zone.
5. THE Template SHALL route the default route (0.0.0.0/0) of each Public_Subnet to the internet gateway.
6. WHERE UseNatGateway is `false`, THE Template SHALL create zero NAT_Gateways, zero internet gateways, zero Public_Subnets, and zero Elastic IPs.
7. WHERE UseNatGateway is `false`, THE Template SHALL create no default route in any Private_Subnet route table.
8. WHERE UseVpcEndpoints is `true`, THE Template SHALL create one VPC_Endpoint for each service whose endpoint availability in us-west-2 is confirmed in the design.
9. WHERE UseVpcEndpoints is `false`, THE Template SHALL create zero VPC_Endpoints and zero Endpoint_Security_Groups.
10. WHERE UseVpcEndpoints is `true`, THE Template SHALL create one Endpoint_Security_Group whose only ingress rule allows TCP 443 from the Runtime_Security_Group.
11. WHERE UseVpcEndpoints is `true`, THE Template SHALL define no Endpoint_Security_Group ingress rule other than the TCP 443 rule from the Runtime_Security_Group.
12. THE Template SHALL define UseNatGateway and UseVpcEndpoints as parameters that accept only `true` or `false`.
13. IF a value other than `true` or `false` is supplied for UseNatGateway or UseVpcEndpoints, THEN THE Template SHALL reject the value during validation and create or modify no resources.

### Requirement 3: Security groups

**User Story:** As a security reviewer, I want least-privilege security groups for the runtime, database, and seed mechanism, so that the database is reachable only from approved sources.

#### Acceptance Criteria

1. THE Template SHALL create exactly three security groups in the VPC: the Runtime_Security_Group, the Database_Security_Group, and the Seed_Security_Group, plus the Endpoint_Security_Group only where UseVpcEndpoints is `true`.
2. THE Runtime_Security_Group SHALL have zero ingress rules.
3. THE Runtime_Security_Group SHALL allow egress on TCP 5432 only to the Database_Security_Group.
4. WHERE UseNatGateway is `true`, THE Runtime_Security_Group SHALL allow egress on TCP 443 to 0.0.0.0/0.
5. WHERE UseVpcEndpoints is `true`, THE Runtime_Security_Group SHALL allow egress on TCP 443 to the Endpoint_Security_Group.
6. IF UseNatGateway is `false`, THEN THE Runtime_Security_Group SHALL have no egress rule to 0.0.0.0/0.
7. THE Database_Security_Group SHALL have exactly two ingress rules: TCP 5432 from the Runtime_Security_Group and TCP 5432 from the Seed_Security_Group.
8. THE Database_Security_Group SHALL have no ingress rule whose source is 0.0.0.0/0 or ::/0.
9. THE Database_Security_Group SHALL have zero egress rules to 0.0.0.0/0 or ::/0.
10. THE Seed_Security_Group SHALL have zero ingress rules.
11. THE Seed_Security_Group SHALL allow egress on TCP 5432 only to the Database_Security_Group.
12. THE Template SHALL define every security group rule that references another security group as a standalone rule resource that references the security group by ID, with zero circular dependencies.

### Requirement 4: Published identifiers

**User Story:** As a developer of later stacks, I want the network identifiers published as SSM parameters, so that other stacks can consume them without cross-stack exports.

#### Acceptance Criteria

1. WHEN stack creation completes, THE Network_Stack SHALL have published the Network_Parameters `vpc-id`, `private-subnet-ids`, `runtime-security-group-id`, `database-security-group-id`, and `seed-security-group-id` under `/inspection-agent/<env>/network/`.
2. THE Network_Stack SHALL publish exactly five Network_Parameters when UseNatGateway is `false` and exactly six when UseNatGateway is `true`.
3. THE Network_Stack SHALL publish `private-subnet-ids` as a StringList of subnet IDs, comma-separated with no spaces, ordered ascending by AZ ID.
4. WHERE UseNatGateway is `true`, THE Network_Stack SHALL publish `public-subnet-ids` as a StringList of subnet IDs, comma-separated with no spaces, ordered ascending by AZ ID.
5. WHERE UseNatGateway is `false`, THE Network_Stack SHALL create no `public-subnet-ids` parameter.
6. THE Template SHALL define one template output per Network_Parameter, each with a description of 1 to 1024 characters.
7. THE Template SHALL define no `Export` and no `Fn::ImportValue`.
8. WHEN the Network_Stack is deleted, THE Network_Stack SHALL remove all Network_Parameters.
9. IF creation of any Network_Parameter fails, THEN THE Network_Stack SHALL roll back and leave no Network_Parameters.

### Requirement 5: VPC flow logs

**User Story:** As a platform engineer, I want optional VPC flow logs with bounded retention, so that I can investigate network traffic when needed without paying for logs by default.

#### Acceptance Criteria

1. THE Template SHALL define EnableFlowLogs as a parameter that accepts only `true` or `false`, with default `false`.
2. THE Template SHALL define FlowLogRetentionDays with default 7 and allowed values 1, 3, 5, 7, 14, 30, 60, and 90.
3. WHERE EnableFlowLogs is `true`, THE Template SHALL create exactly one CloudWatch Logs log group and exactly one flow log resource with traffic type ALL and that log group as destination.
4. WHERE EnableFlowLogs is `true`, THE Template SHALL set the log group retention equal to FlowLogRetentionDays.
5. WHERE EnableFlowLogs is `true`, THE Template SHALL create exactly one IAM role whose trust policy names only the VPC flow logs service as principal.
6. WHERE EnableFlowLogs is `true`, THE IAM role SHALL grant only the actions that create a log stream and put log events, scoped to the log group ARN and its log streams, with no wildcard resource.
7. WHERE EnableFlowLogs is `false`, THE Template SHALL create zero flow log resources, zero flow log log groups, and zero flow log IAM roles.
8. IF FlowLogRetentionDays is outside the allowed values, THEN THE Template SHALL fail parameter validation before any resource is created.

### Requirement 6: Encryption defaults

**User Story:** As a security reviewer, I want encryption, secret handling, and endpoint access to follow least privilege, so that the network layer exposes no unnecessary access or sensitive values.

#### Acceptance Criteria

1. WHERE EnableFlowLogs is `true`, THE Flow_Logs log group SHALL be encrypted at rest, and the design SHALL state whether a customer-managed KMS key is used and why, given that CloudWatch Logs encrypts by default with a service-managed key.
2. THE Network_Parameters SHALL contain identifiers only and no secrets.
3. THE Runtime_Security_Group SHALL have exactly two egress rules, TCP 443 and TCP 5432, and no all-protocol rule.
4. WHERE UseVpcEndpoints is `true`, THE Endpoint_Security_Group SHALL have exactly one ingress rule, on TCP 443.
5. WHERE UseVpcEndpoints is `true`, THE Template SHALL attach to each VPC_Endpoint that supports an endpoint policy a policy restricting access to principals in the account of the Network_Stack.
6. WHERE UseVpcEndpoints is `true`, THE Template SHALL attach no policy to a VPC_Endpoint that does not support endpoint policies, and the design SHALL list those endpoints.
7. THE design SHALL state for each resource in the Template whether encryption at rest applies (yes or no) and give a one-sentence reason where the answer is no.

### Requirement 7: Template conventions

**User Story:** As a maintainer, I want the template to follow the project conventions, so that it is consistent, lint-clean, and portable across environments.

#### Acceptance Criteria

1. THE Template SHALL be a single YAML file at `infra/network.yaml`.
2. THE Template SHALL define exactly one `Env` parameter of type String with default `demo` and AllowedPattern `^[a-z][a-z0-9]{0,9}$`.
3. THE Template SHALL give every parameter a Description of 1 to 200 characters and at least one constraint.
4. THE Template SHALL tag every taggable resource with `Project=inspection-agent` and `Env`.
5. THE Template SHALL contain no literal 12-digit account ID, no literal region name, and no string starting with `arn:`.
6. WHEN `cfn-lint infra/network.yaml` is run from the repository root, THE Template SHALL produce exit code 0 with zero errors and zero warnings.
7. THE Template SHALL derive resource names only from Env and pseudo parameters.
8. THE Network_Stack SHALL be named `inspection-agent-<env>-network`.
9. THE Template SHALL write every IAM statement with explicitly named actions, with no wildcard in the service or action portion, and with specific resources except where resource-level scoping is unsupported.
10. IF Env does not match `^[a-z][a-z0-9]{0,9}$`, THEN THE Template SHALL reject the value before creating any resource.

### Requirement 8: Design documentation of Availability Zones and service reachability

**User Story:** As a designer, I want the design to record verified AZ support and service endpoint availability, so that the template rests on current documented facts.

#### Acceptance Criteria

1. THE design SHALL record the verified Supported_AZ IDs, the documentation URL, and the verification date in YYYY-MM-DD format, no more than 30 days before design approval.
2. IF the verified Supported_AZ IDs differ from `usw2-az1`, `usw2-az2`, and `usw2-az3`, THEN THE design SHALL record each added or removed AZ ID and use the verified list.
3. THE design SHALL list the six services the runtime must reach: Amazon Bedrock runtime, AgentCore Memory data plane, Secrets Manager, CloudWatch Logs, tracing endpoints, and Amazon S3.
4. THE design SHALL record for each of the six services the endpoint service name in us-west-2, the availability (yes or no), the type (Interface or Gateway), and the source URL.
5. IF a service has no VPC endpoint, THEN THE design SHALL mark the service "reachable only through NAT_Gateway" and cite the source.
6. THE design SHALL describe the VPC endpoint alternative, stating the services covered, the services not covered, and a monthly USD cost comparison against NAT_Gateway under stated assumptions of AZ count, endpoint count, and GB per month.
7. THE design SHALL record the AgentCore Runtime networking constraints, including minimum and maximum subnets, minimum and maximum security groups, and required rules, each with a source URL.

### Requirement 9: Manual verification

**User Story:** As a maintainer, I want manual verification steps with explicit pass criteria, so that the stack is verified without automated tests, as the project policy requires.

#### Acceptance Criteria

1. THE verification SHALL pass the cfn-lint step only if `cfn-lint infra/network.yaml` exits with code 0 and reports 0 errors and 0 warnings.
2. WHEN the Network_Stack is deployed with default parameters, THE verification SHALL run `aws ssm get-parameters-by-path` on `/inspection-agent/<env>/network/` with recursion across all result pages, and SHALL pass only if every required Network_Parameter name exists.
3. WHEN the Network_Stack is deployed with UseNatGateway `false`, THE verification SHALL list the NAT gateways in the VPC in the states available, pending, and failed, and SHALL pass only if the count is 0.
4. WHEN the Network_Stack is deployed, THE verification SHALL describe the Database_Security_Group and SHALL pass only if no ingress rule has source 0.0.0.0/0 or ::/0.
5. THE task list for this spec SHALL contain zero automated-test tasks.
6. IF a verification step fails, THEN THE verifier SHALL record the output, fix the Template, redeploy, and repeat the step until the step passes.
