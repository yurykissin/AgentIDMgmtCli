# Credentials live on the blueprint. Agent identities hold none.

function Get-AmBlueprintCredentials {
    param([Parameter(Mandatory)][string]$BlueprintId)
    $bp = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)?`$select=id,displayName,passwordCredentials,keyCredentials"
    $now = (Get-Date).ToUniversalTime()
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in @($bp.passwordCredentials)) {
        if (-not $p) { continue }
        $end = [datetime]::Parse($p.endDateTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        [void]$rows.Add([pscustomobject]@{ Kind = 'Secret'; KeyId = $p.keyId; Name = $p.displayName; Hint = $p.hint; Expires = $end; Expired = ($end -lt $now); DaysLeft = [int][math]::Floor(($end - $now).TotalDays) })
    }
    foreach ($k in @($bp.keyCredentials)) {
        if (-not $k) { continue }
        $end = [datetime]::Parse($k.endDateTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        [void]$rows.Add([pscustomobject]@{ Kind = 'Certificate'; KeyId = $k.keyId; Name = $k.displayName; Hint = ''; Expires = $end; Expired = ($end -lt $now); DaysLeft = [int][math]::Floor(($end - $now).TotalDays) })
    }
    return @($rows)
}

function Add-AmBlueprintSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [string]$Name = 'agentmgmt',
        [ValidateRange(1, 730)][int]$Days = 90
    )
    $body = @{ passwordCredential = @{ displayName = $Name; endDateTime = (Get-Date).ToUniversalTime().AddDays($Days).ToString('yyyy-MM-ddTHH:mm:ssZ') } }
    # The secret text is returned only by this call and can never be read again.
    Invoke-AmGraph -Method POST -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)/addPassword" -Body $body
}

function Remove-AmBlueprintSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BlueprintId, [Parameter(Mandatory)][string]$KeyId)
    $null = Invoke-AmGraph -Method POST -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)/removePassword" -Body @{ keyId = $KeyId }
}

function Get-AmFederatedCredentials {
    param([Parameter(Mandatory)][string]$BlueprintId)
    @(Invoke-AmGraph -Method GET -All -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)/federatedIdentityCredentials")
}

function Add-AmFederatedCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlueprintId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Issuer,
        [Parameter(Mandatory)][string]$Subject,
        [string[]]$Audiences = @('api://AzureADTokenExchange')
    )
    $body = @{ name = $Name; issuer = $Issuer; subject = $Subject; audiences = @($Audiences) }
    Invoke-AmGraph -Method POST -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)/federatedIdentityCredentials" -Body $body
}

function Remove-AmFederatedCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BlueprintId, [Parameter(Mandatory)][string]$CredentialId)
    $null = Invoke-AmGraph -Method DELETE -Path "$(Get-AmObjectRoute Blueprint $BlueprintId)/federatedIdentityCredentials/$CredentialId"
}
