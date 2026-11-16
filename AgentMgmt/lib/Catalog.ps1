function Get-AmBlockedList {
    if (-not $script:State.Cache.ContainsKey('blocked')) {
        $path = Join-Path $script:ModuleRoot 'data/blocked-permissions.json'
        $raw = Get-Content $path -Raw | ConvertFrom-Json
        $map = @{}
        foreach ($row in $raw.permissions) {
            $map[$row[0]] = [pscustomobject]@{ Name = $row[0]; Delegated = $row[1]; Application = $row[2] }
        }
        $script:State.Cache['blocked'] = [pscustomobject]@{ Source = $raw.source; Fetched = $raw.fetched; Map = $map }
    }
    return $script:State.Cache['blocked']
}

# Returns Status: Blocked | Unclear | Allowed
#   Blocked = official list marks this permission type as blocked
#   Unclear = permission is on the list but the page shows "-" for this type
function Test-AmPermissionBlocked {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Application', 'Delegated')][string]$Type
    )
    $list = Get-AmBlockedList
    $entry = $null
    foreach ($key in $list.Map.Keys) { if ($key -ieq $Name) { $entry = $list.Map[$key]; break } }
    if (-not $entry) { return [pscustomobject]@{ Status = 'Allowed'; Name = $Name; Type = $Type } }
    $flag = if ($Type -eq 'Application') { $entry.Application } else { $entry.Delegated }
    $status = if ($flag -eq 'B') { 'Blocked' } else { 'Unclear' }
    return [pscustomobject]@{ Status = $status; Name = $entry.Name; Type = $Type }
}

function Get-AmRiskNote {
    param([string]$Name, [ValidateSet('Application', 'Delegated')][string]$Type)
    $notes = @()
    if ($Name -match '\.All$') { $notes += 'tenant-wide scope (applies to every object, not a single one)' }
    if ($Name -match '(ReadWrite|Write|Update|Delete|Manage|Create|FullControl)') { $notes += 'write-capable' }
    if ($Type -eq 'Application') { $notes += 'app-only: no user context' }
    return ($notes -join '; ')
}

function Get-AmResourceSp {
    param([string]$ResourceAppId = $script:GraphAppId)
    $key = "res:$ResourceAppId"
    if (-not $script:State.Cache.ContainsKey($key)) {
        $sp = Invoke-AmGraph -Method GET -Path "/servicePrincipals(appId='$ResourceAppId')?`$select=id,appId,displayName,appRoles,oauth2PermissionScopes"
        $script:State.Cache[$key] = $sp
    }
    return $script:State.Cache[$key]
}

function Find-AmPermission {
    [CmdletBinding()]
    param(
        [string]$ResourceAppId = $script:GraphAppId,
        [Parameter(Mandatory)][ValidateSet('Application', 'Delegated')][string]$Type,
        [string]$Search
    )
    $sp = Get-AmResourceSp -ResourceAppId $ResourceAppId
    $rows = if ($Type -eq 'Application') {
        @($sp.appRoles | Where-Object { $_.isEnabled -and ($_.allowedMemberTypes -contains 'Application') } | ForEach-Object {
                [pscustomobject]@{ Id = $_.id; Name = $_.value; Description = $_.displayName; Type = 'Application' }
            })
    } else {
        @($sp.oauth2PermissionScopes | Where-Object { $_.isEnabled } | ForEach-Object {
                [pscustomobject]@{ Id = $_.id; Name = $_.value; Description = $_.adminConsentDisplayName; Type = 'Delegated' }
            })
    }
    if ($Search) { $rows = @($rows | Where-Object { $_.Name -like "*$Search*" -or $_.Description -like "*$Search*" }) }
    $rows = @($rows | Sort-Object Name)
    foreach ($row in $rows) {
        $check = Test-AmPermissionBlocked -Name $row.Name -Type $Type
        $row | Add-Member -NotePropertyName Block -NotePropertyValue $check.Status -Force
    }
    return $rows
}

function Resolve-AmResource {
    # Accepts an appId GUID or a display-name fragment; defaults to Microsoft Graph.
    param([string]$Value)
    if (-not $Value) { return Get-AmResourceSp -ResourceAppId $script:GraphAppId }
    if (Test-AmGuid $Value) { return Get-AmResourceSp -ResourceAppId $Value }
    $hits = @(Invoke-AmGraph -Method GET -All -Path "/servicePrincipals?`$filter=startswith(displayName,'$($Value.Replace("'", "''"))')&`$select=id,appId,displayName&`$top=20")
    if ($hits.Count -eq 0) { throw "No service principal found for '$Value'." }
    if ($hits.Count -gt 1) { throw "Ambiguous resource '$Value': $(($hits | ForEach-Object { $_.displayName }) -join ', '). Use its appId." }
    return Get-AmResourceSp -ResourceAppId $hits[0].appId
}
