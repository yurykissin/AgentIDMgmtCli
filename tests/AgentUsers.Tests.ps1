BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../AgentMgmt/AgentMgmt.psd1') -Force
}

Describe 'Blueprint app-only Graph authentication' {
    BeforeEach {
        InModuleScope AgentMgmt {
            $script:State.AccessToken = 'admin-session-token'
            $script:State.RefreshToken = 'admin-refresh-token'
            $script:State.ClientId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }
        $script:testSecret = ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force
        $script:submittedForm = $null
        $script:capturedForm = $null
        Mock -ModuleName AgentMgmt Invoke-AmForm {
            param($Uri, $Form)
            $script:submittedForm = $Form
            $script:capturedForm = $Form.Clone()
            [pscustomobject]@{ Status = 200; Json = [pscustomobject]@{ access_token = 'blueprint-only-token' } }
        }
    }

    AfterEach { $script:testSecret.Dispose() }

    It 'uses the blueprint client ID, secret and Graph .default with client_credentials, without changing admin sign-in' {
        $token = Get-AmBlueprintGraphToken -ClientId '22222222-2222-2222-2222-222222222222' -TenantId '11111111-1111-1111-1111-111111111111' -ClientSecret $script:testSecret
        $token | Should -Be 'blueprint-only-token'
        $script:capturedForm.client_id | Should -Be '22222222-2222-2222-2222-222222222222'
        $script:capturedForm.client_secret | Should -Be 'fixture-secret'
        $script:capturedForm.grant_type | Should -Be 'client_credentials'
        $script:capturedForm.scope | Should -Be 'https://graph.microsoft.com/.default'
        $script:submittedForm.Count | Should -Be 0
        Should -Invoke -ModuleName AgentMgmt Invoke-AmForm -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/token' }
        InModuleScope AgentMgmt {
            $script:State.AccessToken | Should -Be 'admin-session-token'
            $script:State.RefreshToken | Should -Be 'admin-refresh-token'
            $script:State.ClientId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }
    }

    It 'surfaces an OAuth failure without echoing the secret or provider description' {
        Mock -ModuleName AgentMgmt Invoke-AmForm {
            [pscustomobject]@{ Status = 400; Json = [pscustomobject]@{ error = 'invalid_client'; error_description = 'fixture-secret must never be shown' } }
        }
        $message = try {
            Get-AmBlueprintGraphToken -ClientId '22222222-2222-2222-2222-222222222222' -TenantId '11111111-1111-1111-1111-111111111111' -ClientSecret $script:testSecret
        } catch { $_.Exception.Message }
        $message | Should -Match 'invalid_client'
        $message | Should -Not -Match 'fixture-secret|must never be shown'
    }

    It 'rejects a nominally successful response with no token instead of using the admin token' {
        Mock -ModuleName AgentMgmt Invoke-AmForm { [pscustomobject]@{ Status = 200; Json = [pscustomobject]@{} } }
        { Get-AmBlueprintGraphToken -ClientId '22222222-2222-2222-2222-222222222222' -TenantId '11111111-1111-1111-1111-111111111111' -ClientSecret $script:testSecret } | Should -Throw '*token request failed*'
    }

    It 'does not echo arbitrary provider error fields even if they look like identifiers' {
        Mock -ModuleName AgentMgmt Invoke-AmForm { [pscustomobject]@{ Status = 400; Json = [pscustomobject]@{ error = 'do_not_echo_submitted_value' } } }
        $message = try {
            Get-AmBlueprintGraphToken -ClientId '22222222-2222-2222-2222-222222222222' -TenantId '11111111-1111-1111-1111-111111111111' -ClientSecret $script:testSecret
        } catch { $_.Exception.Message }
        $message | Should -Match 'token_request_failed'
        $message | Should -Not -Match 'do_not_echo_submitted_value'
    }
}

Describe 'Agent-user creation preflight and validation' {
    BeforeEach {
        InModuleScope AgentMgmt {
            $script:State.TenantId = '11111111-1111-1111-1111-111111111111'
            $script:State.DryRun = $false
            $script:State.Cache = @{}
        }
        $script:userParameters = @{
            IdentityId = '55555555-5555-5555-5555-555555555555'
            Name = 'AgentUser Lab User'; MailNickname = 'agentuserlab'; UserPrincipalName = 'agentuserlab@contoso.com'
        }
        $script:agentUserResult = [pscustomobject]@{
            id = '77777777-7777-7777-7777-777777777777'
            '@odata.type' = '#microsoft.graph.agentUser'
            identityParentId = '55555555-5555-5555-5555-555555555555'
            displayName = 'AgentUser Lab User'; mailNickname = 'agentuserlab'
            userPrincipalName = 'agentuserlab@contoso.com'; accountEnabled = $true
        }
        $script:testSecret = ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force
        Mock -ModuleName AgentMgmt Read-AmBlueprintClientSecret { throw 'Unexpected credential prompt' }
        Mock -ModuleName AgentMgmt Get-AmBlueprintGraphToken { 'blueprint-only-token' }
        Mock -ModuleName AgentMgmt Resolve-AmBlueprint {
            [pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; appId = '22222222-2222-2222-2222-222222222222' }
        }
        Mock -ModuleName AgentMgmt Get-AmBlueprintPrincipal {
            [pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; appId = '22222222-2222-2222-2222-222222222222' }
        }
        Mock -ModuleName AgentMgmt Get-AmResourceSp {
            [pscustomobject]@{
                id = '88888888-8888-8888-8888-888888888888'
                appId = '00000003-0000-0000-c000-000000000000'
                appRoles = @([pscustomobject]@{
                    id = '99999999-9999-9999-9999-999999999999'
                    value = 'AgentIdUser.ReadWrite.IdentityParentedBy'; isEnabled = $true; allowedMemberTypes = @('Application')
                })
            }
        }
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            param($Method, $Path, $Body, $Token)
            switch -Wildcard ($Path) {
                '/servicePrincipals/55555555-5555-5555-5555-555555555555/microsoft.graph.agentIdentity`?*' {
                    [pscustomobject]@{
                        id = '55555555-5555-5555-5555-555555555555'
                        appId = '66666666-6666-6666-6666-666666666666'
                        agentIdentityBlueprintId = '22222222-2222-2222-2222-222222222222'
                    }
                }
                '/organization`?*' {
                    [pscustomobject]@{
                        id = '11111111-1111-1111-1111-111111111111'
                        verifiedDomains = @(
                            [pscustomobject]@{ name = 'contoso.com'; isVerified = $true },
                            [pscustomobject]@{ name = 'unverified.example'; isVerified = $false }
                        )
                    }
                }
                '/users/microsoft.graph.agentUser`?*' { }
                '/users`?*' { }
                '/servicePrincipals/44444444-4444-4444-4444-444444444444/appRoleAssignments' {
                    [pscustomobject]@{ resourceId = '88888888-8888-8888-8888-888888888888'; appRoleId = '99999999-9999-9999-9999-999999999999' }
                }
                '/users/microsoft.graph.agentUser' { $script:agentUserResult }
                '/users/microsoft.graph.agentUser/77777777-7777-7777-7777-777777777777`?*' { $script:agentUserResult }
                default { throw "Unexpected Graph request: $Method $Path" }
            }
        }
    }

    AfterEach { $script:testSecret.Dispose() }

    It 'creates only the specialized subtype with the child object ID and validates it using the blueprint token' {
        $p = $script:userParameters
        $r = New-AmAgentUser @p -ClientSecret $script:testSecret
        $r.id | Should -Be '77777777-7777-7777-7777-777777777777'
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -ParameterFilter { $ClientId -eq '22222222-2222-2222-2222-222222222222' -and $TenantId -eq '11111111-1111-1111-1111-111111111111' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq '/users/microsoft.graph.agentUser' -and
            $Token -eq 'blueprint-only-token' -and $Body.identityParentId -eq '55555555-5555-5555-5555-555555555555' -and
            $Body.accountEnabled -eq $true -and $Body.displayName -eq 'AgentUser Lab User' -and
            $Body.mailNickname -eq 'agentuserlab' -and $Body.userPrincipalName -eq 'agentuserlab@contoso.com' -and
            -not $Body.ContainsKey('passwordProfile') -and $Body.Count -eq 5
        }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Path -like '/users/microsoft.graph.agentUser/77777777*' -and $Token -eq 'blueprint-only-token' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' -and $Path -ne '/users/microsoft.graph.agentUser' }
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
    }

    It 'supports a deliberately disabled agent-user account without treating false as a missing property' {
        $script:agentUserResult.accountEnabled = $false
        $p = $script:userParameters
        (New-AmAgentUser @p -ClientSecret $script:testSecret -Enabled $false).accountEnabled | Should -BeFalse
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter { $Method -eq 'POST' -and $Body.accountEnabled -eq $false }
    }

    It 'rejects invalid <Field> input before Graph discovery or credentials' -TestCases @(
        @{ Field = 'IdentityId'; Value = 'not-an-object-id' },
        @{ Field = 'Name'; Value = ' ' },
        @{ Field = 'MailNickname'; Value = 'not an alias' },
        @{ Field = 'UserPrincipalName'; Value = 'not-a-upn' }
    ) {
        param($Field, $Value)
        $p = $script:userParameters.Clone()
        $p[$Field] = $Value
        { New-AmAgentUser @p -ClientSecret $script:testSecret } | Should -Throw
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
    }

    It 'does not accept an ordinary application/service principal as the parent' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { [pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555' } } -ParameterFilter { $Path -like '/servicePrincipals/55555555*' }
        $p = $script:userParameters
        { New-AmAgentUser @p } | Should -Throw '*not a child agent identity*'
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
    }

    It 'rejects a mismatched blueprint before authentication' {
        Mock -ModuleName AgentMgmt Resolve-AmBlueprint { [pscustomobject]@{ appId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } }
        $p = $script:userParameters
        { New-AmAgentUser @p } | Should -Throw '*does not belong*'
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
    }

    It 'rejects an existing immutable parent link without asking for a credential' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { $script:agentUserResult } -ParameterFilter { $Path -like '/users/microsoft.graph.agentUser`?*' }
        $p = $script:userParameters
        { New-AmAgentUser @p } | Should -Throw '*already has agent user*immutable*'
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'shows only the linked account when other agents have users too' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            $script:agentUserResult
            [pscustomobject]@{ id = 'other-user'; identityParentId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        } -ParameterFilter { $Path -like '/users/microsoft.graph.agentUser`?*' }
        $r = Get-AmAgentUser -IdentityId '55555555-5555-5555-5555-555555555555'
        $r.id | Should -Be '77777777-7777-7777-7777-777777777777'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter { $Method -eq 'GET' -and $All }
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
    }

    It 'rejects an unverified domain' {
        $p = $script:userParameters.Clone()
        $p.UserPrincipalName = 'agentuserlab@unverified.example'
        { New-AmAgentUser @p } | Should -Throw '*not verified*'
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
    }

    It 'rejects a domain response from a different tenant' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            [pscustomobject]@{ id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; verifiedDomains = @([pscustomobject]@{ name = 'contoso.com'; isVerified = $true }) }
        } -ParameterFilter { $Path -like '/organization`?*' }
        $p = $script:userParameters
        { New-AmAgentUser @p } | Should -Throw '*Cannot verify domains*'
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
    }

    It 'rejects conflicting UPN/nickname values without authentication' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { [pscustomobject]@{ id = 'conflicting-user' } } -ParameterFilter { $Path -like '/users`?*' }
        $p = $script:userParameters
        { New-AmAgentUser @p } | Should -Throw '*already used*'
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
    }

    It 'requires an actual application grant on the blueprint principal, not a declaration or toolkit consent' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { } -ParameterFilter { $Path -like '*/appRoleAssignments' }
        $p = $script:userParameters
        { New-AmAgentUser @p } | Should -Throw '*APPLICATION permission with admin consent*'
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'does not create anything if blueprint token acquisition fails' {
        Mock -ModuleName AgentMgmt Get-AmBlueprintGraphToken { throw 'invalid_client' }
        $p = $script:userParameters
        { New-AmAgentUser @p -ClientSecret $script:testSecret } | Should -Throw '*invalid_client*'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'surfaces a server-side race/uniqueness error without creating a normal user or retrying another token' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { throw 'identityParentId is already linked' } -ParameterFilter { $Method -eq 'POST' }
        $p = $script:userParameters
        { New-AmAgentUser @p -ClientSecret $script:testSecret } | Should -Throw '*already linked*'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 1 -Exactly
    }

    It 'preserves the created user ID if read-back shows the wrong <Field>' -TestCases @(
        @{ Field = 'identityParentId'; Value = 'wrong-parent' },
        @{ Field = '@odata.type'; Value = '#microsoft.graph.user' },
        @{ Field = 'displayName'; Value = 'Unexpected display name' }
    ) {
        param($Field, $Value)
        $script:readBackResult = $script:agentUserResult.PSObject.Copy()
        $script:readBackResult.$Field = $Value
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            $script:readBackResult
        } -ParameterFilter { $Path -like '/users/microsoft.graph.agentUser/77777777*' }
        $p = $script:userParameters
        { New-AmAgentUser @p -ClientSecret $script:testSecret } | Should -Throw '*77777777-7777-7777-7777-777777777777*read-back validation failed*do not retry creation*'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'retries replication on read-back, never the successful creation' {
        $script:readBackAttempts = 0
        Mock -ModuleName AgentMgmt Start-Sleep { }
        Mock -ModuleName AgentMgmt Write-Host { }
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            $script:readBackAttempts++
            if ($script:readBackAttempts -lt 3) { throw 'Request_ResourceNotFound' }
            $script:agentUserResult
        } -ParameterFilter { $Path -like '/users/microsoft.graph.agentUser/77777777*' }
        $p = $script:userParameters
        (New-AmAgentUser @p -ClientSecret $script:testSecret).id | Should -Be '77777777-7777-7777-7777-777777777777'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke -ModuleName AgentMgmt Start-Sleep -Times 2 -Exactly
    }
}

Describe 'Agent-user transport and dry-run' {
    BeforeEach {
        InModuleScope AgentMgmt {
            $script:State.DryRun = $false
            $script:State.CallLog.Clear()
            $script:State.AccessToken = 'admin-session-token'
        }
        $script:userParameters = @{
            IdentityId = '55555555-5555-5555-5555-555555555555'
            Name = 'AgentUser Lab User'; MailNickname = 'agentuserlab'; UserPrincipalName = 'agentuserlab@contoso.com'
        }
        Mock -ModuleName AgentMgmt Get-AmAgentUserCreationPlan {
            [pscustomobject]@{
                Agent = [pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555' }
                Blueprint = [pscustomobject]@{ appId = '22222222-2222-2222-2222-222222222222' }
                TenantId = '11111111-1111-1111-1111-111111111111'
                Body = @{
                    accountEnabled = $true; displayName = 'AgentUser Lab User'; mailNickname = 'agentuserlab'
                    userPrincipalName = 'agentuserlab@contoso.com'; identityParentId = '55555555-5555-5555-5555-555555555555'
                }
            }
        }
        Mock -ModuleName AgentMgmt Get-AmBlueprintGraphToken { 'blueprint-only-token' }
        Mock -ModuleName AgentMgmt Read-AmBlueprintClientSecret { ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force }
        Mock -ModuleName AgentMgmt Get-AmAccessToken { throw 'Admin token must not be used for creation/read-back' }
        Mock -ModuleName AgentMgmt Write-Host { }
        Mock -ModuleName AgentMgmt Invoke-AmHttp {
            param($Method)
            [pscustomobject]@{
                Status = if ($Method -eq 'POST') { 201 } else { 200 }
                Content = '{"id":"77777777-7777-7777-7777-777777777777","@odata.type":"#microsoft.graph.agentUser","identityParentId":"55555555-5555-5555-5555-555555555555","displayName":"AgentUser Lab User","userPrincipalName":"agentuserlab@contoso.com","mailNickname":"agentuserlab","accountEnabled":true}'
            }
        }
    }

    AfterEach { InModuleScope AgentMgmt { $script:State.DryRun = $false } }

    It 'sends the blueprint bearer token on both real Graph-wrapper requests and logs neither token nor secret' {
        $p = $script:userParameters
        $null = New-AmAgentUser @p
        Should -Invoke -ModuleName AgentMgmt Invoke-AmHttp -Times 2 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer blueprint-only-token' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmHttp -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -eq 'https://graph.microsoft.com/v1.0/users/microsoft.graph.agentUser' -and
            ($Body | ConvertFrom-Json).identityParentId -eq '55555555-5555-5555-5555-555555555555' -and $Body -notmatch 'password'
        }
        Should -Invoke -ModuleName AgentMgmt Get-AmAccessToken -Times 0 -Exactly
        (Get-AmCallLog) -join ' ' | Should -Not -Match 'blueprint-only-token|fixture-secret|admin-session-token'
        InModuleScope AgentMgmt { $script:State.AccessToken | Should -Be 'admin-session-token' }
    }

    It 'dry-runs without requesting/reading a credential, acquiring a blueprint token, or making any Graph write' {
        InModuleScope AgentMgmt { $script:State.DryRun = $true }
        $p = $script:userParameters
        $r = New-AmAgentUser @p -SecretEnvironmentVariable NONEXISTENT_TEST_SECRET
        $r | Should -BeNullOrEmpty
        Should -Invoke -ModuleName AgentMgmt Get-AmAgentUserCreationPlan -Times 1 -Exactly
        Should -Invoke -ModuleName AgentMgmt Read-AmBlueprintClientSecret -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Get-AmBlueprintGraphToken -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Invoke-AmHttp -Times 0 -Exactly
        (Get-AmCallLog) -join ' ' | Should -Match '\[dry-run\] POST https://graph.microsoft.com/v1.0/users/microsoft.graph.agentUser'
    }
}

Describe 'Agent-user command and UI wiring' {
    It 'uses the resolved child object ID, not its appId, and honors disabled creation and environment-secret options' {
        Mock -ModuleName AgentMgmt Resolve-AmIdentity { [pscustomobject]@{ id = 'child-object-id'; appId = 'child-client-id' } }
        Mock -ModuleName AgentMgmt New-AmAgentUser { }
        Invoke-AmCommand -Name agent-user-new -Options @{ agent = 'child-client-id'; name = 'Lab User'; alias = 'labuser'; upn = 'labuser@contoso.com'; 'secret-env' = 'BLUEPRINT_SECRET'; disabled = $true }
        Should -Invoke -ModuleName AgentMgmt New-AmAgentUser -ParameterFilter {
            $IdentityId -eq 'child-object-id' -and $Name -eq 'Lab User' -and $MailNickname -eq 'labuser' -and
            $UserPrincipalName -eq 'labuser@contoso.com' -and $SecretEnvironmentVariable -eq 'BLUEPRINT_SECRET' -and -not $Enabled
        }
    }

    It 'does not request credentials or create a user after interactive cancellation' {
        Mock -ModuleName AgentMgmt Write-AmHeader { }
        Mock -ModuleName AgentMgmt Write-AmKv { }
        Mock -ModuleName AgentMgmt Write-AmLine { }
        Mock -ModuleName AgentMgmt Read-AmLine { 'unused' }
        Mock -ModuleName AgentMgmt Confirm-AmYesNo { $false }
        Mock -ModuleName AgentMgmt New-AmAgentUser { throw 'Must not create after cancellation' }
        Invoke-AmNewAgentUserUi -Agent ([pscustomobject]@{ id = 'child-object-id'; displayName = 'Child'; agentIdentityBlueprintId = 'blueprint-client-id' })
        Should -Invoke -ModuleName AgentMgmt New-AmAgentUser -Times 0 -Exactly
    }

    It 'reads environment credentials as SecureString and fails explicitly for an empty variable' {
        $variable = 'AGENTMGMT_TEST_SECRET_' + [guid]::NewGuid().ToString('N')
        try {
            [Environment]::SetEnvironmentVariable($variable, 'fixture-secret')
            $secret = Read-AmBlueprintClientSecret -EnvironmentVariable $variable
            try {
                $secret | Should -BeOfType ([Security.SecureString])
                $secret.Length | Should -Be 14
            } finally { $secret.Dispose() }
            [Environment]::SetEnvironmentVariable($variable, $null)
            { Read-AmBlueprintClientSecret -EnvironmentVariable $variable } | Should -Throw '*missing or empty*'
        } finally { [Environment]::SetEnvironmentVariable($variable, $null) }
    }
}
