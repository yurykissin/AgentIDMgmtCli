try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

class AmGraphException : System.Exception {
    [int]$Status
    [string]$Code
    [string]$Hint
    [string]$Method
    [string]$Url
    AmGraphException([string]$message, [int]$status, [string]$code, [string]$hint, [string]$method, [string]$url) : base($message) {
        $this.Status = $status
        $this.Code = $code
        $this.Hint = $hint
        $this.Method = $method
        $this.Url = $url
    }
}

function Get-AmHint {
    param([int]$Status, [string]$Code, [string]$Message, [string]$Url)

    if ($Message -match 'cannot be granted to agent identities') {
        return 'This permission is on the official blocked-for-agents list. Pick a narrower permission (for example User.ReadUpdate.All instead of User.ReadWrite.All).'
    }
    if ($Message -match 'Content-Type') {
        return 'Write request was sent without a JSON Content-Type header.'
    }
    if ($Message -match 'AADSTS65002') {
        return 'The signing-in client is not pre-authorized for this scope. Use the toolkit app (Settings > Re-run setup), not Azure CLI.'
    }
    if ($Code -eq 'Authorization_RequestDenied' -or $Status -eq 403) {
        return 'The signed-in account lacks the required role or the toolkit app lacks consent. Needed: Agent ID Administrator/Developer (or object owner); Global Administrator or Privileged Role Administrator for tenant-wide consent.'
    }
    if ($Status -eq 401) {
        return 'Token rejected. Sign in again (Settings > Sign out, then retry).'
    }
    if ($Url -match '/copilot/agentRegistrations' -and $Status -ge 400) {
        return 'Agent Registry is a beta API. The token needs AgentRegistration.ReadWrite.All and the signed-in user needs registry access.'
    }
    if ($Status -eq 404) {
        return 'Object not found (it may be deleted, soft-deleted, or still propagating).'
    }
    return $null
}

function Get-AmHttpErrorBody {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        try {
            $stream = $response.Value.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        } catch { }
    }
    return $ErrorRecord.Exception.Message
}

# Thin wrapper over the network so tests can mock it.
function Invoke-AmHttp {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body
    )
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true }
    if ($Body) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $response = Invoke-WebRequest @params
        $text = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $text; RetryAfter = $null }
    } catch {
        $status = 0
        $retry = $null
        $resp = $_.Exception.PSObject.Properties['Response']
        if ($resp -and $resp.Value) {
            $status = [int]$resp.Value.StatusCode
            try { $retry = $resp.Value.Headers['Retry-After'] | Select-Object -First 1 } catch { }
        }
        return [pscustomobject]@{ Status = $status; Content = (Get-AmHttpErrorBody $_); RetryAfter = $retry }
    }
}

function Add-AmCallLog {
    param([string]$Line)
    $log = $script:State.CallLog
    $log.Add(('{0:HH:mm:ss} {1}' -f (Get-Date), $Line))
    while ($log.Count -gt 60) { $log.RemoveAt(0) }
}

function Invoke-AmGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null,
        [switch]$Beta,
        [switch]$All,
        [switch]$NoAuth,
        [switch]$AllowDryRun,
        [string]$Token
    )

    $version = if ($Beta) { 'beta' } else { 'v1.0' }
    $url = if ($Path -match '^https://') { $Path } else { "https://graph.microsoft.com/$version$Path" }
    $json = $null
    if ($null -ne $Body) { $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 -Compress } }

    if ($Method -ne 'GET' -and $script:State.DryRun -and -not $AllowDryRun) {
        Add-AmCallLog "[dry-run] $Method $url"
        Write-Host "[dry-run] $Method $url" -ForegroundColor Yellow
        if ($json) { Write-Host "          $json" -ForegroundColor DarkYellow }
        return $null
    }

    $items = New-Object System.Collections.ArrayList
    $result = $null
    $next = $url
    do {
        $bearer = if ($Token) { $Token } else { Get-AmAccessToken }
        $headers = @{ Authorization = "Bearer $bearer"; 'OData-Version' = '4.0'; Accept = 'application/json'; ConsistencyLevel = 'eventual' }
        $attempt = 0
        do {
            $attempt++
            Add-AmCallLog "$Method $next"
            Write-Verbose "$Method $next"
            $resp = Invoke-AmHttp -Method $Method -Uri $next -Headers $headers -Body $json
            $retryable = $resp.Status -in 429, 502, 503, 504
            if ($retryable -and $attempt -lt 5) {
                $wait = 0
                if ($resp.RetryAfter -and [int]::TryParse([string]$resp.RetryAfter, [ref]$wait) -and $wait -gt 0) { } else { $wait = [math]::Pow(2, $attempt) }
                Start-Sleep -Seconds ([math]::Min($wait, 30))
            }
        } while ($retryable -and $attempt -lt 5)

        if ($resp.Status -lt 200 -or $resp.Status -ge 300) {
            $code = $null
            $message = $resp.Content
            try {
                $err = $resp.Content | ConvertFrom-Json
                if ($err.error) { $code = $err.error.code; $message = $err.error.message }
            } catch { }
            $hint = Get-AmHint -Status $resp.Status -Code $code -Message $message -Url $next
            $text = "$Method $next -> HTTP $($resp.Status) $code`: $message"
            if ($hint) { $text += "`nHint: $hint" }
            throw [AmGraphException]::new($text, $resp.Status, [string]$code, [string]$hint, $Method, $next)
        }

        $parsed = $null
        if ($resp.Content) { try { $parsed = $resp.Content | ConvertFrom-Json } catch { $parsed = $resp.Content } }
        $next = $null
        if ($All -and $parsed -and $parsed.PSObject.Properties['value']) {
            [void]$items.AddRange(@($parsed.value))
            $link = $parsed.PSObject.Properties['@odata.nextLink']
            if ($link) { $next = $link.Value }
        } else {
            $result = $parsed
        }
    } while ($next)

    if ($All) { return , @($items) }
    return $result
}

function Get-AmCallLog { return @($script:State.CallLog) }

function ConvertTo-AmSelect {
    param([string[]]$Fields)
    return '?$select=' + ($Fields -join ',')
}
