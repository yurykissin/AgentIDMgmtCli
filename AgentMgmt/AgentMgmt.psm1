# Version 1 only flags uninitialised variables; Graph responses omit optional properties, so stricter modes would throw.
Set-StrictMode -Version 1

$script:ModuleRoot = $PSScriptRoot

foreach ($file in 'State', 'Graph', 'Auth', 'Catalog', 'Blueprints', 'Identities', 'Permissions', 'Credentials', 'Registry', 'Diagnose', 'Migration', 'AgentUsers', 'Tui', 'Commands') {
    . (Join-Path $PSScriptRoot "lib/$file.ps1")
}

Export-ModuleMember -Function * -Alias *
