function Get-AmMigrationCandidates {
    $apps = @(Invoke-AmGraph -Method GET -All -Path '/applications?$select=id,appId,displayName')
    $principals = @(Invoke-AmGraph -Method GET -All -Path '/servicePrincipals?$select=id,appId,displayName,servicePrincipalType')
    $byAppId = @{}
    foreach ($app in $apps) {
        if ($app.'@odata.type' -match 'agentIdentity' -or -not $app.appId) { continue }
        $byAppId[$app.appId] = [pscustomobject]@{
            id = $app.id; appId = $app.appId; displayName = $app.displayName
            applicationObjectId = $app.id; servicePrincipalObjectId = $null
        }
    }
    foreach ($sp in $principals) {
        if ($sp.'@odata.type' -match 'agentIdentity' -or $sp.servicePrincipalType -ne 'Application' -or -not $sp.appId) { continue }
        if ($byAppId.ContainsKey($sp.appId)) { $byAppId[$sp.appId].servicePrincipalObjectId = $sp.id }
        else {
            $byAppId[$sp.appId] = [pscustomobject]@{
                id = $sp.id; appId = $sp.appId; displayName = $sp.displayName
                applicationObjectId = $null; servicePrincipalObjectId = $sp.id
            }
        }
    }
    $byAppId.Values | Sort-Object displayName, appId
}

function Resolve-AmMigrationCandidate {
    param([Parameter(Mandatory)][string]$Selector)
    $items = @(Get-AmMigrationCandidates)
    $exact = @($items | Where-Object {
        $_.appId -eq $Selector -or $_.applicationObjectId -eq $Selector -or $_.servicePrincipalObjectId -eq $Selector
    })
    if ($exact.Count -eq 1) { return $exact[0] }
    Select-AmMatch -Items $items -Selector $Selector -Label 'application'
}

function Get-AmMigrationResource {
    param([string]$AppId, [string]$ObjectId, [System.Collections.Generic.List[string]]$Warnings)
    try {
        if ($ObjectId) { return Get-AmResourceSpById -Id $ObjectId }
        return Get-AmResourceSp -ResourceAppId $AppId
    } catch [AmGraphException] {
        if ($_.Exception.Status -ne 404) { throw }
        $Warnings.Add("Resource API not found (appId='$AppId', objectId='$ObjectId'). Permission IDs are preserved but cannot be fully resolved.")
        return $null
    }
}

function New-AmMigrationPermission {
    param(
        $Resource, [string]$ResourceAppId, [string]$ResourceObjectId,
        [string]$PermissionId, [string]$PermissionName,
        [ValidateSet('Application', 'Delegated')][string]$Type
    )
    $definition = $null
    if ($Resource) {
        $ResourceAppId = $Resource.appId
        $ResourceObjectId = $Resource.id
        $definitions = if ($Type -eq 'Application') { @($Resource.appRoles) } else { @($Resource.oauth2PermissionScopes) }
        $definition = $definitions | Where-Object {
            ($PermissionId -and $_.id -eq $PermissionId) -or ($PermissionName -and $_.value -eq $PermissionName)
        } | Select-Object -First 1
        if ($definition) { $PermissionId = $definition.id; $PermissionName = $definition.value }
    }
    $compatibility = 'NotEvaluated'
    if ($ResourceAppId -eq $script:GraphAppId) {
        $compatibility = if ($PermissionName) { (Test-AmPermissionBlocked -Name $PermissionName -Type $Type).Status } else { 'Unresolved' }
    }
    [pscustomobject][ordered]@{
        resourceAppId = $ResourceAppId
        resourceObjectId = $ResourceObjectId
        resourceName = if ($Resource) { $Resource.displayName } else { $null }
        type = $Type
        permissionId = $PermissionId
        permission = $PermissionName
        definitionResolved = [bool]$definition
        agentCompatibility = $compatibility
    }
}

function ConvertTo-AmMigrationCredentialMetadata {
    param($Object)
    foreach ($c in @($Object.passwordCredentials)) {
        if ($null -eq $c) { continue }
        [pscustomobject]@{ type = 'Secret'; keyId = $c.keyId; displayName = $c.displayName; startDateTime = $c.startDateTime; endDateTime = $c.endDateTime }
    }
    foreach ($c in @($Object.keyCredentials)) {
        if ($null -eq $c) { continue }
        [pscustomobject]@{ type = $c.type; usage = $c.usage; keyId = $c.keyId; displayName = $c.displayName; startDateTime = $c.startDateTime; endDateTime = $c.endDateTime }
    }
}

function Get-AmMigrationOwners {
    param([string]$Route)
    foreach ($owner in @(Invoke-AmGraph -Method GET -All -Path "$Route/owners?`$select=id,displayName")) {
        [pscustomobject]@{ id = $owner.id; displayName = $owner.displayName; type = $owner.'@odata.type' }
    }
}

function Get-AmMigrationInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate)
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $app = $null
    $sp = $null
    $appOwners = @()
    $spOwners = @()
    $federation = @()
    $configured = @()
    $applicationGrants = @()
    $delegatedGrants = @()
    if ($Candidate.applicationObjectId) {
        $route = "/applications/$($Candidate.applicationObjectId)"
        $app = Invoke-AmGraph -Method GET -Path "$route`?`$select=id,appId,displayName,createdDateTime,signInAudience,identifierUris,tags,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient"
        if ($app.'@odata.type' -match 'agentIdentity') { throw 'Select a standard app registration, not an existing Agent ID blueprint.' }
        $appOwners = @(Get-AmMigrationOwners -Route $route)
        $federation = @(Invoke-AmGraph -Method GET -All -Path "$route/federatedIdentityCredentials?`$select=id,name,issuer,subject,audiences" | ForEach-Object {
            [pscustomobject]@{ id = $_.id; name = $_.name; issuer = $_.issuer; subject = $_.subject; audiences = @($_.audiences) }
        })
        foreach ($entry in @($app.requiredResourceAccess)) {
            if ($null -eq $entry) { continue }
            $resource = Get-AmMigrationResource -AppId $entry.resourceAppId -Warnings $warnings
            foreach ($permission in @($entry.resourceAccess)) {
                $type = if ($permission.type -eq 'Role') { 'Application' } else { 'Delegated' }
                $configured += New-AmMigrationPermission -Resource $resource -ResourceAppId $entry.resourceAppId -PermissionId $permission.id -Type $type
            }
        }
    } else {
        $warnings.Add('No app registration in this tenant. Home-tenant configuration, configured permissions, application owners and federated credentials were not collected.')
    }
    if ($Candidate.servicePrincipalObjectId) {
        $route = "/servicePrincipals/$($Candidate.servicePrincipalObjectId)"
        $sp = Invoke-AmGraph -Method GET -Path "$route`?`$select=id,appId,displayName,createdDateTime,appOwnerOrganizationId,servicePrincipalType,accountEnabled,appRoleAssignmentRequired,tags,passwordCredentials,keyCredentials"
        if ($sp.'@odata.type' -match 'agentIdentity' -or $sp.servicePrincipalType -ne 'Application') { throw 'Select a standard enterprise application, not an agent identity or managed identity.' }
        $spOwners = @(Get-AmMigrationOwners -Route $route)
        foreach ($assignment in @(Invoke-AmGraph -Method GET -All -Path "$route/appRoleAssignments")) {
            $resource = Get-AmMigrationResource -ObjectId $assignment.resourceId -Warnings $warnings
            $permission = New-AmMigrationPermission -Resource $resource -ResourceObjectId $assignment.resourceId -PermissionId $assignment.appRoleId -Type Application
            $applicationGrants += [pscustomobject]@{
                assignmentId = $assignment.id; principalId = $assignment.principalId
                createdDateTime = $assignment.createdDateTime; permission = $permission
            }
        }
        foreach ($grant in @(Invoke-AmGraph -Method GET -All -Path "$route/oauth2PermissionGrants")) {
            $resource = Get-AmMigrationResource -ObjectId $grant.resourceId -Warnings $warnings
            $permissions = @(
                foreach ($scope in @($grant.scope -split '\s+' | Where-Object { $_ })) {
                    New-AmMigrationPermission -Resource $resource -ResourceObjectId $grant.resourceId -PermissionName $scope -Type Delegated
                }
            )
            $delegatedGrants += [pscustomobject]@{
                grantId = $grant.id; clientId = $grant.clientId; resourceObjectId = $grant.resourceId
                consentType = $grant.consentType; principalId = $grant.principalId
                scope = $grant.scope; permissions = $permissions
            }
        }
    } else {
        $warnings.Add('No enterprise application in this tenant. Granted permissions are empty because no service principal exists, not because configured permissions have been consented.')
    }
    $allPermissions = @($configured) + @($applicationGrants | ForEach-Object { $_.permission }) + @($delegatedGrants | ForEach-Object { $_.permissions })
    foreach ($permission in $allPermissions) {
        if (-not $permission.definitionResolved) {
            $warnings.Add("Unresolved permission definition: $($permission.resourceAppId) $($permission.type) $($permission.permissionId) $($permission.permission). Review manually.")
        }
        if ($permission.agentCompatibility -in 'Blocked', 'Unclear') {
            $warnings.Add("$($permission.agentCompatibility) for agents: $($permission.permission) ($($permission.type)). Do not copy without review.")
        }
    }
    $warnings.Add('Graph configured permissions are declarations, not consent. Granted delegated access can be tenant-wide or user-specific; preserve the distinction.')
    $warnings.Add('This is a migration inventory, not an automatic conversion. Review the workload code/authentication flow, new blueprint credentials and sponsor, Azure RBAC, Entra directory roles, Conditional Access and downstream dependencies separately. These dependencies and usage logs were not collected.')
    $warnings.Add('The bundled blocked-permissions list is a deny list, not proof of support. Non-Graph APIs are not evaluated for Agent ID compatibility.')
    [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        exportedAtUtc = [datetime]::UtcNow.ToString('o')
        source = [ordered]@{
            tenantId = $script:State.TenantId; displayName = $Candidate.displayName; appId = $Candidate.appId
            applicationObjectId = $Candidate.applicationObjectId; servicePrincipalObjectId = $Candidate.servicePrincipalObjectId
            homeTenantId = if ($sp) { $sp.appOwnerOrganizationId } else { $script:State.TenantId }
        }
        application = if ($app) {
            [ordered]@{
                createdDateTime = $app.createdDateTime; signInAudience = $app.signInAudience
                identifierUris = @($app.identifierUris | Where-Object { $null -ne $_ }); tags = @($app.tags | Where-Object { $null -ne $_ }); owners = $appOwners
                authentication = [ordered]@{
                    webRedirectUris = @($app.web.redirectUris | Where-Object { $null -ne $_ }); spaRedirectUris = @($app.spa.redirectUris | Where-Object { $null -ne $_ })
                    publicClientRedirectUris = @($app.publicClient.redirectUris | Where-Object { $null -ne $_ })
                    implicitGrantSettings = if ($app.web.implicitGrantSettings) {
                        [ordered]@{
                            enableAccessTokenIssuance = $app.web.implicitGrantSettings.enableAccessTokenIssuance
                            enableIdTokenIssuance = $app.web.implicitGrantSettings.enableIdTokenIssuance
                        }
                    } else { $null }
                    isFallbackPublicClient = $app.isFallbackPublicClient
                }
                credentials = @(ConvertTo-AmMigrationCredentialMetadata -Object $app)
                federatedIdentityCredentials = $federation
            }
        } else { $null }
        enterpriseApplication = if ($sp) {
            [ordered]@{
                createdDateTime = $sp.createdDateTime; servicePrincipalType = $sp.servicePrincipalType
                accountEnabled = $sp.accountEnabled; appRoleAssignmentRequired = $sp.appRoleAssignmentRequired
                tags = @($sp.tags | Where-Object { $null -ne $_ }); owners = $spOwners
                credentials = @(ConvertTo-AmMigrationCredentialMetadata -Object $sp)
            }
        } else { $null }
        permissions = [ordered]@{
            configured = $configured; grantedApplication = $applicationGrants; grantedDelegated = $delegatedGrants
        }
        compatibilityCatalog = [ordered]@{ source = (Get-AmBlockedList).Source; fetched = (Get-AmBlockedList).Fetched }
        warnings = @($warnings | Select-Object -Unique)
    }
}

function Export-AmMigrationInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Candidate,
        [string]$OutputDirectory = (Join-Path (Get-Location).Path 'exports'),
        [switch]$Force
    )
    if (-not (Test-AmGuid $Candidate.appId)) { throw 'The source application must have a valid appId.' }
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $safeName = ([string]$Candidate.displayName -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim().TrimEnd('.')
    if (-not $safeName) { $safeName = 'application' }
    if ($safeName.Length -gt 80) { $safeName = $safeName.Substring(0, 80).TrimEnd('.') }
    $folder = Join-Path $OutputDirectory "$safeName--$($Candidate.appId)"
    $path = Join-Path $folder 'app.json'
    if ((Test-Path -LiteralPath $path) -and -not $Force) { throw "Export already exists: $path. Choose another output directory or use --force to replace it." }
    $inventory = Get-AmMigrationInventory -Candidate $Candidate
    $json = $inventory | ConvertTo-Json -Depth 20
    $null = [System.IO.Directory]::CreateDirectory($folder)
    $mode = if ($Force) { [System.IO.FileMode]::Create } else { [System.IO.FileMode]::CreateNew }
    $stream = [System.IO.File]::Open($path, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Protect-AmFile -Path $path
    [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($path); Warnings = $inventory.warnings }
}
