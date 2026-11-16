Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$script:BootstrapClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line Tools (public client)
$script:ToolkitAppName = 'Agent ID Admin Toolkit'
$script:ToolkitScopes = @(
    'AgentIdentityBlueprint.ReadWrite.All',
    'AgentIdentityBlueprint.DeleteRestore.All',
    'AgentIdentityBlueprintPrincipal.ReadWrite.All',
    'AgentIdentity.ReadWrite.All',
    'AgentIdentity.DeleteRestore.All',
    'AgentRegistration.ReadWrite.All',
    'Application.Read.All',
    'AppRoleAssignment.ReadWrite.All',
    'DelegatedPermissionGrant.ReadWrite.All',
    'Directory.Read.All',
    'User.Read'
)

function Get-AmAuthority {
    param([string]$TenantId)
    $t = if ($TenantId) { $TenantId } elseif ($script:State.TenantId) { $script:State.TenantId } else { 'organizations' }
    return "https://login.microsoftonline.com/$t/oauth2/v2.0"
}

function ConvertFrom-AmJwt {
    param([string]$Token)
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json } catch { return $null }
}

# Thin wrapper so tests can mock it. Never throws on HTTP errors.
function Invoke-AmForm {
    param([string]$Uri, [hashtable]$Form)
    try {
        $r = Invoke-WebRequest -Method POST -Uri $Uri -Body $Form -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Json = ($r.Content | ConvertFrom-Json) }
    } catch {
        $body = Get-AmHttpErrorBody $_
        $json = $null
        try { $json = $body | ConvertFrom-Json } catch { }
        if (-not $json) { $json = [pscustomobject]@{ error = 'request_failed'; error_description = $body } }
        return [pscustomobject]@{ Status = 400; Json = $json }
    }
}

function Set-AmTokenState {
    param($Token, [string]$ClientId)
    $script:State.AccessToken = $Token.access_token
    $script:State.ExpiresAt = [datetime]::UtcNow.AddSeconds([int]$Token.expires_in - 120)
    if ($Token.PSObject.Properties['refresh_token'] -and $Token.refresh_token) { $script:State.RefreshToken = $Token.refresh_token }
    $claims = ConvertFrom-AmJwt $Token.access_token
    if ($claims) {
        $upn = if ($claims.PSObject.Properties['upn']) { $claims.upn } elseif ($claims.PSObject.Properties['unique_name']) { $claims.unique_name } else { $null }
        $script:State.Account = [pscustomobject]@{
            Name     = if ($claims.PSObject.Properties['name']) { $claims.name } else { $null }
            Upn      = $upn
            TenantId = $claims.tid
            Oid      = $claims.oid
            ClientId = $ClientId
        }
        $script:State.Scopes = if ($claims.PSObject.Properties['scp']) { @($claims.scp -split ' ') } else { @() }
        if (-not $script:State.TenantId) { $script:State.TenantId = $claims.tid }
    }
}

function Get-AmDeviceCodeToken {
    param([string]$ClientId, [string]$TenantId, [string]$Scope)
    $base = Get-AmAuthority $TenantId
    $dc = Invoke-AmForm -Uri "$base/devicecode" -Form @{ client_id = $ClientId; scope = $Scope }
    if ($dc.Status -ne 200) { throw "Device code request failed: $($dc.Json.error_description)" }
    Write-Host ''
    Write-Host $dc.Json.message -ForegroundColor Cyan
    $interval = [math]::Max(1, [int]$dc.Json.interval)
    $deadline = [datetime]::UtcNow.AddSeconds([int]$dc.Json.expires_in)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $tok = Invoke-AmForm -Uri "$base/token" -Form @{
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            client_id   = $ClientId
            device_code = $dc.Json.device_code
        }
        if ($tok.Status -eq 200) { return $tok.Json }
        switch ($tok.Json.error) {
            'authorization_pending' { continue }
            'slow_down' { $interval += 5; continue }
            default { throw "Sign-in failed: $($tok.Json.error) $($tok.Json.error_description)" }
        }
    }
    throw 'Device code sign-in timed out.'
}

function Get-AmBrowserToken {
    param([string]$ClientId, [string]$TenantId, [string]$Scope)
    $base = Get-AmAuthority $TenantId
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $challenge = [Convert]::ToBase64String($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $state = [guid]::NewGuid().ToString('N')

    $listener = $null
    $port = 0
    foreach ($try in 1..10) {
        $port = Get-Random -Minimum 49200 -Maximum 65000
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$port/")
        try { $listener.Start(); break } catch { $listener = $null }
    }
    if (-not $listener) { throw 'Could not open a local port for the sign-in redirect.' }

    try {
        $redirect = "http://localhost:$port"
        $query = @(
            "client_id=$ClientId", 'response_type=code', "redirect_uri=$([uri]::EscapeDataString($redirect))",
            'response_mode=query', "scope=$([uri]::EscapeDataString($Scope))", "state=$state",
            "code_challenge=$challenge", 'code_challenge_method=S256', 'prompt=select_account'
        ) -join '&'
        $authUrl = "$base/authorize?$query"
        Write-Host 'Opening your browser to sign in. If nothing opens, paste this URL into a browser:' -ForegroundColor Cyan
        Write-Host $authUrl -ForegroundColor DarkGray
        Open-AmBrowser $authUrl

        $task = $listener.GetContextAsync()
        if (-not $task.Wait([TimeSpan]::FromMinutes(5))) { throw 'Browser sign-in timed out.' }
        $ctx = $task.Result
        $qs = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)
        $page = '<html><body style="font-family:sans-serif"><h3>Signed in. You can close this tab.</h3></body></html>'
        if ($qs['error']) { $page = "<html><body><h3>Sign-in failed: $([System.Net.WebUtility]::HtmlEncode($qs['error_description']))</h3></body></html>" }
        $buf = [System.Text.Encoding]::UTF8.GetBytes($page)
        $ctx.Response.ContentType = 'text/html'
        $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
        $ctx.Response.Close()
        if ($qs['error']) { throw "Sign-in failed: $($qs['error']) $($qs['error_description'])" }
        if ($qs['state'] -ne $state) { throw 'Sign-in state mismatch; aborting.' }

        $tok = Invoke-AmForm -Uri "$base/token" -Form @{
            grant_type    = 'authorization_code'
            client_id     = $ClientId
            code          = $qs['code']
            redirect_uri  = $redirect
            code_verifier = $verifier
            scope         = $Scope
        }
        if ($tok.Status -ne 200) { throw "Token exchange failed: $($tok.Json.error) $($tok.Json.error_description)" }
        return $tok.Json
    } finally {
        $listener.Stop()
        $listener.Close()
    }
}

function Open-AmBrowser {
    param([string]$Url)
    try {
        if (Test-AmWindows) { Start-Process $Url }
        elseif ($PSVersionTable.Platform -eq 'Unix' -and (Test-Path '/usr/bin/open')) { & open $Url }
        else { & xdg-open $Url 2>$null }
    } catch { }
}

function Connect-AmSession {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [string]$ClientId,
        [ValidateSet('Auto', 'Browser', 'Device')][string]$Flow = 'Auto',
        [string]$Scope = 'https://graph.microsoft.com/.default offline_access openid profile'
    )
    if (-not $ClientId) { $ClientId = $script:State.ClientId }
    if (-not $ClientId) { throw 'Toolkit app is not configured. Run Initialize-AmToolkitApp (menu: Settings > Set up toolkit app).' }
    if (-not $TenantId) { $TenantId = $script:State.TenantId }
    $tok = $null
    if ($Flow -in 'Auto', 'Browser') {
        try { $tok = Get-AmBrowserToken -ClientId $ClientId -TenantId $TenantId -Scope $Scope }
        catch { if ($Flow -eq 'Browser') { throw }; Write-Host "Browser sign-in unavailable ($($_.Exception.Message)); using device code." -ForegroundColor Yellow }
    }
    if (-not $tok) { $tok = Get-AmDeviceCodeToken -ClientId $ClientId -TenantId $TenantId -Scope $Scope }
    Set-AmTokenState -Token $tok -ClientId $ClientId
    Save-AmRefreshToken
    return $script:State.Account
}

function Get-AmAccessToken {
    if ($script:State.AccessToken -and [datetime]::UtcNow -lt $script:State.ExpiresAt) { return $script:State.AccessToken }

    if (-not $script:State.RefreshToken) { Import-AmRefreshToken }
    if ($script:State.RefreshToken -and $script:State.ClientId) {
        $tok = Invoke-AmForm -Uri "$(Get-AmAuthority)/token" -Form @{
            grant_type    = 'refresh_token'
            client_id     = $script:State.ClientId
            refresh_token = $script:State.RefreshToken
            scope         = 'https://graph.microsoft.com/.default offline_access'
        }
        if ($tok.Status -eq 200) {
            Set-AmTokenState -Token $tok.Json -ClientId $script:State.ClientId
            Save-AmRefreshToken
            return $script:State.AccessToken
        }
        $script:State.RefreshToken = $null
    }
    [void](Connect-AmSession)
    return $script:State.AccessToken
}

function Initialize-AmToolkitApp {
    [CmdletBinding()]
    param([string]$TenantId, [switch]$Force)

    if ($script:State.ClientId -and -not $Force) {
        Write-Host "Toolkit app already configured: $($script:State.ClientId)" -ForegroundColor Green
        return $script:State.ClientId
    }
    Write-Host 'One-time setup: sign in as a Global Administrator (or Application Administrator + Privileged Role Administrator).' -ForegroundColor Cyan
    Write-Host "This creates an app registration named '$script:ToolkitAppName' and grants it admin consent. Nothing else is changed." -ForegroundColor Cyan

    $bootScope = 'https://graph.microsoft.com/Application.ReadWrite.All https://graph.microsoft.com/DelegatedPermissionGrant.ReadWrite.All https://graph.microsoft.com/Directory.Read.All offline_access'
    $tok = $null
    try { $tok = Get-AmBrowserToken -ClientId $script:BootstrapClientId -TenantId $TenantId -Scope $bootScope }
    catch { Write-Host "Browser sign-in unavailable ($($_.Exception.Message)); using device code." -ForegroundColor Yellow }
    if (-not $tok) { $tok = Get-AmDeviceCodeToken -ClientId $script:BootstrapClientId -TenantId $TenantId -Scope $bootScope }
    $bt = $tok.access_token
    $claims = ConvertFrom-AmJwt $bt
    $tenant = $claims.tid

    $graph = Invoke-AmGraph -Method GET -Token $bt -Path "/servicePrincipals(appId='$script:GraphAppId')?`$select=id,oauth2PermissionScopes"
    $resourceAccess = @()
    $granted = @()
    foreach ($name in $script:ToolkitScopes) {
        $scope = $graph.oauth2PermissionScopes | Where-Object { $_.value -eq $name } | Select-Object -First 1
        if ($scope) {
            $resourceAccess += @{ id = $scope.id; type = 'Scope' }
            $granted += $name
        } else {
            Write-Host "  skipped (not published in this tenant's Graph): $name" -ForegroundColor Yellow
        }
    }
    $required = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = $resourceAccess })

    $existing = @(Invoke-AmGraph -Method GET -Token $bt -All -Path "/applications?`$filter=displayName eq '$script:ToolkitAppName'&`$select=id,appId")
    if ($existing.Count -gt 0) {
        $app = $existing[0]
        Write-Host "Reusing existing app registration $($app.appId)." -ForegroundColor Yellow
        $null = Invoke-AmGraph -Method PATCH -Token $bt -Path "/applications/$($app.id)" -Body @{
            requiredResourceAccess = $required
            isFallbackPublicClient = $true
            publicClient           = @{ redirectUris = @('http://localhost') }
        }
    } else {
        $app = Invoke-AmGraph -Method POST -Token $bt -Path '/applications' -Body @{
            displayName            = $script:ToolkitAppName
            signInAudience         = 'AzureADMyOrg'
            isFallbackPublicClient = $true
            publicClient           = @{ redirectUris = @('http://localhost') }
            requiredResourceAccess = $required
        }
    }

    $sp = @(Invoke-AmGraph -Method GET -Token $bt -All -Path "/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id,appId")
    $spId = if ($sp.Count -gt 0) { $sp[0].id } else { (Invoke-AmGraph -Method POST -Token $bt -Path '/servicePrincipals' -Body @{ appId = $app.appId }).id }

    $scopeString = $granted -join ' '
    $grants = @(Invoke-AmGraph -Method GET -Token $bt -All -Path "/oauth2PermissionGrants?`$filter=clientId eq '$spId' and resourceId eq '$($graph.id)'")
    $adminGrant = $grants | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if ($adminGrant) {
        $null = Invoke-AmGraph -Method PATCH -Token $bt -Path "/oauth2PermissionGrants/$($adminGrant.id)" -Body @{ scope = $scopeString }
    } else {
        $null = Invoke-AmGraph -Method POST -Token $bt -Path '/oauth2PermissionGrants' -Body @{
            clientId    = $spId
            consentType = 'AllPrincipals'
            resourceId  = $graph.id
            scope       = $scopeString
        }
    }

    $script:State.TenantId = $tenant
    $script:State.ClientId = $app.appId
    Save-AmConfig
    Write-Host "Toolkit app ready: $($app.appId) in tenant $tenant" -ForegroundColor Green
    return $app.appId
}

function Remove-AmToolkitApp {
    [CmdletBinding()]
    param()
    if (-not $script:State.ClientId) { Write-Host 'No toolkit app configured.' -ForegroundColor Yellow; return }
    $bootScope = 'https://graph.microsoft.com/Application.ReadWrite.All offline_access'
    $tok = Get-AmBrowserToken -ClientId $script:BootstrapClientId -TenantId $script:State.TenantId -Scope $bootScope
    $app = @(Invoke-AmGraph -Method GET -Token $tok.access_token -All -Path "/applications?`$filter=appId eq '$($script:State.ClientId)'&`$select=id")
    if ($app.Count -gt 0) { $null = Invoke-AmGraph -Method DELETE -Token $tok.access_token -Path "/applications/$($app[0].id)" }
    $script:State.ClientId = $null
    Clear-AmSession
    Save-AmConfig
    Write-Host 'Toolkit app removed.' -ForegroundColor Green
}

function Disconnect-AmSession {
    Clear-AmSession
}
