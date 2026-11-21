# Agent-user identity lab

A tiny runtime for testing **identity**, not AI. No model, prompts, Azure OpenAI subscription or mail sending. The main PowerShell toolkit is unchanged and still has no SDK dependencies.

Start with the terminal probe. Add Teams only after the identity test works:

```text
Blueprint credential -> SDK Agent ID exchange -> child identity + agent user
                                                  |
                                       Graph /me must match agent user

Teams -> authenticated /api/messages -> allowlisted tenant + recipient + tester
                                                  |
                                      echo / whoami / graph / mailbox
```

This is a **single-tenant, single-blueprint development lab**, with multiple explicitly registered child agents supported. It uses Teams SDK 2.2.1, the version used in Microsoft's [agent-factory setup](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/setup). The agentic-user package schema is preview; Frontier enrollment does not by itself prove every workload is provisioned.

## What each check proves

| Check | Evidence | Does NOT prove |
| --- | --- | --- |
| `npm run check` | Local configuration is well formed | Credentials, actual directory relationships or consent |
| `graph` terminal probe | SDK acquired an agent-user token and Graph `/me` returned the configured agent-user ID | Mailbox or Teams readiness |
| `mailbox` terminal probe | `/me` matched, then the agent's Inbox metadata was readable | Teams, email notifications, mail sending or message contents |
| Teams `echo hello` | Real Teams delivery and recipient-scoped reply worked | Graph permissions |
| Teams `whoami` | Shows routing IDs separately from the human sender | Graph token identity; use `graph` |
| `/healthz` | HTTP process is running | Any tenant, credential, license or workload readiness |

The SDK handles the [agent-user token exchange](https://learn.microsoft.com/javascript/api/teams-sdk-typescript/@microsoft/teams.apps/iapptokenprovider?view=msteams-sdk-ts-latest). No administrator token, interactive human sign-in or blueprint app-only Graph token substitutes for the agent-user token.

## 1. Prepare local configuration

Requirements: Node.js **22.12 or later**, npm, and an isolated Frontier test tenant with a blueprint, child identity and linked `agentUser`. Use a supported Node LTS release. A terminal Graph probe needs no public endpoint or Teams app package.

From the repository root in PowerShell:

```powershell
cd samples/identity-runtime
npm ci
npm test
Copy-Item .env.example .env
Copy-Item agents.example.json agents.local.json
```

Edit `.env` and `agents.local.json`. Replace every synthetic ID with the actual value:

| Setting | Meaning |
| --- | --- |
| `TENANT_ID` / mapping `tenantId` | Your tenant directory ID |
| `CLIENT_ID` / `blueprintClientId` | Blueprint **application/client ID**, not application object ID |
| `CLIENT_SECRET` | Secret **value** from that blueprint, not its secret ID |
| `agentClientId` | Child agent service principal's `appId` |
| `agentObjectId` | Child agent service principal's `id` |
| `agentUserId` | Linked agent user's `id`, whose `identityParentId` equals `agentObjectId` |
| `LAB_TESTER_IDS` | Comma-separated human testers' Entra object IDs |

Use the toolkit's agent details and `agent-user-show --agent "<child-object-id>"` to inspect existing objects. This lab trusts your local mapping, it does not replace the toolkit's directory relationship validation. Use the actual IDs returned by the supported teammate provisioning flow if it created a different child/user; don't create another user just to match the sample.

Prefer keeping the secret out of the file: leave the placeholder in `.env`, then in **PowerShell 7** set the process environment without recording it in history:

```powershell
$env:CLIENT_SECRET = Read-Host "Blueprint secret VALUE" -MaskInput
npm run check
```

Node's `--env-file` does not replace an already-set process environment value. Alternatively, edit the ignored `.env` locally for a disposable lab, restricting file access. `.env`, `.env.*` (except `.env.example`), `*.local.json`, `node_modules` and `dist` in this folder are git-ignored. Don't put customer data in differently named files. Never commit secrets, export tokens, enable SDK debug payload logging or paste tokens into online decoders.

Graph and mailbox probes are **off by default**. Echo/help/whoami need no Graph grant. Configuration changes require restarting the runtime.

## 2. Authorize the agent user for Graph

This is an **administrator procedure**, not something the runtime does automatically. Use a disposable child/blueprint with no unrelated inherited or direct grants: `.default` can include previously granted scopes.

The consent relationship is **child service principal as client, agent user as principal, Microsoft Graph service principal as resource**. Blueprint declarations or consent alone are insufficient for this user-backed flow. See [message routing and token acquisition](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/route-messages#appendix-get-an-agentic-user-token-yourself).

In Graph Explorer or another authorized management client, have the tenant administrator:

1. Review the [delegated-grant API permissions and supported administrator roles](https://learn.microsoft.com/graph/api/oauth2permissiongrant-post?view=graph-rest-1.0). The management client needs `DelegatedPermissionGrant.ReadWrite.All` for the write. This permission belongs to the **management client**, never the lab runtime.
2. Resolve Microsoft's Graph service principal **in this tenant**, using a management client authorized to read service principals:

   ```http
   GET https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq '00000003-0000-0000-c000-000000000000'&$select=id,displayName
   ```

3. Check existing grants first:

   ```http
   GET https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$filter=clientId eq '<child-object-id>'
   ```

4. If there is no corresponding single-user Graph grant, create one:

   ```http
   POST https://graph.microsoft.com/v1.0/oauth2PermissionGrants
   Content-Type: application/json

   {
     "clientId": "<child-object-id>",
     "consentType": "Principal",
     "principalId": "<agent-user-object-id>",
     "resourceId": "<this-tenant-graph-service-principal-object-id>",
     "scope": "User.Read"
   }
   ```

   `clientId` here confusingly means service-principal **object ID**, not client/app ID. Do not copy a Graph SP object ID from another tenant. If a matching grant exists, review it and PATCH its scope rather than creating a duplicate. Preserve any intentional existing scopes. Don't broaden to `AllPrincipals` just to make the lab pass. The toolkit's current delegated grant command uses `AllPrincipals`, so it is not the least-privilege substitute for this step.

5. Set `LAB_GRAPH_ENABLED=true` in `.env`, then run:

   ```powershell
   npm run probe -- graph "<agent-user-object-id>"
   ```

Expected: `PASS: Graph /me is agent user ...`, not your administrator/human ID or the blueprint ID. The probe selects only enabled mappings from your local file and exits nonzero on failure.

For the optional mailbox check, add delegated **`Mail.ReadBasic`** to the same single-user grant (`User.Read Mail.ReadBasic`), only after the account has the required Exchange licensing/provisioning. Set `LAB_MAILBOX_ENABLED=true`, then:

```powershell
npm run probe -- mailbox "<agent-user-object-id>"
```

The probe GETs `/me?$select=id`, checks the identity, then GETs `/me/mailFolders/inbox?$select=id`. It does not retrieve messages, subjects or bodies. [Mail folder access requires Mail.ReadBasic or higher](https://learn.microsoft.com/graph/api/mailfolder-get?view=graph-rest-1.0). Licensing/provisioning, permission consent and identity linkage are independent checks; a 403/404 is not automatically a licensing diagnosis. Restart after consent changes to avoid cached tokens.

## 3. Run the Teams echo runtime

**Optional second stage.** An Entra-only user created by `agent-user-new` isn't automatically a discoverable working Teams teammate. First complete the supported [factory registration, package publication and activation](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/setup), then [teammate creation and workload onboarding](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/create-agentic-users). This sample neither implements that provisioning API nor automatically assigns licenses.

1. Start the server:

   ```powershell
   npm start
   ```

2. From another terminal check the process:

   ```powershell
   Invoke-RestMethod http://localhost:3978/healthz
   ```

3. Follow Microsoft's [Dev Tunnels procedure](https://learn.microsoft.com/microsoft-agent-365/developer/test-with-devtunnels) to expose **only this disposable lab port** over public HTTPS. The documented tunnel transport allows anonymous access so the service can deliver requests; the SDK still requires a valid service JWT at `/api/messages`. This runtime explicitly disables authentication bypass, even if an SDK bypass environment variable is present. Don't expose a customer production runtime this way.
4. Register `https://<your-tunnel-host>/api/messages` on the **same test blueprint** following [agent messaging endpoint registration](https://learn.microsoft.com/microsoft-agent-365/developer/agent-messaging-endpoint). For example, from a separately prepared Agent 365 CLI workspace already targeting that blueprint:

   ```powershell
   a365 setup blueprint --endpoint-only --messaging-endpoint "https://<your-tunnel-host>/api/messages"
   ```

   This is an external registration tool, not a dependency of the PowerShell toolkit. Do not run full blueprint setup against an existing blueprint unintentionally. Updating its endpoint affects **every teammate from that blueprint**.
5. After Teams workload onboarding is ready, use a human in `LAB_TESTER_IDS` to open a **personal chat** with the teammate. Send `help`, `echo hello`, `whoami`, `graph`, then optionally `mailbox`. A plain HTTP POST, forged JWT, emulator activity, group chat, unlisted sender, unknown agent, conflicting tenant or wrong child client must not run a diagnostic. Recipient identity, not text or human sender identity, selects the agent.

SDK-authenticated replies use the inbound recipient's agent-user identity, as described in [receiving and sending messages](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/receiving-sending-messages). The local `enabled` switch is only a lab allowlist, not a live directory status check. The runtime has no background/proactive work; it does not process email/Word notifications or persist conversations. Use Microsoft 365/Entra controls to disable accounts and revoke access.

## 4. Validation procedure and evidence

Record UTC test time, operation, expected tenant/child/user IDs, outcome and relevant Entra correlation/request ID. Don't record token strings or secrets.

| Test | Expected |
| --- | --- |
| `npm test` | TypeScript builds; mocked identity/routing tests and real local HTTP 401 tests pass |
| `npm run check` | Local validation passes, explicitly not a live credential test |
| Terminal `graph` | `/me` matches the mapped agent user |
| Terminal `mailbox` | Identity match, then Inbox metadata accessible, no messages read |
| Teams `whoami` | Human sender and recipient agent-user IDs are distinct and correct |
| Second allowlisted agent | Its own user/client IDs, never the first agent's |
| Remove tester from local allowlist, restart | No diagnostic/reply; rejection logged |
| Set mapping `enabled` to false, restart | No diagnostic/reply; rejection logged |
| Unsigned/forged POST to `/api/messages` | HTTP 401, even if payload contains valid-looking IDs |
| Disable Graph flag, restart | Diagnostic says disabled without acquiring a Graph token |

Correlate the live attempt with the relevant **agent/user and service-principal sign-in records in Entra**. The exchange may produce multiple records: distinguish blueprint authentication from the child client and dedicated agent user, and check the target resource and failure details. Do not assume one successful blueprint sign-in proves workload access. Log availability and delay depend on the tenant. Raw SDK exceptions are intentionally suppressed because HTTP errors can contain credential forms; use tenant-side diagnostics rather than adding `console.log(error)`.

Offline tests use synthetic IDs and mocked token/Graph responses; the local HTTP test uses the real SDK's authentication rejection. They do **not** validate Microsoft-issued JWT acceptance, live user token issuance, tenant consent, Exchange provisioning or real Teams replies. Those require the live steps above.

When finished, stop the runtime/tunnel, restore the previous test-blueprint endpoint (or remove only its lab endpoint registration), revoke only lab-specific grants/credentials, and remove `$env:CLIENT_SECRET`. Delete only dedicated lab identities after removing their workload access. No cleanup is automated.

## Useful official examples

- [Microsoft Teams SDK echo example](https://github.com/microsoft/teams.ts/tree/main/examples/echo): the simplest message/reply foundation.
- [Agent 365 n8n sample](https://github.com/microsoft/Agent365-Samples/tree/main/nodejs/n8n/sample-agent): an alternative if you prefer the runtime inside n8n. Not needed for this lab, and don't copy broad permission sets blindly.
- [Teams agent-factory routing](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/route-messages): tenant + recipient routing and agent-user token model.
- [Agent user accounts with Microsoft 365](https://learn.microsoft.com/entra/agent-id/agent-user-oauth-flow): why the account, delegated grant and workload provisioning are separate.
