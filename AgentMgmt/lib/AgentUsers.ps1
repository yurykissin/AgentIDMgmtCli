$script:AgentUserPermission = 'AgentIdUser.ReadWrite.IdentityParentedBy'

function Get-AmVerifiedDomains {
    $organizations = @(Invoke-AmGraph -Method GET -All -Path '/organization?$select=id,verifiedDomains')
    if ($organizations.Count -ne 1 -or $organizations[0].id -ne $script:State.TenantId) {
        throw 'Cannot verify domains for the signed-in toolkit tenant. Check the tenant configuration and sign in again.'
    }
    @($organizations[0].verifiedDomains | Where-Object { $_.isVerified } | ForEach-Object { $_.name })
}

function Get-AmAgentUser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IdentityId)
    if (-not (Test-AmGuid $IdentityId)) { throw 'IdentityId must be the child agent identity object ID (GUID), not its client ID or a name.' }
    $users = @(Invoke-AmGraph -Method GET -All -Path '/users/microsoft.graph.agentUser?$select=id,displayName,userPrincipalName,mailNickname,identityParentId,accountEnabled')
    $linked = @($users | Where-Object { $_.identityParentId -eq $IdentityId })
    if ($linked.Count -gt 1) { throw "More than one agent user is linked to $IdentityId. Expected an immutable one-to-one relationship; investigate before changing anything." }
    if ($linked.Count -eq 1) { return $linked[0] }
    return $null
}

function Get-AmAgentUserCreationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IdentityId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$MailNickname,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [bool]$Enabled = $true
    )
    if (-not (Test-AmGuid $IdentityId)) { throw 'IdentityId must be the child agent identity object ID (GUID).' }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\x00-\x1f]') { throw 'A nonblank display name without control characters is required.' }
    if ($MailNickname -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Mail nickname must start with a letter or digit and contain only letters, digits, dots, underscores or hyphens.' }
    if ($UserPrincipalName -notmatch '^[A-Za-z0-9''.!#^~_-]+@([A-Za-z0-9.-]+)$') { throw 'UPN must be an ASCII alias@verified-domain name with no spaces or accent characters.' }
    $domain = $UserPrincipalName.Substring($UserPrincipalName.IndexOf('@') + 1)
    $agent = Invoke-AmGraph -Method GET -Path "$(Get-AmObjectRoute Identity $IdentityId)?`$select=id,appId,displayName,agentIdentityBlueprintId"
    if ($agent.id -ne $IdentityId -or -not (Test-AmGuid $agent.agentIdentityBlueprintId)) {
        throw 'The selected object is not a child agent identity with a valid blueprint client ID. Use the child object ID, not its appId.'
    }
    $blueprint = Resolve-AmBlueprint -Selector $agent.agentIdentityBlueprintId
    if ($blueprint.appId -ne $agent.agentIdentityBlueprintId) { throw 'The child identity does not belong to the resolved blueprint.' }
    if (-not (Test-AmGuid $script:State.TenantId)) { throw 'A tenant-specific toolkit sign-in is required before creating an agent user.' }
    $existing = Get-AmAgentUser -IdentityId $agent.id
    if ($existing) {
        throw "This agent already has agent user '$($existing.userPrincipalName)' (id=$($existing.id)). The link is immutable and one-to-one; no user was created."
    }
    $domains = @(Get-AmVerifiedDomains)
    if ($domains -notcontains $domain) { throw "UPN domain '$domain' is not verified in this tenant. Verified domains: $($domains -join ', ')." }
    $filter = [uri]::EscapeDataString("userPrincipalName eq '$($UserPrincipalName.Replace("'", "''"))' or mailNickname eq '$($MailNickname.Replace("'", "''"))'")
    $collisions = @(Invoke-AmGraph -Method GET -All -Path "/users?`$filter=$filter&`$select=id,userPrincipalName,mailNickname&`$top=2")
    if ($collisions.Count -gt 0) { throw 'The UPN or mail nickname is already used by a directory user. Choose unused values; no user was created.' }
    $principal = Get-AmBlueprintPrincipal -BlueprintAppId $blueprint.appId
    if (-not $principal) { throw 'The blueprint has no principal. Use Blueprint > Repair missing principal before creating an agent user.' }
    $graph = Get-AmResourceSp -ResourceAppId $script:GraphAppId
    $role = @($graph.appRoles | Where-Object { $_.value -eq $script:AgentUserPermission -and $_.isEnabled -and $_.allowedMemberTypes -contains 'Application' })
    if ($role.Count -ne 1) { throw "Required Graph application permission '$script:AgentUserPermission' is not published in this tenant." }
    $assignments = @(Invoke-AmGraph -Method GET -All -Path "/servicePrincipals/$($principal.id)/appRoleAssignments")
    if (-not ($assignments | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $role[0].id })) {
        throw "Blueprint appId=$($blueprint.appId) needs the '$script:AgentUserPermission' APPLICATION permission with admin consent. Declaring a permission or consenting to the toolkit app is not sufficient. Grant it to the blueprint principal, then retry."
    }
    [pscustomobject]@{
        Agent = $agent
        Blueprint = $blueprint
        TenantId = $script:State.TenantId
        Body = @{
            accountEnabled = $Enabled
            displayName = $Name.Trim()
            mailNickname = $MailNickname
            userPrincipalName = $UserPrincipalName
            identityParentId = $agent.id
        }
    }
}

function Read-AmBlueprintClientSecret {
    param([string]$EnvironmentVariable)
    if ($EnvironmentVariable) {
        if ($EnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Specify an environment variable name, not a credential value.' }
        $value = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if ([string]::IsNullOrEmpty($value)) { throw "Blueprint secret environment variable '$EnvironmentVariable' is missing or empty." }
        try { return ConvertTo-SecureString -String $value -AsPlainText -Force }
        finally { $value = $null }
    }
    Read-Host 'Blueprint client secret VALUE (hidden, never saved)' -AsSecureString
}

function New-AmAgentUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IdentityId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$MailNickname,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [bool]$Enabled = $true,
        [Security.SecureString]$ClientSecret,
        [string]$SecretEnvironmentVariable
    )
    if ($ClientSecret -and $SecretEnvironmentVariable) { throw 'Supply a secure client secret or a secret environment variable name, not both.' }
    $plan = Get-AmAgentUserCreationPlan -IdentityId $IdentityId -Name $Name -MailNickname $MailNickname -UserPrincipalName $UserPrincipalName -Enabled $Enabled
    if ($script:State.DryRun) {
        Write-Host "[dry-run] Would acquire a Graph .default application token as blueprint $($plan.Blueprint.appId). No credential is requested." -ForegroundColor Yellow
        return Invoke-AmGraph -Method POST -Path '/users/microsoft.graph.agentUser' -Body $plan.Body -Token '<blueprint-token-not-acquired-in-dry-run>'
    }
    $ownsSecret = -not $ClientSecret
    $blueprintToken = $null
    try {
        if ($ownsSecret) { $ClientSecret = Read-AmBlueprintClientSecret -EnvironmentVariable $SecretEnvironmentVariable }
        $blueprintToken = Get-AmBlueprintGraphToken -ClientId $plan.Blueprint.appId -TenantId $plan.TenantId -ClientSecret $ClientSecret
        $created = Invoke-AmGraph -Method POST -Path '/users/microsoft.graph.agentUser' -Body $plan.Body -Token $blueprintToken
        if (-not (Test-AmGuid $created.id)) { throw 'Agent-user creation returned no valid user object ID. Do not retry creation until you check the linked agent user.' }
        $userId = $created.id
        try {
            $validated = Invoke-AmWithPropagationRetry {
                Invoke-AmGraph -Method GET -Path "/users/microsoft.graph.agentUser/$userId`?`$select=id,displayName,userPrincipalName,mailNickname,identityParentId,accountEnabled" -Token $blueprintToken
            }
            if ($validated.'@odata.type' -ne '#microsoft.graph.agentUser' -or
                $validated.id -ne $userId -or $validated.identityParentId -ne $plan.Agent.id -or
                $validated.displayName -cne $plan.Body.displayName -or
                $validated.userPrincipalName -ne $UserPrincipalName -or $validated.mailNickname -ne $MailNickname -or
                $null -eq $validated.accountEnabled -or [bool]$validated.accountEnabled -ne $Enabled) {
                throw 'Read-back did not match the requested agent-user subtype, parent, display name, UPN, alias or enabled state.'
            }
        } catch {
            throw "Agent user id=$userId was created, but read-back validation failed: $($_.Exception.Message) Check agent-user-show --agent $IdentityId before doing anything else; do not retry creation."
        }
        return $validated
    } finally {
        $blueprintToken = $null
        if ($ownsSecret -and $ClientSecret) { $ClientSecret.Dispose() }
    }
}
