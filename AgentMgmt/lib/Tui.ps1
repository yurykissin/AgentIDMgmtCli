# Console UI. Everything here only calls the functions in the other lib files.

function Write-AmLine {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Get-AmAccountLabel {
    $a = $script:State.Account
    if (-not $a) { return 'not signed in' }
    $id = if ($a.Upn) { $a.Upn } else { $a.Oid }
    if ($a.Name -and $id) { return "$($a.Name) <$id>" }
    if ($id) { return [string]$id }
    return [string]$a.Name
}

function Write-AmHeader {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host " Agent ID Admin Toolkit - $Title" -ForegroundColor Cyan
    $who = Get-AmAccountLabel
    $tenant = if ($script:State.TenantId) { $script:State.TenantId } else { '-' }
    $mode = if ($script:State.DryRun) { '  [DRY-RUN: changes are only printed]' } else { '' }
    Write-Host " $who | tenant $tenant$mode" -ForegroundColor $(if ($script:State.DryRun) { 'Yellow' } else { 'DarkGray' })
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Read-AmLine {
    param([string]$Prompt, [string]$Default)
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $v = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Wait-AmKey { [void](Read-Host 'Press Enter to continue') }

function Confirm-AmYesNo {
    param([string]$Message, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host "$Message ($hint)"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim().ToLower().StartsWith('y')
}

# Destructive actions require typing the object's name so a stray Enter cannot delete anything.
function Confirm-AmTyped {
    param([string]$Expected, [string]$What)
    Write-AmLine "This will permanently affect: $What" 'Yellow'
    $v = Read-Host "Type the name '$Expected' to confirm (anything else cancels)"
    return ($v -ceq $Expected)
}

function Read-AmPick {
    param([string]$Title, [object[]]$Items, [scriptblock]$Label, [switch]$AllowBack)
    $Items = @($Items)
    if ($Items.Count -eq 0) { Write-AmLine '  (nothing to choose from)' 'Yellow'; return $null }
    Write-AmLine $Title 'White'
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $text = & $Label $Items[$i]
        Write-Host ('  {0,2}) {1}' -f ($i + 1), $text)
    }
    while ($true) {
        $v = Read-Host '  Number (blank to cancel)'
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        $n = 0
        if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        Write-AmLine '  Not a valid number.' 'Yellow'
    }
}

function Read-AmMulti {
    param([string]$Title, [object[]]$Items, [scriptblock]$Label)
    $Items = @($Items)
    if ($Items.Count -eq 0) { Write-AmLine '  (nothing to choose from)' 'Yellow'; return @() }
    Write-AmLine $Title 'White'
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), (& $Label $Items[$i])) }
    $v = Read-Host '  Numbers separated by commas (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($v)) { return @() }
    $out = @()
    foreach ($part in $v.Split(',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { $out += $Items[$n - 1] }
    }
    return @($out)
}

function Invoke-AmUi {
    param([scriptblock]$Action, [switch]$NoPause)
    try { & $Action }
    catch {
        Write-AmLine ''
        Write-AmLine "Error: $($_.Exception.Message)" 'Red'
    }
    if (-not $NoPause) { Wait-AmKey }
}

# ---- Views ---------------------------------------------------------------

function Format-AmBlock {
    param([string]$Status)
    switch ($Status) { 'Blocked' { return '[BLOCKED for agents]' } 'Unclear' { return '[unclear]' } default { return '' } }
}

function Show-AmEffective {
    param([string]$IdentityId)
    $rows = @(Get-AmEffectivePermissions -IdentityId $IdentityId)
    if ($rows.Count -eq 0) { Write-AmLine '  No permissions (direct or inherited).' 'Yellow'; return }
    foreach ($group in ($rows | Group-Object Source)) {
        Write-AmLine "  $($group.Name)" 'Cyan'
        foreach ($r in ($group.Group | Sort-Object Resource, Permission)) {
            Write-Host ("    {0,-12} {1}  ({2})" -f $r.Type, $r.Permission, $r.Resource)
        }
    }
}

function Show-AmTree {
    [CmdletBinding()]
    param([switch]$Detailed)
    $bps = @(Get-AmBlueprints)
    $principals = @(Get-AmBlueprintPrincipals)
    $identities = @(Get-AmIdentities)
    $regs = Get-AmRegistrations
    if ($null -eq $regs) { Write-AmLine "Agent Registry: unknown ($($script:State.RegistryError))" 'Yellow' }
    if ($bps.Count -eq 0) { Write-AmLine 'No blueprints in this tenant.' 'Yellow' }
    foreach ($bp in $bps) {
        $principal = $principals | Where-Object { $_.appId -eq $bp.appId } | Select-Object -First 1
        $kids = @($identities | Where-Object { $_.agentIdentityBlueprintId -eq $bp.appId })
        $pText = if ($principal) { 'principal OK' } else { 'NO PRINCIPAL (blueprint unusable until created)' }
        Write-AmLine "BLUEPRINT  $($bp.displayName)  appId=$($bp.appId)  [$pText]" 'Green'
        if ($Detailed) {
            try {
                foreach ($inh in @(Get-AmInheritablePermissions -BlueprintId $bp.id)) {
                    Write-AmLine ("   inheritable: {0}  scopes={1} roles={2}" -f $inh.resourceAppId, $inh.inheritableScopes.kind, $inh.inheritableRoles.kind) 'DarkGray'
                }
                if ($principal) {
                    foreach ($g in @(Get-AmDelegatedGrants -SpId $principal.id)) { Write-AmLine ("   consented (delegated): {0} -> {1}" -f $g.Resource, ($g.Scopes -join ', ')) 'DarkGray' }
                }
            } catch { Write-AmLine "   (could not read blueprint permissions: $($_.Exception.Message -replace "`n.*", ''))" 'DarkYellow' }
        }
        if ($kids.Count -eq 0) { Write-AmLine '   (no agent identities)' 'DarkGray' }
        foreach ($k in $kids) {
            $state = if ($k.accountEnabled -eq $false) { 'disabled' } else { 'enabled' }
            $reg = if ($null -eq $regs) { 'registry: unknown' } else {
                $hit = $regs | Where-Object { $_.agentIdentityId -eq $k.id -or $_.sourceAgentId -eq $k.id } | Select-Object -First 1
                if ($hit) { "registered: $($hit.displayName)" } else { 'not registered' }
            }
            Write-AmLine "   AGENT  $($k.displayName)  id=$($k.id)  [$state; $reg]" 'White'
            if ($Detailed) {
                try { Show-AmEffective -IdentityId $k.id } catch { Write-AmLine "     (could not read permissions: $($_.Exception.Message -replace "`n.*", ''))" 'DarkYellow' }
            }
        }
    }
    $orphans = @($identities | Where-Object { $bps.appId -notcontains $_.agentIdentityBlueprintId })
    foreach ($o in $orphans) { Write-AmLine "ORPHAN AGENT  $($o.displayName)  id=$($o.id)  (blueprint not visible)" 'Yellow' }
}

# ---- Pickers -------------------------------------------------------------

function Select-AmBlueprintUi {
    $items = @(Get-AmBlueprints)
    Read-AmPick 'Blueprints:' $items { param($b) "$($b.displayName)   appId=$($b.appId)" }
}

function Select-AmIdentityUi {
    param([string]$BlueprintAppId)
    $items = @(Get-AmIdentities -BlueprintAppId $BlueprintAppId)
    Read-AmPick 'Agent identities:' $items { param($a) "$($a.displayName)   id=$($a.id)" }
}

function Select-AmPermissionsUi {
    param([Parameter(Mandatory)][string]$ResourceAppId, [Parameter(Mandatory)][ValidateSet('Application', 'Delegated')][string]$Type, [switch]$Single)
    $search = Read-AmLine 'Search permission name (e.g. User.Read)'
    $rows = @(Find-AmPermission -ResourceAppId $ResourceAppId -Type $Type -Search $search)
    if ($rows.Count -gt 40) { Write-AmLine "  $($rows.Count) matches; showing the first 40. Refine the search to narrow." 'Yellow'; $rows = @($rows | Select-Object -First 40) }
    $label = { param($p) ('{0,-45} {1,-20} {2}' -f $p.Name, (Format-AmBlock $p.Block), $p.Description) }
    if ($Single) { $x = Read-AmPick 'Matches:' $rows $label; if ($x) { return @($x) } else { return @() } }
    return @(Read-AmMulti 'Matches:' $rows $label)
}

function Select-AmResourceUi {
    $v = Read-AmLine 'Resource API (name or appId; blank = Microsoft Graph)'
    return Resolve-AmResource -Value $v
}

function Confirm-AmRisk {
    param([object[]]$Perms, [string]$Type)
    foreach ($p in $Perms) {
        $note = Get-AmRiskNote -Name $p.Name -Type $Type
        if ($note) { Write-AmLine "  $($p.Name): $note" 'Yellow' }
        if ($p.Block -eq 'Blocked') { Write-AmLine "  $($p.Name) is blocked for agent identities and will be refused." 'Red' }
    }
    return (Confirm-AmYesNo 'Continue?' $true)
}

# ---- Permission screens --------------------------------------------------

function Show-AmBlueprintPermissions {
    param($Bp)
    Write-AmLine "Declared (requiredResourceAccess):" 'Cyan'
    foreach ($e in @(Get-AmBlueprintRequiredAccess -BlueprintId $Bp.id)) {
        $res = Get-AmResourceSp -ResourceAppId $e.resourceAppId
        $names = @($e.resourceAccess | ForEach-Object {
                $id = $_.id
                $n = if ($_.type -eq 'Scope') { ($res.oauth2PermissionScopes | Where-Object { $_.id -eq $id }).value } else { ($res.appRoles | Where-Object { $_.id -eq $id }).value }
                "$n($($_.type))"
            })
        Write-Host "  $($res.displayName): $($names -join ', ')"
    }
    Write-AmLine 'Inheritable by agent identities:' 'Cyan'
    foreach ($i in @(Get-AmInheritablePermissions -BlueprintId $Bp.id)) { Write-Host ("  {0}: scopes={1} roles={2}" -f $i.resourceAppId, $i.inheritableScopes.kind, $i.inheritableRoles.kind) }
    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $Bp.appId
    if ($principal) {
        Write-AmLine 'Consented on the blueprint principal:' 'Cyan'
        foreach ($g in @(Get-AmDelegatedGrants -SpId $principal.id)) { Write-Host "  delegated  $($g.Resource): $($g.Scopes -join ', ')" }
        foreach ($a in @(Get-AmAppRoleAssignments -SpId $principal.id)) { Write-Host "  app role   $($a.Resource): $($a.Role)" }
    } else { Write-AmLine '  Blueprint principal missing.' 'Yellow' }
}

function Invoke-AmBlueprintPermissionMenu {
    param($Bp)
    while ($true) {
        Write-AmHeader "Permissions on blueprint '$($Bp.displayName)'"
        Write-Host ' 1) Show permissions'
        Write-Host ' 2) Grant delegated permission (flows to all agents when inheritable)'
        Write-Host ' 3) Revoke delegated permission'
        Write-Host ' 4) Inheritance settings for a resource'
        Write-Host ' 5) Remove inheritance for a resource'
        Write-Host ' 0) Back'
        switch (Read-Host 'Choose') {
            '1' { Invoke-AmUi { Show-AmBlueprintPermissions -Bp $Bp } }
            '2' {
                Invoke-AmUi {
                    $res = Select-AmResourceUi
                    $perms = @(Select-AmPermissionsUi -ResourceAppId $res.appId -Type Delegated)
                    if ($perms.Count -eq 0) { return }
                    if (-not (Confirm-AmRisk $perms 'Delegated')) { return }
                    $inherit = Confirm-AmYesNo 'Let agent identities inherit these scopes?' $true
                    $r = Grant-AmBlueprintDelegated -BlueprintId $Bp.id -ResourceAppId $res.appId -Scopes @($perms.Name) -Inherit $inherit
                    if ($r) {
                        if ($r.Consent -eq 'granted') { Write-AmLine 'Done: consent granted on the blueprint principal.' 'Green' }
                        else {
                            Write-AmLine 'The signed-in user could not grant consent. Send this URL to a Global Administrator:' 'Yellow'
                            Write-AmLine "  $($r.AdminConsentUrl)" 'White'
                        }
                    }
                }
            }
            '3' {
                Invoke-AmUi {
                    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $Bp.appId
                    if (-not $principal) { throw 'Blueprint principal missing.' }
                    $g = Read-AmPick 'Delegated grants:' @(Get-AmDelegatedGrants -SpId $principal.id) { param($x) "$($x.Resource): $($x.Scopes -join ', ')" }
                    if (-not $g) { return }
                    $scopes = @(Read-AmMulti 'Scopes to revoke:' $g.Scopes { param($s) $s })
                    if ($scopes.Count -eq 0) { return }
                    Revoke-AmBlueprintDelegated -BlueprintId $Bp.id -ResourceAppId $g.ResourceAppId -Scopes $scopes
                    Write-AmLine 'Revoked.' 'Green'
                }
            }
            '4' {
                Invoke-AmUi {
                    $res = Select-AmResourceUi
                    $s = Read-AmLine 'Inherit delegated scopes? (allAllowed/none)' 'allAllowed'
                    $r = Read-AmLine 'Inherit application roles? (allAllowed/none)' 'none'
                    Set-AmInheritablePermission -BlueprintId $Bp.id -ResourceAppId $res.appId -Scopes $s -Roles $r | Out-Null
                    Write-AmLine 'Saved.' 'Green'
                }
            }
            '5' {
                Invoke-AmUi {
                    $res = Select-AmResourceUi
                    Remove-AmInheritablePermission -BlueprintId $Bp.id -ResourceAppId $res.appId
                    Write-AmLine 'Removed.' 'Green'
                }
            }
            '0' { return }
            default { }
        }
    }
}

function Invoke-AmIdentityPermissionMenu {
    param($Agent)
    while ($true) {
        Write-AmHeader "Permissions on agent '$($Agent.displayName)'"
        Write-Host ' 1) Show effective permissions (inherited + direct)'
        Write-Host ' 2) Grant direct application permission (this agent only)'
        Write-Host ' 3) Grant direct delegated permission (this agent only)'
        Write-Host ' 4) Revoke direct application permission'
        Write-Host ' 5) Revoke direct delegated permission'
        Write-Host ' 0) Back'
        switch (Read-Host 'Choose') {
            '1' { Invoke-AmUi { Show-AmEffective -IdentityId $Agent.id } }
            '2' {
                Invoke-AmUi {
                    $res = Select-AmResourceUi
                    $perm = @(Select-AmPermissionsUi -ResourceAppId $res.appId -Type Application -Single)
                    if ($perm.Count -eq 0) { return }
                    if (-not (Confirm-AmRisk $perm 'Application')) { return }
                    $null = Grant-AmAppRole -SpId $Agent.id -ResourceAppId $res.appId -RoleName $perm[0].Name
                    Write-AmLine "Granted $($perm[0].Name) directly to $($Agent.displayName)." 'Green'
                }
            }
            '3' {
                Invoke-AmUi {
                    $res = Select-AmResourceUi
                    $perms = @(Select-AmPermissionsUi -ResourceAppId $res.appId -Type Delegated)
                    if ($perms.Count -eq 0) { return }
                    if (-not (Confirm-AmRisk $perms 'Delegated')) { return }
                    $null = Grant-AmDelegated -ClientSpId $Agent.id -ResourceAppId $res.appId -Scopes @($perms.Name)
                    Write-AmLine 'Granted.' 'Green'
                }
            }
            '4' {
                Invoke-AmUi {
                    $a = Read-AmPick 'Direct application permissions:' @(Get-AmAppRoleAssignments -SpId $Agent.id) { param($x) "$($x.Resource): $($x.Role)" }
                    if ($a) { Revoke-AmAppRole -SpId $Agent.id -AssignmentId $a.AssignmentId; Write-AmLine 'Revoked.' 'Green' }
                }
            }
            '5' {
                Invoke-AmUi {
                    $g = Read-AmPick 'Direct delegated grants:' @(Get-AmDelegatedGrants -SpId $Agent.id) { param($x) "$($x.Resource): $($x.Scopes -join ', ')" }
                    if (-not $g) { return }
                    $scopes = @(Read-AmMulti 'Scopes to revoke:' $g.Scopes { param($s) $s })
                    if ($scopes.Count -gt 0) { Revoke-AmDelegated -ClientSpId $Agent.id -ResourceAppId $g.ResourceAppId -Scopes $scopes; Write-AmLine 'Revoked.' 'Green' }
                }
            }
            '0' { return }
            default { }
        }
    }
}

# ---- Object screens ------------------------------------------------------

function Invoke-AmPeopleMenu {
    param([ValidateSet('Blueprint', 'Identity')][string]$Kind, $Obj)
    while ($true) {
        Write-AmHeader "Sponsors / owners of '$($Obj.displayName)'"
        foreach ($rel in 'sponsors', 'owners') {
            if ($Kind -eq 'Identity' -and $rel -eq 'owners') { continue }
            Write-AmLine $rel 'Cyan'
            try { foreach ($u in @(Get-AmRelation -Kind $Kind -Id $Obj.id -Relation $rel)) { Write-Host "  $($u.displayName) <$($u.userPrincipalName)>  $($u.id)" } }
            catch { Write-AmLine "  (cannot read: $($_.Exception.Message -replace "`n.*", ''))" 'Yellow' }
        }
        Write-Host ' 1) Add sponsor   2) Remove sponsor'
        if ($Kind -eq 'Blueprint') { Write-Host ' 3) Add owner     4) Remove owner' }
        Write-Host ' 0) Back'
        $c = Read-Host 'Choose'
        $rel = if ($c -in '1', '2') { 'sponsors' } elseif ($Kind -eq 'Blueprint' -and $c -in '3', '4') { 'owners' } else { $null }
        if ($c -eq '0') { return }
        if (-not $rel) { continue }
        Invoke-AmUi {
            $q = Read-AmLine 'User (UPN, name prefix, or object id)'
            $user = Find-AmUser -Search $q
            if ($c -in '1', '3') { Add-AmRelation -Kind $Kind -Id $Obj.id -UserId $user.id -Relation $rel }
            else { Remove-AmRelation -Kind $Kind -Id $Obj.id -UserId $user.id -Relation $rel }
            Write-AmLine 'Done.' 'Green'
        }
    }
}

function Invoke-AmCredentialMenu {
    param($Bp)
    while ($true) {
        Write-AmHeader "Credentials of blueprint '$($Bp.displayName)'"
        try {
            foreach ($c in @(Get-AmBlueprintCredentials -BlueprintId $Bp.id)) {
                $color = if ($c.Expired) { 'Red' } elseif ($c.DaysLeft -lt 30) { 'Yellow' } else { 'Gray' }
                Write-AmLine ("  {0,-11} {1,-20} expires {2:yyyy-MM-dd} ({3} days)  keyId={4}" -f $c.Kind, $c.Name, $c.Expires, $c.DaysLeft, $c.KeyId) $color
            }
            foreach ($f in @(Get-AmFederatedCredentials -BlueprintId $Bp.id)) { Write-Host "  Federated   $($f.name)  issuer=$($f.issuer)  subject=$($f.subject)  id=$($f.id)" }
        } catch { Write-AmLine "  (cannot read: $($_.Exception.Message -replace "`n.*", ''))" 'Yellow' }
        Write-Host ' 1) New client secret   2) Remove secret   3) Add federated credential   4) Remove federated credential   0) Back'
        switch (Read-Host 'Choose') {
            '1' {
                Invoke-AmUi {
                    $name = Read-AmLine 'Secret name' 'agentmgmt'
                    $days = [int](Read-AmLine 'Valid for days (max 730)' '90')
                    $r = Add-AmBlueprintSecret -BlueprintId $Bp.id -Name $name -Days $days
                    if ($r) {
                        Write-AmLine 'Copy the secret now. It cannot be shown again:' 'Yellow'
                        Write-AmLine "  $($r.secretText)" 'White'
                    }
                }
            }
            '2' {
                Invoke-AmUi {
                    $c = Read-AmPick 'Secrets:' @(Get-AmBlueprintCredentials -BlueprintId $Bp.id | Where-Object Kind -eq 'Secret') { param($x) "$($x.Name) expires $($x.Expires.ToString('yyyy-MM-dd')) keyId=$($x.KeyId)" }
                    if ($c -and (Confirm-AmYesNo "Remove secret '$($c.Name)'?")) { Remove-AmBlueprintSecret -BlueprintId $Bp.id -KeyId $c.KeyId; Write-AmLine 'Removed.' 'Green' }
                }
            }
            '3' {
                Invoke-AmUi {
                    $name = Read-AmLine 'Credential name'
                    $issuer = Read-AmLine 'Issuer URL'
                    $subject = Read-AmLine 'Subject'
                    $null = Add-AmFederatedCredential -BlueprintId $Bp.id -Name $name -Issuer $issuer -Subject $subject
                    Write-AmLine 'Added.' 'Green'
                }
            }
            '4' {
                Invoke-AmUi {
                    $f = Read-AmPick 'Federated credentials:' @(Get-AmFederatedCredentials -BlueprintId $Bp.id) { param($x) "$($x.name)  $($x.subject)" }
                    if ($f -and (Confirm-AmYesNo "Remove '$($f.name)'?")) { Remove-AmFederatedCredential -BlueprintId $Bp.id -CredentialId $f.id; Write-AmLine 'Removed.' 'Green' }
                }
            }
            '0' { return }
            default { }
        }
    }
}

function Invoke-AmBlueprintMenu {
    param($Bp)
    while ($true) {
        Write-AmHeader "Blueprint '$($Bp.displayName)'"
        Write-Host "  appId=$($Bp.appId)  objectId=$($Bp.id)" -ForegroundColor DarkGray
        Write-Host ' 1) Permissions   2) Credentials   3) Sponsors / owners'
        Write-Host ' 4) Create agent identity under this blueprint'
        Write-Host ' 5) Rename   6) Delete (with its agent identities)   0) Back'
        switch (Read-Host 'Choose') {
            '1' { Invoke-AmBlueprintPermissionMenu -Bp $Bp }
            '2' { Invoke-AmCredentialMenu -Bp $Bp }
            '3' { Invoke-AmPeopleMenu -Kind Blueprint -Obj $Bp }
            '4' {
                Invoke-AmUi {
                    $name = Read-AmLine 'Agent identity name'
                    $r = New-AmIdentity -BlueprintAppId $Bp.appId -Name $name
                    if ($r) { Write-AmLine "Created $($r.displayName) id=$($r.id)" 'Green' }
                }
            }
            '5' {
                Invoke-AmUi {
                    $name = Read-AmLine 'New name' $Bp.displayName
                    $null = Rename-AmBlueprint -Id $Bp.id -Name $name
                    $Bp.displayName = $name
                    Write-AmLine 'Renamed.' 'Green'
                }
            }
            '6' {
                Invoke-AmUi {
                    $kids = @(Get-AmIdentities -BlueprintAppId $Bp.appId)
                    Write-AmLine "Agent identities that will be deleted too: $($kids.Count)" 'Yellow'
                    foreach ($k in $kids) { Write-Host "   - $($k.displayName)" }
                    if (Confirm-AmTyped $Bp.displayName "blueprint and $($kids.Count) agent identit$(if ($kids.Count -eq 1) {'y'} else {'ies'})") {
                        Remove-AmBlueprint -Id $Bp.id -WithChildren
                        Write-AmLine 'Delete requested. Cascade deletion can take a little while to appear.' 'Green'
                    } else { Write-AmLine 'Cancelled.' 'Yellow' }
                }
                return
            }
            '0' { return }
            default { }
        }
    }
}

function Invoke-AmIdentityMenu {
    param($Agent)
    while ($true) {
        Write-AmHeader "Agent identity '$($Agent.displayName)'"
        Write-Host "  id=$($Agent.id)  appId=$($Agent.appId)" -ForegroundColor DarkGray
        Write-Host ' 1) Permissions   2) Sponsors   3) Rename   4) Enable / disable'
        Write-Host ' 5) Register in Agent Registry   6) Delete   0) Back'
        switch (Read-Host 'Choose') {
            '1' { Invoke-AmIdentityPermissionMenu -Agent $Agent }
            '2' { Invoke-AmPeopleMenu -Kind Identity -Obj $Agent }
            '3' {
                Invoke-AmUi {
                    $name = Read-AmLine 'New name' $Agent.displayName
                    $null = Rename-AmIdentity -Id $Agent.id -Name $name
                    $Agent.displayName = $name
                    Write-AmLine 'Renamed.' 'Green'
                }
            }
            '4' {
                Invoke-AmUi {
                    $now = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Identity $Agent.id)?`$select=accountEnabled"
                    $target = -not [bool]$now.accountEnabled
                    if (Confirm-AmYesNo "Currently $(if ($now.accountEnabled) {'enabled'} else {'disabled'}). Set to $(if ($target) {'enabled'} else {'disabled'})?" $true) {
                        $null = Set-AmIdentityEnabled -Id $Agent.id -Enabled $target
                        Write-AmLine 'Updated.' 'Green'
                    }
                }
            }
            '5' {
                Invoke-AmUi {
                    $name = Read-AmLine 'Registry display name' "$($Agent.displayName) Agent"
                    $r = Register-AmAgent -IdentityId $Agent.id -Name $name
                    if ($r) { Write-AmLine "Registered: $($r.id)" 'Green' }
                }
            }
            '6' {
                Invoke-AmUi {
                    if (Confirm-AmTyped $Agent.displayName 'this agent identity') { Remove-AmIdentity -Id $Agent.id; Write-AmLine 'Deleted.' 'Green' } else { Write-AmLine 'Cancelled.' 'Yellow' }
                }
                return
            }
            '0' { return }
            default { }
        }
    }
}

function Invoke-AmRegistryMenu {
    while ($true) {
        Write-AmHeader 'Agent Registry (beta)'
        $regs = Get-AmRegistrations
        if ($null -eq $regs) { Write-AmLine "Cannot read the registry: $($script:State.RegistryError)" 'Yellow' }
        else { foreach ($r in $regs) { Write-Host "  $($r.displayName)  id=$($r.id)  agent=$($r.agentIdentityId)" } }
        Write-Host ' 1) Register an existing agent identity   2) Rename registration   3) Delete registration   0) Back'
        switch (Read-Host 'Choose') {
            '1' {
                Invoke-AmUi {
                    $a = Select-AmIdentityUi
                    if ($a) {
                        $name = Read-AmLine 'Registry display name' "$($a.displayName) Agent"
                        $r = Register-AmAgent -IdentityId $a.id -Name $name
                        if ($r) { Write-AmLine "Registered: $($r.id)" 'Green' }
                    }
                }
            }
            '2' {
                Invoke-AmUi {
                    $r = Read-AmPick 'Registrations:' @(Get-AmRegistrations) { param($x) "$($x.displayName)  $($x.id)" }
                    if ($r) { $null = Update-AmRegistration -Id $r.id -Name (Read-AmLine 'New name' $r.displayName); Write-AmLine 'Updated.' 'Green' }
                }
            }
            '3' {
                Invoke-AmUi {
                    $r = Read-AmPick 'Registrations:' @(Get-AmRegistrations) { param($x) "$($x.displayName)  $($x.id)" }
                    if ($r -and (Confirm-AmTyped $r.displayName 'this registration (the agent identity itself is kept)')) { Remove-AmRegistration -Id $r.id; Write-AmLine 'Deleted.' 'Green' }
                }
            }
            '0' { return }
            default { }
        }
    }
}

function Invoke-AmSettingsMenu {
    while ($true) {
        Write-AmHeader 'Settings'
        Write-Host (" Toolkit app: {0}" -f $(if ($script:State.ClientId) { $script:State.ClientId } else { '(not set up)' }))
        Write-Host (" Remember sign-in: {0}   Dry-run: {1}" -f $script:State.Remember, $script:State.DryRun)
        Write-Host ' 1) Set up toolkit app (first run)   2) Sign in   3) Sign out'
        Write-Host ' 4) Toggle dry-run   5) Toggle remember sign-in   6) Show Graph call log'
        Write-Host ' 7) Run diagnostics (read-only)   8) Delete toolkit app   0) Back'
        switch (Read-Host 'Choose') {
            '1' { Invoke-AmUi { [void](Initialize-AmToolkitApp -Force:(Confirm-AmYesNo 'Re-create even if already configured?')) } }
            '2' { Invoke-AmUi { [void](Connect-AmSession); Write-AmLine "Signed in as $(Get-AmAccountLabel)" 'Green' } }
            '3' { Invoke-AmUi { Disconnect-AmSession; Write-AmLine 'Signed out.' 'Green' } }
            '4' { $script:State.DryRun = -not $script:State.DryRun }
            '5' { $script:State.Remember = -not $script:State.Remember; Save-AmConfig }
            '6' { Invoke-AmUi { Get-AmCallLog | ForEach-Object { Write-Host $_ } } }
            '7' { Invoke-AmUi { Invoke-AmDiagnose | ForEach-Object { Write-AmLine ('{0,-5} {1,-45} {2}' -f $_.Result, $_.Check, $_.Detail) $(if ($_.Result -eq 'PASS') { 'Green' } else { 'Red' }) } } }
            '8' { Invoke-AmUi { if (Confirm-AmTyped 'DELETE' 'the toolkit app registration (blueprints are not touched)') { Remove-AmToolkitApp } } }
            '0' { return }
            default { }
        }
    }
}

function Invoke-AmCreateMenu {
    Write-AmHeader 'Create'
    Write-Host ' 1) New blueprint (+ principal)   2) New agent identity   0) Back'
    switch (Read-Host 'Choose') {
        '1' {
            Invoke-AmUi {
                $name = Read-AmLine 'Blueprint name'
                $r = New-AmBlueprint -Name $name
                if ($r) { Write-AmLine "Created blueprint $($r.Blueprint.displayName) appId=$($r.Blueprint.appId); principal created." 'Green' }
            }
        }
        '2' {
            Invoke-AmUi {
                $bp = Select-AmBlueprintUi
                if (-not $bp) { return }
                $name = Read-AmLine 'Agent identity name'
                $r = New-AmIdentity -BlueprintAppId $bp.appId -Name $name
                if ($r) { Write-AmLine "Created $($r.displayName) id=$($r.id)" 'Green' }
            }
        }
        default { }
    }
}

function Start-AmTui {
    [CmdletBinding()]
    param()
    while ($true) {
        Write-AmHeader 'Main menu'
        Write-Host ' 1) Browse tree   2) Browse tree with permissions'
        Write-Host ' 3) Manage a blueprint        (permissions, credentials, rename, DELETE)'
        Write-Host ' 4) Manage an agent identity  (permissions, rename, enable/disable, DELETE)'
        Write-Host ' 5) Create blueprint / agent identity   6) Agent Registry'
        Write-Host ' 7) Settings / diagnostics   0) Quit'
        switch (Read-Host 'Choose') {
            '1' { Invoke-AmUi { Show-AmTree } }
            '2' { Invoke-AmUi { Show-AmTree -Detailed } }
            '3' { Invoke-AmUi -NoPause { $bp = Select-AmBlueprintUi; if ($bp) { Invoke-AmBlueprintMenu -Bp $bp } } }
            '4' { Invoke-AmUi -NoPause { $a = Select-AmIdentityUi; if ($a) { Invoke-AmIdentityMenu -Agent $a } } }
            '5' { Invoke-AmCreateMenu }
            '6' { Invoke-AmRegistryMenu }
            '7' { Invoke-AmSettingsMenu }
            '0' { return }
            default { }
        }
    }
}
