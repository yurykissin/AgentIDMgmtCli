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

$script:AmWidth = 72

# Screen header: product name, where you are (breadcrumb), who you are, which tenant.
function Write-AmHeader {
    param([string]$Title)
    $w = $script:AmWidth
    Write-Host ''
    Write-Host ('=' * $w) -ForegroundColor DarkCyan
    Write-Host '  AGENT ID ADMIN TOOLKIT' -ForegroundColor Cyan -NoNewline
    if ($script:State.DryRun) { Write-Host '   [DRY-RUN: changes are only printed]' -ForegroundColor Yellow } else { Write-Host '' }
    Write-Host "  $Title" -ForegroundColor White
    Write-Host ('-' * $w) -ForegroundColor DarkCyan
    $signedIn = [bool]$script:State.Account
    $tenant = if ($script:State.TenantId) { $script:State.TenantId } else { '-' }
    Write-Host ('  {0,-10} ' -f 'Signed in') -ForegroundColor DarkGray -NoNewline
    Write-Host (Get-AmAccountLabel) -ForegroundColor $(if ($signedIn) { 'Green' } else { 'Yellow' })
    Write-Host ('  {0,-10} ' -f 'Tenant') -ForegroundColor DarkGray -NoNewline
    Write-Host $tenant -ForegroundColor Gray
    Write-Host ('=' * $w) -ForegroundColor DarkCyan
}

# A heading inside a screen:  "-- Title ------------"
function Write-AmSection {
    param([string]$Title, [string]$Color = 'Cyan')
    $pad = [Math]::Max(3, $script:AmWidth - $Title.Length - 6)
    Write-Host ''
    Write-Host ("  -- $Title " + ('-' * $pad)) -ForegroundColor $Color
}

# "  Label        value" with the label dimmed so values line up.
function Write-AmKv {
    param([string]$Label, [string]$Value, [string]$Color = 'Gray', [int]$Width = 12, [string]$Indent = '  ')
    Write-Host ("$Indent{0,-$Width} " -f $Label) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function New-AmMenuItem {
    param([string]$Key, [string]$Text, [string]$Hint = '', [switch]$Danger)
    [pscustomobject]@{ Key = $Key; Text = $Text; Hint = $Hint; Danger = [bool]$Danger }
}

# Grouped menu: each section is @{ Title = '...'; Items = @(New-AmMenuItem ...) }; 0 is always the exit row.
function Write-AmMenu {
    param([object[]]$Sections, [string]$ExitText = 'Back')
    foreach ($s in $Sections) {
        Write-Host ''
        if ($s.Title) { Write-Host ("  {0}" -f $s.Title.ToUpper()) -ForegroundColor Cyan }
        foreach ($i in $s.Items) {
            Write-Host ('   {0,2}  ' -f $i.Key) -ForegroundColor Yellow -NoNewline
            Write-Host $i.Text -ForegroundColor $(if ($i.Danger) { 'Red' } else { 'White' }) -NoNewline:([bool]$i.Hint)
            if ($i.Hint) { Write-Host (' ' * [Math]::Max(1, 35 - $i.Text.Length)) -NoNewline; Write-Host $i.Hint -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
    Write-Host ('   {0,2}  ' -f '0') -ForegroundColor Yellow -NoNewline
    Write-Host $ExitText -ForegroundColor DarkGray
    Write-Host ('-' * $script:AmWidth) -ForegroundColor DarkCyan
}

function Read-AmChoice { return (Read-Host '  Select') }

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
    Write-AmSection $Title 'White'
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('   {0,2}  ' -f ($i + 1)) -ForegroundColor Yellow -NoNewline
        Write-Host (& $Label $Items[$i])
    }
    Write-Host ''
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
    Write-AmSection $Title 'White'
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('   {0,2}  ' -f ($i + 1)) -ForegroundColor Yellow -NoNewline
        Write-Host (& $Label $Items[$i])
    }
    Write-Host ''
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

function Get-AmResourceName {
    param([string]$ResourceAppId)
    try { $r = Get-AmResourceSp -ResourceAppId $ResourceAppId; if ($r.displayName) { return [string]$r.displayName } } catch { }
    return $ResourceAppId
}

function Show-AmEffective {
    param([string]$IdentityId, [string]$Indent = '  ')
    $rows = @(Get-AmEffectivePermissions -IdentityId $IdentityId)
    if ($rows.Count -eq 0) { Write-AmLine "$Indent(no permissions, direct or inherited)" 'DarkGray'; return }
    foreach ($group in ($rows | Group-Object Source)) {
        Write-AmLine "$Indent$($group.Name)" 'Cyan'
        foreach ($r in ($group.Group | Sort-Object Resource, Type, Permission)) {
            $color = if ($r.Type -eq 'Application') { 'Magenta' } else { 'Gray' }
            Write-AmLine ("$Indent  {0,-12} {1,-34} {2}" -f $r.Type, $r.Permission, $r.Resource) $color
        }
    }
}

# Tree legend: [B] blueprint, [A] agent identity. -Detailed adds the permissions under each node.
function Show-AmTree {
    [CmdletBinding()]
    param([switch]$Detailed)
    $bps = @(Get-AmBlueprints)
    $principals = @(Get-AmBlueprintPrincipals)
    $identities = @(Get-AmIdentities)
    $regs = Get-AmRegistrations
    if ($null -eq $regs) { Write-AmLine "  Agent Registry: unknown ($($script:State.RegistryError))" 'DarkYellow' }
    Write-AmLine '  [B] blueprint   [A] agent identity' 'DarkGray'
    if ($bps.Count -eq 0) { Write-AmLine '  No blueprints in this tenant.' 'Yellow' }
    foreach ($bp in $bps) {
        $principal = $principals | Where-Object { $_.appId -eq $bp.appId } | Select-Object -First 1
        $kids = @($identities | Where-Object { $_.agentIdentityBlueprintId -eq $bp.appId })
        Write-Host ''
        Write-Host '  [B] ' -ForegroundColor Green -NoNewline
        Write-Host $bp.displayName -ForegroundColor Green -NoNewline
        if ($principal) { Write-Host '   principal OK' -ForegroundColor DarkGray } else { Write-Host '   NO PRINCIPAL (unusable until created)' -ForegroundColor Red }
        Write-Host "      appId $($bp.appId)" -ForegroundColor DarkGray
        if ($Detailed) {
            try {
                foreach ($inh in @(Get-AmInheritablePermissions -BlueprintId $bp.id)) {
                    Write-AmLine ("      inheritable  {0}: scopes={1}, roles={2}" -f (Get-AmResourceName $inh.resourceAppId), $inh.inheritableScopes.kind, $inh.inheritableRoles.kind) 'DarkGray'
                }
                if ($principal) {
                    foreach ($g in @(Get-AmDelegatedGrants -SpId $principal.id)) { Write-AmLine ("      consented    {0}: {1} (delegated)" -f $g.Resource, ($g.Scopes -join ', ')) 'DarkGray' }
                    foreach ($a in @(Get-AmAppRoleAssignments -SpId $principal.id)) { Write-AmLine ("      consented    {0}: {1} (application)" -f $a.Resource, $a.Role) 'DarkGray' }
                }
            } catch { Write-AmLine "      (could not read blueprint permissions: $($_.Exception.Message -replace "`n.*", ''))" 'DarkYellow' }
        }
        if ($kids.Count -eq 0) { Write-AmLine '      (no agent identities)' 'DarkGray' }
        for ($n = 0; $n -lt $kids.Count; $n++) {
            $k = $kids[$n]
            $last = ($n -eq $kids.Count - 1)
            $branch = if ($last) { '\-- ' } else { '+-- ' }
            $rail = if ($last) { '    ' } else { '|   ' }
            $enabled = ($k.accountEnabled -ne $false)
            $reg = if ($null -eq $regs) { 'registry unknown' } else {
                $hit = $regs | Where-Object { $_.agentIdentityId -eq $k.id -or $_.sourceAgentId -eq $k.id } | Select-Object -First 1
                if ($hit) { "registered as '$($hit.displayName)'" } else { 'not registered' }
            }
            Write-Host "      $branch" -ForegroundColor DarkGray -NoNewline
            Write-Host '[A] ' -ForegroundColor White -NoNewline
            Write-Host $k.displayName -ForegroundColor White -NoNewline
            Write-Host '   ' -NoNewline
            Write-Host $(if ($enabled) { 'enabled' } else { 'DISABLED' }) -ForegroundColor $(if ($enabled) { 'DarkGray' } else { 'Yellow' }) -NoNewline
            Write-Host "; $reg" -ForegroundColor DarkGray
            Write-AmLine "      $rail    id $($k.id)" 'DarkGray'
            if ($Detailed) {
                try { Show-AmEffective -IdentityId $k.id -Indent "      $rail    " } catch { Write-AmLine "      $rail    (could not read permissions: $($_.Exception.Message -replace "`n.*", ''))" 'DarkYellow' }
            }
        }
    }
    $orphans = @($identities | Where-Object { $bps.appId -notcontains $_.agentIdentityBlueprintId })
    foreach ($o in $orphans) { Write-AmLine "  [A] ORPHAN  $($o.displayName)  id=$($o.id)  (blueprint not visible)" 'Yellow' }
    Write-Host ''
    Write-AmLine ("  {0} blueprint(s), {1} agent identit{2}" -f $bps.Count, $identities.Count, $(if ($identities.Count -eq 1) { 'y' } else { 'ies' })) 'DarkGray'
}

# ---- Pickers -------------------------------------------------------------

function Select-AmBlueprintUi {
    $items = @(Get-AmBlueprints)
    Read-AmPick 'Choose a blueprint' $items { param($b) ("{0}`n        appId {1}" -f $b.displayName, $b.appId) }
}

function Select-AmIdentityUi {
    param([string]$BlueprintAppId)
    $items = @(Get-AmIdentities -BlueprintAppId $BlueprintAppId)
    Read-AmPick 'Choose an agent identity' $items { param($a) ("{0}`n        id {1}" -f $a.displayName, $a.id) }
}

function Select-AmPermissionsUi {
    param([Parameter(Mandatory)][string]$ResourceAppId, [Parameter(Mandatory)][ValidateSet('Application', 'Delegated')][string]$Type, [switch]$Single)
    $search = Read-AmLine 'Search permission name (e.g. User.Read)'
    $rows = @(Find-AmPermission -ResourceAppId $ResourceAppId -Type $Type -Search $search)
    if ($rows.Count -gt 40) { Write-AmLine "  $($rows.Count) matches; showing the first 40. Refine the search to narrow." 'Yellow'; $rows = @($rows | Select-Object -First 40) }
    $label = {
        param($p)
        $tag = Format-AmBlock $p.Block
        $desc = [string]$p.Description
        if ($desc.Length -gt 62) { $desc = $desc.Substring(0, 59) + '...' }
        $head = if ($tag) { '{0}  {1}' -f $p.Name, $tag } else { [string]$p.Name }
        if ($desc) { "$head`n        $desc" } else { $head }
    }
    $title = "$Type permissions matching '$search'"
    if ($Single) { $x = Read-AmPick $title $rows $label; if ($x) { return @($x) } else { return @() } }
    return @(Read-AmMulti $title $rows $label)
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
    Write-AmSection 'Declared on the blueprint (requiredResourceAccess)'
    $declared = @(Get-AmBlueprintRequiredAccess -BlueprintId $Bp.id)
    if ($declared.Count -eq 0) { Write-AmLine '  (none)' 'DarkGray' }
    foreach ($e in $declared) {
        $res = Get-AmResourceSp -ResourceAppId $e.resourceAppId
        Write-AmLine "  $($res.displayName)" 'White'
        foreach ($ra in @($e.resourceAccess)) {
            $id = $ra.id
            $n = if ($ra.type -eq 'Scope') { ($res.oauth2PermissionScopes | Where-Object { $_.id -eq $id }).value } else { ($res.appRoles | Where-Object { $_.id -eq $id }).value }
            $type = if ($ra.type -eq 'Scope') { 'Delegated' } else { 'Application' }
            Write-AmLine ("    {0,-12} {1}" -f $type, $n) $(if ($type -eq 'Application') { 'Magenta' } else { 'Gray' })
        }
    }
    Write-AmSection 'Agents may inherit (inheritable permissions)'
    $inh = @(Get-AmInheritablePermissions -BlueprintId $Bp.id)
    if ($inh.Count -eq 0) { Write-AmLine '  (nothing is inheritable yet)' 'DarkGray' }
    else {
        Write-AmLine ('  {0,-28} {1,-18} {2}' -f 'Resource', 'Delegated scopes', 'Application roles') 'DarkGray'
        foreach ($i in $inh) { Write-AmLine ('  {0,-28} {1,-18} {2}' -f (Get-AmResourceName $i.resourceAppId), $i.inheritableScopes.kind, $i.inheritableRoles.kind) }
    }
    Write-AmSection 'Granted to the blueprint principal (consent / app roles)'
    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $Bp.appId
    if (-not $principal) { Write-AmLine '  Blueprint principal missing.' 'Yellow'; return }
    $grants = @(Get-AmDelegatedGrants -SpId $principal.id)
    $roles = @(Get-AmAppRoleAssignments -SpId $principal.id)
    if ($grants.Count + $roles.Count -eq 0) { Write-AmLine '  (nothing granted)' 'DarkGray' }
    foreach ($g in $grants) { Write-AmLine ('  {0,-12} {1}: {2}' -f 'Delegated', $g.Resource, ($g.Scopes -join ', ')) }
    foreach ($a in $roles) { Write-AmLine ('  {0,-12} {1}: {2}' -f 'Application', $a.Resource, $a.Role) 'Magenta' }
}

function Invoke-AmBlueprintPermissionMenu {
    param($Bp)
    while ($true) {
        Write-AmHeader "Blueprint '$($Bp.displayName)'  >  Permissions"
        Write-AmMenu -Sections @(
            @{ Title = 'View'; Items = @(
                    (New-AmMenuItem '1' 'Show permissions' 'declared, inheritable, granted')) },
            @{ Title = 'Grant and revoke'; Items = @(
                    (New-AmMenuItem '2' 'Add permission' 'delegated or application; agents inherit if enabled'),
                    (New-AmMenuItem '3' 'Remove permission' 'pick from what is granted')) },
            @{ Title = 'Inheritance by agent identities'; Items = @(
                    (New-AmMenuItem '4' 'Set inheritance for a resource' 'scopes / roles: allAllowed or none'),
                    (New-AmMenuItem '5' 'Remove inheritance for a resource' '')) }
        )
        switch (Read-AmChoice) {
            '1' { Invoke-AmUi { Show-AmBlueprintPermissions -Bp $Bp } }
            '2' {
                Invoke-AmUi {
                    $res = Select-AmResourceUi
                    $kind = Read-AmLine 'Permission type: (d)elegated = on behalf of a user, (a)pplication = app-only' 'd'
                    $isApp = $kind.Trim().ToLower().StartsWith('a')
                    $type = if ($isApp) { 'Application' } else { 'Delegated' }
                    $perms = @(Select-AmPermissionsUi -ResourceAppId $res.appId -Type $type)
                    if ($perms.Count -eq 0) { return }
                    if (-not (Confirm-AmRisk $perms $type)) { return }
                    $inherit = Confirm-AmYesNo 'Let agent identities inherit these permissions?' $true
                    if ($isApp) {
                        $null = Grant-AmBlueprintAppRole -BlueprintId $Bp.id -ResourceAppId $res.appId -Roles @($perms.Name) -Inherit $inherit
                        Write-AmLine "Done: $(@($perms.Name) -join ', ') granted to the blueprint principal." 'Green'
                    } else {
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
            }
            '3' {
                Invoke-AmUi {
                    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $Bp.appId
                    if (-not $principal) { throw 'Blueprint principal missing.' }
                    $items = @()
                    foreach ($g in @(Get-AmDelegatedGrants -SpId $principal.id)) {
                        foreach ($s in $g.Scopes) { $items += [pscustomobject]@{ Type = 'Delegated'; Resource = $g.Resource; ResourceAppId = $g.ResourceAppId; Name = $s } }
                    }
                    foreach ($a in @(Get-AmAppRoleAssignments -SpId $principal.id)) {
                        $items += [pscustomobject]@{ Type = 'Application'; Resource = $a.Resource; ResourceAppId = $a.ResourceAppId; Name = $a.Role }
                    }
                    $sel = @(Read-AmMulti 'Granted permissions:' $items { param($x) ('{0,-12} {1}: {2}' -f $x.Type, $x.Resource, $x.Name) })
                    if ($sel.Count -eq 0) { return }
                    if (-not (Confirm-AmYesNo "Remove $($sel.Count) permission(s)?")) { return }
                    foreach ($grp in ($sel | Group-Object Type, ResourceAppId)) {
                        $first = $grp.Group[0]
                        if ($first.Type -eq 'Delegated') { Revoke-AmBlueprintDelegated -BlueprintId $Bp.id -ResourceAppId $first.ResourceAppId -Scopes @($grp.Group.Name) }
                        else { Revoke-AmBlueprintAppRole -BlueprintId $Bp.id -ResourceAppId $first.ResourceAppId -Roles @($grp.Group.Name) }
                    }
                    Write-AmLine 'Removed.' 'Green'
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
        Write-AmHeader "Agent '$($Agent.displayName)'  >  Permissions"
        Write-AmMenu -Sections @(
            @{ Title = 'View'; Items = @(
                    (New-AmMenuItem '1' 'Show effective permissions' 'inherited from blueprint + direct')) },
            @{ Title = 'Grant directly (this agent only)'; Items = @(
                    (New-AmMenuItem '2' 'Grant application permission' 'app-only, one permission'),
                    (New-AmMenuItem '3' 'Grant delegated permission' 'on behalf of a user, one or more')) },
            @{ Title = 'Revoke direct grants'; Items = @(
                    (New-AmMenuItem '4' 'Revoke application permission' ''),
                    (New-AmMenuItem '5' 'Revoke delegated permission' '')) }
        )
        switch (Read-AmChoice) {
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
        Write-AmHeader "$(if ($Kind -eq 'Blueprint') { 'Blueprint' } else { 'Agent' }) '$($Obj.displayName)'  >  $(if ($Kind -eq 'Blueprint') { 'Sponsors and owners' } else { 'Sponsors' })"
        foreach ($rel in 'sponsors', 'owners') {
            if ($Kind -eq 'Identity' -and $rel -eq 'owners') { continue }
            Write-AmSection ($rel.Substring(0, 1).ToUpper() + $rel.Substring(1))
            try {
                $people = @(Get-AmRelation -Kind $Kind -Id $Obj.id -Relation $rel)
                if ($people.Count -eq 0) { Write-AmLine '  (none)' 'DarkGray' }
                foreach ($u in $people) { Write-AmLine ('  {0,-28} {1}' -f $u.displayName, $u.userPrincipalName) }
            }
            catch { Write-AmLine "  (cannot read: $($_.Exception.Message -replace "`n.*", ''))" 'Yellow' }
        }
        $items = @(
            @{ Title = 'Sponsors'; Items = @(
                    (New-AmMenuItem '1' 'Add sponsor' 'search by UPN or name'),
                    (New-AmMenuItem '2' 'Remove sponsor' 'pick from the list')) }
        )
        if ($Kind -eq 'Blueprint') {
            $items += @{ Title = 'Owners'; Items = @(
                    (New-AmMenuItem '3' 'Add owner' 'search by UPN or name'),
                    (New-AmMenuItem '4' 'Remove owner' 'pick from the list')) }
        }
        Write-AmMenu -Sections $items
        $c = Read-AmChoice
        $rel = if ($c -in '1', '2') { 'sponsors' } elseif ($Kind -eq 'Blueprint' -and $c -in '3', '4') { 'owners' } else { $null }
        if ($c -eq '0') { return }
        if (-not $rel) { continue }
        Invoke-AmUi {
            if ($c -in '1', '3') {
                $q = Read-AmLine 'User (UPN, name prefix, or object id)'
                $user = Find-AmUser -Search $q
                Add-AmRelation -Kind $Kind -Id $Obj.id -UserId $user.id -Relation $rel
            } else {
                $current = @(Get-AmRelation -Kind $Kind -Id $Obj.id -Relation $rel)
                $user = Read-AmPick "Remove which $($rel.TrimEnd('s'))?" $current { param($x) "$($x.displayName) <$($x.userPrincipalName)>" }
                if (-not $user) { return }
                Remove-AmRelation -Kind $Kind -Id $Obj.id -UserId $user.id -Relation $rel
            }
            Write-AmLine 'Done.' 'Green'
        }
    }
}

function Invoke-AmCredentialMenu {
    param($Bp)
    while ($true) {
        Write-AmHeader "Blueprint '$($Bp.displayName)'  >  Credentials"
        $creds = @()
        $fed = @()
        try { $creds = @(Get-AmBlueprintCredentials -BlueprintId $Bp.id) } catch { Write-AmLine "  (cannot read secrets/certificates: $($_.Exception.Message -replace "`n.*", ''))" 'Yellow' }
        try { $fed = @(Get-AmFederatedCredentials -BlueprintId $Bp.id) } catch { Write-AmLine "  (cannot read federated credentials: $($_.Exception.Message -replace "`n.*", ''))" 'Yellow' }
        Write-AmSection 'Secrets and certificates'
        if ($creds.Count -eq 0) { Write-AmLine '  (none)' 'DarkGray' }
        else { Write-AmLine ('  {0,-11} {1,-20} {2,-6} {3,-12} {4}' -f 'Kind', 'Name', 'Hint', 'Expires', 'Status') 'DarkGray' }
        foreach ($c in $creds) {
            $color = if ($c.Expired) { 'Red' } elseif ($c.DaysLeft -lt 30) { 'Yellow' } else { 'Gray' }
            $label = if ($c.Name) { $c.Name } else { '(unnamed)' }
            $state = if ($c.Expired) { 'EXPIRED' } else { "$($c.DaysLeft) days left" }
            Write-AmLine ("  {0,-11} {1,-20} {2,-6} {3,-12:yyyy-MM-dd} {4}" -f $c.Kind, $label, $c.Hint, $c.Expires, $state) $color
            Write-AmLine "              keyId $($c.KeyId)" 'DarkGray'
        }
        Write-AmSection 'Federated credentials'
        if ($fed.Count -eq 0) { Write-AmLine '  (none)' 'DarkGray' }
        foreach ($f in $fed) {
            Write-AmLine "  $($f.name)" 'White'
            Write-AmKv 'issuer' $f.issuer -Indent '    '
            Write-AmKv 'subject' $f.subject -Indent '    '
        }
        Write-AmMenu -Sections @(
            @{ Title = 'Client secrets'; Items = @(
                    (New-AmMenuItem '1' 'New client secret' 'shown once, copy it immediately'),
                    (New-AmMenuItem '2' 'Remove secret' '' -Danger)) },
            @{ Title = 'Federated credentials'; Items = @(
                    (New-AmMenuItem '3' 'Add federated credential' 'issuer + subject'),
                    (New-AmMenuItem '4' 'Remove federated credential' '' -Danger)) }
        )
        switch (Read-AmChoice) {
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
        Write-AmKv 'appId' $Bp.appId
        Write-AmKv 'objectId' $Bp.id
        Write-AmMenu -Sections @(
            @{ Title = 'Configure'; Items = @(
                    (New-AmMenuItem '1' 'Permissions' 'add / remove / inheritance'),
                    (New-AmMenuItem '2' 'Credentials' 'secrets and federated credentials'),
                    (New-AmMenuItem '3' 'Sponsors and owners' '')) },
            @{ Title = 'Agent identities'; Items = @(
                    (New-AmMenuItem '4' 'Create agent identity' 'under this blueprint')) },
            @{ Title = 'Manage'; Items = @(
                    (New-AmMenuItem '5' 'Rename' '')) },
            @{ Title = 'Danger zone'; Items = @(
                    (New-AmMenuItem '6' 'Delete blueprint' 'also deletes its agent identities' -Danger)) }
        )
        switch (Read-AmChoice) {
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
        Write-AmHeader "Agent '$($Agent.displayName)'"
        Write-AmKv 'id' $Agent.id
        Write-AmKv 'appId' $Agent.appId
        Write-AmMenu -Sections @(
            @{ Title = 'Configure'; Items = @(
                    (New-AmMenuItem '1' 'Permissions' 'effective, grant, revoke'),
                    (New-AmMenuItem '2' 'Sponsors' '')) },
            @{ Title = 'Manage'; Items = @(
                    (New-AmMenuItem '3' 'Rename' ''),
                    (New-AmMenuItem '4' 'Enable / disable' 'toggles sign-in for this agent'),
                    (New-AmMenuItem '5' 'Register in Agent Registry' 'beta')) },
            @{ Title = 'Danger zone'; Items = @(
                    (New-AmMenuItem '6' 'Delete agent identity' '' -Danger)) }
        )
        switch (Read-AmChoice) {
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
        Write-AmSection 'Registrations'
        if ($null -eq $regs) { Write-AmLine "  Cannot read the registry: $($script:State.RegistryError)" 'Yellow' }
        elseif (@($regs).Count -eq 0) { Write-AmLine '  (none)' 'DarkGray' }
        else {
            foreach ($r in $regs) {
                Write-AmLine "  $($r.displayName)" 'White'
                Write-AmKv 'id' $r.id -Indent '    '
                Write-AmKv 'agent' $r.agentIdentityId -Indent '    '
            }
        }
        Write-AmMenu -Sections @(
            @{ Title = 'Actions'; Items = @(
                    (New-AmMenuItem '1' 'Register an agent identity' 'pick an existing one'),
                    (New-AmMenuItem '2' 'Rename registration' ''),
                    (New-AmMenuItem '3' 'Delete registration' 'the agent identity is kept' -Danger)) }
        )
        switch (Read-AmChoice) {
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
        Write-AmSection 'Current state'
        Write-AmKv 'Toolkit app' $(if ($script:State.ClientId) { $script:State.ClientId } else { '(not set up)' }) $(if ($script:State.ClientId) { 'Gray' } else { 'Yellow' }) 18
        Write-AmKv 'Remember sign-in' $(if ($script:State.Remember) { 'on' } else { 'off' }) 'Gray' 18
        Write-AmKv 'Dry-run' $(if ($script:State.DryRun) { 'ON (changes are only printed)' } else { 'off' }) $(if ($script:State.DryRun) { 'Yellow' } else { 'Gray' }) 18
        Write-AmMenu -Sections @(
            @{ Title = 'Sign-in'; Items = @(
                    (New-AmMenuItem '1' 'Set up toolkit app' 'first run: creates the app registration'),
                    (New-AmMenuItem '2' 'Sign in' ''),
                    (New-AmMenuItem '3' 'Sign out' '')) },
            @{ Title = 'Options'; Items = @(
                    (New-AmMenuItem '4' 'Toggle dry-run' 'print writes instead of sending'),
                    (New-AmMenuItem '5' 'Toggle remember sign-in' 'keep a refresh token on this machine')) },
            @{ Title = 'Diagnostics'; Items = @(
                    (New-AmMenuItem '6' 'Show Graph call log' ''),
                    (New-AmMenuItem '7' 'Run diagnostics' 'read-only checks')) },
            @{ Title = 'Danger zone'; Items = @(
                    (New-AmMenuItem '8' 'Delete toolkit app' 'blueprints are not touched' -Danger)) }
        )
        switch (Read-AmChoice) {
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
    Write-AmMenu -Sections @(
        @{ Title = 'New'; Items = @(
                (New-AmMenuItem '1' 'Blueprint' 'also creates its principal'),
                (New-AmMenuItem '2' 'Agent identity' 'under an existing blueprint')) }
    )
    switch (Read-AmChoice) {
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
        Write-AmMenu -ExitText 'Quit' -Sections @(
            @{ Title = 'Overview'; Items = @(
                    (New-AmMenuItem '1' 'Browse tree' 'blueprints and their agent identities'),
                    (New-AmMenuItem '2' 'Browse tree with permissions' 'adds inherited / direct permissions')) },
            @{ Title = 'Manage'; Items = @(
                    (New-AmMenuItem '3' 'Blueprint' 'permissions, credentials, rename, delete'),
                    (New-AmMenuItem '4' 'Agent identity' 'permissions, rename, enable, delete')) },
            @{ Title = 'Create'; Items = @(
                    (New-AmMenuItem '5' 'New blueprint / agent identity' '')) },
            @{ Title = 'Tools'; Items = @(
                    (New-AmMenuItem '6' 'Agent Registry' 'beta'),
                    (New-AmMenuItem '7' 'Settings and diagnostics' 'sign-in, dry-run, call log')) }
        )
        switch (Read-AmChoice) {
            '1' { Invoke-AmUi { Write-AmHeader 'Browse tree'; Show-AmTree } }
            '2' { Invoke-AmUi { Write-AmHeader 'Browse tree with permissions'; Show-AmTree -Detailed } }
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
