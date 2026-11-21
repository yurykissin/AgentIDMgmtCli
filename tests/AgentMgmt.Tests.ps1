BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../AgentMgmt/AgentMgmt.psd1') -Force
}

Describe 'Graph wrapper' {
    BeforeEach {
        InModuleScope AgentMgmt { $script:State.Cache = @{}; $script:State.DryRun = $false }
        Mock -ModuleName AgentMgmt Get-AmAccessToken { 'tok' }
    }

    It 'follows @odata.nextLink when -All is used' {
        $script:calls = 0
        Mock -ModuleName AgentMgmt Invoke-AmHttp {
            $script:calls++
            if ($Uri -like '*page2*') { [pscustomobject]@{ Status = 200; Content = '{"value":[{"id":"c"}]}' } }
            else { [pscustomobject]@{ Status = 200; Content = '{"value":[{"id":"a"},{"id":"b"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/x?page2"}' } }
        }
        $r = InModuleScope AgentMgmt { @(Invoke-AmGraph -Method GET -All -Path '/x') }
        $r.Count | Should -Be 3
    }

    It 'returns a real empty array (Count 0) when -All finds nothing' {
        Mock -ModuleName AgentMgmt Invoke-AmHttp { [pscustomobject]@{ Status = 200; Content = '{"value":[]}' } }
        $n = InModuleScope AgentMgmt { (@(Invoke-AmGraph -Method GET -All -Path '/x')).Count }
        $n | Should -Be 0
    }

    It 'returns Count 1 for a single result' {
        Mock -ModuleName AgentMgmt Invoke-AmHttp { [pscustomobject]@{ Status = 200; Content = '{"value":[{"id":"a"}]}' } }
        $n = InModuleScope AgentMgmt { $x = @(Invoke-AmGraph -Method GET -All -Path '/x'); "$($x.Count)|$($x[0].id)" }
        $n | Should -Be '1|a'
    }

    It 'turns an HTTP error into AmGraphException with the agent-blocked hint' {
        Mock -ModuleName AgentMgmt Invoke-AmHttp {
            [pscustomobject]@{ Status = 400; Content = '{"error":{"code":"Request_BadRequest","message":"The specified app role cannot be granted to agent identities."}}' }
        }
        $err = InModuleScope AgentMgmt {
            try { Invoke-AmGraph -Method POST -Path '/x' -Body @{ a = 1 } } catch { $_.Exception }
        }
        $err.Status | Should -Be 400
        $err.Hint | Should -Match 'blocked'
    }

    It 'does not send write calls in dry-run mode' {
        Mock -ModuleName AgentMgmt Invoke-AmHttp { throw 'must not be called' }
        InModuleScope AgentMgmt {
            $script:State.DryRun = $true
            $null = Invoke-AmGraph -Method POST -Path '/x' -Body @{ a = 1 } 6>$null
            $script:State.DryRun = $false
        }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmHttp -Times 0
    }

    It 'retries on HTTP 429 and then succeeds' {
        $script:n = 0
        Mock -ModuleName AgentMgmt Start-Sleep { }
        Mock -ModuleName AgentMgmt Invoke-AmHttp {
            $script:n++
            if ($script:n -lt 3) { [pscustomobject]@{ Status = 429; Content = ''; RetryAfter = '1' } }
            else { [pscustomobject]@{ Status = 200; Content = '{"ok":true}' } }
        }
        $r = InModuleScope AgentMgmt { Invoke-AmGraph -Method GET -Path '/x' }
        $r.ok | Should -BeTrue
        $script:n | Should -Be 3
    }
}

Describe 'Propagation retry' {
    It 'retries while a new app is not yet replicated, then succeeds' {
        Mock -ModuleName AgentMgmt Start-Sleep { }
        Mock -ModuleName AgentMgmt Write-Host { }
        $r = InModuleScope AgentMgmt {
            $script:pn = 0
            Invoke-AmWithPropagationRetry {
                $script:pn++
                if ($script:pn -lt 3) { throw 'The appId x of the service principal does not reference a valid application object.' }
                'ok'
            }
        }
        $r | Should -Be 'ok'
    }
    It 'does not retry unrelated errors' {
        Mock -ModuleName AgentMgmt Start-Sleep { }
        { InModuleScope AgentMgmt { Invoke-AmWithPropagationRetry { throw 'Forbidden' } } } | Should -Throw 'Forbidden'
        Should -Invoke -ModuleName AgentMgmt Start-Sleep -Times 0
    }
}

Describe 'Blueprint application permissions' {
    BeforeEach {
        InModuleScope AgentMgmt { $script:State.Cache = @{} }
        Mock -ModuleName AgentMgmt Invoke-AmGraph { [pscustomobject]@{ id = 'bp-obj'; appId = 'bp-app'; displayName = 'bp' } }
        Mock -ModuleName AgentMgmt Get-AmBlueprintPrincipal { [pscustomobject]@{ id = 'princ' } }
        Mock -ModuleName AgentMgmt Get-AmResourceSp {
            [pscustomobject]@{ id = 'g-sp'; appId = '00000003-0000-0000-c000-000000000000'; displayName = 'Microsoft Graph'
                appRoles = @([pscustomobject]@{ id = 'r1'; value = 'User.Read.All'; isEnabled = $true; allowedMemberTypes = @('Application') }) }
        }
        Mock -ModuleName AgentMgmt Add-AmBlueprintRequiredAccess { }
        Mock -ModuleName AgentMgmt Grant-AmAppRole { }
        Mock -ModuleName AgentMgmt Set-AmInheritablePermission { }
        Mock -ModuleName AgentMgmt Get-AmInheritablePermissions { @([pscustomobject]@{ resourceAppId = '00000003-0000-0000-c000-000000000000'; inheritableScopes = [pscustomobject]@{ kind = 'allAllowed' } }) }
    }

    It 'declares the role, assigns it to the blueprint principal and keeps scope inheritance' {
        InModuleScope AgentMgmt { $null = Grant-AmBlueprintAppRole -BlueprintId 'bp-obj' -ResourceAppId '00000003-0000-0000-c000-000000000000' -Roles 'User.Read.All' }
        Should -Invoke -ModuleName AgentMgmt Add-AmBlueprintRequiredAccess -ParameterFilter { $Type -eq 'Role' -and $PermissionId -eq 'r1' }
        Should -Invoke -ModuleName AgentMgmt Grant-AmAppRole -ParameterFilter { $SpId -eq 'princ' -and $RoleName -eq 'User.Read.All' }
        Should -Invoke -ModuleName AgentMgmt Set-AmInheritablePermission -ParameterFilter { $Scopes -eq 'allAllowed' -and $Roles -eq 'allAllowed' }
    }

    It 'refuses a blocked role before calling Graph writes' {
        { InModuleScope AgentMgmt { Grant-AmBlueprintAppRole -BlueprintId 'bp-obj' -ResourceAppId '00000003-0000-0000-c000-000000000000' -Roles 'User.ReadWrite.All' } } | Should -Throw
        Should -Invoke -ModuleName AgentMgmt Grant-AmAppRole -Times 0
    }
}

Describe 'Blueprint provisioning' {
    BeforeEach {
        Mock -ModuleName AgentMgmt Get-AmCurrentUser { [pscustomobject]@{ id = 'me-id' } }
        Mock -ModuleName AgentMgmt Get-AmBlueprintPrincipal { $null }
        Mock -ModuleName AgentMgmt Start-Sleep { }
        Mock -ModuleName AgentMgmt Write-Host { }
        Mock -ModuleName AgentMgmt Write-Warning { }
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            [pscustomobject]@{ id = 'bp-object'; appId = 'bp-client'; displayName = 'Lab Agent Blueprint' }
        }
    }

    It 'retries principal creation on replication lag without creating another blueprint' {
        $script:principalAttempts = 0
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            $script:principalAttempts++
            if ($script:principalAttempts -lt 3) { throw "The appId 'bp-client' of the service principal does not reference a valid application object." }
            [pscustomobject]@{ id = 'principal-object'; appId = 'bp-client' }
        } -ParameterFilter { $Path -eq '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' }
        $r = New-AmBlueprint -Name 'Lab Agent Blueprint'
        $r.Blueprint.id | Should -Be 'bp-object'
        $r.Principal.id | Should -Be 'principal-object'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq '/applications/microsoft.graph.agentIdentityBlueprint' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 3 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' -and $Body.appId -eq 'bp-client' }
        Should -Invoke -ModuleName AgentMgmt Start-Sleep -Times 2 -Exactly
    }

    It 'reuses an existing principal when repairing a blueprint' {
        Mock -ModuleName AgentMgmt Get-AmBlueprintPrincipal { [pscustomobject]@{ id = 'existing-principal'; appId = 'bp-client' } }
        $r = Initialize-AmBlueprintPrincipal -BlueprintAppId 'bp-client'
        $r.id | Should -Be 'existing-principal'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly
    }

    It 'does not retry unrelated errors and reports the already-created blueprint for recovery' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { throw 'Forbidden' } -ParameterFilter { $Path -eq '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' }
        { New-AmBlueprint -Name 'Lab Agent Blueprint' } | Should -Throw 'Forbidden'
        Should -Invoke -ModuleName AgentMgmt Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName AgentMgmt Write-Warning -ParameterFilter { $Message -like '*bp-client*bp-principal*' }
    }

    It 'stops after the bounded propagation retry and never recreates the application' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { throw 'The appId does not reference a valid application object.' } -ParameterFilter { $Path -eq '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' }
        { New-AmBlueprint -Name 'Lab Agent Blueprint' } | Should -Throw '*does not reference a valid application object*'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 8 -Exactly -ParameterFilter { $Path -eq '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Path -eq '/applications/microsoft.graph.agentIdentityBlueprint' }
        Should -Invoke -ModuleName AgentMgmt Start-Sleep -Times 7 -Exactly
    }

    It 'repairs the selected blueprint through the CLI without posting another application' {
        Mock -ModuleName AgentMgmt Resolve-AmBlueprint { [pscustomobject]@{ id = 'bp-object'; appId = 'bp-client' } }
        Mock -ModuleName AgentMgmt Invoke-AmGraph { [pscustomobject]@{ id = 'repaired-principal'; appId = 'bp-client' } }
        $r = Invoke-AmCommand -Name bp-principal -Options @{ blueprint = 'bp-client' }
        $r.id | Should -Be 'repaired-principal'
        Should -Invoke -ModuleName AgentMgmt Resolve-AmBlueprint -ParameterFilter { $Selector -eq 'bp-client' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Path -like '/applications*' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body.appId -eq 'bp-client' }
    }
}

Describe 'Credentials' {
    It 'reads secrets from the plain application route' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            [pscustomobject]@{ passwordCredentials = @([pscustomobject]@{ keyId = 'k1'; displayName = 's1'; hint = 'abc'; endDateTime = '2099-01-01T00:00:00Z' }); keyCredentials = @() }
        }
        $r = InModuleScope AgentMgmt { Get-AmBlueprintCredentials -BlueprintId 'bp1' }
        @($r).Count | Should -Be 1
        $r[0].Name | Should -Be 's1'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter { $Path -like '/applications/bp1?*passwordCredentials*' }
    }
}

Describe 'Blocked-for-agents list' {
    It 'blocks User.ReadWrite.All for application and delegated' {
        InModuleScope AgentMgmt {
            (Test-AmPermissionBlocked -Name 'User.ReadWrite.All' -Type Application).Status | Should -Be 'Blocked'
            (Test-AmPermissionBlocked -Name 'user.readwrite.all' -Type Delegated).Status | Should -Be 'Blocked'
        }
    }
    It 'allows User.ReadUpdate.All and User.Read' {
        InModuleScope AgentMgmt {
            (Test-AmPermissionBlocked -Name 'User.ReadUpdate.All' -Type Application).Status | Should -Be 'Allowed'
            (Test-AmPermissionBlocked -Name 'User.Read' -Type Delegated).Status | Should -Be 'Allowed'
        }
    }
    It 'reports Unclear when the official table shows a dash for that type' {
        InModuleScope AgentMgmt {
            (Test-AmPermissionBlocked -Name 'Application.ReadWrite.All' -Type Delegated).Status | Should -Be 'Unclear'
        }
    }
}

Describe 'Request bodies' {
    BeforeEach {
        InModuleScope AgentMgmt { $script:State.Cache = @{ me = [pscustomobject]@{ id = 'me-id' } } }
    }

    It 'creates an agent identity with the blueprint appId, not the object id' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { [pscustomobject]@{ id = 'new' } }
        InModuleScope AgentMgmt { $null = New-AmIdentity -BlueprintAppId 'bp-app-id' -Name 'a1' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq '/servicePrincipals/microsoft.graph.agentIdentity' -and
            $Body.agentIdentityBlueprintId -eq 'bp-app-id' -and $Body.displayName -eq 'a1' -and
            $Body.'sponsors@odata.bind'[0] -like '*/users/me-id'
        }
    }

    It 'creates a blueprint and then its principal' {
        Mock -ModuleName AgentMgmt Get-AmBlueprintPrincipal { $null }
        Mock -ModuleName AgentMgmt Invoke-AmGraph { [pscustomobject]@{ id = 'o'; appId = 'app1' } }
        InModuleScope AgentMgmt { $null = New-AmBlueprint -Name 'bp' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter { $Path -eq '/applications/microsoft.graph.agentIdentityBlueprint' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter { $Path -eq '/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' -and $Body.appId -eq 'app1' }
    }

    It 'POSTs a new inheritable permission and PATCHes an existing one' {
        Mock -ModuleName AgentMgmt Get-AmInheritablePermissions { @() }
        Mock -ModuleName AgentMgmt Invoke-AmGraph { }
        InModuleScope AgentMgmt { Set-AmInheritablePermission -BlueprintId 'b' -ResourceAppId 'r' -Scopes allAllowed -Roles none }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter {
            $Method -eq 'POST' -and $Path -like '*/b/inheritablePermissions' -and
            $Body.inheritableScopes.kind -eq 'allAllowed' -and $Body.inheritableRoles.kind -eq 'none'
        }
        Mock -ModuleName AgentMgmt Get-AmInheritablePermissions { @([pscustomobject]@{ resourceAppId = 'r' }) }
        InModuleScope AgentMgmt { Set-AmInheritablePermission -BlueprintId 'b' -ResourceAppId 'r' -Scopes none -Roles allAllowed }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter { $Method -eq 'PATCH' -and $Path -like '*/inheritablePermissions/r' }
    }
}

Describe 'Direct application permissions' {
    BeforeEach {
        InModuleScope AgentMgmt { $script:State.Cache = @{} }
        Mock -ModuleName AgentMgmt Get-AmResourceSp {
            [pscustomobject]@{
                id = 'graph-sp'; appId = '00000003-0000-0000-c000-000000000000'; displayName = 'Microsoft Graph'
                appRoles = @([pscustomobject]@{ id = 'role-1'; value = 'User.ReadUpdate.All'; isEnabled = $true; allowedMemberTypes = @('Application') })
                oauth2PermissionScopes = @()
            }
        }
        Mock -ModuleName AgentMgmt Get-AmAppRoleAssignments { @() }
        Mock -ModuleName AgentMgmt Invoke-AmGraph { }
    }

    It 'refuses a blocked permission without calling Graph' {
        { InModuleScope AgentMgmt { Grant-AmAppRole -SpId 'agent' -ResourceAppId '00000003-0000-0000-c000-000000000000' -RoleName 'User.ReadWrite.All' } } | Should -Throw '*blocked*'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0
    }

    It 'assigns an allowed role with the documented body' {
        InModuleScope AgentMgmt { $null = Grant-AmAppRole -SpId 'agent' -ResourceAppId '00000003-0000-0000-c000-000000000000' -RoleName 'User.ReadUpdate.All' }
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq '/servicePrincipals/agent/appRoleAssignments' -and
            $Body.principalId -eq 'agent' -and $Body.resourceId -eq 'graph-sp' -and $Body.appRoleId -eq 'role-1'
        }
    }
}

Describe 'Helpers' {
    It 'renders the signed-in account as text, not a hashtable dump' {
        InModuleScope AgentMgmt {
            $script:State.Account = [pscustomobject]@{ Name = 'A B'; Upn = 'a@b.c'; Oid = 'o'; TenantId = 't'; ClientId = 'c' }
            Get-AmAccountLabel | Should -Be 'A B <a@b.c>'
            $script:State.Account = $null
            Get-AmAccountLabel | Should -Be 'not signed in'
        }
    }
    It 'Select-AmMatch resolves by id, exact name and unique fragment, and rejects ambiguity' {
        InModuleScope AgentMgmt {
            $items = @(
                [pscustomobject]@{ id = '1'; appId = 'a1'; displayName = 'n8n read' },
                [pscustomobject]@{ id = '2'; appId = 'a2'; displayName = 'n8n write' })
            (Select-AmMatch -Items $items -Selector 'a2' -Label 'x').id | Should -Be '2'
            (Select-AmMatch -Items $items -Selector 'n8n write' -Label 'x').id | Should -Be '2'
            (Select-AmMatch -Items $items -Selector 'read' -Label 'x').id | Should -Be '1'
            { Select-AmMatch -Items $items -Selector 'n8n' -Label 'x' } | Should -Throw '*ambiguous*'
            { Select-AmMatch -Items $items -Selector 'zzz' -Label 'x' } | Should -Throw '*No x found*'
        }
    }

    It 'parses --name value options and bare flags' {
        InModuleScope AgentMgmt {
            $o = ConvertTo-AmOptions -Tokens @('--agent', 'my agent', '--yes', '--days', '30')
            $o['agent'] | Should -Be 'my agent'
            $o['yes'] | Should -BeTrue
            $o['days'] | Should -Be '30'
        }
    }

    It 'builds an admin-consent URL like a365 does' {
        Mock -ModuleName AgentMgmt Get-AmResourceSp { [pscustomobject]@{ servicePrincipalNames = @() } }
        $url = InModuleScope AgentMgmt {
            $script:State.TenantId = 'tid'
            New-AmAdminConsentUrl -ClientAppId 'cid' -ResourceAppId $script:GraphAppId -Scopes @('User.Read')
        }
        $url | Should -Match '^https://login.microsoftonline.com/tid/v2.0/adminconsent\?client_id=cid&scope=https%3A%2F%2Fgraph.microsoft.com%2FUser.Read'
    }
}

Describe 'Effective permissions' {
    It 'shows inherited permissions only when the resource is inheritable, plus direct ones' {
        InModuleScope AgentMgmt {
            Mock Invoke-AmGraph { [pscustomobject]@{ id = 'ag'; appId = 'agapp'; displayName = 'writer'; agentIdentityBlueprintId = 'bpapp' } }
            Mock Get-AmDelegatedGrants {
                if ($SpId -eq 'ag') { @() }
                else { @([pscustomobject]@{ Resource = 'Graph'; ResourceAppId = 'g'; Scopes = @('User.Read') }) }
            }
            Mock Get-AmAppRoleAssignments {
                if ($SpId -eq 'ag') { @([pscustomobject]@{ Resource = 'Graph'; ResourceAppId = 'g'; Role = 'User.ReadUpdate.All' }) } else { @() }
            }
            Mock Get-AmBlueprints { @([pscustomobject]@{ id = 'bp'; appId = 'bpapp'; displayName = 'BP' }) }
            Mock Get-AmBlueprintPrincipal { [pscustomobject]@{ id = 'bpsp' } }
            Mock Get-AmInheritablePermissions { @([pscustomobject]@{ resourceAppId = 'g'; inheritableScopes = [pscustomobject]@{ kind = 'allAllowed' }; inheritableRoles = [pscustomobject]@{ kind = 'none' } }) }

            $rows = @(Get-AmEffectivePermissions -IdentityId 'ag')
            ($rows | Where-Object Permission -eq 'User.Read').Source | Should -Match 'Inherited'
            ($rows | Where-Object Permission -eq 'User.ReadUpdate.All').Source | Should -Be 'Direct on agent'

            Mock Get-AmInheritablePermissions { @() }
            @(Get-AmEffectivePermissions -IdentityId 'ag' | Where-Object Permission -eq 'User.Read').Count | Should -Be 0
        }
    }
}

Describe 'Menu rendering' {
    It 'prints grouped sections, items with hints, and an exit row' {
        $text = InModuleScope AgentMgmt {
            $out = Write-AmMenu -ExitText 'Quit' -Sections @(
                @{ Title = 'Manage'; Items = @((New-AmMenuItem '1' 'Rename' 'change the name'), (New-AmMenuItem '2' 'Delete' '' -Danger)) }
            ) 6>&1
            ($out | ForEach-Object { "$_" }) -join "`n"
        }
        $text | Should -Match 'MANAGE'
        $text | Should -Match '1\s+Rename\s+change the name'
        $text | Should -Match '2\s+Delete'
        $text | Should -Match '0\s+Quit'
    }
}
