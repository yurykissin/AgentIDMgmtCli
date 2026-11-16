# Read-only probes. Safe to run against any tenant; they never create, change or delete anything.

function Invoke-AmProbe {
    param([string]$Name, [scriptblock]$Test)
    try {
        $detail = & $Test
        [pscustomobject]@{ Check = $Name; Result = 'PASS'; Detail = [string]$detail }
    } catch {
        $msg = $_.Exception.Message -replace "`n.*", ''
        [pscustomobject]@{ Check = $Name; Result = 'FAIL'; Detail = $msg }
    }
}

function Invoke-AmDiagnose {
    [CmdletBinding()]
    param()
    $results = New-Object System.Collections.ArrayList

    [void]$results.Add((Invoke-AmProbe 'Signed in' {
                $token = Get-AmAccessToken
                $me = Get-AmCurrentUser
                "$($me.userPrincipalName) in tenant $($script:State.TenantId)"
            }))

    [void]$results.Add((Invoke-AmProbe 'Token carries the toolkit scopes' {
                $claims = ConvertFrom-AmJwt -Token (Get-AmAccessToken)
                $have = @("$($claims.scp)" -split ' ' | Where-Object { $_ })
                $missing = @($script:ToolkitScopes | Where-Object { $have -notcontains $_ })
                if ($missing.Count -gt 0) { throw "missing: $($missing -join ', '). Re-run Settings > Set up toolkit app (-Force) and sign in again." }
                "$($have.Count) scopes present"
            }))

    [void]$results.Add((Invoke-AmProbe 'Scope names exist in this tenant' {
                $graph = Get-AmResourceSp -ResourceAppId $script:GraphAppId
                $known = @($graph.oauth2PermissionScopes | ForEach-Object { $_.value })
                $unknown = @($script:ToolkitScopes | Where-Object { $known -notcontains $_ })
                if ($unknown.Count -gt 0) { throw "unknown to Graph in this tenant: $($unknown -join ', ')" }
                'all toolkit scopes are defined by Microsoft Graph'
            }))

    $bps = $null
    [void]$results.Add((Invoke-AmProbe 'List blueprints' { $script:probeBps = @(Get-AmBlueprints); "$(@($script:probeBps).Count) found" }))
    $bps = @($script:probeBps)

    [void]$results.Add((Invoke-AmProbe 'List blueprint principals' { "$(@(Get-AmBlueprintPrincipals).Count) found" }))
    [void]$results.Add((Invoke-AmProbe 'List agent identities' { "$(@(Get-AmIdentities).Count) found" }))

    if ($bps.Count -gt 0) {
        $bp = $bps[0]
        [void]$results.Add((Invoke-AmProbe "Inheritable permissions ($($bp.displayName))" { "$(@(Get-AmInheritablePermissions -BlueprintId $bp.id).Count) resource(s)" }))
        [void]$results.Add((Invoke-AmProbe "Sponsors ($($bp.displayName))" { "$(@(Get-AmRelation -Kind Blueprint -Id $bp.id -Relation sponsors).Count) sponsor(s)" }))
        [void]$results.Add((Invoke-AmProbe "Credentials ($($bp.displayName))" { "$(@(Get-AmBlueprintCredentials -BlueprintId $bp.id).Count) credential(s)" }))
    }

    [void]$results.Add((Invoke-AmProbe 'Agent Registry (beta)' {
                $regs = Get-AmRegistrations
                if ($null -eq $regs) { throw $script:State.RegistryError }
                "$($regs.Count) registration(s)"
            }))

    return @($results)
}
