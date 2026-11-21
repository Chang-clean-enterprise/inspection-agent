# Authentication

This page describes sign-in for inspection-agent: the demo personas, how groups map to inspection lines, how to create the demo users, and how to get a token for a manual check or a script. Sign-in uses an Amazon Cognito user pool created by `infra/auth.yaml` (stack `inspection-agent-<env>-auth`). All data and users are synthetic.

Examples use `<env>` for the environment name (default `demo`) and region `us-west-2`. Passwords and tokens never appear in this repository.

## 1. Personas and groups

| Persona label | Email (sign-in name) | Group |
|---|---|---|
| `inspector-a` (Line A inspector) | `inspector-a@example.com` | `line-a` |
| `inspector-b` (Line B inspector) | `inspector-b@example.com` | `line-b` |
| `supervisor` (Quality supervisor) | `supervisor@example.com` | `supervisors` |

Users sign in with the email address. The persona label is stored in the standard `name` attribute. The Cognito `username` claim is an opaque value, so consumers use the `sub` claim as the stable user identifier.

The `cognito:groups` claim of the token is the only authorization input. Email, username, and custom attributes are never used for authorization. The user pool has no custom attributes and no Lambda triggers, so the claim is the one Cognito adds by default.

A token carries the groups the user had when Cognito issued it. A group change shows up in tokens issued after the change. A signed-in user keeps the old groups until the token expires.

## 2. Group-to-line mapping

| Group | Inspection lines the group can read |
|---|---|
| `line-a` | Line A only |
| `line-b` | Line B only |
| `supervisors` | Line A and line B |

The user pool stores only the group names. The tool layer enforces this mapping in code, using the groups from the verified token. A user with no group, or a token with no `cognito:groups` claim, gets no access.

## 3. Create the demo users

Run `scripts/create-demo-users.sh` after step 2 of the deploy (the `auth` stack exists from that step on). Run it once per environment. The step 9 update of the `auth` stack keeps the pool and the users, so the script does not need to run again after step 9.

The script reads one password per user from an environment variable:

| Variable | User |
|---|---|
| `DEMO_PASSWORD_INSPECTOR_A` | `inspector-a@example.com` |
| `DEMO_PASSWORD_INSPECTOR_B` | `inspector-b@example.com` |
| `DEMO_PASSWORD_SUPERVISOR` | `supervisor@example.com` |

Set the variables without echoing the value, then run the script:

In bash:

```bash
read -r -s -p "inspector-a password: " DEMO_PASSWORD_INSPECTOR_A && export DEMO_PASSWORD_INSPECTOR_A; echo
read -r -s -p "inspector-b password: " DEMO_PASSWORD_INSPECTOR_B && export DEMO_PASSWORD_INSPECTOR_B; echo
read -r -s -p "supervisor password: " DEMO_PASSWORD_SUPERVISOR && export DEMO_PASSWORD_SUPERVISOR; echo
```

In zsh (the default shell on macOS, where `read -p` means something else):

```zsh
read -rs "DEMO_PASSWORD_INSPECTOR_A?inspector-a password: " && export DEMO_PASSWORD_INSPECTOR_A; echo
read -rs "DEMO_PASSWORD_INSPECTOR_B?inspector-b password: " && export DEMO_PASSWORD_INSPECTOR_B; echo
read -rs "DEMO_PASSWORD_SUPERVISOR?supervisor password: " && export DEMO_PASSWORD_SUPERVISOR; echo
```

Then run the script:

```bash
scripts/create-demo-users.sh --env <env> --region us-west-2
```

Alternative: leave a variable unset and run the script from a terminal. The script then prompts for that password without echoing it. When no value is available, the script exits with a non-zero status and names the missing variable.

Password rules: at least 8 characters, with no required character classes. This relaxed policy is a demo setting. Use a stronger policy (longer minimum, mixed character classes) for any non-demo use. The script is safe to run again with the same inputs. It skips users that exist, sets the permanent password, and makes sure the group membership is in place.

## 4. Sign-in, deploy order, and SSM parameters

The `auth` stack never reads the UI stack, so there is no circular dependency. The UI callback address reaches `auth` through SSM and a stack parameter that `scripts/deploy.sh` copies at step 9.

| Step | Stack | Auth-relevant action |
|---|---|---|
| 2 | `auth` | Created with the default localhost `CallbackUrl` and `LogoutUrl`. Publishes the five SSM parameters below. The demo users script can run from here on |
| 8 | `ui` | Creates the CloudFront address. Publishes `/inspection-agent/<env>/ui/callback-url` and `/inspection-agent/<env>/ui/logout-url` |
| 9 | `auth` (update) | `deploy.sh` reads the two `ui` parameters and updates `auth` with `CallbackUrl` and `LogoutUrl`. The user pool, app client, and users stay the same |

The `auth` stack publishes exactly five parameters:

| SSM parameter | Value |
|---|---|
| `/inspection-agent/<env>/auth/user-pool-id` | The ID of the Cognito user pool. |
| `/inspection-agent/<env>/auth/app-client-id` | The ID of the public app client, which the runtime matches against the `client_id` claim. |
| `/inspection-agent/<env>/auth/issuer-url` | The token issuer, `https://cognito-idp.<region>.amazonaws.com/<user-pool-id>`, which matches the `iss` claim. |
| `/inspection-agent/<env>/auth/discovery-url` | The issuer URL followed by `/.well-known/openid-configuration`, used by the runtime JWT authorizer. |
| `/inspection-agent/<env>/auth/hosted-ui-domain` | The host name of the hosted sign-in pages, with no `https://` and no trailing slash. |

## 5. Get an access token through the hosted UI

Use this for a manual check. The app client has no client secret, so **PKCE is required** for the authorization code flow. The steps below create the PKCE verifier and challenge. Run them in one shell session, because the verifier must stay the same from step 1 to step 2.

You need `aws`, `openssl`, `curl`, and `jq`.

Setup. Read the domain and client ID from SSM:

```bash
DOMAIN=$(aws ssm get-parameter --region us-west-2 --name /inspection-agent/<env>/auth/hosted-ui-domain --query Parameter.Value --output text)
CLIENT_ID=$(aws ssm get-parameter --region us-west-2 --name /inspection-agent/<env>/auth/app-client-id --query Parameter.Value --output text)
REDIRECT_URI=http://localhost:3000/callback
```

**Step 1. Generate the verifier and challenge, and print the authorize URL.**

```bash
VERIFIER=$(openssl rand -base64 64 | tr -d '=+/\n' | cut -c1-64)
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
echo "https://${DOMAIN}/oauth2/authorize?client_id=${CLIENT_ID}&response_type=code&scope=openid+email+profile&redirect_uri=${REDIRECT_URI}&code_challenge_method=S256&code_challenge=${CHALLENGE}"
```

Open the printed URL in a browser and sign in with a demo user's email and password. The browser then redirects to the localhost callback address. Nothing listens there, so the page shows a connection error. That is expected. Copy the value of the `code` query parameter from the address bar.

Keep this terminal open. `VERIFIER` must stay set in the same terminal between step 1 and step 2.

**Step 2. Exchange the code for tokens.** Paste the code value in place of `PASTE_CODE_HERE`. Keep the response in a shell variable, not in a file:

```bash
CODE="PASTE_CODE_HERE"
RESPONSE=$(curl -s -X POST "https://${DOMAIN}/oauth2/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "code_verifier=${VERIFIER}")
ACCESS_TOKEN=$(printf '%s' "$RESPONSE" | jq -r '.access_token // empty')
printf '%s' "$RESPONSE" | python3 -c '
import sys, json, base64
r = json.load(sys.stdin)
t = r.get("access_token")
if not t:
    print("Token endpoint error:", r.get("error", r))
    sys.exit(1)
p = t.split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
print("cognito:groups:", c.get("cognito:groups"))
print("client_id:", c.get("client_id"))
'
```

The script prints only `cognito:groups` and `client_id`, never the token. If `access_token` is missing, it prints the error from the endpoint.

A code works once and expires after about 5 minutes. If the endpoint returns `invalid_grant`, the code was used, expired, or paired with a different verifier. Get a new code by repeating step 1 (this creates a new verifier and challenge) and then step 2.

After the `ui` stack exists and step 9 has run, the CloudFront callback address is also an allowed redirect URI. The localhost address stays allowed. The `CallbackUrl` and `LogoutUrl` parameters accept only `https://` URLs with a plain DNS host name and `http://localhost` URLs. Wildcards such as `https://*.example.com/callback` are rejected before deployment.

## 6. Inspect the group claim locally

Decode the token on your own machine. Never paste a token into an online decoder or any other third-party service.

With `jq`:

```bash
printf '%s' "$ACCESS_TOKEN" | jq -R 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson'
```

With Python 3 only:

```bash
printf '%s' "$ACCESS_TOKEN" | python3 -c 'import sys,json,base64; p=sys.stdin.read().split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))),indent=2))'
```

Check these claims in an access token:

| Claim | Expected value |
|---|---|
| `cognito:groups` | An array with the user's group, for example `["line-a"]` |
| `token_use` | `access` |
| `client_id` | The value of `/inspection-agent/<env>/auth/app-client-id` |
| `iss` | The value of `/inspection-agent/<env>/auth/issuer-url` |

Result for a user that belongs to no group:

A user with no group gets an access token with no group entries in `cognito:groups`. Cognito either omits the claim or leaves it empty. The tool layer treats a missing claim and an empty list the same way, as no access.

## 7. Get an access token from a script

The app client enables SRP and refresh only. The AWS CLI cannot do SRP, so use the `pycognito` library from a throwaway virtual environment outside the repository. The password comes from `getpass` or an environment variable, and is never an argument.

1. Create a virtual environment outside the repository and install the library:

   ```bash
   python3 -m venv /tmp/auth-venv
   /tmp/auth-venv/bin/pip install pycognito
   ```

2. Read the pool ID, client ID, and the email of the user into shell variables. Export them so the snippet can read them:

   ```bash
   export POOL_ID=$(aws ssm get-parameter --region us-west-2 --name /inspection-agent/<env>/auth/user-pool-id --query Parameter.Value --output text)
   export CLIENT_ID=$(aws ssm get-parameter --region us-west-2 --name /inspection-agent/<env>/auth/app-client-id --query Parameter.Value --output text)
   export AUTH_EMAIL=inspector-a@example.com
   ```

3. Run the snippet. It asks for the password with `getpass`. To avoid the prompt, export the password in a variable such as `DEMO_PASSWORD_INSPECTOR_A` first and read it with `os.environ`. The snippet prints the access token on standard output, so capture it in a variable and never print it to a shared terminal or log:

   ```bash
   ACCESS_TOKEN=$(/tmp/auth-venv/bin/python - <<'EOF'
   import getpass, os
   from pycognito.aws_srp import AWSSRP

   pool_id = os.environ["POOL_ID"]
   region = pool_id.split("_")[0]
   password = os.environ.get("DEMO_PASSWORD_INSPECTOR_A") or getpass.getpass("Password: ")
   srp = AWSSRP(
       username=os.environ["AUTH_EMAIL"],
       password=password,
       pool_id=pool_id,
       client_id=os.environ["CLIENT_ID"],
       pool_region=region,
   )
   print(srp.authenticate_user()["AuthenticationResult"]["AccessToken"])
   EOF
   )
   ```

4. Inspect the claims as in section 6, then remove the virtual environment when you are done:

   ```bash
   unset ACCESS_TOKEN
   rm -rf /tmp/auth-venv
   ```

A token from SRP sign-in carries the scope `aws.cognito.signin.user.admin`. A token from the hosted UI carries `openid`, `email`, and `profile`. No authorization depends on the scope.

How `scripts/invoke` gets its token is decided in a later spec. This page only shows how to obtain a token by hand.

## 8. Handling rules

- Never commit a token to the repository.
- Never paste a token into an issue, a pull request, a chat, or an online decoder.
- Never put a password on a command line. Use an environment variable set with `read -r -s -p` (bash) or `read -rs "VAR?prompt: "` (zsh), or an interactive prompt.
- Keep tokens in shell variables. Do not write them to files.

## 9. MFA

Multi-factor authentication is off in this user pool. This is a setting for the demo only. Enable MFA for any non-demo use.

## 10. Token lifetimes and failure messages

Default lifetimes:

| Token | Default | Template parameter |
|---|---|---|
| Access token and ID token | 60 minutes | `JwtValidityMinutes` (60 to 1440) |
| Refresh token | 1 day | `RefreshValidityDays` (1 to 3650) |

Common causes when a call with a token fails:

- **Wrong client ID.** The runtime accepts only tokens whose `client_id` equals `/inspection-agent/<env>/auth/app-client-id`. A token from another app client, or an ID token (which has `aud` and no `client_id`), is rejected. Send the access token.
- **Expired token.** Check the `exp` claim. Sign in again to get a new token.
- **Missing `Authorization` header allowlist.** The runtime validates the token, but it forwards the `Authorization` header to the agent code only when `Authorization` is in the runtime's request header allowlist. Without it, the agent sees no token and cannot read `cognito:groups`, so tools deny every request.
