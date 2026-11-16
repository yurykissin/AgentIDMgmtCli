function Get-AmResourceSpById {
    param([Parameter(Mandatory)][string]$Id)
    $key = "resid:$Id"
    if (-not $script:State.Cache.ContainsKey($key)) {
        $script:State.Cache[$key] = Invoke-AmGraph -Method GET -Path "/servicePrincipals/$Id`?`$select=id,appId,displayName,appRoles,oauth2PermissionScopes,servicePrincipalNames"
    }
    return $script:State.Cache[$key]
}

function Assert-AmPermissionAllowed {
    param([string]$Name, [ValidateSet('Application', 'Delegated')][string]$Type, [string]$Target = 'agent identities', [switch]$SkipBlockCheck)
    $check = Test-AmPermissionBlocked -Name $Name -Type $Type
    if ($check.Status -eq 'Blocked' -and -not $SkipBlockCheck) {
        throw "$($check.Name) ($Type) is on Microsoft's blocked-for-agents list and cannot be granted to $Target. Choose a narrower permission."
    }
    if ($check.Status -eq 'Unclear') {
        Write-Warning "$($check.Name) ($Type) is on the blocked list with a '-' (not applicable) marker for this type; Graph will make the final decision."
    }
}

function New-AmAdminConsentUrl {
    param([Parameter(Mandatory)][string]$ClientAppId, [Parameter(Mandatory)][string]$ResourceAppId, [Parameter(Mandatory)][string[]]$Scopes)
    $sp = Get-AmResourceSp -ResourceAppId $ResourceAppId
    $prefix = if ($ResourceAppId -eq $script:GraphAppId) { 'https://graph.microsoft.com' }
    else {
        $uri = @($sp.servicePrincipalNames | Where-Object { $_ -notmatch '^[0-9a-fA-F-]{36}$' }) | Select-Object -First 1
        if ($uri) { $uri.TrimEnd('/') } else { $ResourceAppId }
    }
    $scopeParam = [uri]::EscapeDataString(($Scopes | ForEach-Object { "$prefix/$_" }) -join ' ')
    $tenant = if ($script:State.TenantId) { $script:State.TenantId } else { 'organizations' }
    $redirect = [uri]::EscapeDataString('https://entra.microsoft.com/TokenAuthorize')
    return "https://login.microsoftonline.com/$tenant/v2.0/adminconsent?client_id=$ClientAppId&scope=$scopeParam&redirect_uri=$redirect&state=$([guid]::NewGuid().ToString('N'))"
}

# ---- Blueprint: required resource access (declaration only) -------------

function Get-AmBlueprintRequiredAccess {
    param([Parameter(Mandatory)][string]$BlueprintId)
    $bp = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)?`$select=id,appId,requiredResourceAccess"
    return @($bp.requiredResourceAccess)
}

function ConvertTo-AmRequiredAccessBody {
    param([object[]]$Entries)
    return @($Entries | Where-Object { @($_.resourceAccess).Count -gt 0 } | ForEach-Object {
            @{ resourceAppId = $_.resourceAppId; resourceAccess = @($_.resourceAccess | ForEach-Object { @{ id = $_.id; type = $_.type } }) }
        })
}

function Add-AmBlueprintRequiredAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string]$PermissionId,
        [Parameter(Mandatory)][ValidateSet('Scope', 'Role')][string]$Type
    )
    $current = @(Get-AmBlueprintRequiredAccess -BlueprintId $BlueprintId)
    $entry = $current | Where-Object { $_.resourceAppId -eq $ResourceAppId } | Select-Object -First 1
    if (-not $entry) {
        $entry = [pscustomobject]@{ resourceAppId = $ResourceAppId; resourceAccess = @() }
        $current += $entry
    }
    if (-not (@($entry.resourceAccess) | Where-Object { $_.id -eq $PermissionId -and $_.type -eq $Type })) {
        $entry.resourceAccess = @($entry.resourceAccess) + [pscustomobject]@{ id = $PermissionId; type = $Type }
    }
    $null = Invoke-AmGraph -Method PATCH -Path (Get-AmObjectRoute Blueprint $BlueprintId) -Body @{ requiredResourceAccess = @(ConvertTo-AmRequiredAccessBody $current) }
}

function Remove-AmBlueprintRequiredAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string]$PermissionId
    )
    $current = @(Get-AmBlueprintRequiredAccess -BlueprintId $BlueprintId)
    foreach ($entry in $current) {
        if ($entry.resourceAppId -eq $ResourceAppId) { $entry.resourceAccess = @(@($entry.resourceAccess) | Where-Object { $_.id -ne $PermissionId }) }
    }
    $null = Invoke-AmGraph -Method PATCH -Path (Get-AmObjectRoute Blueprint $BlueprintId) -Body @{ requiredResourceAccess = @(ConvertTo-AmRequiredAccessBody $current) }
}

# ---- Blueprint: inheritable permissions ---------------------------------

function Get-AmInheritablePermissions {
    param([Parameter(Mandatory)][string]$BlueprintId)
    @(Invoke-AmGraph -Method GET -All -Path "/applications/microsoft.graph.agentIdentityBlueprint/$BlueprintId/inheritablePermissions")
}

function Set-AmInheritablePermission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [ValidateSet('allAllowed', 'none')][string]$Scopes = 'allAllowed',
        [ValidateSet('allAllowed', 'none')][string]$Roles = 'none'
    )
    $body = @{
        resourceAppId     = $ResourceAppId
        inheritableScopes = if ($Scopes -eq 'allAllowed') { @{ '@odata.type' = '#microsoft.graph.allAllowedScopes'; kind = 'allAllowed' } } else { @{ '@odata.type' = '#microsoft.graph.noScopes'; kind = 'none' } }
        inheritableRoles  = if ($Roles -eq 'allAllowed') { @{ '@odata.type' = '#microsoft.graph.allAllowedRoles'; kind = 'allAllowed' } } else { @{ '@odata.type' = '#microsoft.graph.noRoles'; kind = 'none' } }
    }
    $base = "/applications/microsoft.graph.agentIdentityBlueprint/$BlueprintId/inheritablePermissions"
    $existing = @(Get-AmInheritablePermissions -BlueprintId $BlueprintId) | Where-Object { $_.resourceAppId -eq $ResourceAppId }
    if ($existing) {
        $patch = @{ inheritableScopes = $body.inheritableScopes; inheritableRoles = $body.inheritableRoles }
        Invoke-AmGraph -Method PATCH -Path "$base/$ResourceAppId" -Body $patch
    } else {
        Invoke-AmGraph -Method POST -Path $base -Body $body
    }
}

function Remove-AmInheritablePermission {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BlueprintId, [Parameter(Mandatory)][string]$ResourceAppId)
    $null = Invoke-AmGraph -Method DELETE -Path "/applications/microsoft.graph.agentIdentityBlueprint/$BlueprintId/inheritablePermissions/$ResourceAppId"
}

# ---- Delegated grants (OAuth2) on any service principal -----------------

function Get-AmDelegatedGrants {
    param([Parameter(Mandatory)][string]$SpId)
    $rows = @(Invoke-AmGraph -Method GET -All -Path "/oauth2PermissionGrants?`$filter=clientId eq '$SpId'")
    foreach ($row in $rows) {
        $res = Get-AmResourceSpById -Id $row.resourceId
        [pscustomobject]@{
            GrantId = $row.id; Resource = $res.displayName; ResourceAppId = $res.appId; ResourceSpId = $row.resourceId
            ConsentType = $row.consentType; Scopes = @($row.scope -split ' ' | Where-Object { $_ })
        }
    }
}

function Grant-AmDelegated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientSpId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string[]]$Scopes,
        [string]$Target = 'agent identities',
        [switch]$SkipBlockCheck
    )
    $res = Get-AmResourceSp -ResourceAppId $ResourceAppId
    foreach ($scope in $Scopes) {
        Assert-AmPermissionAllowed -Name $scope -Type Delegated -Target $Target -SkipBlockCheck:$SkipBlockCheck
        if (-not ($res.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })) { throw "Scope '$scope' does not exist on $($res.displayName)." }
    }
    $existing = @(Invoke-AmGraph -Method GET -All -Path "/oauth2PermissionGrants?`$filter=clientId eq '$ClientSpId' and resourceId eq '$($res.id)'") | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if ($existing) {
        $merged = @(($existing.scope -split ' ' | Where-Object { $_ }) + $Scopes | Select-Object -Unique)
        Invoke-AmGraph -Method PATCH -Path "/oauth2PermissionGrants/$($existing.id)" -Body @{ scope = ($merged -join ' ') }
    } else {
        Invoke-AmGraph -Method POST -Path '/oauth2PermissionGrants' -Body @{ clientId = $ClientSpId; consentType = 'AllPrincipals'; resourceId = $res.id; scope = ($Scopes -join ' ') }
    }
}

function Revoke-AmDelegated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientSpId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string[]]$Scopes
    )
    $res = Get-AmResourceSp -ResourceAppId $ResourceAppId
    $existing = @(Invoke-AmGraph -Method GET -All -Path "/oauth2PermissionGrants?`$filter=clientId eq '$ClientSpId' and resourceId eq '$($res.id)'") | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if (-not $existing) { throw "No tenant-wide delegated grant found for $($res.displayName)." }
    $remaining = @($existing.scope -split ' ' | Where-Object { $_ -and ($Scopes -notcontains $_) })
    if ($remaining.Count -eq 0) { $null = Invoke-AmGraph -Method DELETE -Path "/oauth2PermissionGrants/$($existing.id)" }
    else { $null = Invoke-AmGraph -Method PATCH -Path "/oauth2PermissionGrants/$($existing.id)" -Body @{ scope = ($remaining -join ' ') } }
}

# ---- Application permissions (app role assignments) ---------------------

function Get-AmAppRoleAssignments {
    param([Parameter(Mandatory)][string]$SpId)
    $rows = @(Invoke-AmGraph -Method GET -All -Path "/servicePrincipals/$SpId/appRoleAssignments")
    foreach ($row in $rows) {
        $res = Get-AmResourceSpById -Id $row.resourceId
        $role = $res.appRoles | Where-Object { $_.id -eq $row.appRoleId } | Select-Object -First 1
        [pscustomobject]@{
            AssignmentId = $row.id; Resource = $res.displayName; ResourceAppId = $res.appId; ResourceSpId = $row.resourceId
            RoleId = $row.appRoleId; Role = if ($role) { $role.value } else { "(unknown $($row.appRoleId))" }
        }
    }
}

function Grant-AmAppRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SpId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string]$RoleName,
        [string]$Target = 'agent identities',
        [switch]$SkipBlockCheck
    )
    Assert-AmPermissionAllowed -Name $RoleName -Type Application -Target $Target -SkipBlockCheck:$SkipBlockCheck
    $res = Get-AmResourceSp -ResourceAppId $ResourceAppId
    $role = @($res.appRoles | Where-Object { $_.value -ieq $RoleName -and $_.isEnabled -and ($_.allowedMemberTypes -contains 'Application') })
    if ($role.Count -ne 1) { throw "Application permission '$RoleName' was not found on $($res.displayName)." }
    $dupe = @(Get-AmAppRoleAssignments -SpId $SpId) | Where-Object { $_.RoleId -eq $role[0].id -and $_.ResourceSpId -eq $res.id }
    if ($dupe) { Write-Host "Already assigned: $RoleName" -ForegroundColor Yellow; return $dupe }
    Invoke-AmGraph -Method POST -Path "/servicePrincipals/$SpId/appRoleAssignments" -Body @{ principalId = $SpId; resourceId = $res.id; appRoleId = $role[0].id }
}

function Revoke-AmAppRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SpId, [Parameter(Mandatory)][string]$AssignmentId)
    $null = Invoke-AmGraph -Method DELETE -Path "/servicePrincipals/$SpId/appRoleAssignments/$AssignmentId"
}

# ---- Blueprint-level orchestration --------------------------------------

function Grant-AmBlueprintDelegated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string[]]$Scopes,
        [bool]$Inherit = $true,
        [switch]$SkipBlockCheck
    )
    $bp = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)?`$select=id,appId,displayName"
    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $bp.appId
    if (-not $principal) { throw "Blueprint '$($bp.displayName)' has no blueprint principal in this tenant." }
    $res = Get-AmResourceSp -ResourceAppId $ResourceAppId

    foreach ($scope in $Scopes) {
        Assert-AmPermissionAllowed -Name $scope -Type Delegated -Target 'agent identities (blueprint permissions flow to them)' -SkipBlockCheck:$SkipBlockCheck
        $def = $res.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled } | Select-Object -First 1
        if (-not $def) { throw "Scope '$scope' does not exist on $($res.displayName)." }
        Add-AmBlueprintRequiredAccess -BlueprintId $BlueprintId -ResourceAppId $ResourceAppId -PermissionId $def.id -Type Scope
    }

    $consent = 'granted'
    $url = $null
    try {
        $null = Grant-AmDelegated -ClientSpId $principal.id -ResourceAppId $ResourceAppId -Scopes $Scopes -Target 'agent identities (blueprint permissions flow to them)' -SkipBlockCheck:$SkipBlockCheck
    } catch [AmGraphException] {
        if ($_.Exception.Status -ne 403) { throw }
        $consent = 'needs-admin'
        $url = New-AmAdminConsentUrl -ClientAppId $bp.appId -ResourceAppId $ResourceAppId -Scopes $Scopes
    }

    if ($Inherit) {
        $current = @(Get-AmInheritablePermissions -BlueprintId $BlueprintId) | Where-Object { $_.resourceAppId -eq $ResourceAppId } | Select-Object -First 1
        $roles = if ($current -and $current.inheritableRoles -and $current.inheritableRoles.kind -eq 'allAllowed') { 'allAllowed' } else { 'none' }
        $null = Set-AmInheritablePermission -BlueprintId $BlueprintId -ResourceAppId $ResourceAppId -Scopes allAllowed -Roles $roles
    }
    return [pscustomobject]@{ Blueprint = $bp.displayName; Resource = $res.displayName; Scopes = $Scopes; Consent = $consent; AdminConsentUrl = $url; Inherited = $Inherit }
}

function Revoke-AmBlueprintDelegated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [Parameter(Mandatory)][string]$ResourceAppId,
        [Parameter(Mandatory)][string[]]$Scopes
    )
    $bp = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)?`$select=id,appId,displayName"
    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $bp.appId
    if ($principal) { Revoke-AmDelegated -ClientSpId $principal.id -ResourceAppId $ResourceAppId -Scopes $Scopes }
    $res = Get-AmResourceSp -ResourceAppId $ResourceAppId
    foreach ($scope in $Scopes) {
        $def = $res.oauth2PermissionScopes | Where-Object { $_.value -eq $scope } | Select-Object -First 1
        if ($def) { Remove-AmBlueprintRequiredAccess -BlueprintId $BlueprintId -ResourceAppId $ResourceAppId -PermissionId $def.id }
    }
}

# ---- Effective permissions ----------------------------------------------

function Get-AmEffectivePermissions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IdentityId)
    $agent = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Identity $IdentityId)?`$select=id,appId,displayName,agentIdentityBlueprintId"
    $rows = New-Object System.Collections.ArrayList

    foreach ($g in @(Get-AmDelegatedGrants -SpId $agent.id)) {
        foreach ($s in $g.Scopes) { [void]$rows.Add([pscustomobject]@{ Resource = $g.Resource; Permission = $s; Type = 'Delegated'; Source = 'Direct on agent' }) }
    }
    foreach ($a in @(Get-AmAppRoleAssignments -SpId $agent.id)) {
        [void]$rows.Add([pscustomobject]@{ Resource = $a.Resource; Permission = $a.Role; Type = 'Application'; Source = 'Direct on agent' })
    }

    $bp = @(Get-AmBlueprints) | Where-Object { $_.appId -eq $agent.agentIdentityBlueprintId } | Select-Object -First 1
    if ($bp) {
        $principal = Get-AmBlueprintPrincipal -BlueprintAppId $bp.appId
        $inherit = @(Get-AmInheritablePermissions -BlueprintId $bp.id)
        if ($principal) {
            foreach ($g in @(Get-AmDelegatedGrants -SpId $principal.id)) {
                $rule = $inherit | Where-Object { $_.resourceAppId -eq $g.ResourceAppId } | Select-Object -First 1
                if ($rule -and $rule.inheritableScopes.kind -eq 'allAllowed') {
                    foreach ($s in $g.Scopes) { [void]$rows.Add([pscustomobject]@{ Resource = $g.Resource; Permission = $s; Type = 'Delegated'; Source = "Inherited from blueprint '$($bp.displayName)'" }) }
                }
            }
            foreach ($a in @(Get-AmAppRoleAssignments -SpId $principal.id)) {
                $rule = $inherit | Where-Object { $_.resourceAppId -eq $a.ResourceAppId } | Select-Object -First 1
                if ($rule -and $rule.inheritableRoles.kind -eq 'allAllowed') {
                    [void]$rows.Add([pscustomobject]@{ Resource = $a.Resource; Permission = $a.Role; Type = 'Application'; Source = "Inherited from blueprint '$($bp.displayName)'" })
                }
            }
        }
    }
    return @($rows)
}
