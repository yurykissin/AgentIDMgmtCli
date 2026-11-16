# Agent Registry (beta): /beta/copilot/agentRegistrations. Preview API, shapes may change.

$script:AgentXAppId = '59eca866-2f46-40b8-96ff-63f663121ef9'

function Get-AmRegistrations {
    # Returns $null (not an exception) when the registry cannot be read, so the tree can show "unknown".
    try {
        return @(Invoke-AmGraph -Method GET -Beta -All -Path '/copilot/agentRegistrations')
    } catch [AmGraphException] {
        $script:State.RegistryError = $_.Exception.Message
        return $null
    }
}

function Resolve-AmRegistration {
    param([Parameter(Mandatory)][string]$Selector)
    $regs = Get-AmRegistrations
    if ($null -eq $regs) { throw "Cannot read the Agent Registry: $($script:State.RegistryError)" }
    Select-AmMatch -Items $regs -Selector $Selector -Label 'registration'
}

function New-AmRegistrationBody {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$OwnerId,
        [Parameter(Mandatory)][string]$BlueprintObjectId,
        [Parameter(Mandatory)][string]$IdentityObjectId,
        [string]$Description
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $body = @{
        id                         = [guid]::NewGuid().ToString()
        displayName                = $Name
        ownerIds                   = @($OwnerId)
        createdBy                  = $OwnerId
        sourceCreatedDateTime      = $now
        sourceLastModifiedDateTime = $now
        agentIdentityBlueprintId   = $BlueprintObjectId
        agentIdentityId            = $IdentityObjectId
        sourceAgentId              = $IdentityObjectId
        managedByAppId             = $script:AgentXAppId
    }
    if ($Description) { $body.description = $Description }
    return $body
}

function Register-AmAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IdentityId,
        [string]$Name,
        [string]$Description
    )
    $idn = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Identity $IdentityId)?`$select=id,appId,displayName,agentIdentityBlueprintId"
    $bp = @(Get-AmBlueprints) | Where-Object { $_.appId -eq $idn.agentIdentityBlueprintId } | Select-Object -First 1
    if (-not $bp) { throw "Could not find the blueprint of '$($idn.displayName)'." }
    $displayName = if ($Name) { $Name } else { "$($idn.displayName) Agent" }
    $body = New-AmRegistrationBody -Name $displayName -OwnerId (Get-AmCurrentUser).id -BlueprintObjectId $bp.id -IdentityObjectId $idn.id -Description $Description
    Invoke-AmGraph -Method POST -Beta -Path '/copilot/agentRegistrations' -Body $body
}

function Update-AmRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$Name, [string]$Description)
    $body = @{ sourceLastModifiedDateTime = (Get-Date).ToUniversalTime().ToString('o') }
    if ($Name) { $body.displayName = $Name }
    if ($Description) { $body.description = $Description }
    Invoke-AmGraph -Method PATCH -Beta -Path "/copilot/agentRegistrations/$Id" -Body $body
}

function Remove-AmRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $null = Invoke-AmGraph -Method DELETE -Beta -Path "/copilot/agentRegistrations/$Id"
}
