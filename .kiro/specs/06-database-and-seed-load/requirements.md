# Requirements Document

## Introduction

This feature creates the Amazon RDS for PostgreSQL database for the inspection-agent demo and a repeatable way to load the schema and the seed data from `data/` into it. The template is `infra/database.yaml` (stack `inspection-agent-<env>-database`). The database lives in the private subnets published by the network stack. Because the database is private, the load runs inside the VPC through an AWS Lambda function that an operator invokes on demand from a laptop with one command.

The feature also creates two database roles besides the master user: an owner role for DDL and loading, and a read-only application role `agent_ro` for the future agent tools. Credentials for all three database users are generated and held in AWS Secrets Manager. Endpoint, port, database name, and secret ARNs are published as SSM parameters under `/inspection-agent/<env>/database/`.

Out of scope: the agent tools, the agent, the runtime, the MCP server, and rotation of credentials.

All data is synthetic. All code, comments, docs, and output are in English. Per the steering Testing policy, this spec adds no test files. The Reviewer verifies each acceptance criterion by hand.

## Glossary

- **Database_Stack**: The CloudFormation stack `inspection-agent-<env>-database`, created from `infra/database.yaml`.
- **Network_Stack**: The CloudFormation stack `inspection-agent-<env>-network`, created from `infra/network.yaml`.
- **Database_Instance**: The RDS for PostgreSQL instance created by the Database_Stack.
- **Database_Name**: The name of the application database inside the Database_Instance. The value is `inspection`.
- **Master_User**: The RDS master user of the Database_Instance. The Seed_Function uses it only to create and update the Owner_Role and the Readonly_Role.
- **Owner_Role**: The database role `inspection_owner`. It owns all application tables and is used for DDL and for loading data.
- **Readonly_Role**: The database role `agent_ro`. It is the only database role the agent tools use.
- **Credential_Secrets**: The three AWS Secrets Manager secrets that hold the credentials of the Master_User, the Owner_Role, and the Readonly_Role. Their names are `inspection-agent/<env>/database/master`, `inspection-agent/<env>/database/owner`, and `inspection-agent/<env>/database/agent-ro`.
- **Application_Tables**: The seven tables defined in the Schema_File: `lines`, `parts`, `characteristics`, `inspectors`, `lots`, `inspection_reports`, and `measurements`.
- **Schema_File**: The file `data/schema.sql`.
- **Seed_Files**: The seven CSV files in `data/seed/`, one per Application_Table.
- **Seed_Function**: The AWS Lambda function in the Database_Stack that runs inside the private subnets, applies the Schema_File, loads the Seed_Files, and configures the roles.
- **Seed_Security_Group**: The security group published by the Network_Stack at `/inspection-agent/<env>/network/seed-security-group-id`. The Seed_Function uses it.
- **Seed_Command**: The operational script `scripts/seed.sh`, also reachable as `make seed`. It invokes the Seed_Function and prints the result.
- **Row_Count_Report**: The output of the Seed_Command that lists, for each Application_Table, the number of rows in the database and the number of data rows in the matching Seed_File.
- **Database_Parameters**: The SSM parameters under `/inspection-agent/<env>/database/` that the Database_Stack publishes.
- **Database_Doc**: The document `docs/database.md`.
- **Operator**: A person who runs `scripts/deploy.sh` and the Seed_Command with AWS credentials from a laptop.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: Database instance in the private subnets

**User Story:** As an operator, I want an RDS for PostgreSQL instance inside the private subnets of the project VPC, so that the database follows the network layout of the demo.

#### Acceptance Criteria

1. THE Database_Stack SHALL create one Database_Instance with the PostgreSQL engine, major version 16, and the initial database named by the Database_Name.
2. THE Database_Stack SHALL read the private subnet IDs from the SSM parameter `/inspection-agent/<env>/network/private-subnet-ids` and create a database subnet group from them.
3. THE Database_Stack SHALL read the database security group ID from the SSM parameter `/inspection-agent/<env>/network/database-security-group-id` and attach that security group to the Database_Instance.
4. THE Database_Stack SHALL set the Database_Instance property `PubliclyAccessible` to false.
5. THE Database_Stack SHALL declare an `InstanceClass` parameter with the default `db.t4g.micro`.
6. THE Database_Stack SHALL declare a `MultiAz` parameter with the allowed values `true` and `false` and the default `false`.
7. WHEN `MultiAz` is `true`, THE Database_Stack SHALL create the Database_Instance as a Multi-AZ deployment.
8. THE Database_Stack SHALL declare a `DeletionProtection` parameter with the allowed values `true` and `false` and the default `false`.
9. THE Database_Stack SHALL set the Database_Instance deletion protection to the value of the `DeletionProtection` parameter.
10. IF the SSM parameter for the private subnet IDs or for the database security group ID does not exist, THEN THE Database_Stack SHALL fail the stack creation with an error that names the missing parameter.

### Requirement 2: Instance protection settings

**User Story:** As an operator, I want storage encryption, backups, and encrypted connections on by default, so that the demo database meets the security baseline at low cost.

#### Acceptance Criteria

1. THE Database_Stack SHALL enable storage encryption on the Database_Instance.
2. THE Database_Stack SHALL set the automated backup retention period of the Database_Instance to 1 day.
3. THE Database_Stack SHALL attach a DB parameter group to the Database_Instance that sets `rds.force_ssl` to 1.
4. THE Database_Stack SHALL allocate gp3 storage of 20 GiB to the Database_Instance.
5. THE Database_Stack SHALL attach the tags `Project` with the value `inspection-agent` and `Env` with the value of the `Env` parameter to every resource of the Database_Stack that supports tags.
6. THE Database_Stack SHALL declare the `Env` parameter with the default `demo` and the pattern `^[a-z][a-z0-9]{0,9}$`.

### Requirement 3: Credentials in Secrets Manager

**User Story:** As a security reviewer, I want every database credential generated and stored in Secrets Manager, so that no plaintext credential exists in templates, parameters, environment variables, or the repository.

#### Acceptance Criteria

1. THE Database_Stack SHALL create the three Credential_Secrets with the names defined in the Glossary.
2. THE Database_Stack SHALL generate the password of each Credential_Secret with Secrets Manager at creation time.
3. THE Database_Stack SHALL store in each Credential_Secret the keys `username`, `password`, `host`, `port`, and `dbname`.
4. THE Database_Stack SHALL pass the Master_User password to the Database_Instance through a Secrets Manager reference and not through a template literal or a template parameter value.
5. THE Database_Stack SHALL set the Seed_Function environment variables to non-secret values only, namely the ARNs of the Credential_Secrets and the Database_Name.
6. THE Database_Stack SHALL grant the Seed_Function the permission `secretsmanager:GetSecretValue` on the three Credential_Secrets and on no other secret.
7. THE Database_Stack SHALL create the Credential_Secrets without a resource policy that grants access to any principal outside the account.
8. WHEN the Seed_Function runs, THE Seed_Function SHALL write no password to its log output and no password to its response.

### Requirement 4: Network path for the Seed_Function

**User Story:** As an operator, I want the Seed_Function to reach both the database and Secrets Manager from inside the VPC, so that loading works without a public database address or a bastion host.

#### Acceptance Criteria

1. THE Database_Stack SHALL place the Seed_Function in the private subnets read from `/inspection-agent/<env>/network/private-subnet-ids` and attach the Seed_Security_Group to the Seed_Function.
2. THE Network_Stack SHALL allow the Seed_Security_Group to open outbound HTTPS connections to Secrets Manager, both when `UseNatGateway` is `true` and when `UseVpcEndpoints` is `true`.
3. WHERE `UseVpcEndpoints` is `true`, THE Network_Stack SHALL allow inbound HTTPS from the Seed_Security_Group on the interface endpoint security group.
4. THE Network_Stack SHALL keep the Database_Instance security group free of any inbound rule whose source is a CIDR range.
5. THE Database_Stack SHALL contain no resource that assigns a public IP address, an Elastic IP address, or an internet-facing load balancer.
6. WHEN the Network_Stack is updated to satisfy criteria 2 and 3, THE Network_Stack SHALL keep the existing rules for the runtime security group unchanged.

### Requirement 5: Database roles

**User Story:** As a security reviewer, I want a read-only role for the agent and a separate owner role for DDL and loading, so that the agent cannot change data or schema even if a tool is misused.

#### Acceptance Criteria

1. WHEN the Seed_Function runs, THE Seed_Function SHALL create the Owner_Role and the Readonly_Role if absent, with the passwords from their Credential_Secrets.
2. WHEN the Seed_Function runs and a role exists, THE Seed_Function SHALL set the password of that role to the value in its Credential_Secret.
3. THE Seed_Function SHALL make the Owner_Role the owner of every Application_Table.
4. THE Seed_Function SHALL grant the Readonly_Role the `CONNECT` privilege on the database named by the Database_Name.
5. THE Seed_Function SHALL grant the Readonly_Role the `USAGE` privilege on the schema `public` and the `SELECT` privilege on each of the seven Application_Tables.
6. THE Seed_Function SHALL grant the Readonly_Role no privilege other than those listed in criteria 4 and 5.
7. THE Seed_Function SHALL revoke the `TEMPORARY` privilege on the database and the `CREATE` privilege on the schema `public` from the Readonly_Role and from `PUBLIC`.
8. THE Seed_Function SHALL set the role-level `statement_timeout` of the Readonly_Role to 10 seconds.
9. THE Seed_Function SHALL set the connection limit of the Readonly_Role to 10.
10. THE Seed_Function SHALL set the role-level `default_transaction_read_only` of the Readonly_Role to `on`.
11. WHEN the Readonly_Role executes an `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, or DDL statement, THE Database_Instance SHALL reject the statement with an error.
12. WHEN the Readonly_Role executes a `SELECT` statement on an Application_Table, THE Database_Instance SHALL return the rows.

### Requirement 6: Seed function

**User Story:** As an operator, I want the load to run inside the VPC on demand, so that the private database can be loaded without a bastion host or a public address.

#### Acceptance Criteria

1. THE Database_Stack SHALL create the Seed_Function with the Python 3.12 runtime in region `us-west-2`.
2. THE Database_Stack SHALL grant the Seed_Function an execution role that follows least privilege: the AWS managed VPC access and logging permissions required for a Lambda function in a VPC, and `secretsmanager:GetSecretValue` as defined in Requirement 3.
3. THE Database_Stack SHALL package the Schema_File and the Seed_Files into the deployment artifact of the Seed_Function.
4. WHEN the Seed_Function receives an invocation, THE Seed_Function SHALL connect to the Database_Instance with TLS.
5. THE Seed_Function SHALL connect as the Master_User only to create or update the Owner_Role and the Readonly_Role, and SHALL connect as the Owner_Role to apply the Schema_File and to load the Seed_Files.
6. THE Seed_Function SHALL accept no SQL text, no credential, and no file path in its invocation payload.
7. THE Seed_Function SHALL have a timeout long enough for the load of the seven Seed_Files to complete, and a timeout value stated in the template.
8. THE Database_Stack SHALL declare no EventBridge rule, no trigger, and no schedule for the Seed_Function, so that the Seed_Function runs only when the Operator invokes it.

### Requirement 7: Schema and data load

**User Story:** As an operator, I want the load to create the schema and load every seed row in a way that is safe to repeat, so that I can reset the demo data at any time.

#### Acceptance Criteria

1. WHEN the Seed_Function runs on a database that has no Application_Table, THE Seed_Function SHALL create all objects defined in the Schema_File.
2. WHEN the Seed_Function runs on a database whose Application_Tables already exist, THE Seed_Function SHALL complete the schema step without error and SHALL leave the existing table definitions unchanged.
3. WHEN the Seed_Function runs on a database in which a table or an index defined in the Schema_File is absent, THE Seed_Function SHALL create the absent object.
4. WHEN the Seed_Function runs, THE Seed_Function SHALL load the Seed_Files in an order that satisfies all foreign keys: `lines`, `parts`, `characteristics`, `inspectors`, `lots`, `inspection_reports`, `measurements`.
5. WHEN the Seed_Function finishes the load, THE content of each Application_Table SHALL equal the data rows of the matching Seed_File.
6. WHEN the Seed_Function runs a second time with unchanged Seed_Files, THE content of every Application_Table SHALL equal the content after the first run.
7. THE Seed_Function SHALL run the data load of all seven Application_Tables in one database transaction.
8. IF any step of the load fails, THEN THE Seed_Function SHALL roll back the data load transaction, leave the Application_Tables as they were before the invocation, and return an error that names the failing step and the table.
9. THE Seed_Function SHALL apply the roles and grants of Requirement 5 after the schema and data steps, so that the grants cover tables created in the same run.
10. THE Seed_Function SHALL read only the Schema_File and the Seed_Files from its deployment artifact and SHALL read the file `data/seed/METADATA.json` to confirm that the key `synthetic` has the value `true` before loading.
11. IF the key `synthetic` in `METADATA.json` is missing or is not `true`, THEN THE Seed_Function SHALL stop before any database change and return an error.

### Requirement 8: Seed command

**User Story:** As an operator, I want one command from my laptop that creates or updates the schema, loads the seed, and prints row counts, so that no manual SQL is needed.

#### Acceptance Criteria

1. WHEN the Operator runs `scripts/seed.sh --env <env> --region <region>`, THE Seed_Command SHALL deploy the current Schema_File and Seed_Files to the Seed_Function, invoke the Seed_Function, and print the Row_Count_Report.
2. THE Seed_Command SHALL accept the options `--env` with the default `demo` and `--region` with the default `us-west-2`, and SHALL reject an `--env` value that does not match `^[a-z][a-z0-9]{0,9}$` before any AWS call.
3. THE Seed_Command SHALL find the Seed_Function through a Database_Parameters entry or a Database_Stack output and not through a hard-coded name.
4. WHEN the Seed_Function returns success, THE Seed_Command SHALL print one line per Application_Table with the table name, the row count in the database, and the data row count of the matching Seed_File, and SHALL exit with status 0.
5. IF a row count in the database differs from the data row count of the matching Seed_File, THEN THE Seed_Command SHALL mark the line as a mismatch and exit with a non-zero status.
6. IF the Seed_Function returns an error, THEN THE Seed_Command SHALL print the error message and the step that failed, and SHALL exit with a non-zero status.
7. THE Seed_Command SHALL add a `make seed` target to the Makefile that passes `ENV` and `REGION` to the script.
8. THE Seed_Command SHALL require no manual SQL, no bastion host, and no password supplied by the Operator.
9. WHEN the Operator runs the Seed_Command twice in a row, THE Seed_Command SHALL print the same Row_Count_Report both times.
10. THE Seed_Command SHALL contain no secret and SHALL print no secret.

### Requirement 9: Published parameters and outputs

**User Story:** As a developer of later components, I want the connection facts and secret ARNs published in SSM, so that the runtime and the MCP server can read them without a cross-stack export.

#### Acceptance Criteria

1. THE Database_Stack SHALL publish these SSM parameters of type `String`: `/inspection-agent/<env>/database/endpoint`, `/inspection-agent/<env>/database/port`, `/inspection-agent/<env>/database/db-name`, `/inspection-agent/<env>/database/master-secret-arn`, `/inspection-agent/<env>/database/owner-secret-arn`, `/inspection-agent/<env>/database/agent-ro-secret-arn`, and `/inspection-agent/<env>/database/seed-function-name`.
2. THE Database_Stack SHALL set the values of the Database_Parameters to the endpoint address, the port, the Database_Name, the three Credential_Secret ARNs, and the Seed_Function name of the same stack.
3. THE Database_Stack SHALL publish no password and no secret value in any SSM parameter or stack output.
4. THE Database_Stack SHALL declare an output with a non-empty description for each identifier that an operator or another stack consumes.
5. THE Database_Stack SHALL attach the mandatory tags to every Database_Parameters entry.
6. THE Database_Stack SHALL use no CloudFormation `Export` and no `Fn::ImportValue`.

### Requirement 10: Template and repository hygiene

**User Story:** As a reviewer, I want the new template and scripts to follow the repository conventions and hold no secrets, so that the change passes lint and the security baseline.

#### Acceptance Criteria

1. THE `infra/database.yaml` template SHALL pass `cfn-lint` with zero errors and zero warnings.
2. THE `infra/database.yaml` template SHALL follow all 10 rules in `docs/cloudformation-conventions.md`.
3. THE `infra/network.yaml` template SHALL pass `cfn-lint` with zero errors and zero warnings after the change in Requirement 4.
4. THE Database_Stack SHALL contain no literal account ID, no literal region name, and no literal ARN string.
5. THE repository SHALL contain no password, access key, token, or private key in `infra/database.yaml`, in `scripts/seed.sh`, in the Seed_Function source, or in `docs/database.md`.
6. THE Seed_Function source SHALL live under `src/` and SHALL NOT live under `scripts/`.
7. WHEN the Operator runs `ruff check .`, THE repository SHALL report no violation in the Seed_Function source.
8. THE change SHALL add no test file, test suite, test fixture, or verification script.

### Requirement 11: Deploy sequence and documentation

**User Story:** As an operator, I want the new stack and the seed step described and wired into the existing workflow, so that I can follow one document from deploy to a loaded database.

#### Acceptance Criteria

1. WHEN the Operator runs `scripts/deploy.sh deploy database`, THE deploy script SHALL create or update the Database_Stack with the existing flow and no change to the order of the Deploy_Sequence.
2. WHEN the Operator runs `scripts/teardown.sh`, THE Database_Stack SHALL delete without a retained resource, WHILE `DeletionProtection` is `false`.
3. THE Database_Doc SHALL describe the architecture, the parameters, the three database users, the Credential_Secrets names, the Database_Parameters, the Seed_Command, and the teardown behavior including the effect of `DeletionProtection`.
4. THE `data/README.md` SHALL replace the sentence "A loading script is not part of this folder." with a pointer to the Seed_Command.
5. THE `scripts/README.md` SHALL list `scripts/seed.sh` as the seed operational script.
6. THE Database_Doc SHALL state the dependency on the Network_Stack change in Requirement 4 and the order: deploy the Network_Stack first, then the Database_Stack, then run the Seed_Command.

### Requirement 12: Manual verification of the read-only role

**User Story:** As a reviewer, I want a recorded hand check from inside the VPC, so that I can trust that the agent role can read and cannot write.

#### Acceptance Criteria

1. THE Database_Doc SHALL contain a section that lists the manual verification steps, run from inside the VPC, for example from an AWS CloudShell VPC environment in a private subnet that uses the Seed_Security_Group.
2. THE Database_Doc SHALL list a step that obtains the Readonly_Role password from Secrets Manager into a shell variable without printing it, and SHALL state that the password is not recorded in the document.
3. THE Database_Doc SHALL record, for the Readonly_Role, a `SELECT count(*)` on each Application_Table and the returned counts.
4. THE Database_Doc SHALL record, for the Readonly_Role, one `INSERT`, one `UPDATE`, one `DELETE`, one `TRUNCATE`, one `CREATE TABLE`, and one `CREATE TEMPORARY TABLE` statement, and the error returned for each.
5. THE Database_Doc SHALL record a step that shows a connection attempt to the Database_Instance from the Operator laptop, outside the VPC, that fails to connect, as evidence that the Database_Instance is not reachable from the internet.
6. THE Database_Doc SHALL record the date of the check and the observed result of each step, and SHALL contain no password and no token.
7. THE change SHALL add no script for the manual verification.
