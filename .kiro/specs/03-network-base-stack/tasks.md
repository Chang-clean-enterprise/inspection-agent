# Implementation Plan: Network Base Stack

## Overview

GitHub issue: #3

This plan builds `infra/network.yaml`, the only deliverable of this spec, and deploys it as the stack `inspection-agent-<env>-network`. The template is CloudFormation YAML. The work follows the design's component order: parameters, mappings, and conditions; the VPC and private subnets; optional NAT egress; security groups; optional VPC endpoints; optional flow logs; SSM parameters and outputs; then the manual verification steps V1 to V10 from the design's Testing Strategy.

Project testing policy (`.kiro/steering/tech.md`): no automated tests. Every place a test task would appear is a manual verification step instead. Each one names the action to run by hand and the observable pass result. Record what was checked, and the result, as a sub-bullet under that task (the task notes). If a step fails, record the output, fix the template, redeploy, and repeat the step until it passes (Requirement 9.6).

Rules that apply to every task:

- The only file created or changed outside `.kiro/specs/03-network-base-stack/` is `infra/network.yaml`. Do not edit `requirements.md`, `scripts/`, `Makefile`, or `docs/`. Do not edit `infra/README.md`; it already lists the template.
- Follow `docs/cloudformation-conventions.md`: YAML only, every parameter has a Description of 1 to 200 characters and a constraint, `Project=inspection-agent` and `Env` tags on every resource type that has a `Tags` property, no literal account ID, region name, or `arn:` string (build ARNs with `!Sub arn:${AWS::Partition}:...`), `Resource: "*"` only with a comment directly above it, and no `Export` or `Fn::ImportValue`.
- Names come only from `Env` and pseudo parameters. The `Name` tag is `inspection-agent-${Env}-<what>`.
- Run `cfn-lint infra/network.yaml` from the repository root after every template task. Zero errors and zero warnings are required (Rule 7, Requirement 7.6).
- Deploy verification (task 8) creates billable resources (NAT gateways cost money while they exist; see the design cost table). One stack is reused through parameter updates and is torn down in task 8.9. Never run a deploy or teardown against an account the user has not confirmed.
- Replace every account-specific value with `<ACCOUNT_ID>` or another angle-bracket placeholder before writing command output into the task notes. Never paste `aws sts get-caller-identity` output.
- Deploy and delete go through `make deploy-network` and `make delete-network` (default parameters). Parameter overrides are not supported by `scripts/deploy.sh`, so for the update steps run `aws cloudformation deploy` directly with the same stack name, `--template-file infra/network.yaml`, `--region us-west-2`, `--capabilities CAPABILITY_NAMED_IAM`, `--no-fail-on-empty-changeset`, and `--parameter-overrides`.

Handling of the design's gaps (the design applies none of the proposed changes to `requirements.md`; this plan follows the design as written):

| Gap | Handling in this plan |
|---|---|
| G1 | Task 3.1 adds an inline TCP 443 egress rule from the Runtime_Security_Group to the S3 prefix list when `UseVpcEndpoints` is `true`, and task 1.1 adds the `S3PrefixListId` parameter. Verified in task 8.5 |
| G2 | Task 4.1 gives the five interface endpoints account-only policies and gives the S3 gateway endpoint the AgentCore service-principal policy. Verified in task 8.5 |
| G3 | Task 5.1 builds the flow log role with the two actions from Requirement 5.6. Task 8.6 proves whether two actions are enough. If it fails, record the output and stop. Amending Requirement 5.6 needs user approval, so do not widen the role on your own |
| G4 | Task 3.1 reads Requirement 6.3 as "only TCP 443 and TCP 5432, plus a loopback placeholder when needed". Verified in tasks 8.3 and 8.4 |
| G5 | Task 3.1 gives the Database, Seed, and Endpoint groups an inline loopback placeholder egress rule so no default allow-all egress remains. Tasks 8.3 and 8.5 read the placeholder as "zero egress" |
| G6 | Task 1.1 adds the `AzCount` parameter (`2` or `3`, default `2`) and the AZ ID mapping |
| G7 | Task 1.1 documents the CIDR containment and non-overlap rules in the parameter descriptions. EC2 rejects violations at subnet creation, which task 8.7 does not exercise (it is checked by reading the template in task 1.3) |
| G8 | No template work. The seed group stays minimal as the design specifies. The seed and endpoint-access question is recorded in the notes of task 6.1 and left to spec #6 |

## Tasks

- [x] 1. Template foundation, VPC, and private subnets
  - [x] 1.1 Create `infra/network.yaml` with parameters, mappings, and conditions
    - Create `infra/network.yaml` with `AWSTemplateFormatVersion` and a template `Description`
    - Parameters from design section 1: `Env` (String, default `demo`, `AllowedPattern: ^[a-z][a-z0-9]{0,9}$`), `UseNatGateway` (default `true`), `UseVpcEndpoints` (default `false`), `AzCount` (`"2"` or `"3"`, default `"2"`), `VpcCidr` (default `10.20.0.0/16`, prefix `/16` to `/24`), `PrivateSubnet1Cidr` to `PrivateSubnet3Cidr` (defaults `10.20.0.0/24`, `10.20.1.0/24`, `10.20.2.0/24`), `PublicSubnet1Cidr` to `PublicSubnet3Cidr` (defaults `10.20.100.0/24`, `10.20.101.0/24`, `10.20.102.0/24`), `S3PrefixListId` (default `pl-68a54001`, `AllowedPattern: ^pl-[0-9a-f]{8,17}$`), `EnableFlowLogs` (default `false`), and `FlowLogRetentionDays` (Number, default 7, allowed values 1, 3, 5, 7, 14, 30, 60, 90)
    - Boolean-style parameters use `AllowedValues: ["true", "false"]`
    - Every parameter has a Description of 1 to 200 characters and a constraint. The `UseNatGateway` and `UseVpcEndpoints` descriptions say that at least one must be `true` for an AgentCore Runtime to start. The subnet CIDR descriptions say each CIDR must lie inside `VpcCidr` and not overlap another (gap G7)
    - `Mappings` block with the AZ IDs `usw2-az1`, `usw2-az2`, `usw2-az3` (keys `First`, `Second`, `Third`)
    - Conditions from design section 2: `UseNat`, `UseEndpoints`, `HasAz3`, `NatAz3`, `FlowLogsOn`, `NoEgressPath`
    - _Requirements: 1.2, 1.7, 1.8, 2.12, 2.13, 5.1, 5.2, 5.8, 7.1, 7.2, 7.3, 7.10_

  - [x] 1.2 Add the VPC, private subnets, route tables, and associations
    - `Vpc` with `EnableDnsSupport: true` and `EnableDnsHostnames: true`
    - `PrivateSubnet1`, `PrivateSubnet2`, and `PrivateSubnet3` (only when `HasAz3`) using `AvailabilityZoneId` from the mapping and `MapPublicIpOnLaunch: false`
    - One `PrivateRouteTable` per AZ (the third only when `HasAz3`) and the subnet route table associations
    - Add no route to an internet gateway in any private route table
    - Tag `Vpc`, subnets, and route tables with `Project=inspection-agent`, `Env`, and a `Name` tag; the association resources have no tags
    - _Requirements: 1.1, 1.2, 1.3, 1.5, 1.6, 1.8, 1.9, 7.4, 7.7_

  - [x] 1.3 Manual verification: foundation
    - Run `cfn-lint infra/network.yaml` from the repository root. Pass: exit code 0, zero errors, zero warnings.
    - Read the template. Pass: `Env` is the only name input; subnets use `AvailabilityZoneId`; no `Fn::GetAZs` call; private route tables hold no internet gateway route; every parameter has a Description and a constraint; no 12-digit number, region name, or `arn:` string appears.
    - Read the CIDR parameters. Pass: the defaults lie inside `10.20.0.0/16` and do not overlap (gap G7 is handled by the descriptions and the EC2 check at deploy time).
    - Record what was checked and the results in the task notes.
    - Notes (task 1.3 run):
      - `cfn-lint infra/network.yaml`: exit code 4, zero errors, 8 warnings, all for items that later tasks use: W2001 unused parameters `PublicSubnet1Cidr`, `PublicSubnet2Cidr`, `PublicSubnet3Cidr` (task 2.1), `S3PrefixListId` (task 3.1), `FlowLogRetentionDays` (task 5.1); W8001 unused conditions `NatAz3` (task 2.1), `FlowLogsOn` and `NoEgressPath` (tasks 5.1 and 3.1). The zero-warning pass is therefore not yet met. It is expected to clear once tasks 2.1, 3.1, and 5.1 land and is re-checked in 2.2, 3.2, 5.2, and 6.2.
      - Template read: `Env` is the only name input (names use `!Sub inspection-agent-${Env}-...`); subnets use `AvailabilityZoneId` via `!FindInMap`; no `Fn::GetAZs`; no internet gateway or route resource exists, so private route tables hold no IGW route; every parameter has a Description (all under 200 characters) and a constraint (AllowedPattern or AllowedValues); grep for 12-digit numbers, `arn:`, `Export`, `ImportValue` finds nothing; the only region name is in a YAML comment (line 93), not in a resource value. Pass.
      - CIDR defaults: private 10.20.0.0/24, 10.20.1.0/24, 10.20.2.0/24 and public 10.20.100.0/24, 10.20.101.0/24, 10.20.102.0/24 all lie inside 10.20.0.0/16 and none overlap. Pass. Descriptions state the containment and non-overlap rule (G7).
      - `git status --porcelain`: only `infra/network.yaml` and `.kiro/specs/03-network-base-stack/` are new.
    - _Requirements: 1.1 to 1.9, 7.1 to 7.7, 7.10, 9.1_

- [x] 2. Optional NAT egress
  - [x] 2.1 Add the internet gateway, public subnets, NAT gateways, and routes
    - All resources in this task carry the `UseNat` condition. Resources for the third AZ also carry `NatAz3`
    - `InternetGateway` and `InternetGatewayAttachment`
    - `PublicSubnet1` to `PublicSubnet3` in the same AZ IDs as the private subnets, `MapPublicIpOnLaunch: false`
    - One shared `PublicRouteTable`, a `PublicDefaultRoute` (`0.0.0.0/0` to the internet gateway), and the associations
    - One `NatEip` (`Domain: vpc`, depends on the gateway attachment) and one `NatGateway` per public subnet
    - One `PrivateDefaultRoute` per private route table: `0.0.0.0/0` to the NAT gateway in the same AZ
    - With `UseNatGateway=false` the template creates no public subnet, internet gateway, NAT gateway, Elastic IP, or default route
    - _Requirements: 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 7.4_

  - [x] 2.2 Manual verification: NAT egress template
    - Run `cfn-lint infra/network.yaml`. Pass: exit code 0, zero errors, zero warnings.
    - Read the template. Pass: each NAT resource has the `UseNat` condition, the third-AZ resources have `NatAz3`, each private default route points to the NAT gateway of its own AZ, and the public route table is the only table with an internet gateway route.
    - Record what was checked and the results in the task notes.
    - Notes (task 2.2 run):
      - `cfn-lint infra/network.yaml`: exit code 4, zero errors, 4 warnings, all for items that later tasks use: W2001 unused parameters `S3PrefixListId` (line 66, task 3.1) and `FlowLogRetentionDays` (line 78, task 5.1); W8001 unused conditions `FlowLogsOn` (line 109, task 5.1) and `NoEgressPath` (line 110, task 3.1). The earlier warnings for `PublicSubnet1Cidr` to `PublicSubnet3Cidr` and `NatAz3` are gone. The zero-warning pass is not yet met; it is expected to clear after tasks 3.1 and 5.1 and is re-checked in 3.2, 5.2, and 6.2.
      - Template read: `InternetGateway`, `InternetGatewayAttachment`, `PublicSubnet1`/`2`, `PublicRouteTable`, `PublicDefaultRoute`, the public subnet associations for 1 and 2, `NatEip1`/`2`, `NatGateway1`/`2`, and `PrivateDefaultRoute1`/`2` carry `UseNat`. `PublicSubnet3`, `PublicSubnet3RouteTableAssociation`, `NatEip3`, `NatGateway3`, and `PrivateDefaultRoute3` carry `NatAz3` (`UseNat` and `HasAz3`). Each `PrivateDefaultRouteN` uses `NatGatewayId: !Ref NatGatewayN` with `RouteTableId: !Ref PrivateRouteTableN`, so each route targets the NAT gateway of its own AZ (NatGatewayN sits in PublicSubnetN, same AZ ID as PrivateSubnetN). `InternetGatewayId`/`GatewayId` appear only in the attachment and `PublicDefaultRoute`, so the public route table is the only table with an internet gateway route. Pass.
      - Cosmetic: no blank line between `PrivateSubnet3RouteTableAssociation` and `InternetGateway` (around line 144). cfn-lint does not flag it; left unchanged.
    - _Requirements: 1.4, 1.5, 2.1 to 2.7, 7.6_

- [x] 3. Security groups
  - [x] 3.1 Add the security groups and rules
    - `RuntimeSecurityGroup`, `DatabaseSecurityGroup`, `SeedSecurityGroup`, all in `Vpc`, tagged. Every group sets `SecurityGroupEgress` inline so the default allow-all egress rule is removed
    - Loopback placeholder (gap G5): `IpProtocol: "-1"`, `CidrIp: 127.0.0.1/32`, description "Placeholder. Removes the default allow-all egress rule." Use it inline on the Database and Seed groups, and on the Runtime group when `NoEgressPath` holds
    - Runtime group (gaps G1 and G4): zero ingress; inline TCP 443 to `0.0.0.0/0` when `UseNat`; inline TCP 443 to `S3PrefixListId` when `UseEndpoints`; standalone TCP 5432 egress to the Database group; the only ports are 443 and 5432, with no all-protocol rule to a routable address
    - Standalone rule resources, all by group ID, with no circular dependency: `RuntimeToDatabaseEgress`, `SeedToDatabaseEgress`, `DatabaseFromRuntimeIngress`, `DatabaseFromSeedIngress`
    - Database group: exactly two ingress rules (TCP 5432 from the Runtime group and from the Seed group), no `0.0.0.0/0` or `::/0` source, loopback placeholder egress only
    - Seed group: zero ingress, TCP 5432 egress to the Database group only
    - Add the `EndpointSecurityGroup` (`UseEndpoints`) with the loopback placeholder egress, plus standalone `EndpointFromRuntimeIngress` (TCP 443 from the Runtime group) and `RuntimeToEndpointEgress` (TCP 443 to the Endpoint group), both `UseEndpoints`
    - _Requirements: 2.9, 2.10, 2.11, 3.1 to 3.12, 6.3, 6.4, 7.4_

  - [x] 3.2 Manual verification: security group template
    - Run `cfn-lint infra/network.yaml`. Pass: exit code 0, zero errors, zero warnings.
    - Read the template. Pass: the Database group has exactly two ingress rule resources and no `0.0.0.0/0` or `::/0` anywhere in its rules; every group has inline `SecurityGroupEgress`; every rule that references another group is a standalone resource; the rule resources have no `Tags`; no resource refers back in a cycle (cfn-lint reports none).
    - Record what was checked and the results in the task notes.
    - Notes (task 3.2 run):
      - `cfn-lint infra/network.yaml`: exit code 4, zero errors, 2 warnings, both for items task 5.1 will use: W2001 unused parameter `FlowLogRetentionDays` (line 78) and W8001 unused condition `FlowLogsOn` (line 109). The warnings for `S3PrefixListId` and `NoEgressPath` are gone. The zero-warning pass is not yet met; it is expected to clear after task 5.1 and is re-checked in 5.2 and 6.2.
      - Template read (lines 448 to 596): the Database group has exactly two ingress rule resources (`DatabaseFromRuntimeIngress`, `DatabaseFromSeedIngress`, both TCP 5432 by source group ID) and no ingress inline. `0.0.0.0/0` appears in the security group section only once, at line 460 in the Runtime group egress (TCP 443 under `UseNat`). `::/0` does not appear in the template. Neither appears in any Database group rule. Pass.
      - `RuntimeSecurityGroup`, `DatabaseSecurityGroup`, `SeedSecurityGroup`, and `EndpointSecurityGroup` each set inline `SecurityGroupEgress`. Pass.
      - Every rule that references another group (`RuntimeToDatabaseEgress`, `SeedToDatabaseEgress`, `DatabaseFromRuntimeIngress`, `DatabaseFromSeedIngress`, `EndpointFromRuntimeIngress`, `RuntimeToEndpointEgress`) is a standalone resource. Inline rules use only CIDR or prefix list targets. Pass.
      - The six rule resources have no `Tags` property. Pass. cfn-lint reports no circular dependency.
    - _Requirements: 3.1 to 3.12, 6.3, 7.6_

- [x] 4. Optional VPC endpoints
  - [x] 4.1 Add the interface and gateway endpoints with policies
    - All resources carry `UseEndpoints`
    - Five interface endpoints, one per service from design section 5, each in every private subnet with the `EndpointSecurityGroup`, `PrivateDnsEnabled: true`, tags, and a policy: `BedrockRuntimeEndpoint`, `AgentCoreEndpoint`, `SecretsManagerEndpoint`, `LogsEndpoint`, `XrayEndpoint`. Build each service name with `!Sub com.amazonaws.${AWS::Region}.<service>`
    - Interface endpoint policies (gap G2): `Principal: "*"` with `StringEquals` on `aws:PrincipalAccount` set to `${AWS::AccountId}`; explicit actions and resources from the design table (`bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`; the 13 Memory data plane actions; `secretsmanager:GetSecretValue` and `DescribeSecret` on `secret:inspection-agent/${Env}/*`; the four `logs:` actions on `/aws/bedrock-agentcore/*`; the five `xray:` actions)
    - The `xray` policy uses `Resource: "*"` with a YAML comment on the line directly above it saying these actions do not support resource-level scoping
    - `S3Endpoint` (Gateway) attached to every private route table, with the policy from the design: `s3:GetObject` on the `acr-code-*-${AWS::Region}-an` bucket and its objects, for the service principal `bedrock-agentcore.amazonaws.com` (gap G2: this policy is not limited to account principals)
    - Build every ARN with `!Sub arn:${AWS::Partition}:...`
    - With `UseVpcEndpoints=false` the template creates no endpoint and no Endpoint_Security_Group
    - _Requirements: 2.8, 2.9, 6.4, 6.5, 6.6, 7.4, 7.5, 7.9_

  - [x] 4.2 Manual verification: endpoint template
    - Run `cfn-lint infra/network.yaml`. Pass: exit code 0, zero errors, zero warnings.
    - Read the template. Pass: six endpoints exist, five Interface and one Gateway, all under `UseEndpoints`; every policy names explicit actions; the only `Resource: "*"` is the `xray` statement and it has the comment directly above; no `arn:` literal appears outside `!Sub`.
    - Record what was checked and the results in the task notes.
    - Notes (task 4.2 run):
      - `cfn-lint infra/network.yaml`: exit code 4, zero errors, 2 warnings, both for items task 5.1 will use: W2001 unused parameter `FlowLogRetentionDays` (line 78) and W8001 unused condition `FlowLogsOn` (line 109). No warning comes from the endpoint resources. The zero-warning pass is not yet met; it is expected to clear after task 5.1 and is re-checked in 5.2 and 6.2.
      - Template read (lines 599 to 825): six `AWS::EC2::VPCEndpoint` resources, all with `Condition: UseEndpoints`. Five are `VpcEndpointType: Interface` (`BedrockRuntimeEndpoint`, `AgentCoreEndpoint`, `SecretsManagerEndpoint`, `LogsEndpoint`, `XrayEndpoint`) and one is `Gateway` (`S3Endpoint`). Every policy lists explicit actions. Pass.
      - `Resource: "*"` appears once (line 780, `XrayEndpoint`), with the comment on line 779 directly above it. Pass.
      - Every `arn:` match is inside a `!Sub` (a grep for `arn:` lines without `!Sub` returns nothing). Pass.
      - The five interface policies use `Principal: "*"` with `aws:PrincipalAccount` equal to `${AWS::AccountId}`. The S3 policy names the service principal `bedrock-agentcore.amazonaws.com` (gap G2). Pass.
      - Action name check against the AWS Service Authorization Reference for `bedrock-agentcore` (https://docs.aws.amazon.com/service-authorization/latest/reference/list_bedrock-agentcore.html): `BatchCreateMemoryRecords`, `BatchUpdateMemoryRecords`, and `BatchDeleteMemoryRecords` are the correct IAM action names, so no correction was made. The same page shows that `BatchCreateMemoryRecords` and `BatchUpdateMemoryRecords` also authorize `bedrock-agentcore:UpdateMemoryRecordExpirySpecification`. That action is not in the AgentCore endpoint policy. If a later spec sets record expiry through the batch calls, the endpoint policy needs that action. Left unchanged because the design's 13-action list is the task scope.
    - _Requirements: 2.8, 2.9, 6.5, 6.6, 7.5, 7.6, 7.9_

- [x] 5. Optional flow logs
  - [x] 5.1 Add the flow log group, role, and flow log
    - All resources carry `FlowLogsOn`
    - `FlowLogGroup`: name `/inspection-agent/${Env}/network/flow-logs`, `RetentionInDays: !Ref FlowLogRetentionDays`, tagged, no `KmsKeyId` (CloudWatch Logs default encryption, as the design decides)
    - `FlowLogRole`: trust policy with the single principal `vpc-flow-logs.amazonaws.com`, plus the `aws:SourceAccount` and `ArnLike` `aws:SourceArn` conditions from the design. The role policy allows only `logs:CreateLogStream` and `logs:PutLogEvents` on the log group ARN and `${arn}:*`, with no wildcard resource (gap G3: keep the two actions; do not add others)
    - `VpcFlowLog`: `ResourceType: VPC`, `TrafficType: ALL`, `LogDestinationType: cloud-watch-logs`, the log group, and `DeliverLogsPermissionArn` set to the role
    - With `EnableFlowLogs=false` the template creates no log group, flow log, or role
    - _Requirements: 5.1 to 5.7, 6.1, 7.4, 7.9_

  - [x] 5.2 Manual verification: flow log template
    - Run `cfn-lint infra/network.yaml`. Pass: exit code 0, zero errors, zero warnings.
    - Read the template. Pass: the trust policy lists only `vpc-flow-logs.amazonaws.com`; the role policy has exactly two actions and no `*` resource; the retention is the parameter; there is no `KmsKeyId`.
    - Record what was checked and the results in the task notes.
    - Notes (task 5.2 run):
      - `cfn-lint infra/network.yaml`: exit code 0, zero errors, zero warnings. The earlier warnings for `FlowLogRetentionDays` and `FlowLogsOn` are gone now that task 5.1 uses them. Pass.
      - Template read (lines 823 to 889): `FlowLogRole` trust policy lists the single principal `vpc-flow-logs.amazonaws.com`, with `aws:SourceAccount` and `ArnLike` `aws:SourceArn` conditions. Pass.
      - The role policy has exactly two actions, `logs:CreateLogStream` and `logs:PutLogEvents`, on the log group ARN and `${arn}:*`, both built with `!Sub`. No `*` resource in the role policy; the only `Resource: "*"` in the template is the `xray` endpoint statement (line 780). Pass.
      - `FlowLogGroup` has `RetentionInDays: !Ref FlowLogRetentionDays`. No `KmsKeyId` appears anywhere in the template. Pass.
      - `FlowLogGroup`, `FlowLogRole`, and `VpcFlowLog` all carry `Condition: FlowLogsOn`. `VpcFlowLog` uses `TrafficType: ALL`, `LogDestinationType: cloud-watch-logs`, and `DeliverLogsPermissionArn` from the role.
      - Whether two actions are enough for delivery (gap G3) is not checked here; task 8.6 covers it.
    - _Requirements: 5.3 to 5.7, 6.1, 7.6, 7.9_

- [x] 6. Published identifiers and outputs
  - [x] 6.1 Add the SSM parameters and template outputs
    - Five `AWS::SSM::Parameter` resources always created: `vpc-id`, `private-subnet-ids` (type `StringList`, `!Join [",", [...]]`, ordered `usw2-az1`, `usw2-az2`, `usw2-az3`, built from the subnets that exist for `AzCount`), `runtime-security-group-id`, `database-security-group-id`, and `seed-security-group-id`, all named `/inspection-agent/${Env}/network/<key>`
    - One more parameter, `public-subnet-ids` (`StringList`, same form), with the `UseNat` condition, so the count is 5 when `UseNatGateway=false` and 6 when `true`
    - Tag the parameters with the map form from Rule 10. The values are identifiers only
    - One output per parameter (`VpcId`, `PrivateSubnetIds`, `PublicSubnetIds` with `UseNat`, `RuntimeSecurityGroupId`, `DatabaseSecurityGroupId`, `SeedSecurityGroupId`), each with a Description of 1 to 1024 characters. No `Export`
    - Add no `DependsOn` between the parameters and other resources beyond what references create, so a failed parameter rolls back the whole stack
    - Task notes (gap G8, no template work): record that the Seed_Security_Group allows only TCP 5432 to the database, so a seed mechanism using only this group cannot reach any AWS API, and that the Endpoint_Security_Group accepts only the Runtime group. Spec #6 decides how to resolve this
    - Notes (task 6.1 run):
      - Added six `AWS::SSM::Parameter` resources (`VpcIdParameter`, `PrivateSubnetIdsParameter`, `RuntimeSecurityGroupIdParameter`, `DatabaseSecurityGroupIdParameter`, `SeedSecurityGroupIdParameter`, and `PublicSubnetIdsParameter` with `UseNat`) and six outputs (`PublicSubnetIds` with `UseNat`), at the end of `infra/network.yaml`. Subnet lists use `!If [HasAz3, ...]` with `!Join [",", ...]`. Tags use the map form. No `Export`, no `DependsOn`. `cfn-lint infra/network.yaml`: exit code 0.
      - Gap G8: the Seed_Security_Group allows only TCP 5432 to the Database_Security_Group, so a seed mechanism that uses only this group cannot reach any AWS API (Secrets Manager, CloudWatch Logs, S3). The Endpoint_Security_Group accepts TCP 443 only from the Runtime_Security_Group, and no endpoint security group ID is published, so a seed mechanism cannot use the VPC endpoints either. Spec #6 decides how to resolve this (for example its own TCP 443 group next to the seed group).
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 6.2, 7.4_

  - [x] 6.2 Manual verification: complete template
    - Run `cfn-lint infra/network.yaml` from the repository root. Pass: exit code 0, zero errors, zero warnings (design V1, Requirement 9.1).
    - Run `grep -nE 'Export|ImportValue|arn:|[0-9]{12}|us-(east|west)-[0-9]' infra/network.yaml`. Pass: no `Export` or `ImportValue`; no 12-digit number; no region name; every `arn:` match is inside a `!Sub`.
    - Run `grep -n 'Description' infra/network.yaml` and read each parameter and output. Pass: each parameter Description is 1 to 200 characters, each output Description is 1 to 1024 characters.
    - Run `git status --porcelain`. Pass: the only new or changed file outside `.kiro/specs/03-network-base-stack/` is `infra/network.yaml`.
    - Record what was checked and the results in the task notes.
    - Notes (task 6.2 run):
      - First grep run found one region name: line 93, a YAML comment that said "us-west-2". Requirement 7.5 and the task's grep both flag it, so the comment now reads "in the deployment Region". No other change.
      - `cfn-lint infra/network.yaml`: exit code 0, zero errors, zero warnings. Pass.
      - `grep -nE 'Export|ImportValue|arn:|[0-9]{12}|us-(east|west)-[0-9]'` after the fix: no `Export`, `ImportValue`, 12-digit number, or region name. Every `arn:` match (lines 622 to 863) is inside a `!Sub`; a check for `arn:` lines without `!Sub` returns zero. Pass.
      - `grep -n 'Description'`: all 14 parameter Descriptions are 1 to 123 characters (limit 200); the six SSM parameter Descriptions and six output Descriptions are well under 1024. Pass.
      - `git status --porcelain`: only `?? .kiro/specs/03-network-base-stack/` and `?? infra/network.yaml`. Pass.
    - _Requirements: 4.6, 4.7, 7.1 to 7.9, 9.1_

- [x] 7. Checkpoint - Confirm template checks
  - Confirm that tasks 1.3, 2.2, 3.2, 4.2, 5.2, and 6.2 passed and are recorded in the task notes. Ensure cfn-lint is clean, ask the user if questions arise.
  - Ask the user to confirm the AWS account and profile before task 8 creates billable resources.
  - Notes (task 7 run):
    - Template checks: tasks 1.3, 2.2, 3.2, 4.2, 5.2, and 6.2 are recorded above. The latest `cfn-lint infra/network.yaml` run (task 6.2) exited 0 with zero errors and zero warnings, and the user confirmed it is clean.
    - Account confirmation: the user ran `aws sts get-caller-identity` themselves for profile `luis:RealLifeProject:AdministratorAccess` in `us-west-2`. The account ID is `<ACCOUNT_ID>`. The user approved deploying the stack `inspection-agent-<env>-network` in this account and Region. No aws command was run for this checkpoint, and the command output is not recorded here.

- [x] 8. Manual verification on a deployed stack
  - [x] 8.1 V2: deploy defaults and read the published parameters
    - Run `make deploy-network`. Pass: the stack `inspection-agent-demo-network` reaches `CREATE_COMPLETE`.
    - Run `aws ssm get-parameters-by-path --path /inspection-agent/demo/network/ --recursive --region us-west-2 --query 'Parameters[].Name'`; the CLI follows result pages unless `--no-paginate` is given. Pass: exactly six names, the five required plus `public-subnet-ids`.
    - Read `private-subnet-ids` with `aws ssm get-parameter`. Pass: a StringList of two IDs, comma-separated with no spaces, in `usw2-az1`, `usw2-az2` order.
    - Run `aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id>`. Pass: every `AvailabilityZoneId` is one of the three Supported_AZs, private subnets have `MapPublicIpOnLaunch=false`, and there is one NAT gateway and one Elastic IP per AZ.
    - Record what was checked and the results in the task notes.
    - Notes (task 8.1 run):
      - Deploy: the user ran the deploy themselves (the command was blocked in the sandbox). Not run by the agent. `aws cloudformation describe-stacks` (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`) shows `inspection-agent-demo-network` in `CREATE_COMPLETE`. Pass.
      - SSM path `/inspection-agent/demo/network/`: exactly six parameters: `database-security-group-id`, `private-subnet-ids`, `public-subnet-ids`, `runtime-security-group-id`, `seed-security-group-id`, `vpc-id`. Pass.
      - `private-subnet-ids`: type `StringList`, value `subnet-09a7ad419487150c2,subnet-06a15b478c8ed0597`, two IDs, no spaces. The first is in `usw2-az1` and the second in `usw2-az2`. Pass.
      - `describe-subnets` on `vpc-0884be785334b4f22`: four subnets (two private 10.20.0.0/24 and 10.20.1.0/24, two public 10.20.100.0/24 and 10.20.101.0/24). AZ IDs are only `usw2-az1` and `usw2-az2`. `MapPublicIpOnLaunch` is `False` on all four. Pass.
      - NAT gateways in the VPC: two, both `available`, one in each public subnet (`usw2-az1` and `usw2-az2`). Elastic IPs tagged with this stack: two (domain `vpc`), one per NAT gateway. Pass.
    - _Requirements: 1.1 to 1.8, 2.1 to 2.5, 4.1 to 4.4, 9.2_

  - [x] 8.2 V3: NAT count with `UseNatGateway=false`
    - Update the stack with `aws cloudformation deploy ... --parameter-overrides UseNatGateway=false`.
    - Run `aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=<vpc-id> Name=state,Values=available,pending,failed --region us-west-2`. Pass: the NAT gateway count is 0.
    - List internet gateways, Elastic IPs, and subnets of the VPC and describe the route tables. Pass: zero internet gateways, zero public subnets, zero Elastic IPs from this stack, no `0.0.0.0/0` route.
    - Re-run the SSM path query from 8.1. Pass: five parameters and `public-subnet-ids` is gone.
    - Record what was checked and the results in the task notes.
    - Notes (task 8.2 run):
      - Update: the user ran the stack update themselves (stack-changing commands are blocked in the sandbox). Not run by the agent. `aws cloudformation describe-stacks` (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`) shows `inspection-agent-demo-network` in `UPDATE_COMPLETE` with `UseNatGateway=false` (`UseVpcEndpoints=false`, `AzCount=2`). Pass.
      - `describe-nat-gateways` on `vpc-0884be785334b4f22` with states `available,pending,failed`: count 0. Pass.
      - Internet gateways attached to the VPC: 0. Elastic IPs tagged with this stack: 0. Subnets: two (10.20.0.0/24 in `usw2-az1`, 10.20.1.0/24 in `usw2-az2`, both `MapPublicIpOnLaunch=False`), so zero public subnets. Pass.
      - Route tables of the VPC (three: two private plus the main table): every route is `10.20.0.0/16` to `local`. No `0.0.0.0/0` route. Pass.
      - SSM path `/inspection-agent/demo/network/`: five parameters (`database-security-group-id`, `private-subnet-ids`, `runtime-security-group-id`, `seed-security-group-id`, `vpc-id`). `public-subnet-ids` is gone. Pass.
    - _Requirements: 1.4, 1.5, 2.6, 2.7, 4.2, 4.5, 9.3_

  - [x] 8.3 V4: database security group has no open ingress
    - Run `aws ec2 describe-security-groups --group-ids <database-sg-id> --region us-west-2 --query 'SecurityGroups[0].IpPermissions'`. Pass: exactly two ingress rules (TCP 5432 from the Runtime group, TCP 5432 from the Seed group) and no rule with source `0.0.0.0/0` or `::/0`.
    - Run the same command with `--query 'SecurityGroups[0].IpPermissionsEgress'` on the database group. Pass: only the loopback placeholder (`127.0.0.1/32`) appears (gaps G5).
    - Run the ingress query on the Runtime and Seed groups. Pass: zero ingress rules on each.
    - Read the Runtime and Seed egress rules. Pass: TCP 5432 to the Database group only, plus the loopback placeholder on the Runtime group while both options are off (gap G4).
    - Record what was checked and the results in the task notes.
    - Notes (task 8.3 run):
      - Stack `inspection-agent-demo-network` in profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`, with `UseNatGateway=false`. Group IDs read from the SSM parameters: Runtime `sg-0e3bc777ed58c4462`, Database `sg-05a5c972813614631`, Seed `sg-08666b8091a3cc7d6`. Only read-only aws commands were run.
      - Database ingress: one permission entry, TCP 5432, with two group sources (the Runtime group and the Seed group), so exactly two rules. `IpRanges` and `Ipv6Ranges` are empty, so no `0.0.0.0/0` or `::/0`. Pass.
      - Database egress: only protocol `-1` to `127.0.0.1/32` (the placeholder, gap G5). Pass.
      - Runtime ingress: empty. Seed ingress: empty. Pass.
      - Runtime egress: TCP 5432 to the Database group, plus the `127.0.0.1/32` placeholder (gap G4, both options off). Seed egress: TCP 5432 to the Database group, plus the `127.0.0.1/32` placeholder (gap G5). No other targets. Pass.
    - _Requirements: 3.1 to 3.11, 6.3, 9.4_

  - [x] 8.4 V5: both options off
    - Update with `UseNatGateway=false UseVpcEndpoints=false`.
    - Describe the route tables and VPC endpoints. Pass: only local routes, zero VPC endpoints, zero Endpoint_Security_Groups, and no egress rule to `0.0.0.0/0` on the Runtime group.
    - Record in the task notes that a runtime cannot start in this mode (design section "Both UseNatGateway and UseVpcEndpoints false").
    - Record what was checked and the results in the task notes.
    - Notes (task 8.4 run):
      - Update step skipped: the deployed stack `inspection-agent-demo-network` (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`) was already in this state. `aws cloudformation describe-stacks` shows `UPDATE_COMPLETE` with `UseNatGateway=false`, `UseVpcEndpoints=false`, `EnableFlowLogs=false`, `AzCount=2`. Only read-only aws commands were run.
      - Route tables of `vpc-0884be785334b4f22`: three routes in total (two private tables plus the main table), all `10.20.0.0/16` to `local`. No other route. Internet gateways attached: 0. NAT gateways (available, pending, failed): 0. Pass.
      - VPC endpoints in the VPC: 0. Security groups in the VPC: the default group plus the Runtime, Database, and Seed groups, so zero Endpoint_Security_Groups. Pass.
      - Runtime group egress: TCP 5432 to the Database group and the `127.0.0.1/32` placeholder (protocol `-1`). No `0.0.0.0/0` rule. Pass.
      - A runtime cannot start in this mode: with both options off the VPC has no NAT egress and no VPC endpoints, so the runtime has no path to AgentCore, Bedrock, Secrets Manager, or CloudWatch Logs (design section "Both UseNatGateway and UseVpcEndpoints false"). This mode is valid only for template inspection.
    - _Requirements: 2.6, 2.7, 2.9, 3.6_

  - [x] 8.5 V6: endpoints on
    - Update with `UseNatGateway=false UseVpcEndpoints=true`.
    - Run `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=<vpc-id> --region us-west-2`. Pass: six endpoints (five Interface, one Gateway), each with a policy document naming explicit actions. The five interface policies name account principals; the S3 policy names the AgentCore service principal (gap G2).
    - Run `describe-security-groups` for the Endpoint group. Pass: exactly one ingress rule, TCP 443 from the Runtime group.
    - Run `describe-security-groups` for the Runtime group. Pass: egress TCP 443 to the Endpoint group and to the S3 prefix list, and TCP 5432 to the Database group (gap G1).
    - Record what was checked and the results in the task notes.
    - Notes (task 8.5 run):
      - Update step skipped: the user already updated the stack. `aws cloudformation describe-stacks` (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`) shows `inspection-agent-demo-network` in `UPDATE_COMPLETE` with `UseNatGateway=false`, `UseVpcEndpoints=true`, `EnableFlowLogs=false`, `AzCount=2`. Only read-only aws commands were run.
      - `describe-vpc-endpoints` on `vpc-0884be785334b4f22`: six endpoints, all `available`: five Interface (`bedrock-runtime`, `bedrock-agentcore`, `secretsmanager`, `logs`, `xray`, all `PrivateDnsEnabled=true`, all using the Endpoint group `sg-0b5a50725a2780615`) and one Gateway (`s3`). Pass.
      - Policies: each interface policy has `Principal: "*"` with `StringEquals` on `aws:PrincipalAccount` equal to `<ACCOUNT_ID>` and lists explicit actions (bedrock: 2; agentcore: 13 Memory actions; secretsmanager: 2; xray: 5; logs: 4). The S3 policy names the service principal `bedrock-agentcore.amazonaws.com` with `s3:GetObject` on `acr-code-*-us-west-2-an` and its objects (gap G2). Only the `xray` policy uses `Resource: "*"`. Pass.
      - Endpoint group ingress: exactly one rule, TCP 443 from the Runtime group `sg-0e3bc777ed58c4462`. Egress is only the `127.0.0.1/32` placeholder. Pass.
      - Runtime group: ingress empty. Egress: TCP 5432 to the Database group `sg-05a5c972813614631`, TCP 443 to the Endpoint group, TCP 443 to the S3 prefix list `pl-68a54001` (gap G1). No `0.0.0.0/0` rule and no placeholder, since an egress path exists. Pass.
    - _Requirements: 2.8, 2.10, 2.11, 3.5, 6.3, 6.4, 6.5, 6.6_

  - [x] 8.6 V7: flow logs on and off
    - Update with `UseNatGateway=false UseVpcEndpoints=false EnableFlowLogs=true`.
    - Run `aws ec2 describe-flow-logs`, `aws logs describe-log-groups --log-group-name-prefix /inspection-agent/demo/network/`, and `aws iam get-role` and `list-role-policies` for the flow log role. Pass: one flow log with `TrafficType=ALL` and the log group as destination, retention 7 days, no `kmsKeyId`, role trust names only `vpc-flow-logs.amazonaws.com`, and the role policy has exactly the two actions scoped to the log group.
    - After a few minutes run `aws logs describe-log-streams` on the group. Pass: at least one log stream exists, which proves two actions are enough (gap G3). If no stream appears, record the output, stop, and report to the user. Amending Requirement 5.6 needs approval.
    - Update with `EnableFlowLogs=false`. Pass: the log group, flow log, and role are gone.
    - Record what was checked and the results in the task notes.
    - Notes (task 8.6 run, first half: flow logs on):
      - Update step skipped: the user already updated the stack. `aws cloudformation describe-stacks` (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`) shows `inspection-agent-demo-network` in `UPDATE_COMPLETE` with `UseNatGateway=false`, `UseVpcEndpoints=false`, `EnableFlowLogs=true`, `FlowLogRetentionDays=7`, `AzCount=2`. Only read-only aws commands were run.
      - `describe-flow-logs`: one flow log `fl-0732fc0739f3bfa0c` on `vpc-0884be785334b4f22`, `TrafficType=ALL`, `LogDestinationType=cloud-watch-logs`, `LogGroupName=/inspection-agent/demo/network/flow-logs`, `FlowLogStatus=ACTIVE`, `DeliverLogsStatus=SUCCESS`, tagged `Project=inspection-agent` and `Env=demo`. Pass.
      - `describe-log-groups` with prefix `/inspection-agent/demo/network/`: one group, `retentionInDays=7`, no `kmsKeyId` field. Pass.
      - `iam get-role` for the flow log role: trust names only the service `vpc-flow-logs.amazonaws.com`, with conditions `aws:SourceAccount=<ACCOUNT_ID>` and `aws:SourceArn` like `arn:aws:ec2:us-west-2:<ACCOUNT_ID>:vpc-flow-log/*`. No attached managed policies. Pass.
      - `list-role-policies`: one inline policy, `inspection-agent-demo-flow-log-delivery`. `get-role-policy`: exactly two actions, `logs:CreateLogStream` and `logs:PutLogEvents`, on the log group ARN and `<log group ARN>:*` only. No wildcard resource. Pass.
      - Gap G3: `describe-log-streams` on the group returned ten streams (`eni-...-all`) in the first read, with ingestion times about two minutes after creation. Two actions are enough when the log group already exists. G3 resolved: Requirement 5.6 needs no amendment.
    - Notes (task 8.6 run, second half: flow logs off). All commands were read-only, with profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`:
      - The user ran the update. `aws cloudformation describe-stacks` shows `inspection-agent-demo-network` in `UPDATE_COMPLETE` with `EnableFlowLogs=false`. `UseNatGateway=false`, `UseVpcEndpoints=false`, `FlowLogRetentionDays=7`, and `AzCount=2` are unchanged.
      - `aws cloudformation list-stack-resources`: zero resources with `FlowLog` in the logical ID (`FlowLogGroup`, `FlowLogRole`, `VpcFlowLog` are gone from the stack).
      - `aws ec2 describe-flow-logs` (by tag `Project=inspection-agent` and by id `fl-0732fc0739f3bfa0c`): `FlowLogs` is empty both times. Pass.
      - `aws logs describe-log-groups --log-group-name-prefix /inspection-agent/demo/network/`: `logGroups` is empty. Pass.
      - Flow log role: the role name is generated by CloudFormation, so it was found by listing roles. `aws iam list-roles` has no role whose name contains `inspection-agent-demo-network`. The only role with a `vpc-flow-logs` trust is `vpc-flow-log-role-20240628205029980700000001`. That role is not part of this stack (name pattern and 2024 creation stamp differ), so it was left alone. Pass: the stack's flow log role is gone.
      - Result: V7 passes. Task 8.6 is ready to close.
    - _Requirements: 5.1 to 5.7, 6.1_

  - [x] 8.7 V8: invalid parameter values are rejected
    - Run `aws cloudformation deploy` with each of `UseNatGateway=maybe`, `Env=Demo`, `FlowLogRetentionDays=10`, and `AzCount=4`. Pass: each is rejected at validation with an error, and `aws cloudformation describe-stacks` shows the stack unchanged.
    - Record what was checked and the results in the task notes.
    - Notes (task 8.7 run). The user ran the four deploys; they cannot run in the sandbox, and nothing was redeployed. Each failed at `CreateChangeSet` with a `ValidationError`:
      - `UseNatGateway=maybe`: "Parameter 'UseNatGateway' must be one of AllowedValues". Pass (Requirement 2.13).
      - `Env=Demo`: "Parameter 'Env' must match pattern ^[a-z][a-z0-9]{0,9}$". Pass (Requirement 7.10).
      - `FlowLogRetentionDays=10`: "must be one of AllowedValues". Pass (Requirement 5.8).
      - `AzCount=4`: "must be one of AllowedValues". Pass.
      - Read-only check afterwards (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`): `aws cloudformation describe-stacks` shows `inspection-agent-demo-network` in `UPDATE_COMPLETE` with `UseNatGateway=false`, `UseVpcEndpoints=false`, `EnableFlowLogs=false`, `AzCount=2`, `Env=demo`, `FlowLogRetentionDays=7`, all unchanged from the end of task 8.6. `aws cloudformation list-change-sets` returns an empty list, so no change sets were left behind.
      - Result: V8 passes. Task 8.7 is ready to close.
    - _Requirements: 2.13, 5.8, 7.10_

  - [x] 8.8 V9: tags on every taggable resource
    - Run `describe-vpcs`, `describe-subnets`, `describe-security-groups`, `describe-nat-gateways` (restore `UseNatGateway=true` first so one exists), `describe-vpc-endpoints` (restore `UseVpcEndpoints=true`), and `aws ssm list-tags-for-resource` for one parameter. Pass: each shows `Project=inspection-agent` and `Env=demo`.
    - Record what was checked and the results in the task notes.
    - Notes (task 8.8 run). The user already restored `UseNatGateway=true` and `UseVpcEndpoints=true`, so the restore step was skipped. All commands were read-only, with profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`:
      - `aws cloudformation describe-stacks`: `inspection-agent-demo-network` is `UPDATE_COMPLETE` with `UseNatGateway=true`, `UseVpcEndpoints=true`, `EnableFlowLogs=false`, `AzCount=2`, `Env=demo`, `FlowLogRetentionDays=7`.
      - VPC `vpc-0884be785334b4f22` (read from SSM `vpc-id`): `Project=inspection-agent`, `Env=demo`. Pass.
      - Subnets: all four (two private, two public) carry both tags. Pass.
      - Security groups: the Runtime, Database, Seed, and Endpoint groups carry both tags. The VPC `default` group has no tags; it is created by EC2 with the VPC and is not a stack resource. Pass.
      - NAT gateways: two, both tagged. Pass.
      - VPC endpoints: six (s3, secretsmanager, bedrock-runtime, logs, xray, bedrock-agentcore), all tagged. Pass.
      - Route tables: the three stack route tables (two private, one public) are tagged. The fourth, `rtb-05090fa4c2f4445ba`, is the VPC main route table (`Main=True`), created by EC2 and not a stack resource; it has no tags. Pass.
      - Internet gateway: one, tagged. Elastic IPs: two, tagged. Pass.
      - SSM `list-tags-for-resource` on `/inspection-agent/demo/network/vpc-id`: `Project=inspection-agent` and `Env=demo`, plus the `aws:cloudformation:*` tags. Pass.
      - Result: V9 passes for every resource the stack creates. Only the two EC2 auto-created resources (default security group, main route table) are untagged.
    - _Requirements: 7.4_

  - [x] 8.9 V10: teardown
    - Run `make delete-network`, then `aws cloudformation describe-stacks --stack-name inspection-agent-demo-network`. Pass: the stack no longer exists.
    - Run the SSM path query and the V3 NAT query. Pass: zero parameters, zero NAT gateways remain.
    - If the stack ends in `DELETE_FAILED` because of AgentCore network interfaces, apply the recovery in the design section "Teardown and deletion order", then repeat the step.
    - Record what was checked and the results in the task notes.
    - Notes (task 8.9 run):
      - Delete: the user ran `make delete-network` themselves. The agent ran only read-only checks (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`).
      - `aws cloudformation describe-stacks --stack-name inspection-agent-demo-network`: ValidationError, the stack does not exist (no `DELETE_FAILED`). Pass.
      - SSM path `/inspection-agent/demo/network/`: zero parameters. Pass.
      - NAT gateways tagged `Project=inspection-agent` (states available, pending, failed, deleting): zero. VPC endpoints tagged `Project=inspection-agent`: zero. VPCs tagged `Project=inspection-agent`: zero. Elastic IPs tagged `Project=inspection-agent` or with the tag `aws:cloudformation:stack-name=inspection-agent-demo-network`: zero. Pass.
      - No network interface recovery was needed.
    - _Requirements: 4.8, 9.6_

- [x] 9. Final checkpoint - Confirm the stack is verified
  - Confirm that tasks 8.1 to 8.9 passed, that no billable resources remain, and that the notes record gaps G1 to G8. Ensure all checks pass, ask the user if questions arise.
  - Notes (task 9 run):
    - Tasks 8.1 to 8.9 are all marked complete and each note records a Pass result (8.1 deploy and SSM, 8.2 no NAT, 8.3 database group, 8.4 both options off, 8.5 endpoints, 8.6 flow logs on and off, 8.7 invalid parameters, 8.8 tags, 8.9 teardown).
    - `cfn-lint infra/network.yaml` re-run: exit code 0, zero errors, zero warnings. Pass.
    - Read-only re-check (profile `luis:RealLifeProject:AdministratorAccess`, `us-west-2`, account `<ACCOUNT_ID>`): `describe-stacks` for `inspection-agent-demo-network` returns "does not exist". NAT gateways tagged `Project=inspection-agent` (available, pending, failed, deleting): 0. Elastic IPs tagged `Project=inspection-agent`: 0. VPC endpoints tagged `Project=inspection-agent`: 0. No billable resources remain. Pass.
    - Gaps G1 to G8 are recorded: the handling table near the top of this file lists all eight. Verification results: G1 and G2 in task 8.5, G3 in task 8.6 (two actions are enough; Requirement 5.6 needs no amendment), G4 in tasks 8.3 and 8.4, G5 in task 8.3, G6 in tasks 8.1 and 8.7 (`AzCount` default 2 gives two AZs, `AzCount=4` is rejected), G7 in task 1.3 (read check; EC2 enforcement not exercised), G8 in task 6.1 (left to spec #6).

## Notes

- This spec has no automated tests. Every verification task is a manual step with an action and a pass result, as `.kiro/steering/tech.md` and `docs/kiro-workflow.md` require.
- The design has no Correctness Properties section, so no property test tasks exist.
- Not proven by this spec, and left to later specs: a real runtime starting with NAT off and endpoints on, and the endpoint policies allowing its calls (spec #9); seed mechanism reachability (spec #6, gap G8); the OTLP traces path over the `xray` endpoint (specs #9 and #11).
- Requirement changes proposed in the design (G1 to G7) are not applied. Apply them to `requirements.md` only with the user's approval.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2"] },
    { "id": 2, "tasks": ["1.3"] },
    { "id": 3, "tasks": ["2.1"] },
    { "id": 4, "tasks": ["2.2"] },
    { "id": 5, "tasks": ["3.1"] },
    { "id": 6, "tasks": ["3.2"] },
    { "id": 7, "tasks": ["4.1"] },
    { "id": 8, "tasks": ["4.2"] },
    { "id": 9, "tasks": ["5.1"] },
    { "id": 10, "tasks": ["5.2"] },
    { "id": 11, "tasks": ["6.1"] },
    { "id": 12, "tasks": ["6.2"] },
    { "id": 13, "tasks": ["7"] },
    { "id": 14, "tasks": ["8.1"] },
    { "id": 15, "tasks": ["8.2"] },
    { "id": 16, "tasks": ["8.3"] },
    { "id": 17, "tasks": ["8.4"] },
    { "id": 18, "tasks": ["8.5"] },
    { "id": 19, "tasks": ["8.6"] },
    { "id": 20, "tasks": ["8.7"] },
    { "id": 21, "tasks": ["8.8"] },
    { "id": 22, "tasks": ["8.9"] },
    { "id": 23, "tasks": ["9"] }
  ]
}
```
