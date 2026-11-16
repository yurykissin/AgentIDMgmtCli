function Get-AmIdentities {
    [CmdletBinding()]
    param([string]$BlueprintAppId)
    $all = @(Invoke-AmGraph -Method GET -All -Path '/servicePrincipals/microsoft.graph.agentIdentity?$select=id,appId,displayName,accountEnabled,agentIdentityBlueprintId,createdDateTime')
    if ($BlueprintAppId) { $all = @($all | Where-Object { $_.agentIdentityBlueprintId -eq $BlueprintAppId }) }
    return $all
}

function Resolve-AmIdentity {
    param([Parameter(Mandatory)][string]$Selector, [string]$BlueprintAppId)
    Select-AmMatch -Items (Get-AmIdentities -BlueprintAppId $BlueprintAppId) -Selector $Selector -Label 'agent identity'
}

function New-AmIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintAppId,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$SponsorIds
    )
    if (-not $SponsorIds) { $SponsorIds = @((Get-AmCurrentUser).id) }
    # Graph expects the blueprint's appId here, not its object id.
    $body = @{
        displayName              = $Name
        agentIdentityBlueprintId = $BlueprintAppId
        'sponsors@odata.bind'    = @($SponsorIds | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
    }
    Invoke-AmGraph -Method POST -Path '/servicePrincipals/microsoft.graph.agentIdentity' -Body $body
}

function Rename-AmIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name)
    Invoke-AmGraph -Method PATCH -Path (Get-AmObjectRoute Identity $Id) -Body @{ displayName = $Name }
}

function Set-AmIdentityEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][bool]$Enabled)
    Invoke-AmGraph -Method PATCH -Path (Get-AmObjectRoute Identity $Id) -Body @{ accountEnabled = $Enabled }
}

function Remove-AmIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $null = Invoke-AmGraph -Method DELETE -Path (Get-AmObjectRoute Identity $Id)
}
