$script:GraphAppId = '00000003-0000-0000-c000-000000000000'

$script:State = @{
    TenantId     = $null
    ClientId     = $null
    DryRun       = $false
    Remember     = $false
    AccessToken  = $null
    ExpiresAt    = [datetime]::MinValue
    RefreshToken = $null
    Account      = $null
    Scopes       = @()
    CallLog      = New-Object System.Collections.Generic.List[string]
    Cache        = @{}
    RegistryError = $null
}

function Get-AmHome {
    $base = if ($env:AGENTMGMT_HOME) { $env:AGENTMGMT_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agentmgmt' }
    if (-not (Test-Path $base)) { $null = New-Item -ItemType Directory -Path $base -Force }
    return $base
}

function Get-AmConfigPath { Join-Path (Get-AmHome) 'config.json' }
function Get-AmTokenPath { Join-Path (Get-AmHome) 'tokens.json' }

function Test-AmWindows { return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }

function Protect-AmFile {
    param([string]$Path)
    if (Test-AmWindows) { return }
    & chmod 600 $Path 2>$null
}

function Import-AmConfig {
    $path = Get-AmConfigPath
    if (-not (Test-Path $path)) { return }
    $cfg = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($key in 'TenantId', 'ClientId', 'Remember') {
        $prop = $cfg.PSObject.Properties[$key.Substring(0, 1).ToLower() + $key.Substring(1)]
        if ($prop -and $null -ne $prop.Value) { $script:State[$key] = $prop.Value }
    }
}

function Save-AmConfig {
    $cfg = [ordered]@{
        tenantId = $script:State.TenantId
        clientId = $script:State.ClientId
        remember = [bool]$script:State.Remember
    }
    $path = Get-AmConfigPath
    $cfg | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
    Protect-AmFile $path
}

function Save-AmRefreshToken {
    $path = Get-AmTokenPath
    if (-not $script:State.Remember -or -not $script:State.RefreshToken) {
        if (Test-Path $path) { Remove-Item $path -Force }
        return
    }
    $onWindows = Test-AmWindows
    $value = $script:State.RefreshToken
    if ($onWindows) {
        $value = ConvertFrom-SecureString (ConvertTo-SecureString $value -AsPlainText -Force)
    }
    @{ protected = $onWindows; refreshToken = $value } | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
    Protect-AmFile $path
}

function Import-AmRefreshToken {
    $path = Get-AmTokenPath
    if (-not (Test-Path $path)) { return }
    try {
        $raw = Get-Content $path -Raw | ConvertFrom-Json
        $value = $raw.refreshToken
        if ($raw.protected) {
            $secure = ConvertTo-SecureString $value
            $value = [System.Net.NetworkCredential]::new('', $secure).Password
        }
        $script:State.RefreshToken = $value
    } catch {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

function Clear-AmSession {
    $script:State.AccessToken = $null
    $script:State.RefreshToken = $null
    $script:State.ExpiresAt = [datetime]::MinValue
    $script:State.Account = $null
    $script:State.Scopes = @()
    $script:State.Cache = @{}
    $path = Get-AmTokenPath
    if (Test-Path $path) { Remove-Item $path -Force }
}

function Test-AmGuid {
    param([string]$Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$parsed)
}
