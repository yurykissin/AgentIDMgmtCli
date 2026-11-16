<#
.SYNOPSIS
    Entra Agent ID admin toolkit (console UI). Direct Microsoft Graph calls only.
.EXAMPLE
    ./agentmgmt.ps1                       # interactive menu
    ./agentmgmt.ps1 -Command tree
    ./agentmgmt.ps1 -Command agent-grant --agent "n8n write agent" --permission User.ReadUpdate.All -DryRun
#>
[CmdletBinding()]
param(
    [string]$Command,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentMgmt/AgentMgmt.psd1') -Force

& (Get-Module AgentMgmt) {
    param($Command, $DryRun, $Rest)
    Import-AmConfig
    if ($DryRun) { $script:State.DryRun = $true }
    if (-not $Command) { Start-AmTui; return }
    try {
        $opts = ConvertTo-AmOptions -Tokens $Rest
        Invoke-AmCommand -Name $Command -Options $opts
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} $Command $DryRun.IsPresent $Rest
