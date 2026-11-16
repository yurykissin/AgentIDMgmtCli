param(
    [ValidateSet(
        "tree",
        "show-blueprint",
        "show-identity",
        "show-blueprint-permissions",
        "show-identity-permissions",
        "create-graph",
        "create-a365",
        "register-existing",
        "delete-blueprint",
        "delete-identity",
        "delete-registration"
    )]
    [string]$Command = "",

    [string]$TenantId,
    [string]$Selector,
    [string]$BlueprintName,
    [string]$IdentityName,
    [string]$RegistrationName,
    [string]$Description,
    [string]$SponsorObjectId,
    [string]$AgentName,
    [string]$GraphClientId,
    [string]$GraphAccessToken,
    [switch]$NoRegister,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$M365
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AgentXAppId = "59eca866-2f46-40b8-96ff-63f663121ef9"
$script:RegistryReadable = $true
$script:InteractiveMenuMode = $false
$script:CachedCustomToken = $null
$script:CachedCustomTokenExpires = [datetime]::MinValue

function Get-AzContext {
    try {
        $raw = az account show -o json 2>$null
        if (-not $raw) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Ensure-AzureConnection {
    $ctx = Get-AzContext
    $needsLogin = $false

    if (-not $ctx) {
        $needsLogin = $true
    } elseif ($script:TenantId -and $ctx.tenantId -ne $script:TenantId) {
        Write-Host "Current tenant is $($ctx.tenantId), expected $script:TenantId." -ForegroundColor Yellow
        $needsLogin = $true
    }

    if ($needsLogin) {
        Write-Host "Signing in to Azure..." -ForegroundColor Cyan
        if ($script:TenantId) {
            az login --tenant $script:TenantId --allow-no-subscriptions | Out-Null
        } else {
            az login --allow-no-subscriptions | Out-Null
        }
        $ctx = Get-AzContext
        if (-not $ctx) {
            throw "Azure login did not produce an active account context."
        }
    }

    Write-Host "Connected Azure context:" -ForegroundColor Green
    Write-Host "  User: $($ctx.user.name)"
    Write-Host "  Tenant: $($ctx.tenantId)"
    Write-Host "  Subscription: $($ctx.name) [$($ctx.id)]"

    if (-not $script:TenantId) {
        $script:TenantId = $ctx.tenantId
    }
}

function Get-GraphTokenViaCustomClient {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    if ($script:CachedCustomToken -and [datetime]::UtcNow -lt $script:CachedCustomTokenExpires) {
        return $script:CachedCustomToken
    }

    if (-not $script:TenantId) {
        throw "TenantId is required for custom client device code flow."
    }

    $base = "https://login.microsoftonline.com/$script:TenantId/oauth2/v2.0"
    $dcBody = @{
        client_id = $ClientId
        scope = $Scope
    }
    $dc = Invoke-RestMethod -Method POST -Uri "$base/devicecode" -Body $dcBody -ContentType "application/x-www-form-urlencoded"
    Write-Host $dc.message -ForegroundColor Cyan

    $interval = [int]$dc.interval
    $expiresAt = [datetime]::UtcNow.AddSeconds([int]$dc.expires_in)
    while ([datetime]::UtcNow -lt $expiresAt) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method POST -Uri "$base/token" -Body @{
                grant_type = "urn:ietf:params:oauth:grant-type:device_code"
                client_id = $ClientId
                device_code = $dc.device_code
            } -ContentType "application/x-www-form-urlencoded"
            $script:CachedCustomToken = $tok.access_token
            $script:CachedCustomTokenExpires = [datetime]::UtcNow.AddSeconds([int]$tok.expires_in - 120)
            return $script:CachedCustomToken
        } catch {
            $msg = $_.ErrorDetails.Message
            if ($msg -and ($msg -match "authorization_pending" -or $msg -match "slow_down")) {
                continue
            }
            throw
        }
    }
    throw "Device code flow timed out."
}

function Get-ApiVersionFromPath {
    param([string]$Path)
    if ($Path -like "/copilot/*") { return "beta" }
    return "v1.0"
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET","POST","PATCH","DELETE")] [string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )
    $apiVersion = Get-ApiVersionFromPath -Path $Path
    $url = "https://graph.microsoft.com/$apiVersion$Path"
    $token = $null
    $isRegistryCall = $Path -like "/copilot/*"
    if ($GraphAccessToken) {
        $token = $GraphAccessToken
    } elseif ($isRegistryCall -and $GraphClientId) {
        $token = Get-GraphTokenViaCustomClient -ClientId $GraphClientId -Scope "https://graph.microsoft.com/AgentRegistration.ReadWrite.All offline_access openid profile"
    } else {
        $tokenArgs = @("account", "get-access-token", "--resource", "https://graph.microsoft.com/", "-o", "json")
        if ($script:TenantId) {
            $tokenArgs += @("--tenant", $script:TenantId)
        }
        $tokenRaw = (& az @tokenArgs 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Could not acquire Graph token from Azure CLI.`n$tokenRaw"
        }
        try {
            $tokenData = $tokenRaw | ConvertFrom-Json
        } catch {
            throw "Could not parse Azure CLI token response.`n$tokenRaw"
        }
        if (-not ($tokenData.PSObject.Properties.Name -contains "accessToken")) {
            throw "Azure CLI token response has no accessToken.`n$tokenRaw"
        }
        $token = $tokenData.accessToken
    }

    $headers = @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
        "OData-Version" = "4.0"
    }

    try {
        if ($Method -eq "GET") {
            return Invoke-RestMethod -Method GET -Uri $url -Headers $headers
        }
        if ($Method -eq "DELETE") {
            Invoke-RestMethod -Method DELETE -Uri $url -Headers $headers | Out-Null
            return $null
        }

        $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
        return Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -Body $jsonBody
    } catch {
        $response = $_.Exception.Response
        if ($response) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $bodyText = $reader.ReadToEnd()
            if ($url -like "*/beta/copilot/agentRegistrations*") {
                $bodyText += "`nHint: Azure CLI app may be blocked for AgentRegistration scopes (AADSTS65002)."
                $bodyText += "`nPass -GraphClientId <your-app-client-id> with delegated AgentRegistration.ReadWrite.All consent, or pass -GraphAccessToken."
            }
            throw "Graph call failed: $Method $url`n$bodyText"
        }
        throw "Graph call failed: $Method $url`n$($_.Exception.Message)"
    }
}

function Get-CurrentUserId {
    $me = Invoke-Graph -Method GET -Path "/me?`$select=id,displayName,userPrincipalName"
    return $me.id
}

function Get-Blueprints {
    $resp = Invoke-Graph -Method GET -Path "/applications/microsoft.graph.agentIdentityBlueprint?`$select=id,appId,displayName,createdDateTime"
    return @($resp.value)
}

function Get-Identities {
    $resp = Invoke-Graph -Method GET -Path "/servicePrincipals/microsoft.graph.agentIdentity?`$select=id,appId,displayName,accountEnabled,agentIdentityBlueprintId"
    return @($resp.value)
}

function Get-Registrations {
    try {
        $resp = Invoke-Graph -Method GET -Path "/copilot/agentRegistrations"
        $script:RegistryReadable = $true
        return @($resp.value)
    } catch {
        $script:RegistryReadable = $false
        Write-Host "Warning: Agent registry endpoint unavailable or unauthorized. Continuing without registrations." -ForegroundColor Yellow
        return @()
    }
}

function Resolve-Blueprint {
    param([Parameter(Mandatory = $true)][string]$Value)
    $bps = Get-Blueprints
    $k = $Value.ToLowerInvariant()
    $matches = @(
        $bps | Where-Object {
            $_.id.ToLowerInvariant() -eq $k -or
            $_.appId.ToLowerInvariant() -eq $k -or
            $_.displayName.ToLowerInvariant() -eq $k
        }
    )
    if ($matches.Count -eq 0) { throw "Blueprint not found: $Value" }
    if ($matches.Count -gt 1) { throw "Multiple blueprints matched: $Value" }
    return $matches[0]
}

function Resolve-Identity {
    param([Parameter(Mandatory = $true)][string]$Value)
    $ids = Get-Identities
    $k = $Value.ToLowerInvariant()
    $matches = @(
        $ids | Where-Object {
            $_.id.ToLowerInvariant() -eq $k -or
            $_.appId.ToLowerInvariant() -eq $k -or
            $_.displayName.ToLowerInvariant() -eq $k
        }
    )
    if ($matches.Count -eq 0) { throw "Identity not found: $Value" }
    if ($matches.Count -gt 1) { throw "Multiple identities matched: $Value" }
    return $matches[0]
}

function Resolve-Registration {
    param([Parameter(Mandatory = $true)][string]$Value)
    $regs = Get-Registrations
    $k = $Value.ToLowerInvariant()
    $matches = @(
        $regs | Where-Object {
            $_.id.ToLowerInvariant() -eq $k -or
            $_.displayName.ToLowerInvariant() -eq $k
        }
    )
    if ($matches.Count -eq 0) { throw "Registration not found: $Value" }
    if ($matches.Count -gt 1) { throw "Multiple registrations matched: $Value" }
    return $matches[0]
}

function Select-ByIndex {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label
    )
    if ($Items.Count -eq 0) { return $null }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i + 1), (& $Label $Items[$i]))
    }
    $raw = Read-Host "Select number"
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed)) {
        throw "Invalid selection: $raw"
    }
    $idx = $parsed - 1
    if ($idx -lt 0 -or $idx -ge $Items.Count) {
        throw "Selection out of range: $raw"
    }
    return $Items[$idx]
}

function Confirm-Delete {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Force) { return }
    $typed = Read-Host "Type exact name to confirm delete: $Name"
    if ($typed -ne $Name) { throw "Delete cancelled. Name mismatch." }
}

function Show-PermissionsForSp {
    param([Parameter(Mandatory = $true)][string]$ServicePrincipalId)

    $grants = Invoke-Graph -Method GET -Path "/oauth2PermissionGrants?`$filter=clientId eq '$ServicePrincipalId'"
    $roles = Invoke-Graph -Method GET -Path "/servicePrincipals/$ServicePrincipalId/appRoleAssignments?`$select=id,resourceId,appRoleId"

    Write-Host "`nDelegated grants:" -ForegroundColor Cyan
    @($grants.value) |
        Select-Object resourceId, scope |
        Format-Table -AutoSize

    Write-Host "`nApplication role assignments:" -ForegroundColor Cyan
    @($roles.value) |
        Select-Object resourceId, appRoleId |
        Format-Table -AutoSize
}

function Cmd-Tree {
    $bps = Get-Blueprints
    $ids = Get-Identities
    $regs = Get-Registrations

    foreach ($bp in ($bps | Sort-Object displayName)) {
        Write-Host "BP: $($bp.displayName)" -ForegroundColor Green
        Write-Host "  blueprintObjectId: $($bp.id)"
        Write-Host "  blueprintAppId:    $($bp.appId)"

        $bpRegs = @($regs | Where-Object { $_.agentIdentityBlueprintId -eq $bp.id })
        if ($script:RegistryReadable) {
            if ($bpRegs.Count -gt 0) {
                Write-Host "  ADMIN REGISTRATION:"
                foreach ($r in $bpRegs) {
                    Write-Host "    REG: $($r.displayName)"
                    Write-Host "      registrationId: $($r.id)"
                    Write-Host "      agentIdentityId: $($r.agentIdentityId)"
                }
            } else {
                Write-Host "  ADMIN REGISTRATION: missing" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ADMIN REGISTRATION: unknown (no access to /beta/copilot/agentRegistrations)" -ForegroundColor Yellow
        }

        $bpIds = @($ids | Where-Object { $_.agentIdentityBlueprintId -eq $bp.id })
        if ($bpIds.Count -eq 0) {
            Write-Host "  AGENTS: none"
        } else {
            Write-Host "  AGENTS:"
            foreach ($i in $bpIds) {
                $state = if ($i.accountEnabled) { "enabled" } else { "disabled" }
                Write-Host "    AGENT: $($i.displayName) [$state]"
                Write-Host "      identityObjectId: $($i.id)"
                Write-Host "      identityAppId:    $($i.appId)"
            }
        }
        Write-Host ""
    }

    $orphans = @($ids | Where-Object { -not $_.agentIdentityBlueprintId })
    if ($orphans.Count -gt 0) {
        Write-Host "ORPHAN AGENTS (no linked blueprint id)" -ForegroundColor Yellow
        foreach ($o in $orphans) {
            Write-Host "  AGENT: $($o.displayName) ($($o.id))"
        }
        Write-Host ""
    }
}

function Cmd-ShowBlueprint {
    if (-not $Selector) { throw "-Selector is required." }
    $bp = Resolve-Blueprint -Value $Selector
    $bp | Format-List id, appId, displayName, createdDateTime
}

function Cmd-ShowIdentity {
    if (-not $Selector) { throw "-Selector is required." }
    $idn = Resolve-Identity -Value $Selector
    $idn | Format-List id, appId, displayName, accountEnabled
}

function Cmd-ShowBlueprintPermissions {
    if (-not $Selector) { throw "-Selector is required." }
    $bp = Resolve-Blueprint -Value $Selector
    $sp = Invoke-Graph -Method GET -Path "/servicePrincipals?`$filter=appId eq '$($bp.appId)'&`$select=id,appId,displayName"
    if (-not $sp.value -or $sp.value.Count -eq 0) {
        throw "No service principal found for blueprint appId $($bp.appId)."
    }
    Show-PermissionsForSp -ServicePrincipalId $sp.value[0].id
}

function Cmd-ShowIdentityPermissions {
    if (-not $Selector) { throw "-Selector is required." }
    $idn = Resolve-Identity -Value $Selector
    Show-PermissionsForSp -ServicePrincipalId $idn.id
}

function Cmd-CreateGraph {
    if (-not $BlueprintName) { throw "-BlueprintName is required." }
    if (-not $IdentityName) { throw "-IdentityName is required." }

    $ownerId = Get-CurrentUserId
    $sponsorId = if ($SponsorObjectId) { $SponsorObjectId } else { $ownerId }

    $bpBody = @{
        displayName = $BlueprintName
        "sponsors@odata.bind" = @("https://graph.microsoft.com/v1.0/users/$sponsorId")
    }
    $bp = Invoke-Graph -Method POST -Path "/applications/microsoft.graph.agentIdentityBlueprint" -Body $bpBody

    $principalBody = @{ appId = $bp.appId }
    $null = Invoke-Graph -Method POST -Path "/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal" -Body $principalBody

    $idBody = @{
        displayName = $IdentityName
        agentIdentityBlueprintId = $bp.id
        "sponsors@odata.bind" = @("https://graph.microsoft.com/v1.0/users/$sponsorId")
    }
    $idn = Invoke-Graph -Method POST -Path "/servicePrincipals/microsoft.graph.agentIdentity" -Body $idBody

    $reg = $null
    if (-not $NoRegister) {
        $now = (Get-Date).ToUniversalTime().ToString("o")
        $regBody = @{
            id = [guid]::NewGuid().ToString()
            displayName = $(if ($RegistrationName) { $RegistrationName } else { "$IdentityName Agent" })
            ownerIds = @($ownerId)
            createdBy = $ownerId
            sourceCreatedDateTime = $now
            sourceLastModifiedDateTime = $now
            agentIdentityBlueprintId = $bp.id
            agentIdentityId = $idn.id
            sourceAgentId = $idn.id
            managedByAppId = $AgentXAppId
        }
        if ($Description) { $regBody.description = $Description }
        $reg = Invoke-Graph -Method POST -Path "/copilot/agentRegistrations" -Body $regBody
    }

    [pscustomobject]@{
        blueprint = $bp
        identity = $idn
        registration = $reg
    } | ConvertTo-Json -Depth 8
}

function Cmd-CreateA365 {
    if (-not $AgentName) { throw "-AgentName is required." }
    $args = @("setup", "all", "--agent-name", $AgentName)
    if ($TenantId) { $args += @("--tenant-id", $TenantId) }
    if ($M365) { $args += @("--m365") }
    if ($DryRun) { $args += @("--dry-run") }
    & a365 @args
}

function Cmd-RegisterExisting {
    $bps = Get-Blueprints
    $ids = Get-Identities
    $regs = Get-Registrations
    $bp = $null

    if ($BlueprintName) {
        $bp = Resolve-Blueprint -Value $BlueprintName
    } else {
        if ($script:RegistryReadable) {
            $registeredBpIds = @($regs | Where-Object { $_.agentIdentityBlueprintId } | ForEach-Object { $_.agentIdentityBlueprintId })
            $registeredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($rid in $registeredBpIds) { [void]$registeredSet.Add($rid) }
            $candidates = @($bps | Where-Object { -not $registeredSet.Contains($_.id) })
            Write-Host "Unregistered blueprints (no admin portal registration found):" -ForegroundColor Cyan
            if ($candidates.Count -eq 0) {
                throw "No unregistered blueprints were found."
            }
            $bp = Select-ByIndex -Items $candidates -Label {
                param($x)
                "BP: $($x.displayName) | objectId=$($x.id)"
            }
        } else {
            Write-Host "Registry list is unavailable, so unregistered filtering is not possible." -ForegroundColor Yellow
            Write-Host "Select blueprint from all blueprints:" -ForegroundColor Cyan
            $bp = Select-ByIndex -Items $bps -Label {
                param($x)
                "BP: $($x.displayName) | objectId=$($x.id)"
            }
        }
    }

    $idn = $null
    if ($IdentityName) {
        $idn = Resolve-Identity -Value $IdentityName
    } else {
        $bpIdentities = @($ids | Where-Object { $_.agentIdentityBlueprintId -eq $bp.id })
        if ($bpIdentities.Count -eq 0) {
            throw "No identities found for blueprint: $($bp.displayName)"
        }
        if ($bpIdentities.Count -eq 1) {
            $idn = $bpIdentities[0]
            Write-Host "Selected only identity for blueprint: $($idn.displayName)" -ForegroundColor Green
        } else {
            Write-Host "Select identity under blueprint '$($bp.displayName)':" -ForegroundColor Cyan
            $idn = Select-ByIndex -Items $bpIdentities -Label {
                param($x)
                "AGENT: $($x.displayName) | objectId=$($x.id)"
            }
        }
    }

    if ($idn.agentIdentityBlueprintId -and $idn.agentIdentityBlueprintId -ne $bp.id) {
        throw "Selected identity does not belong to selected blueprint."
    }

    if ($script:InteractiveMenuMode) {
        if (-not $GraphClientId -and -not $GraphAccessToken) {
            $maybeClient = Read-Host "Optional Graph app client ID for registry auth (blank = Azure CLI token)"
            if ($maybeClient) { $GraphClientId = $maybeClient }
        }
        if (-not $RegistrationName) {
            $prompt = "Registration display name [$($bp.displayName)]"
            $entered = Read-Host $prompt
            if ($entered) { $RegistrationName = $entered }
        }
        if (-not $Description) {
            $Description = Read-Host "Registration description (optional)"
            if (-not $Description) { $Description = $null }
        }
    }

    $ownerId = Get-CurrentUserId
    $regDisplayName = if ($RegistrationName) { $RegistrationName } else { $bp.displayName }
    $now = (Get-Date).ToUniversalTime().ToString("o")

    $regBody = @{
        id = [guid]::NewGuid().ToString()
        displayName = $regDisplayName
        ownerIds = @($ownerId)
        createdBy = $ownerId
        sourceCreatedDateTime = $now
        sourceLastModifiedDateTime = $now
        agentIdentityBlueprintId = $bp.id
        agentIdentityId = $idn.id
        sourceAgentId = $idn.id
        managedByAppId = $AgentXAppId
    }
    if ($Description) { $regBody.description = $Description }

    try {
        $reg = Invoke-Graph -Method POST -Path "/copilot/agentRegistrations" -Body $regBody
        Write-Host "Registered existing agent in admin portal." -ForegroundColor Green
        $reg | ConvertTo-Json -Depth 8
    } catch {
        Write-Host "Registry POST failed with current Azure CLI auth context." -ForegroundColor Yellow
        Write-Host "Use -GraphClientId or -GraphAccessToken for SDK-style Graph registration auth." -ForegroundColor Yellow
        throw
    }
}

function Cmd-DeleteBlueprint {
    if (-not $Selector) { throw "-Selector is required." }
    $bp = Resolve-Blueprint -Value $Selector
    Confirm-Delete -Name $bp.displayName
    Invoke-Graph -Method DELETE -Path "/applications/$($bp.id)/microsoft.graph.agentIdentityBlueprint"
    Write-Host "Deleted blueprint: $($bp.displayName) ($($bp.id))" -ForegroundColor Green
}

function Cmd-DeleteIdentity {
    if (-not $Selector) { throw "-Selector is required." }
    $idn = Resolve-Identity -Value $Selector
    Confirm-Delete -Name $idn.displayName
    Invoke-Graph -Method DELETE -Path "/servicePrincipals/$($idn.id)/microsoft.graph.agentIdentity"
    Write-Host "Deleted identity: $($idn.displayName) ($($idn.id))" -ForegroundColor Green
}

function Cmd-DeleteRegistration {
    if (-not $Selector) { throw "-Selector is required." }
    $reg = Resolve-Registration -Value $Selector
    Confirm-Delete -Name $reg.displayName
    Invoke-Graph -Method DELETE -Path "/copilot/agentRegistrations/$($reg.id)"
    Write-Host "Deleted registration: $($reg.displayName) ($($reg.id))" -ForegroundColor Green
}

function Invoke-InteractiveMenu {
    while ($true) {
        Write-Host ""
        Write-Host "AgentMgmt Menu" -ForegroundColor Cyan
        Write-Host "1) Tree view"
        Write-Host "2) Show blueprint"
        Write-Host "3) Show identity"
        Write-Host "4) Show blueprint permissions"
        Write-Host "5) Show identity permissions"
        Write-Host "6) Create (Graph)"
        Write-Host "7) Create (a365)"
        Write-Host "8) Delete blueprint"
        Write-Host "9) Delete identity"
        Write-Host "10) Delete registration"
        Write-Host "11) Register existing (show unregistered BPs, then select)"
        Write-Host "0) Exit"

        $choice = Read-Host "Select option"
        if ($choice -eq "0") { return }

        switch ($choice) {
            "1" { Cmd-Tree }
            "2" {
                $Selector = Read-Host "Blueprint selector (id, appId, or exact name)"
                Cmd-ShowBlueprint
            }
            "3" {
                $Selector = Read-Host "Identity selector (id, appId, or exact name)"
                Cmd-ShowIdentity
            }
            "4" {
                $Selector = Read-Host "Blueprint selector (id, appId, or exact name)"
                Cmd-ShowBlueprintPermissions
            }
            "5" {
                $Selector = Read-Host "Identity selector (id, appId, or exact name)"
                Cmd-ShowIdentityPermissions
            }
            "6" {
                $BlueprintName = Read-Host "Blueprint name"
                $IdentityName = Read-Host "Identity name"
                $RegistrationName = Read-Host "Registration name (blank = auto)"
                if (-not $RegistrationName) { $RegistrationName = $null }
                $Description = Read-Host "Description (optional)"
                if (-not $Description) { $Description = $null }
                $SponsorObjectId = Read-Host "Sponsor object ID (blank = current user)"
                if (-not $SponsorObjectId) { $SponsorObjectId = $null }
                $registerChoice = Read-Host "Register in admin portal? (Y/n)"
                $NoRegister = $registerChoice -match "^[Nn]"
                Cmd-CreateGraph
            }
            "7" {
                $AgentName = Read-Host "Agent base name"
                $dry = Read-Host "Dry run? (Y/n)"
                $DryRun = -not ($dry -match "^[Nn]")
                $m = Read-Host "Use M365 mode? (y/N)"
                $M365 = $m -match "^[Yy]"
                Cmd-CreateA365
            }
            "8" {
                $Selector = Read-Host "Blueprint selector (id, appId, or exact name)"
                Cmd-DeleteBlueprint
            }
            "9" {
                $Selector = Read-Host "Identity selector (id, appId, or exact name)"
                Cmd-DeleteIdentity
            }
            "10" {
                $Selector = Read-Host "Registration selector (id or exact name)"
                Cmd-DeleteRegistration
            }
            "11" {
                $BlueprintName = $null
                $IdentityName = $null
                $RegistrationName = $null
                $Description = $null
                Cmd-RegisterExisting
            }
            default { Write-Host "Unknown option." -ForegroundColor Yellow }
        }
    }
}

if (-not $Command) {
    Ensure-AzureConnection
    $script:InteractiveMenuMode = $true
    Invoke-InteractiveMenu
    exit 0
}

Ensure-AzureConnection

switch ($Command) {
    "tree" { Cmd-Tree; break }
    "show-blueprint" { Cmd-ShowBlueprint; break }
    "show-identity" { Cmd-ShowIdentity; break }
    "show-blueprint-permissions" { Cmd-ShowBlueprintPermissions; break }
    "show-identity-permissions" { Cmd-ShowIdentityPermissions; break }
    "create-graph" { Cmd-CreateGraph; break }
    "create-a365" { Cmd-CreateA365; break }
    "register-existing" { Cmd-RegisterExisting; break }
    "delete-blueprint" { Cmd-DeleteBlueprint; break }
    "delete-identity" { Cmd-DeleteIdentity; break }
    "delete-registration" { Cmd-DeleteRegistration; break }
    default { throw "Unsupported command: $Command" }
}

