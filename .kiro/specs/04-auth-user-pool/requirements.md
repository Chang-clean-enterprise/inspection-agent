# Requirements Document

## Introduction

This spec defines the sign-in and identity layer of "inspection-agent", a demo of an AI agent that answers questions about manufacturing inspection data. The stack is Strands Agents (Python 3.12) on Amazon Bedrock AgentCore Runtime, Claude models on Amazon Bedrock, PostgreSQL on Amazon RDS, Amazon Cognito for sign-in, and AWS CloudFormation (YAML only) for all infrastructure, in region us-west-2. All data is synthetic. All code, comments, docs, and UI text are in English.

The deliverables are:

- One CloudFormation template, `infra/auth.yaml`, deployed as the stack `inspection-agent-<env>-auth`. It creates an Amazon Cognito user pool, a public app client, a hosted UI domain, and three groups, and publishes its identifiers as SSM parameters.
- One operational script, `scripts/create-demo-users.sh` (the "create demo users" script from `.kiro/steering/structure.md`), that creates three demo users and assigns them to groups.
- One document, `docs/auth.md`, that describes the personas, the group-to-line mapping, and how to obtain a token.

The AgentCore Runtime validates the token of the signed-in user. The tool layer reads the verified identity, including group membership, from that token. Group membership is the only source of authorization.

This spec maps to the spec folder `.kiro/specs/04-auth-user-pool/`. The design records the GitHub issue number on the first line of its Overview, as `docs/kiro-workflow.md` requires.

Out of scope: the UI, the AgentCore Runtime and its JWT authorizer configuration, and the tool-layer authorization code. Those belong to later specs.

Project testing policy: this project forbids automated tests (`.kiro/steering/tech.md`). Every acceptance criterion is verified manually, with cfn-lint, ruff where Python is involved, and by inspecting the deployed stack.

### Notes for the design phase

1. **Token type verification.** The design SHALL verify in the current AgentCore documentation which token the AgentCore Runtime JWT authorizer validates (access token or ID token), which claims the authorizer checks (`allowedClients`, `allowedAudience`, `allowedScopes`), and how the verified claims, including `cognito:groups`, reach the agent code. The design SHALL record the result and the source URL. The design SHALL confirm that Cognito includes `cognito:groups` in access tokens and ID tokens, and SHALL state which claim (`client_id` for access tokens, `aud` for ID tokens) the authorizer matches against the app client ID.
2. **Custom attributes.** Custom attributes are not carried in access tokens unless a token customization is added. The design SHALL NOT rely on custom attributes. If the design adds a token customization, it SHALL justify it.
3. **Circular dependency and deploy order.** The UI domain exists only after the UI stack exists, and the UI stack needs the user pool and app client. `scripts/deploy.sh` already deploys `auth` at step 2 with default callback and logout URLs and redeploys `auth` at step 9 with `CallbackUrl` and `LogoutUrl` read from `/inspection-agent/<env>/ui/callback-url` and `/inspection-agent/<env>/ui/logout-url`. The design SHALL reuse this mechanism, SHALL keep the Auth_Stack free of any reference to the UI stack, and SHALL document the deploy order.
4. **Hosted UI domain prefix.** A Cognito domain prefix is unique per Region across accounts and cannot contain the strings `aws`, `amazon`, or `cognito`. The design SHALL choose a prefix scheme that is unique without a literal account ID in the template (Rule 6) and without a secret.
5. **Conflicts with steering.** The request and steering do not appear to conflict. The design SHALL list any conflict found. Points to check: Rule 2 (every parameter has a constraint, including URL parameters), Rule 4 (tags on resources that support them), Rule 6 (no literal region or ARN strings in the issuer URL), Rule 7 (zero cfn-lint warnings), Rule 10 (SSM parameters, no `Export`), and the rule that `scripts/` holds only the 10 allowed Operational_Scripts.

## Glossary

- **Auth_Stack**: The CloudFormation stack `inspection-agent-<env>-auth`, defined by `infra/auth.yaml`.
- **Template**: The file `infra/auth.yaml`.
- **Env**: The value of the `Env` template parameter, matching `^[a-z][a-z0-9]{0,9}$`, default `demo`.
- **User_Pool**: The Amazon Cognito user pool created by the Auth_Stack.
- **App_Client**: The Cognito user pool app client created by the Auth_Stack for the UI and for scripts.
- **Hosted_UI_Domain**: The Cognito domain, with a prefix chosen in the design, that serves the hosted sign-in pages.
- **Group**: A Cognito user pool group. The three Groups are `line-a`, `line-b`, and `supervisors`.
- **Demo_User**: One of the three users `inspector-a`, `inspector-b`, and `supervisor`, each with an `example.com` email address.
- **Access_Token**: The Cognito access token (JWT) issued after sign-in.
- **ID_Token**: The Cognito ID token (JWT) issued after sign-in.
- **Group_Claim**: The `cognito:groups` claim in a token.
- **Callback_URL**: The OAuth 2.0 redirect URI the hosted UI sends the authorization code to.
- **Logout_URL**: The URL the hosted UI redirects to after sign-out.
- **Discovery_URL**: The OpenID Connect discovery URL of the User_Pool, `https://cognito-idp.<region>.amazonaws.com/<user-pool-id>/.well-known/openid-configuration`.
- **Issuer_URL**: The `iss` value of tokens issued by the User_Pool, `https://cognito-idp.<region>.amazonaws.com/<user-pool-id>`.
- **Auth_Parameters**: The SSM parameters published by the Auth_Stack under `/inspection-agent/<env>/auth/`.
- **Demo_Users_Script**: The operational script `scripts/create-demo-users.sh`.
- **Auth_Doc**: The file `docs/auth.md`.
- **PKCE**: Proof Key for Code Exchange, the OAuth 2.0 extension that replaces a client secret for public clients.
- **cfn-lint**: The CloudFormation linter run as `cfn-lint infra/auth.yaml` from the repository root.
- **Deploy_Order**: The sequence in `scripts/deploy.sh` in which `auth` is deployed at step 2 and updated at step 9.

## Requirements

### Requirement 1: User pool and hosted UI domain

**User Story:** As a platform engineer, I want a Cognito user pool with a hosted sign-in page, so that demo users can sign in without custom login code.

#### Acceptance Criteria

1. THE Template SHALL create exactly one User_Pool.
2. THE Template SHALL create exactly one Hosted_UI_Domain attached to the User_Pool.
3. THE Template SHALL configure the User_Pool to use the email address as the sign-in alias, so that a user can sign in with an email address and cannot sign in with a separate username value.
4. THE Template SHALL carry the tags `Project` with the value `inspection-agent` and `Env` with the value of the Env parameter on every resource that supports tags.
5. THE Template SHALL declare the `Env` parameter with the default `demo` and the AllowedPattern `^[a-z][a-z0-9]{0,9}$`.
6. THE Template SHALL give every parameter a Description of 1 to 200 characters and at least one constraint (AllowedPattern, AllowedValues, MinLength, MaxLength, MinValue, or MaxValue).
7. THE Template SHALL contain no literal 12-digit account ID, no literal region name, and no literal ARN string, and SHALL obtain these values through pseudo parameters or intrinsic functions.
8. WHEN the Auth_Stack is deleted, THE Auth_Stack SHALL remove the User_Pool, the App_Client, the Hosted_UI_Domain, and the Groups, and the stack SHALL reach the status `DELETE_COMPLETE` with none of these resources remaining.
9. IF the Hosted_UI_Domain prefix is already in use in the region or does not match the Cognito domain prefix rules, THEN THE Auth_Stack SHALL fail stack creation with status `ROLLBACK_COMPLETE`, SHALL report the failing Hosted_UI_Domain resource in the stack events, and SHALL leave no User_Pool from that attempt.
10. IF the Env parameter value does not match the AllowedPattern `^[a-z][a-z0-9]{0,9}$`, THEN THE Template SHALL reject the stack operation before any resource is created and SHALL report a parameter validation error naming `Env`.

### Requirement 2: Public app client with authorization code flow and PKCE

**User Story:** As a UI developer, I want a public app client that uses the authorization code flow with PKCE, so that the browser app signs users in without storing a client secret.

#### Acceptance Criteria

1. THE Template SHALL create exactly one App_Client with no client secret.
2. THE Template SHALL enable the OAuth 2.0 authorization code grant as the only allowed OAuth flow on the App_Client, with the implicit grant and the client credentials grant both disabled.
3. THE Template SHALL allow exactly the OAuth scopes `openid`, `email`, and `profile` on the App_Client, and no other scopes.
4. THE Template SHALL define the Callback_URL and the Logout_URL as template parameters named `CallbackUrl` and `LogoutUrl`, each with a default value that begins with `http://localhost`.
5. THE Template SHALL give the `CallbackUrl` and `LogoutUrl` parameters an AllowedPattern that accepts only `https://` URLs whose host is made of DNS labels (letters, digits, hyphens, and dots, with no wildcard) and `http://localhost` URLs, and a maximum length of 1024 characters.
6. IF a deployment supplies a value for `CallbackUrl` or `LogoutUrl` that does not match the AllowedPattern, THEN CloudFormation SHALL reject the deployment before creating or updating any resource, and the Auth_Stack SHALL keep its previous state.
7. WHEN the Auth_Stack is updated with new values for the `CallbackUrl` and `LogoutUrl` parameters, THE Auth_Stack SHALL register both the default localhost URL and the supplied URL as allowed callback URLs and as allowed logout URLs on the App_Client.
8. THE Template SHALL contain no reference to any resource, output, or export of the UI stack.
9. THE Template SHALL enable exactly the explicit auth flows `ALLOW_USER_SRP_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` on the App_Client, so that the sign-in flow the Auth_Doc describes for scripts works without a client secret.
10. THE Template SHALL enable prevention of user existence errors on the App_Client, so that a sign-in attempt for an unknown user returns the same error indication as a sign-in attempt with a wrong password.
11. THE Auth_Doc SHALL state that the App_Client requires PKCE for the authorization code flow, because the App_Client has no client secret.

### Requirement 3: Groups as the only source of authorization

**User Story:** As a security reviewer, I want group membership to be the only source of authorization, so that the tool layer decides access from one verifiable claim.

#### Acceptance Criteria

1. THE Template SHALL create exactly three Groups in the User_Pool, with the names `line-a`, `line-b`, and `supervisors`, and no other Group.
2. THE Template SHALL give each Group a description of 1 to 200 characters that states the persona the Group represents (Line A inspector, Line B inspector, or Quality supervisor).
3. THE Template SHALL define zero custom attributes on the User_Pool.
4. THE Template SHALL define zero Lambda triggers on the User_Pool, including no pre-token-generation trigger.
5. IF the design document records a token customization that requires a Lambda trigger, THEN THE Template SHALL define only the trigger named in that design justification, and THE Auth_Doc SHALL state the purpose of that trigger and confirm that it does not add or change the Group_Claim.
6. THE Auth_Doc SHALL state that the Group_Claim is the only authorization input and that no other attribute, including email, username, and custom attributes, is used for authorization.
7. WHEN a user who belongs to a Group signs in, THE User_Pool SHALL issue a token whose Group_Claim contains the name of every Group the user belongs to.
8. WHEN a user who belongs to no Group signs in, THE User_Pool SHALL issue a token whose Group_Claim is absent or empty, so that the tool layer grants that user no access.

### Requirement 4: Group claim in the token validated by the runtime

**User Story:** As a tool-layer developer, I want the verified token to carry the user's groups, so that the tools can enforce line-level permissions from the verified identity.

#### Acceptance Criteria

1. WHEN a Demo_User signs in through the App_Client, THE Access_Token SHALL contain the Group_Claim with the name of every Group the Demo_User belongs to, and the Group_Claim SHALL contain no name of a Group the Demo_User does not belong to.
2. WHEN a Demo_User who belongs to no Group signs in through the App_Client, THE Access_Token SHALL contain no Group_Claim or a Group_Claim with zero entries.
3. THE design SHALL record which token type (Access_Token or ID_Token) the AgentCore Runtime JWT authorizer validates, with the documentation source (document title and URL).
4. THE design SHALL record whether the verified claims are forwarded to the agent code, and in what form (for example, a decoded claim set or a raw header), with the documentation source (document title and URL).
5. THE design SHALL record which token claim the authorizer matches against the App_Client ID, and which AgentCore authorizer setting (`allowedClients` or `allowedAudience`) the runtime spec uses.
6. IF the token that the AgentCore Runtime validates does not carry the Group_Claim, THEN THE design SHALL specify a token customization, justify why no alternative without customization exists, and name the token type that the customization modifies.
7. THE Template SHALL set no Access_Token claim override that removes the Group_Claim.
8. IF the documentation source for criterion 3, 4, or 5 cannot be found, THEN THE design SHALL mark the item as unverified and SHALL list a manual verification step (sign in as a Demo_User, decode the token, and inspect the claims) that resolves it before the runtime spec is implemented.

### Requirement 5: Demo users

**User Story:** As a demo presenter, I want three pre-created demo users, so that I can show a line A inspector, a line B inspector, and a supervisor.

#### Acceptance Criteria

1. WHEN the Demo_Users_Script runs successfully, THE Demo_Users_Script SHALL create the Demo_User `inspector-a` with the email `inspector-a@example.com` and the membership in the Group `line-a`.
2. WHEN the Demo_Users_Script runs successfully, THE Demo_Users_Script SHALL create the Demo_User `inspector-b` with the email `inspector-b@example.com` and the membership in the Group `line-b`.
3. WHEN the Demo_Users_Script runs successfully, THE Demo_Users_Script SHALL create the Demo_User `supervisor` with the email `supervisor@example.com` and the membership in the Group `supervisors`.
4. WHEN the Demo_Users_Script runs successfully, THE Demo_Users_Script SHALL mark the email address of each Demo_User as verified.
5. WHEN the Demo_Users_Script runs successfully, THE Demo_Users_Script SHALL set a permanent password for each Demo_User, so that no Demo_User is in the `FORCE_CHANGE_PASSWORD` state.
6. THE Demo_Users_Script SHALL read the password of each Demo_User from an environment variable or, when the variable is unset and standard input is a terminal, from an interactive prompt that does not echo the input.
7. IF a password is not available from an environment variable or a prompt, THEN THE Demo_Users_Script SHALL exit with a non-zero status and a message that names the missing variable, before any change to the User_Pool.
8. IF a password does not satisfy the password policy of the User_Pool, THEN THE Demo_Users_Script SHALL exit with a non-zero status and print the error returned by Cognito without printing the password.
9. WHEN the Demo_Users_Script runs a second time with the same inputs, THE Demo_Users_Script SHALL leave the User_Pool in the same state as after the first run, with exactly three Demo_Users, the same group memberships, and the same passwords, and SHALL exit with status 0.
10. WHEN a Demo_User already exists, THE Demo_Users_Script SHALL skip the creation of that user, then set the permanent password and ensure the group membership.
11. THE Demo_Users_Script SHALL read the User_Pool ID from the SSM parameter `/inspection-agent/<env>/auth/user-pool-id`.
12. THE Demo_Users_Script SHALL accept `--env` and `--region` options with the defaults `demo` and `us-west-2`, matching `scripts/deploy.sh`.
13. THE Demo_Users_Script SHALL print no password and no token to the terminal, and SHALL write no password or token to any file in the repository. THE Demo_Users_Script MAY write a password to a short-lived temporary file with mode 600 in a private directory outside the repository, SHALL delete that file right after the AWS CLI call that uses it, and SHALL delete the directory on exit.
14. THE Demo_Users_Script SHALL pass the password to the AWS CLI through a `--cli-input-json file://` reference to the temporary file described in criterion 13, so that the password is never a command-line argument and stays out of the process list. (Changed after the V4 failure on AWS CLI 2.31.22, which rejects `file:///dev/stdin`.)
15. IF the SSM parameter `/inspection-agent/<env>/auth/user-pool-id` does not exist or cannot be read, THEN THE Demo_Users_Script SHALL exit with a non-zero status and a message that names the parameter, before any change to the User_Pool.
16. IF a Group required by the Demo_Users_Script does not exist in the User_Pool, THEN THE Demo_Users_Script SHALL exit with a non-zero status and a message that names the missing Group.
17. IF an AWS CLI call fails for a reason other than a password policy violation, THEN THE Demo_Users_Script SHALL exit with a non-zero status and print the error returned by the AWS CLI without printing any password.

### Requirement 6: Token lifetimes, sign-up, MFA, and password policy

**User Story:** As a demo presenter, I want long-enough token lifetimes and no self-service sign-up, so that a live demo does not expire mid-session and only the three Demo_Users can sign in.

#### Acceptance Criteria

1. THE Template SHALL expose an Access_Token validity parameter in minutes with an allowed range of 60 to 1440 and a default of 60, and SHALL set the Access_Token validity of the App_Client from that parameter.
2. THE Template SHALL set the ID_Token validity of the App_Client to the same value, in the same unit, as the Access_Token validity.
3. THE Template SHALL set the refresh token validity of the App_Client to a value between 1 day and 3650 days, with a default of 1 day.
4. THE Template SHALL set the token validity units on the App_Client explicitly for the Access_Token, the ID_Token, and the refresh token.
5. THE Template SHALL configure the User_Pool so that only an administrator can create users.
6. IF a self-service sign-up request is sent to the User_Pool, THEN THE User_Pool SHALL reject the request, SHALL NOT create a user, and SHALL return an error to the caller indicating that sign-up is not allowed.
7. THE Template SHALL set MFA on the User_Pool to off, with a YAML comment adjacent to the setting that states this is a demo setting.
8. THE Template SHALL set the User_Pool password policy to a minimum length of 8 characters and no required character classes. This relaxed policy is a demo setting chosen by the user, and the Template SHALL state so in a YAML comment adjacent to the setting.
9. THE Template SHALL set the temporary password validity of the User_Pool to a value between 1 day and 7 days, with a value of 1 day in the default configuration.
10. THE Template SHALL set the User_Pool account recovery mechanism to a verified email address as the only recovery option.
11. IF a supplied Access_Token validity value is outside 60 to 1440 minutes, THEN THE Template SHALL fail parameter validation before any resource is created or changed.

### Requirement 7: Outputs and SSM parameters

**User Story:** As a developer of the runtime and UI stacks, I want the identifiers of the User_Pool published in standard places, so that later stacks and scripts read them without hard-coding.

#### Acceptance Criteria

1. THE Template SHALL publish the User_Pool ID, the App_Client ID, the Issuer_URL, the Discovery_URL, and the Hosted_UI_Domain as five stack outputs, each with a Description of 1 to 1024 characters.
2. THE Template SHALL publish the User_Pool ID as the SSM parameter `/inspection-agent/<env>/auth/user-pool-id`, where `<env>` is the value of the `Env` parameter.
3. THE Template SHALL publish the App_Client ID as the SSM parameter `/inspection-agent/<env>/auth/app-client-id`.
4. THE Template SHALL publish the Issuer_URL as the SSM parameter `/inspection-agent/<env>/auth/issuer-url`. The value SHALL have the form `https://cognito-idp.<region>.amazonaws.com/<user-pool-id>`.
5. THE Template SHALL publish the Discovery_URL as the SSM parameter `/inspection-agent/<env>/auth/discovery-url`, for use by the AgentCore Runtime JWT authorizer. The value SHALL be the Issuer_URL followed by `/.well-known/openid-configuration`.
6. THE Template SHALL publish the Hosted_UI_Domain, as a full host name of the form `<prefix>.auth.<region>.amazoncognito.com` with no `https://` scheme and no trailing slash, as the SSM parameter `/inspection-agent/<env>/auth/hosted-ui-domain`.
7. THE Template SHALL build the Issuer_URL and the Discovery_URL with `!Sub` from the User_Pool ID and the pseudo parameter `AWS::Region`.
8. THE Template SHALL carry the tags `Project` and `Env` on every SSM parameter it creates, with the `Env` tag value equal to the `Env` parameter.
9. THE Template SHALL use no CloudFormation `Export` and no `Fn::ImportValue`.
10. WHEN the stack is deployed, THE Template SHALL create exactly five SSM parameters, each of type `String`, and each parameter value SHALL equal the value of the stack output of the same name.
11. IF the SSM parameter creation fails during stack create or update, THEN THE Template SHALL cause CloudFormation to roll the stack back, so that no partial set of the five parameters remains.

### Requirement 8: Deploy order and cross-stack ordering

**User Story:** As a platform engineer, I want the auth and UI stacks to deploy without a circular dependency, so that the full deploy succeeds from an empty account.

#### Acceptance Criteria

1. WHEN the Auth_Stack is deployed with the default parameters, THE Auth_Stack SHALL reach `CREATE_COMPLETE` with the App_Client callback URL list set to exactly one value that begins with `http://localhost` and the logout URL list set to exactly one value that begins with `http://localhost`.
2. WHEN the Auth_Stack is updated with the CloudFront Callback_URL and Logout_URL, THE Auth_Stack SHALL reach `UPDATE_COMPLETE` and SHALL keep the same User_Pool ID and the same App_Client ID as before the update, without replacing either resource.
3. WHEN the Auth_Stack reaches `UPDATE_COMPLETE` after the update with the CloudFront Callback_URL and Logout_URL, THE Auth_Stack SHALL list the CloudFront Callback_URL as a callback URL and the CloudFront Logout_URL as a logout URL on the App_Client.
4. IF the Auth_Stack update with the CloudFront Callback_URL and Logout_URL fails, THEN THE Auth_Stack SHALL roll back to the previous localhost URLs and SHALL leave the User_Pool, the App_Client, and the existing users unchanged.
5. THE Auth_Doc SHALL document the Deploy_Order: deploy `auth` at step 2 with localhost URLs, deploy `ui` at step 8, then update `auth` at step 9 with the URLs read from the SSM parameters `/inspection-agent/<env>/ui/callback-url` and `/inspection-agent/<env>/ui/logout-url`.
6. THE Auth_Doc SHALL state that `scripts/create-demo-users.sh` runs after step 2 and needs to run only once per environment, and that the update at step 9 does not require the script to run again.

### Requirement 9: Authentication documentation

**User Story:** As a demo presenter and developer, I want one document that explains the personas and how to get a token, so that I can check sign-in by hand and call the agent from scripts.

#### Acceptance Criteria

1. THE Auth_Doc SHALL describe the three personas: Line A inspector (`line-a`, user `inspector-a`), Line B inspector (`line-b`, user `inspector-b`), and Quality supervisor (`supervisors`, user `supervisor`).
2. THE Auth_Doc SHALL contain a table with one row per Group (three rows: `line-a`, `line-b`, `supervisors`) that maps each Group to the inspection lines it can read, with `line-a` mapped to line A only, `line-b` mapped to line B only, and `supervisors` mapped to both line A and line B.
3. THE Auth_Doc SHALL describe how to run the Demo_Users_Script, including the exact names of the three environment variables that hold the passwords (one per demo user), and SHALL contain no password value.
4. THE Auth_Doc SHALL describe, as numbered steps, how to obtain an Access_Token for a manual check through the hosted UI.
5. THE Auth_Doc SHALL describe how to inspect the Group_Claim of an Access_Token using only local tooling on the user's machine, and SHALL state that the token must not be sent to a third-party service.
6. THE Auth_Doc SHALL describe, as numbered steps, how to obtain an Access_Token from a script, including for `scripts/invoke`, with the password read from an environment variable or an interactive prompt and never passed as a literal command-line argument.
7. THE Auth_Doc SHALL state that tokens are never committed to the repository and never pasted into issues.
8. THE Auth_Doc SHALL list exactly five SSM parameters under `/inspection-agent/<env>/auth/`, giving for each the full key name and a one-sentence statement of the value it holds.
9. THE Auth_Doc SHALL state that the MFA-off setting is for the demo only and SHALL state that MFA must be enabled for any non-demo use.
10. THE Auth_Doc SHALL be written in English.

### Requirement 10: No secrets and quality checks

**User Story:** As a security reviewer, I want the repository to contain no passwords or tokens, so that publishing the repository leaks no credentials.

#### Acceptance Criteria

1. THE repository SHALL contain no password, no access key, no API key, no token, no private key, and no client secret in any file added or changed by this spec.
2. THE Template SHALL contain no password value, and no parameter whose name contains "Password", "Secret", or "Token" SHALL have a `Default` value.
3. THE Template SHALL pass `cfn-lint infra/auth.yaml` with zero errors and zero warnings, and the command SHALL exit with code 0.
4. THE Template SHALL be written in YAML and SHALL contain no JSON-format template content.
5. THE Demo_Users_Script SHALL be the only file added to `scripts/` by this spec, and no existing file in `scripts/` SHALL be modified, except `scripts/README.md` if it lists the script.
6. THE Demo_Users_Script SHALL set `set -Eeuo pipefail` before its first command other than the shebang, and SHALL run without syntax errors under bash 3.2, using no associative arrays, no `mapfile` or `readarray`, and no `${var,,}` or `${var^^}` case conversion.
7. THE spec task list SHALL contain no task that creates a test file, test suite, test fixture, or eval harness, and each verification step SHALL name the action performed and the observable pass result, such as a command exit code or a returned value.
8. IF the Demo_Users_Script needs a password for a demo user, THEN THE Demo_Users_Script SHALL read it from an environment variable or a prompt at run time, SHALL exit with a non-zero code and an error message naming the missing input when no value is supplied, and SHALL NOT write the password to any file in the repository or to standard output. THE Demo_Users_Script MAY write it to a short-lived mode-600 temporary file outside the repository, deleted right after the AWS CLI call and on exit.
