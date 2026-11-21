# Agent ID Admin Toolkit

Console toolkit for Microsoft Entra Agent ID. It manages blueprints (BP), agent identities, their permissions, credentials, sponsors/owners and Agent Registry entries using **direct Microsoft Graph REST calls**. It does not need `a365`, the Azure CLI, an Agent SDK or the Graph PowerShell modules. It runs standalone, with no server.

```
Blueprint (application)  1 : n  Agent identity (service principal)
   |-- blueprint principal (service principal, must exist)
   |-- credentials (secret / federated) live here, never on the agents
   `-- inheritable permissions flow to every child agent
```

## Requirements

- PowerShell 7 (Windows, macOS, Linux) or Windows PowerShell 5.1. No modules to install.
- A tenant account that can manage agent identities: **Agent ID Developer** (create) or **Agent ID Administrator** (manage all), or owner/sponsor of the objects. Granting tenant-wide consent needs **Global Administrator** or **Privileged Role Administrator**. If you lack that role the toolkit prints a `/v2.0/adminconsent` URL to forward.
- For the first run only, rights to create an app registration and grant admin consent (Global Administrator is simplest).

## Quick start

```powershell
./agentmgmt.ps1                  # interactive menu
```

1. **Settings > Set up toolkit app.** Signs you in once through Microsoft Graph Command Line Tools, creates a public-client app ("Agent ID Admin Toolkit", redirect `http://localhost`) and grants it tenant-wide consent for the delegated scopes it needs. The client id is stored in `~/.agentmgmt/config.json`. This is a normal app registration, not a blueprint (blueprints cannot be public clients).
2. **Settings > Run diagnostics.** Read-only checks of sign-in, scopes, list calls, inheritable permissions and the registry. Run this first on a new tenant.
3. Use the menu: browse the tree, manage a blueprint or an agent, create, registry.

Sign-in tries the browser (PKCE on localhost) and falls back to device code. The refresh token is kept in memory unless you switch on **Remember sign-in**; then it is stored DPAPI-protected on Windows or in a mode-600 file elsewhere. The refresh token is the only secret ever persisted.

## What it can do

| Area | Actions |
| --- | --- |
| Tree | Blueprint > agents, registry state, optional permission detail |
| Blueprints | Create (+ principal), rename, delete (with children, typed confirmation) |
| Agent identities | Create under a blueprint, rename, enable/disable, delete |
| Agent users | Create a passwordless `agentUser` under a child agent, validate its immutable 1:1 link, show the linked account |
| Blueprint permissions | Declare (requiredResourceAccess), consent on the principal, inheritable permissions, admin-consent URL fallback |
| Agent permissions | Direct application role or delegated grant on one agent, revoke, effective view (inherited vs direct) |
| Safety | Official blocked-for-agents list enforced before any grant; warnings for tenant-wide `*.All` and write permissions |
| Credentials | Client secret (shown once), federated credential, expiry list |
| People | Sponsors and owners add/remove |
| Registry (beta) | List, register existing identity, rename, delete |
| Migration inventory | Select an existing app registration / enterprise app and export a read-only local JSON inventory |
| Other | Dry-run mode, Graph call log, non-interactive commands |

### The permission model in one picture

- **Required resource access** on the BP is only a declaration.
- **Inheritable permissions** on the BP say which resources' permissions children may inherit.
- **Consent on the BP principal** is what actually grants the permission, and it flows to children for inheritable resources.
- **Direct grants on one agent** apply to that agent only.
- The agent's effective permissions are the union of inherited and direct ones.

Typical split (the November lab): grant `User.Read` on the BP and make it inheritable, so every agent gets read; give only the writer agent a direct `User.ReadUpdate.All` application role.

### Blocked permissions

Microsoft blocks some permissions for agent identities, for example `User.ReadWrite.All`. Graph rejects them with "The specified app role cannot be granted to agent identities." The toolkit ships a copy of the official list (`AgentMgmt/data/blocked-permissions.json`, source URL and fetch date inside) and refuses these grants up front, so use `User.ReadUpdate.All` or another narrower permission. The list is a deny list, not an allow list: an unblocked permission can still fail. Cells with "-" on the official page are shown as **unclear** and left to Graph. Re-check the file against the official page now and then:
<https://learn.microsoft.com/graph/api/resources/agentid-platform-overview#microsoft-graph-permissions-blocked-for-agents>

## Non-interactive use

For a separate **no-AI agent-user identity lab**, see [`samples/identity-runtime`](samples/identity-runtime/README.md). It provides a terminal Graph `/me` probe, optional read-only mailbox check, and SDK-authenticated Teams echo runtime. It does not provision Microsoft 365 teammates, and adds no dependencies to this PowerShell toolkit.

```powershell
./agentmgmt.ps1 -Command help
./agentmgmt.ps1 -Command tree
./agentmgmt.ps1 -Command perms --agent "n8n write agent"
./agentmgmt.ps1 -Command agent-grant --agent "n8n write agent" --permission User.ReadUpdate.All -DryRun
./agentmgmt.ps1 -Command bp-grant --blueprint "n8n-lab Blueprint" --permission User.Read
./agentmgmt.ps1 -Command bp-grant --blueprint "n8n-lab Blueprint" --permission User.Read.All --type application
./agentmgmt.ps1 -Command agent-delete --agent zz-test-agent --yes
```

Options use `--name value`. `-DryRun` prints every write call instead of sending it. Destructive commands need `--yes`.

## Export an existing app for migration

Choose **8 > Export existing app** from the main menu, search by name, then select an app by number. App registrations and their enterprise applications are paired by app ID. Enterprise applications without a local app registration are also selectable. Existing Agent ID objects and managed identities are excluded.

```powershell
./agentmgmt.ps1 -Command app-export --app "Customer Service Agent"
./agentmgmt.ps1 -Command app-export --app "<app-id-or-object-id>" --output "C:\AgentExports"
```

The default output is `./exports/<safe-app-name>--<appId>/app.json`, relative to your current directory. Duplicate names are distinguished by app ID, unsafe filename characters are replaced, and existing exports are not overwritten unless you explicitly pass `--force`. Use separate output roots for different customer tenants. The default `exports/` directory is git-ignored; exports contain customer configuration and should stay private.

The JSON contains:

- Source tenant, app ID, application and service-principal object IDs.
- Configured API permissions **separately** from actual application-role assignments and delegated consent grants. Includes Graph and other resource APIs, permission names/IDs, and tenant-wide versus user-specific consent.
- Application and enterprise-app owners, credential metadata (never secret values or certificate key material), federated identity settings, and redirect/authentication configuration.
- Blocked/unclear Graph permission warnings using the bundled catalog, with its source and fetch date. Other APIs are marked `NotEvaluated`, not assumed compatible. Missing permission definitions keep their original IDs and produce warnings.

This feature sends only Graph **GET** requests. It creates no blueprint or agent identity, grants no consent, and changes or deletes nothing in the tenant. It still writes the local JSON when toolkit dry-run is enabled. Normal token refresh/sign-in may occur if needed. If a configuration/permission read fails (other than a missing resource API definition), the export fails instead of producing a misleading incomplete inventory.

An enterprise-app-only export cannot read the home tenant's app registration. An app-registration-only export has no local grants. Both situations are called out explicitly. Azure RBAC, Entra directory roles, Conditional Access, sign-in logs and code/downstream dependencies are **not collected** and need manual review. A JSON inventory is not a working migration: credentials, a sponsor and workload authentication changes still need planning. See [Microsoft's migration guidance](https://learn.microsoft.com/entra/agent-id/migrate-custom-app-registrations-to-agent-id).

## Create an agent user (teammate identity)

An agent user is a specialized, passwordless `microsoft.graph.agentUser`, not a normal user with a password. It has an **immutable one-to-one relationship** to a child agent identity. `identityParentId` is the child's **object ID**, never its client ID or the blueprint ID. The toolkit resolves `--agent` to the child object ID, discovers its parent blueprint, and authenticates **as that blueprint** for creation and read-back. The administrator's toolkit token is used only for preflight discovery; it is never used to create the account.

### Prerequisites and procedure

1. Create a blueprint, its principal and a child agent identity. Repair any missing blueprint principal first.
2. Grant **Microsoft Graph > Application > `AgentIdUser.ReadWrite.IdentityParentedBy`** to the **blueprint**, with admin consent. It is not enough to declare the permission or grant it to the toolkit app. Use Entra admin center > App registrations > the blueprint > API permissions, or the existing toolkit command:
   ```powershell
   ./agentmgmt.ps1 -Command bp-grant --blueprint "<blueprint-appId>" --permission AgentIdUser.ReadWrite.IdentityParentedBy --type application --no-inherit
   ```
   Use an administrator authorized to grant application permissions. `--no-inherit` avoids enabling inheritance for this operation; it does not change any existing inheritance policy.
3. Configure a valid **client secret on the blueprint** (Blueprint > Credentials), retaining its **value**, not the credential key ID. The current CLI flow supports client-secret credentials only, not certificate or federated assertions. Do not copy secrets into command arguments, configuration files or JSON exports.
4. Choose an unused mail nickname and UPN in a **verified domain of the same tenant**. The toolkit's alias input accepts letters/digits followed by letters/digits, dots, underscores or hyphens. The toolkit account needs directory read access for domain, user and permission checks (already included in its normal setup).
5. Choose **5 > Create > 3 > Agent user / teammate identity**, then select the child agent. Alternatively choose **4 > Agent identity > 7 > Agent user / teammate identity > 2 > Create**.
6. Enter display name, alias and UPN; confirm the immutable parent link. After all preflight checks pass, enter the blueprint secret in the hidden prompt. The toolkit requests `client_credentials` with the blueprint **appId** and `https://graph.microsoft.com/.default`, then posts exactly the specialized subtype:
   ```http
   POST https://graph.microsoft.com/v1.0/users/microsoft.graph.agentUser
   Authorization: Bearer <blueprint-access-token>
   Content-Type: application/json

   {
     "accountEnabled": true,
     "displayName": "AgentUser Lab User",
     "mailNickname": "agentuserlab",
     "userPrincipalName": "agentuserlab@contoso.com",
     "identityParentId": "<child-agent-object-id>"
   }
   ```
7. Record the returned **agent-user object ID** separately from the child and blueprint IDs. The toolkit automatically reads the new agent user back using the same blueprint token and validates its subtype, parent ID, display name, UPN, alias and enabled state. Reads retry replication errors. If creation succeeds but read-back fails, the error preserves the created user ID: inspect it rather than repeating creation.

Command-line equivalents (the first command prompts securely):

```powershell
./agentmgmt.ps1 -Command agent-user-new --agent "<child-object-id>" --name "AgentUser Lab User" --alias agentuserlab --upn agentuserlab@contoso.com
./agentmgmt.ps1 -Command agent-user-show --agent "<child-object-id>"
./agentmgmt.ps1 -Command agent-user-new --agent "<child-object-id>" --name "AgentUser Lab User" --alias agentuserlab --upn agentuserlab@contoso.com -DryRun
```

For automation, `--secret-env BLUEPRINT_CLIENT_SECRET` reads a secret from a pre-populated environment variable. Supply it through your secret manager, not a literal command in shell history; unset it afterwards. Blueprint secrets and tokens are never persisted or placed in the toolkit's sign-in state or Graph call log. The normal administrator sign-in/remember-sign-in behavior is unchanged.

Dry-run performs read-only preflight and prints the planned specialized POST. It **does not prompt for/read the blueprint secret, acquire a blueprint token, or create a user**. Preflight rejects an existing parent link, unverified domain, conflicting UPN/nickname, wrong object type and missing actual blueprint permission/admin consent. It does not silently fall back to another token, a normal `/users` creation, broader permissions or a password.

**Entra identity only:** this API does not provision a mailbox, Teams presence or a complete Agent 365 teammate. Those require the separate Microsoft 365 provisioning flow; no licenses or Microsoft 365 resources are created by this command.

### Live validation checklist

Use a disposable blueprint/child and unique `zz-test-*` names, never a production agent.

1. Without the blueprint application grant, creation must fail **before requesting the secret or posting a user**. Grant and consent to the permission on the correct blueprint.
2. Run dry-run with a verified test UPN. Confirm `identityParentId` equals the child's object ID and no credential is requested.
3. Create once with the hidden secret prompt. Confirm the returned subtype is `#microsoft.graph.agentUser`, `identityParentId` matches the child object ID, and the UPN/alias/enabled state match your input.
4. Run `agent-user-show` for the same child. It must return the same user ID. In Entra, inspect the agent-user account and blueprint service-principal sign-in logs; do not expect an ordinary interactive-user login or a mailbox/Teams presence.
5. Repeat creation for the same child with a different unused UPN: it must reject the existing immutable link without acquiring another blueprint token. Also check an unverified domain and a UPN/nickname already in use.
6. With a separate unlinked test child and valid inputs, try an invalid/expired secret. Token acquisition must fail, no user must be created, and no secret/token may appear in output or the Graph call log. The service remains the final authority for races/uniqueness between preflight and POST; API failures are surfaced, never converted into success.
7. Cleanup is explicit and is **not automated by this feature**. Delete the test account with a blueprint Graph token via `DELETE /v1.0/users/microsoft.graph.agentUser/<agent-user-id>` (the **user** object ID, not the child ID). Delete the test child/blueprint only after the user is removed. Do not delete production objects to test the relationship.

Offline regression coverage lives in `tests/AgentUsers.Tests.ps1`. No live customer/tenant changes are made by the test suite.

Official references: [creation API](https://learn.microsoft.com/graph/api/agentuser-post?view=graph-rest-1.0), [blueprint permission, immutable relationship and cleanup](https://learn.microsoft.com/entra/agent-id/create-delete-agent-user-account), [agent-user listing](https://learn.microsoft.com/graph/api/agentuser-list?view=graph-rest-1.0), [client-credentials authentication](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow).

## Verified vs unverified

Built from the official Graph documentation and the behaviour of `a365`. It could **not** be run against a live tenant while it was written. The unit tests (`tests/`) are offline with a mocked network layer.

Please confirm on your tenant, in this order, using disposable `zz-test-*` objects:

1. `Settings > Run diagnostics` passes (this also shows whether the scope names exist in your tenant).
2. Create a BP and an agent identity (the open question is whether Graph accepts your delegated token for identity creation, or needs a blueprint-credential token).
3. Rename a blueprint, then an agent identity (agent rename via PATCH is unverified).
4. Grant `User.Read` on the BP with inheritance, then `User.ReadUpdate.All` directly on one agent, and check **effective permissions**.
5. Try a blocked permission (`User.ReadWrite.All`) and confirm it is refused.
6. Registry list/register (beta; earlier Azure CLI tokens failed with AADSTS65002, the toolkit uses its own app instead).
7. Delete the test agent, then the test BP.

Notes:
- Agent identity creation passes the blueprint's **appId** as `agentIdentityBlueprintId`, per the documentation. The registry body keeps the blueprint object id, as the earlier working script did.
- Several endpoints are beta or recent; the routes live in `Get-AmObjectRoute` and the permission functions, so route fixes are one-line changes.

## Troubleshooting

| Symptom | Meaning / fix |
| --- | --- |
| AADSTS65002 | A pre-authorized first-party client was used for a scope it cannot request. The toolkit uses its own app; re-run setup if it is missing. |
| 403 on consent | The signed-in user is not allowed to grant tenant-wide consent. Send the printed admin-consent URL to a Global Administrator. |
| "cannot be granted to agent identities" | The permission is on the blocked list. Choose a narrower one. |
| Token lacks scopes | Settings > Set up toolkit app with force, then sign in again. |
| Registry "unknown" | Preview API not readable by the current token or tenant; the rest of the toolkit is unaffected. |
| Blueprint delete seems slow | Deleting a blueprint cascades to its identities asynchronously; refresh the tree after a moment. |
| Creating a blueprint principal says the appId does not reference a valid application | Entra replication lag. Creation retries for about 28 seconds without creating another blueprint. If it still fails, the blueprint remains: select it in **3 > Blueprint**, then **7 > Repair missing principal**, or run `./agentmgmt.ps1 -Command bp-principal --blueprint "<blueprint-appId>"`. Repair reuses an existing principal and never creates another blueprint. |

## Tests

```powershell
Invoke-Pester ./tests
```

## Layout

```
agentmgmt.ps1         entry point (menu or -Command)
AgentMgmt/            module (State, Graph, Auth, Catalog, Blueprints, Identities,
                      Permissions, Credentials, Registry, Diagnose, Migration, AgentUsers, Tui, Commands)
tests/                Pester tests (offline)
legacy/               previous a365/Azure CLI script and Python CLI docs
agentmgmtcli/         previous Python CLI, kept for reference only
```
