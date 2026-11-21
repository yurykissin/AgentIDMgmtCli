# Non-interactive mode: agentmgmt.ps1 -Command <name> --option value

function ConvertTo-AmOptions {
    param([object[]]$Tokens)
    $opts = @{}
    $list = @($Tokens | Where-Object { $null -ne $_ })
    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = [string]$list[$i]
        if ($t -match '^--?([A-Za-z][\w-]*)$') {
            $key = $Matches[1].ToLower()
            if ($i + 1 -lt $list.Count -and ([string]$list[$i + 1]) -notmatch '^--?[A-Za-z]') { $opts[$key] = [string]$list[$i + 1]; $i++ }
            else { $opts[$key] = $true }
        } else { throw "Unexpected argument '$t'. Options look like --name value." }
    }
    return $opts
}

function Get-AmCommandHelp {
@'
Commands (all accept --dry-run via the -DryRun switch of agentmgmt.ps1):
  tree [--detailed]                         blueprint > agents (> permissions)
  diagnose                                  read-only checks of auth, routes and scopes
  setup [--force]                           create the toolkit app registration (first run)
  login | logout
  bp-list | agent-list [--blueprint X]
  bp-new --name N
  bp-rename --blueprint X --name N
  bp-delete --blueprint X [--with-children] --yes
  agent-new --blueprint X --name N
  agent-rename --agent X --name N
  agent-delete --agent X --yes
  agent-enable --agent X | agent-disable --agent X
  perms --agent X                           effective permissions (inherited + direct)
  bp-perms --blueprint X                    permissions declared/consented/inheritable
  bp-grant --blueprint X --permission P[,P2] [--type delegated|application] [--resource R] [--no-inherit]
  agent-grant --agent X --permission P [--type application|delegated] [--resource R]
  secret-new --blueprint X [--name N] [--days 90]
  register --agent X [--name N]
  app-export --app X [--output DIRECTORY] [--force]  read-only migration inventory to local JSON
  blocked [--search S]                      show the blocked-for-agents list
'@
}

function Get-AmOpt {
    param([hashtable]$Options, [string]$Name, [switch]$Required)
    if ($Options.ContainsKey($Name) -and $Options[$Name] -ne $true) { return [string]$Options[$Name] }
    if ($Required) { throw "Missing --$Name." }
    return $null
}

function Invoke-AmCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Options = @{})

    $resolveBp = { Resolve-AmBlueprint -Selector (Get-AmOpt $Options 'blueprint' -Required) }
    $resolveAgent = { Resolve-AmIdentity -Selector (Get-AmOpt $Options 'agent' -Required) }
    $needYes = { if (-not $Options.ContainsKey('yes') -and -not $script:State.DryRun) { throw 'This is destructive. Re-run with --yes to confirm.' } }
    $resource = { Resolve-AmResource -Value (Get-AmOpt $Options 'resource') }

    switch ($Name.ToLower()) {
        'help' { Get-AmCommandHelp }
        'tree' { Show-AmTree -Detailed:($Options.ContainsKey('detailed')) }
        'diagnose' { Invoke-AmDiagnose }
        'setup' { [void](Initialize-AmToolkitApp -Force:($Options.ContainsKey('force'))) }
        'login' { [void](Connect-AmSession); "Signed in as $(Get-AmAccountLabel)" }
        'logout' { Disconnect-AmSession }
        'bp-list' { Get-AmBlueprints | Select-Object displayName, appId, id }
        'agent-list' {
            $bpSel = Get-AmOpt $Options 'blueprint'
            $appId = if ($bpSel) { (& $resolveBp).appId } else { $null }
            Get-AmIdentities -BlueprintAppId $appId | Select-Object displayName, id, appId, accountEnabled, agentIdentityBlueprintId
        }
        'bp-new' { New-AmBlueprint -Name (Get-AmOpt $Options 'name' -Required) }
        'bp-rename' { $bp = & $resolveBp; Rename-AmBlueprint -Id $bp.id -Name (Get-AmOpt $Options 'name' -Required) }
        'bp-delete' { & $needYes; $bp = & $resolveBp; Remove-AmBlueprint -Id $bp.id -WithChildren:($Options.ContainsKey('with-children')) }
        'agent-new' { $bp = & $resolveBp; New-AmIdentity -BlueprintAppId $bp.appId -Name (Get-AmOpt $Options 'name' -Required) }
        'agent-rename' { $a = & $resolveAgent; Rename-AmIdentity -Id $a.id -Name (Get-AmOpt $Options 'name' -Required) }
        'agent-delete' { & $needYes; $a = & $resolveAgent; Remove-AmIdentity -Id $a.id }
        'agent-enable' { $a = & $resolveAgent; Set-AmIdentityEnabled -Id $a.id -Enabled $true }
        'agent-disable' { $a = & $resolveAgent; Set-AmIdentityEnabled -Id $a.id -Enabled $false }
        'perms' { $a = & $resolveAgent; Get-AmEffectivePermissions -IdentityId $a.id }
        'bp-perms' { $bp = & $resolveBp; Show-AmBlueprintPermissions -Bp $bp }
        'bp-grant' {
            $bp = & $resolveBp
            $res = & $resource
            $perms = @((Get-AmOpt $Options 'permission' -Required).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $type = Get-AmOpt $Options 'type'
            $inherit = -not $Options.ContainsKey('no-inherit')
            if ($type -ieq 'application') { Grant-AmBlueprintAppRole -BlueprintId $bp.id -ResourceAppId $res.appId -Roles $perms -Inherit:$inherit }
            else { Grant-AmBlueprintDelegated -BlueprintId $bp.id -ResourceAppId $res.appId -Scopes $perms -Inherit:$inherit }
        }
        'agent-grant' {
            $a = & $resolveAgent
            $res = & $resource
            $perm = Get-AmOpt $Options 'permission' -Required
            $type = Get-AmOpt $Options 'type'
            if (-not $type) { $type = 'application' }
            if ($type -ieq 'delegated') { Grant-AmDelegated -ClientSpId $a.id -ResourceAppId $res.appId -Scopes @($perm.Split(',') | ForEach-Object { $_.Trim() }) }
            else { Grant-AmAppRole -SpId $a.id -ResourceAppId $res.appId -RoleName $perm }
        }
        'secret-new' {
            $bp = & $resolveBp
            $days = 90
            $d = Get-AmOpt $Options 'days'
            if ($d) { $days = [int]$d }
            $n = Get-AmOpt $Options 'name'
            if (-not $n) { $n = 'agentmgmt' }
            Add-AmBlueprintSecret -BlueprintId $bp.id -Name $n -Days $days
        }
        'register' {
            $a = & $resolveAgent
            Register-AmAgent -IdentityId $a.id -Name (Get-AmOpt $Options 'name')
        }
        'app-export' {
            $candidate = Resolve-AmMigrationCandidate -Selector (Get-AmOpt $Options 'app' -Required)
            $exportOptions = @{ Candidate = $candidate; Force = $Options.ContainsKey('force') }
            $outputDirectory = Get-AmOpt $Options 'output'
            if ($outputDirectory) { $exportOptions.OutputDirectory = $outputDirectory }
            $result = Export-AmMigrationInventory @exportOptions
            "Saved migration inventory: $($result.Path)"
            foreach ($warning in $result.Warnings) { Write-Warning $warning }
        }
        'blocked' {
            $list = Get-AmBlockedList
            $s = Get-AmOpt $Options 'search'
            $list.Map.Values | Where-Object { -not $s -or $_.Name -like "*$s*" } | Sort-Object Name
        }
        default { throw "Unknown command '$Name'. Run with -Command help." }
    }
}
