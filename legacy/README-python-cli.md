# agentmgmtcli

Toolkit to manage Microsoft Entra Agent ID blueprints and agent identities with:
- tree display (blueprint -> identities -> registrations)
- read-only permission inspection
- create via Graph (with optional registry registration) or via `a365`
- granular delete for one identity, one blueprint, or one registry entry

## Scope

This project is intentionally focused on Agent ID object lifecycle:
- **Blueprint CRUD** (v1 includes create, list/show, delete)
- **Identity CRUD** (v1 includes create, list/show, delete)
- **Registry CRUD** (v1 includes create and delete)
- **Permission view only** (no mutation yet)

## Important notes

- Graph registration (`/beta/copilot/agentRegistrations`) is a beta endpoint and can change.
- Deleting a blueprint can leave child identities visible for some time because server-side cascade is asynchronous.
- This CLI does not persist secrets or tokens. It reuses Azure CLI login via `az account get-access-token`.

## Install (do not auto-run)

```bash
cd /Volumes/Data/VSCode/MyProjects/agentmgmtcli
python -m pip install -e .
```

## No Python option (Windows PowerShell)

If you do not want Python on Windows, use the included script:

`agentmgmt.ps1`

Prerequisites:
- `az` CLI
- `a365` CLI only if you use the `create-a365` command

Examples:

```powershell
cd D:\VSCode\MyProjects\agentmgmtcli
az login --tenant <tenant-id>

# interactive menu
.\agentmgmt.ps1

# or direct command mode
.\agentmgmt.ps1 -Command tree -TenantId <tenant-id>
.\agentmgmt.ps1 -Command show-blueprint -TenantId <tenant-id> -Selector "n8n Agents BP"
.\agentmgmt.ps1 -Command show-identity -TenantId <tenant-id> -Selector "<identity-id>"

.\agentmgmt.ps1 -Command show-blueprint-permissions -TenantId <tenant-id> -Selector "n8n Agents BP"
.\agentmgmt.ps1 -Command show-identity-permissions -TenantId <tenant-id> -Selector "<identity-id>"

.\agentmgmt.ps1 -Command create-graph -TenantId <tenant-id> -BlueprintName "My BP" -IdentityName "My Identity"
.\agentmgmt.ps1 -Command create-a365 -TenantId <tenant-id> -AgentName "my agent" -DryRun
.\agentmgmt.ps1 -Command register-existing -TenantId <tenant-id> -BlueprintName "Existing BP" -IdentityName "Existing Agent" -RegistrationName "Existing Agent"
.\agentmgmt.ps1 -Command register-existing -TenantId <tenant-id> -GraphClientId "<app-client-id-with-AgentRegistration-consent>"

.\agentmgmt.ps1 -Command delete-identity -TenantId <tenant-id> -Selector "<identity-id>"
.\agentmgmt.ps1 -Command delete-blueprint -TenantId <tenant-id> -Selector "My BP"
.\agentmgmt.ps1 -Command delete-registration -TenantId <tenant-id> -Selector "<registration-id>"
```

On startup, the script now:
- checks `az account show`
- prints active user, tenant, and subscription
- runs `az login` automatically if not signed in or if tenant mismatch exists

Tree output labels are explicit:
- `BP:` for blueprints
- `AGENT:` for agent identities
- `ADMIN REGISTRATION:` for admin portal registration state

If `/beta/copilot/agentRegistrations` is blocked, tree still works and marks registration as unknown.

`register-existing` behavior:
- if `-BlueprintName` is omitted, it lists unregistered blueprints (when registry listing is available) and asks you to pick one
- if the chosen blueprint has one identity, it auto-selects it
- if multiple identities exist, it prompts for identity selection
- default registration name is the blueprint name
- for registry APIs in restricted tenants, provide `-GraphClientId` (delegated `AgentRegistration.ReadWrite.All`) or `-GraphAccessToken`

For registry operations, script uses Azure CLI Graph token.
In some tenants, direct registry calls can still fail because the Azure CLI app is not preauthorized for Agent 365 registry APIs.

## Authentication

Sign in first:

```bash
az login --tenant <tenant-id>
```

The CLI reads a Graph token from `az`. If the token lacks required delegated permissions, Graph calls fail with authorization errors.

## Commands

### Tree display

```bash
agentmgmt tree --tenant-id <tenant-id>
agentmgmt tree --tenant-id <tenant-id> --json
```

### Show one blueprint or identity

```bash
agentmgmt show blueprint "<id|app-id|exact-name>" --tenant-id <tenant-id> --permissions
agentmgmt show identity "<id|app-id|exact-name>" --tenant-id <tenant-id> --permissions
```

### Create with Graph engine

Creates:
1. blueprint (`POST /applications/microsoft.graph.agentIdentityBlueprint`)
2. blueprint principal (`POST /servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal`)
3. identity (`POST /servicePrincipals/microsoft.graph.agentIdentity`)
4. optional registration (`POST /beta/copilot/agentRegistrations`)

```bash
agentmgmt create graph \
  --tenant-id <tenant-id> \
  --blueprint-name "My BP" \
  --identity-name "My Identity" \
  --register
```

Optional:
- `--sponsor-object-id <user-object-id>` to override sponsor
- `--registration-name "My Agent"` for admin portal entry name
- `--no-register` to skip Agent 365 registry call

### Create by delegating to a365

```bash
agentmgmt create a365 \
  --agent-name "my agent" \
  --tenant-id <tenant-id> \
  --dry-run
```

For real execution, omit `--dry-run`.

### Granular delete

```bash
agentmgmt delete identity "<id|app-id|exact-name>" --tenant-id <tenant-id>
agentmgmt delete blueprint "<id|app-id|exact-name>" --tenant-id <tenant-id>
agentmgmt delete registration "<id|exact-name>" --tenant-id <tenant-id>
```

Each delete asks for typed confirmation unless `--force` is provided.

## Permissions expected

Typical delegated permissions include:
- Blueprint create/read/update/delete scopes
- Identity create/delete scopes
- Registration read/write for beta Agent Registry endpoint

The exact least-privileged set depends on which commands you run.

## Project layout

```
agentmgmtcli/
  agentmgmtcli/
    auth.py
    graph.py
    treeview.py
    a365.py
    cli.py
  pyproject.toml
  README.md
```

