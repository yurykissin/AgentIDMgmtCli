function Get-AmCurrentUser {
    if (-not $script:State.Cache.ContainsKey('me')) {
        $script:State.Cache['me'] = Invoke-AmGraph -Method GET -Path '/me?$select=id,displayName,userPrincipalName'
    }
    return $script:State.Cache['me']
}

function Get-AmObjectRoute {
    param([Parameter(Mandatory)][ValidateSet('Blueprint', 'Principal', 'Identity')][string]$Kind, [Parameter(Mandatory)][string]$Id)
    switch ($Kind) {
        'Blueprint' { return "/applications/$Id/microsoft.graph.agentIdentityBlueprint" }
        'Principal' { return "/servicePrincipals/$Id/microsoft.graph.agentIdentityBlueprintPrincipal" }
        'Identity' { return "/servicePrincipals/$Id/microsoft.graph.agentIdentity" }
    }
}

function Select-AmMatch {
    param([object[]]$Items, [string]$Selector, [string]$Label)
    $Items = @($Items)
    if (-not $Selector) { throw "$Label selector is required." }
    $exact = @($Items | Where-Object { $_.id -eq $Selector -or $_.appId -eq $Selector })
    if ($exact.Count -eq 1) { return $exact[0] }
    $named = @($Items | Where-Object { $_.displayName -eq $Selector })
    if ($named.Count -eq 0) { $named = @($Items | Where-Object { $_.displayName -like "*$Selector*" }) }
    if ($named.Count -eq 1) { return $named[0] }
    if ($named.Count -gt 1) { throw "$Label '$Selector' is ambiguous: $(($named | ForEach-Object { "$($_.displayName) [$($_.id)]" }) -join '; '). Use the object id." }
    throw "No $Label found matching '$Selector'."
}

# ---- Blueprints ---------------------------------------------------------

function Get-AmBlueprints {
    @(Invoke-AmGraph -Method GET -All -Path '/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,createdDateTime,signInAudience,requiredResourceAccess')
}

function Get-AmBlueprintPrincipals {
    @(Invoke-AmGraph -Method GET -All -Path '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal?$select=id,appId,displayName')
}

function Resolve-AmBlueprint {
    param([Parameter(Mandatory)][string]$Selector)
    Select-AmMatch -Items (Get-AmBlueprints) -Selector $Selector -Label 'blueprint'
}

function Get-AmBlueprintPrincipal {
    param([Parameter(Mandatory)][string]$BlueprintAppId)
    $hits = @(Invoke-AmGraph -Method GET -All -Path "/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal?`$filter=appId eq '$BlueprintAppId'&`$select=id,appId,displayName")
    if ($hits.Count -gt 0) { return $hits[0] }
    return $null
}

function Initialize-AmBlueprintPrincipal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BlueprintAppId)
    $appIdValue = $BlueprintAppId
    Invoke-AmWithPropagationRetry {
        $existing = Get-AmBlueprintPrincipal -BlueprintAppId $appIdValue
        if ($existing) { return $existing }
        Invoke-AmGraph -Method POST -Path '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' -Body @{ appId = $appIdValue }
    }
}

function New-AmBlueprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$SponsorIds,
        [string[]]$OwnerIds
    )
    $me = Get-AmCurrentUser
    if (-not $SponsorIds) { $SponsorIds = @($me.id) }
    if (-not $OwnerIds) { $OwnerIds = @($me.id) }
    $body = @{
        displayName           = $Name
        'sponsors@odata.bind' = @($SponsorIds | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
        'owners@odata.bind'   = @($OwnerIds | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
    }
    $bp = Invoke-AmGraph -Method POST -Path '/applications/microsoft.graph.agentIdentityBlueprint' -Body $body
    if (-not $bp) { return $null }
    # The principal is not created automatically; without it the blueprint cannot be used in the tenant.
    try { $principal = Initialize-AmBlueprintPrincipal -BlueprintAppId $bp.appId }
    catch {
        Write-Warning "Blueprint '$($bp.displayName)' already exists (appId=$($bp.appId), objectId=$($bp.id)), but its principal could not be provisioned. Do not create another blueprint. Use Manage blueprint > Repair missing principal, or -Command bp-principal --blueprint $($bp.appId), to retry."
        throw
    }
    return [pscustomobject]@{ Blueprint = $bp; Principal = $principal }
}

function Rename-AmBlueprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name)
    Invoke-AmGraph -Method PATCH -Path (Get-AmObjectRoute Blueprint $Id) -Body @{ displayName = $Name }
}

function Remove-AmBlueprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [switch]$WithChildren)
    $bp = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Blueprint $Id)?`$select=id,appId,displayName"
    $children = @(Get-AmIdentities -BlueprintAppId $bp.appId)
    if ($children.Count -gt 0 -and -not $WithChildren) {
        throw "Blueprint '$($bp.displayName)' still has $($children.Count) agent identit$(if ($children.Count -eq 1) { 'y' } else { 'ies' }). Delete them first or pass -WithChildren."
    }
    foreach ($child in $children) { Remove-AmIdentity -Id $child.id }
    $null = Invoke-AmGraph -Method DELETE -Path (Get-AmObjectRoute Blueprint $Id)
}

# ---- Sponsors / owners --------------------------------------------------

function Get-AmRelation {
    param(
        [Parameter(Mandatory)][ValidateSet('Blueprint', 'Identity')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('sponsors', 'owners')][string]$Relation = 'sponsors'
    )
    @(Invoke-AmGraph -Method GET -All -Path "$(Get-AmObjectRoute $Kind $Id)/$Relation`?`$select=id,displayName,userPrincipalName")
}

function Add-AmRelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Blueprint', 'Identity')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$UserId,
        [ValidateSet('sponsors', 'owners')][string]$Relation = 'sponsors'
    )
    $null = Invoke-AmGraph -Method POST -Path "$(Get-AmObjectRoute $Kind $Id)/$Relation/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$UserId" }
}

function Remove-AmRelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Blueprint', 'Identity')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$UserId,
        [ValidateSet('sponsors', 'owners')][string]$Relation = 'sponsors'
    )
    $null = Invoke-AmGraph -Method DELETE -Path "$(Get-AmObjectRoute $Kind $Id)/$Relation/$UserId/`$ref"
}

function Find-AmUser {
    param([Parameter(Mandatory)][string]$Search)
    if (Test-AmGuid $Search) { return Invoke-AmGraph -Method GET -Path "/users/$Search`?`$select=id,displayName,userPrincipalName" }
    $q = $Search.Replace("'", "''")
    $hits = @(Invoke-AmGraph -Method GET -All -Path "/users?`$filter=startswith(displayName,'$q') or startswith(userPrincipalName,'$q')&`$select=id,displayName,userPrincipalName&`$top=10")
    if ($hits.Count -eq 0) { throw "No user found for '$Search'." }
    if ($hits.Count -gt 1) { throw "Several users match '$Search': $(($hits | ForEach-Object { $_.userPrincipalName }) -join ', ')." }
    return $hits[0]
}
