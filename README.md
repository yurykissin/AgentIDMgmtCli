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

## Tests

```powershell
Invoke-Pester ./tests
```

## Layout

```
agentmgmt.ps1         entry point (menu or -Command)
AgentMgmt/            module (State, Graph, Auth, Catalog, Blueprints, Identities,
                      Permissions, Credentials, Registry, Diagnose, Migration, Tui, Commands)
tests/                Pester tests (offline)
legacy/               previous a365/Azure CLI script and Python CLI docs
agentmgmtcli/         previous Python CLI, kept for reference only
```
