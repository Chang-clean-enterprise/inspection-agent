# CloudFormation conventions

Every CloudFormation template in this repository follows the 10 rules below. Check a template against this document one rule at a time. The templates live in `infra/`, one per Component, as `infra/<component>.yaml`. See `.kiro/steering/structure.md` for the layout and naming rules.

## Rule 1: YAML only

Templates are written in YAML and saved with the `.yaml` file extension. JSON templates, AWS CDK, and Terraform are not used.

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: inspection-agent network stack
```

## Rule 2: Every parameter has a Description and a constraint

Every template parameter has a non-empty `Description` and at least one constraint from this list: `AllowedValues`, `AllowedPattern`, `MinLength`/`MaxLength`, `MinValue`/`MaxValue`, or an AWS-specific parameter type such as `AWS::EC2::VPC::Id` or `AWS::SSM::Parameter::Value<String>`.

```yaml
Parameters:
  DbName:
    Type: String
    Description: Name of the initial PostgreSQL database.
    Default: inspection
    AllowedPattern: ^[a-z][a-z0-9_]{0,62}$
  VpcId:
    Type: AWS::SSM::Parameter::Value<String>
    Description: SSM parameter name that holds the VPC ID published by the network stack.
    Default: /inspection-agent/demo/network/vpc-id
```

## Rule 3: Outputs for every consumed identifier

Every template declares an `Outputs` section. It has one output for each resource identifier, name, or ARN that another stack or an operator consumes. Every output has a non-empty `Description`.

```yaml
Outputs:
  DbEndpoint:
    Description: Endpoint address of the RDS for PostgreSQL instance.
    Value: !GetAtt Database.Endpoint.Address
```

## Rule 4: Mandatory tags

Every resource type that supports the `Tags` property carries the tag `Project` with the value `inspection-agent` and the tag `Env` with the value of the Env parameter.

```yaml
Resources:
  Database:
    Type: AWS::RDS::DBInstance
    Properties:
      Tags:
        - Key: Project
          Value: inspection-agent
        - Key: Env
          Value: !Ref Env
```

## Rule 5: IAM least privilege

IAM policy statements follow least privilege.

- No statement uses `*` as a full Action value or as a service-level action wildcard (for example `s3:*`).
- No statement uses `*` in a Resource value unless a YAML comment on the line directly above that statement gives the reason.

```yaml
Statements:
  - Effect: Allow
    Action:
      - ssm:GetParameter
    Resource: !Sub arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/inspection-agent/${Env}/*
  # logs:DescribeLogGroups does not support resource-level permissions.
  - Effect: Allow
    Action:
      - logs:DescribeLogGroups
    Resource: "*"
```

## Rule 6: No literal account IDs, regions, or ARN strings

Templates contain no literal 12-digit account IDs, no literal region names, and no literal ARN strings. Build such values with `!Sub` or `!Join` from the pseudo parameters `AWS::AccountId`, `AWS::Region`, and `AWS::Partition`, from template parameters, or from SSM keys.

```yaml
Resource: !Sub arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:inspection-agent/${Env}/*
```

## Rule 7: cfn-lint passes with zero errors and zero warnings

Every template passes cfn-lint with zero errors and zero warnings before it is committed. Run this command from the repository root to check one template:

```bash
cfn-lint infra/<component>.yaml
```

The region comes from `.cfnlintrc.yaml` at the repository root, so it is not passed on the command line:

```yaml
regions:
  - us-west-2
```

## Rule 8: Stack names

Every stack is deployed with the Stack_Name `inspection-agent-<env>-<component>`. `<env>` is the value of the Env parameter. `<component>` contains only lowercase letters, digits, and hyphens and is one of the 8 Component names.

```yaml
# Deployed as: inspection-agent-<env>-<component>
# Example:     inspection-agent-demo-runtime
Description: inspection-agent runtime stack
```

## Rule 9: Env parameter

Every template declares an `Env` parameter of type String with the default `demo` and the AllowedPattern `^[a-z][a-z0-9]{0,9}$`. It allows 1 to 10 characters, starts with a lowercase letter, and contains only lowercase letters and digits.

```yaml
Parameters:
  Env:
    Type: String
    Description: Deployment environment name. Part of every stack name and SSM parameter path.
    Default: demo
    AllowedPattern: ^[a-z][a-z0-9]{0,9}$
```

## Rule 10: Cross-stack values use SSM parameters

Values shared across stacks are published and read as SSM parameters named `/inspection-agent/<env>/<component>/<key>`, where `<component>` is the producing stack's Component. CloudFormation `Export` and `Fn::ImportValue` are not used for cross-stack values.

Producer, in the memory stack:

```yaml
Resources:
  MemoryIdParameter:
    Type: AWS::SSM::Parameter
    Properties:
      Name: !Sub /inspection-agent/${Env}/memory/memory-id
      Type: String
      Value: !GetAtt Memory.MemoryId
      Description: AgentCore Memory ID published for the runtime stack.
      Tags:
        Project: inspection-agent
        Env: !Ref Env
```

Consumer, in another stack:

```yaml
Parameters:
  MemoryIdParameterName:
    Type: AWS::SSM::Parameter::Value<String>
    Description: SSM parameter that holds the AgentCore Memory ID.
    Default: /inspection-agent/demo/memory/memory-id
```
