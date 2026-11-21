BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../AgentMgmt/AgentMgmt.psd1') -Force
}

Describe 'Migration candidate selection' {
    BeforeEach {
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            param($Path)
            if ($Path -like '/applications`?*') {
                [pscustomobject]@{ id = 'app-object'; appId = 'app-client'; displayName = 'Customer Agent' }
                [pscustomobject]@{ id = 'bp-object'; appId = 'bp-client'; displayName = 'Blueprint'; '@odata.type' = '#microsoft.graph.agentIdentityBlueprint' }
                [pscustomobject]@{ id = 'no-sp-object'; appId = 'no-sp-client'; displayName = 'Unprovisioned' }
            } elseif ($Path -like '/servicePrincipals`?*') {
                [pscustomobject]@{ id = 'sp-object'; appId = 'app-client'; displayName = 'Customer Agent SP'; servicePrincipalType = 'Application' }
                [pscustomobject]@{ id = 'foreign-object'; appId = 'foreign-client'; displayName = 'Customer Agent'; servicePrincipalType = 'Application' }
                [pscustomobject]@{ id = 'mi-object'; appId = 'mi-client'; displayName = 'Managed'; servicePrincipalType = 'ManagedIdentity' }
                [pscustomobject]@{ id = 'agent-object'; appId = 'agent-client'; displayName = 'Real agent'; servicePrincipalType = 'Application'; '@odata.type' = '#microsoft.graph.agentIdentity' }
                [pscustomobject]@{ id = 'bp-sp'; appId = 'bp-client'; displayName = 'Blueprint SP'; servicePrincipalType = 'Application'; '@odata.type' = '#microsoft.graph.agentIdentityBlueprintPrincipal' }
            } else { throw "Unexpected request: $Path" }
        }
    }

    It 'pairs objects by appId and includes unpaired apps, not agent or managed identities' {
        $items = @(Get-AmMigrationCandidates)
        $items.Count | Should -Be 3
        $paired = $items | Where-Object appId -EQ 'app-client'
        $paired.applicationObjectId | Should -Be 'app-object'
        $paired.servicePrincipalObjectId | Should -Be 'sp-object'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 2 -Exactly -ParameterFilter { $Method -eq 'GET' -and $All }
    }

    It 'accepts either object ID or client ID and refuses duplicate names' {
        (Resolve-AmMigrationCandidate -Selector 'sp-object').applicationObjectId | Should -Be 'app-object'
        (Resolve-AmMigrationCandidate -Selector 'app-object').appId | Should -Be 'app-client'
        (Resolve-AmMigrationCandidate -Selector 'foreign-client').servicePrincipalObjectId | Should -Be 'foreign-object'
        { Resolve-AmMigrationCandidate -Selector 'Customer Agent' } | Should -Throw '*ambiguous*'
    }
}

Describe 'Read-only migration inventory' {
    BeforeEach {
        $script:exportRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope AgentMgmt {
            $script:State.Cache = @{}
            $script:State.TenantId = 'tenant-one'
            $script:migrationCandidate = [pscustomobject]@{
                displayName = 'Customer/Agent:*?'
                appId = '11111111-1111-1111-1111-111111111111'
                applicationObjectId = 'app-object'; servicePrincipalObjectId = 'sp-object'
            }
        }
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            param($Method, $Path)
            if ($Method -ne 'GET') { throw 'Tenant writes are forbidden in an export.' }
            switch -Wildcard ($Path) {
                '/applications/app-object`?*' {
                    [pscustomobject]@{
                        id = 'app-object'; appId = '11111111-1111-1111-1111-111111111111'; displayName = 'Customer/Agent:*?'
                        requiredResourceAccess = @(
                            [pscustomobject]@{ resourceAppId = '00000003-0000-0000-c000-000000000000'; resourceAccess = @(
                                [pscustomobject]@{ id = 'graph-blocked'; type = 'Role' },
                                [pscustomobject]@{ id = 'configured-only'; type = 'Scope' }
                            ) },
                            [pscustomobject]@{ resourceAppId = 'custom-api'; resourceAccess = @([pscustomobject]@{ id = 'custom-role'; type = 'Role' }) }
                        )
                        passwordCredentials = @([pscustomobject]@{ keyId = 'secret-id'; displayName = 'old secret'; endDateTime = '2030-01-01'; secretText = 'DO-NOT-EXPORT-SECRET'; hint = 'DO-NOT-EXPORT-HINT' })
                        keyCredentials = @([pscustomobject]@{ keyId = 'cert-id'; type = 'AsymmetricX509Cert'; key = 'DO-NOT-EXPORT-KEY' })
                        web = [pscustomobject]@{ redirectUris = @('https://localhost/callback'); extra = 'DO-NOT-EXPORT-WEB' }
                    }
                }
                '/servicePrincipals/sp-object`?*' {
                    [pscustomobject]@{ id = 'sp-object'; appId = '11111111-1111-1111-1111-111111111111'; servicePrincipalType = 'Application'; accountEnabled = $true }
                }
                '*/owners?*' { [pscustomobject]@{ id = 'owner-id'; displayName = 'Owner'; '@odata.type' = '#microsoft.graph.user'; extra = 'DO-NOT-EXPORT-OWNER' } }
                '*/federatedIdentityCredentials?*' {
                    [pscustomobject]@{ id = 'fic-id'; name = 'runtime'; issuer = 'https://issuer.example'; subject = 'workload'; audiences = @('api://AzureADTokenExchange'); extra = 'DO-NOT-EXPORT-FIC' }
                }
                '*/appRoleAssignments' {
                    [pscustomobject]@{ id = 'assignment'; principalId = 'sp-object'; resourceId = 'graph-sp'; appRoleId = 'granted-only' }
                }
                '*/oauth2PermissionGrants' {
                    [pscustomobject]@{ id = 'user-grant'; clientId = 'sp-object'; resourceId = 'graph-sp'; consentType = 'Principal'; principalId = 'user-id'; scope = 'User.Read  Unknown.Scope' }
                    [pscustomobject]@{ id = 'admin-grant'; clientId = 'sp-object'; resourceId = 'graph-sp'; consentType = 'AllPrincipals'; principalId = $null; scope = 'User.Read' }
                }
                default { throw "Unexpected request: $Path" }
            }
        }
        Mock -ModuleName AgentMgmt Get-AmResourceSp {
            param($ResourceAppId)
            if ($ResourceAppId -eq 'custom-api') {
                return [pscustomobject]@{ id = 'custom-sp'; appId = 'custom-api'; displayName = 'Custom API'; appRoles = @([pscustomobject]@{ id = 'custom-role'; value = 'User.ReadWrite.All' }) }
            }
            [pscustomobject]@{
                id = 'graph-sp'; appId = '00000003-0000-0000-c000-000000000000'; displayName = 'Microsoft Graph'
                appRoles = @(
                    [pscustomobject]@{ id = 'graph-blocked'; value = 'User.ReadWrite.All' },
                    [pscustomobject]@{ id = 'granted-only'; value = 'User.Read.All' }
                )
                oauth2PermissionScopes = @(
                    [pscustomobject]@{ id = 'configured-only'; value = 'Mail.Read' },
                    [pscustomobject]@{ id = 'user-read'; value = 'User.Read' }
                )
            }
        }
        Mock -ModuleName AgentMgmt Get-AmResourceSpById {
            [pscustomobject]@{
                id = 'graph-sp'; appId = '00000003-0000-0000-c000-000000000000'; displayName = 'Microsoft Graph'
                appRoles = @([pscustomobject]@{ id = 'granted-only'; value = 'User.Read.All' })
                oauth2PermissionScopes = @([pscustomobject]@{ id = 'user-read'; value = 'User.Read' })
            }
        }
    }

    It 'separates configured and actual grants, resolves all APIs and preserves user versus admin consent' {
        $r = InModuleScope AgentMgmt { Get-AmMigrationInventory -Candidate $script:migrationCandidate }
        $r.permissions.configured.Count | Should -Be 3
        $r.permissions.grantedApplication.Count | Should -Be 1
        $r.permissions.grantedApplication[0].permission.permission | Should -Be 'User.Read.All'
        $r.permissions.configured[0].agentCompatibility | Should -Be 'Blocked'
        $r.permissions.configured[2].agentCompatibility | Should -Be 'NotEvaluated'
        $r.permissions.grantedDelegated.Count | Should -Be 2
        $r.permissions.grantedDelegated[0].principalId | Should -Be 'user-id'
        $r.permissions.grantedDelegated[0].consentType | Should -Be 'Principal'
        $r.permissions.grantedDelegated[0].permissions.Count | Should -Be 2
        $r.permissions.grantedDelegated[1].consentType | Should -Be 'AllPrincipals'
        ($r.warnings -join ' ') | Should -Match 'Blocked.*User.ReadWrite.All'
        ($r.warnings -join ' ') | Should -Match 'Unresolved permission definition'
        $r.application.owners[0].id | Should -Be 'owner-id'
        $r.application.federatedIdentityCredentials[0].subject | Should -Be 'workload'
        $r.source.tenantId | Should -Be 'tenant-one'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
    }

    It 'writes parseable JSON under a safe app-name folder and exports metadata, never credential values' {
        $result = InModuleScope AgentMgmt -Parameters @{ Root = $script:exportRoot } {
            param($Root)
            Export-AmMigrationInventory -Candidate $script:migrationCandidate -OutputDirectory $Root
        }
        $result.Path | Should -Match 'Customer_Agent___--11111111-1111-1111-1111-111111111111'
        $json = Get-Content -LiteralPath $result.Path -Raw
        $json | Should -Not -Match 'DO-NOT-EXPORT'
        $r = $json | ConvertFrom-Json
        $r.application.credentials.Count | Should -Be 2
        $r.application.authentication.webRedirectUris[0] | Should -Be 'https://localhost/callback'
        $r.permissions.grantedApplication[0].permission.permissionId | Should -Be 'granted-only'
        $r.schemaVersion | Should -Be '1.0'
    }

    It 'refuses overwrites unless force is explicit and resolves relative output from the PowerShell location' {
        InModuleScope AgentMgmt -Parameters @{ Root = $script:exportRoot } {
            param($Root)
            $null = New-Item -ItemType Directory -Path $Root
            Push-Location $Root
            try {
                $first = Export-AmMigrationInventory -Candidate $script:migrationCandidate -OutputDirectory 'relative'
                $first.Path | Should -BeLike "$Root*"
                { Export-AmMigrationInventory -Candidate $script:migrationCandidate -OutputDirectory 'relative' } | Should -Throw '*already exists*'
                $again = Export-AmMigrationInventory -Candidate $script:migrationCandidate -OutputDirectory 'relative' -Force
                $again.Path | Should -Be $first.Path
            } finally { Pop-Location }
        }
    }

    It 'exports enterprise-app-only sources without claiming home-tenant configuration was read' {
        $r = InModuleScope AgentMgmt {
            $script:migrationCandidate.applicationObjectId = $null
            Get-AmMigrationInventory -Candidate $script:migrationCandidate
        }
        $r.application | Should -BeNullOrEmpty
        $r.permissions.configured.Count | Should -Be 0
        $r.permissions.grantedApplication.Count | Should -Be 1
        ($r.warnings -join ' ') | Should -Match 'No app registration in this tenant'
        Should -Invoke -ModuleName AgentMgmt Invoke-AmGraph -Times 0 -Exactly -ParameterFilter { $Path -like '/applications/*' }
    }

    It 'exports app-registration-only sources without inventing consent' {
        $r = InModuleScope AgentMgmt {
            $script:migrationCandidate.servicePrincipalObjectId = $null
            Get-AmMigrationInventory -Candidate $script:migrationCandidate
        }
        $r.enterpriseApplication | Should -BeNullOrEmpty
        $r.permissions.grantedApplication.Count | Should -Be 0
        $r.permissions.grantedDelegated.Count | Should -Be 0
        $r.permissions.configured.Count | Should -Be 3
        ($r.warnings -join ' ') | Should -Match 'No enterprise application'
    }

    It 'keeps unresolvable resource IDs with a warning instead of losing assignments' {
        Mock -ModuleName AgentMgmt Get-AmResourceSpById {
            InModuleScope AgentMgmt { throw [AmGraphException]::new('missing resource', 404, 'Request_ResourceNotFound', '', 'GET', '/resource') }
        }
        $r = InModuleScope AgentMgmt { Get-AmMigrationInventory -Candidate $script:migrationCandidate }
        $r.permissions.grantedApplication[0].permission.resourceObjectId | Should -Be 'graph-sp'
        $r.permissions.grantedApplication[0].permission.permissionId | Should -Be 'granted-only'
        $r.permissions.grantedApplication[0].permission.definitionResolved | Should -BeFalse
        ($r.warnings -join ' ') | Should -Match 'Resource API not found'
    }

    It 'fails visibly on permission read errors and leaves no success-shaped JSON' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph { throw 'permission read forbidden' } -ParameterFilter { $Path -like '*/appRoleAssignments' }
        InModuleScope AgentMgmt -Parameters @{ Root = $script:exportRoot } {
            param($Root)
            { Export-AmMigrationInventory -Candidate $script:migrationCandidate -OutputDirectory $Root } | Should -Throw '*permission read forbidden*'
        }
        Test-Path -LiteralPath $script:exportRoot | Should -BeFalse
    }

    It 'retains empty collections as JSON arrays and still exports in dry-run mode' {
        Mock -ModuleName AgentMgmt Invoke-AmGraph {
            param($Path)
            if ($Path -like '/applications/app-object`?*') { [pscustomobject]@{ id = 'app-object' } }
            elseif ($Path -like '/servicePrincipals/sp-object`?*') { [pscustomobject]@{ id = 'sp-object'; servicePrincipalType = 'Application' } }
        }
        $result = InModuleScope AgentMgmt -Parameters @{ Root = $script:exportRoot } {
            param($Root)
            $script:State.DryRun = $true
            try { Export-AmMigrationInventory -Candidate $script:migrationCandidate -OutputDirectory $Root }
            finally { $script:State.DryRun = $false }
        }
        $r = Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json
        $r.permissions.configured | Should -HaveCount 0
        $r.permissions.grantedApplication | Should -HaveCount 0
        $r.permissions.grantedDelegated | Should -HaveCount 0
        $r.application.credentials | Should -HaveCount 0
        $r.application.owners | Should -HaveCount 0
        $r.application.authentication.webRedirectUris | Should -HaveCount 0
    }
}

Describe 'Migration export entry points' {
    BeforeEach {
        Mock -ModuleName AgentMgmt Resolve-AmMigrationCandidate { [pscustomobject]@{ displayName = 'Selected app'; appId = 'client' } }
        Mock -ModuleName AgentMgmt Export-AmMigrationInventory { [pscustomobject]@{ Path = '/local/app.json'; Warnings = @('Review dependency') } }
        Mock -ModuleName AgentMgmt Write-Warning { }
    }

    It 'wires the CLI selector, output and force options to the read-only export' {
        Invoke-AmCommand -Name app-export -Options @{ app = 'Selected app'; output = '/local'; force = $true } | Should -Match 'Saved migration inventory'
        Should -Invoke -ModuleName AgentMgmt Resolve-AmMigrationCandidate -ParameterFilter { $Selector -eq 'Selected app' }
        Should -Invoke -ModuleName AgentMgmt Export-AmMigrationInventory -ParameterFilter { $OutputDirectory -eq '/local' -and $Force -and $Candidate.appId -eq 'client' }
        Should -Invoke -ModuleName AgentMgmt Write-Warning -ParameterFilter { $Message -eq 'Review dependency' }
    }

    It 'does not export when the picker is cancelled' {
        Mock -ModuleName AgentMgmt Write-AmHeader { }
        Mock -ModuleName AgentMgmt Write-AmLine { }
        Mock -ModuleName AgentMgmt Read-AmLine { '' }
        Mock -ModuleName AgentMgmt Get-AmMigrationCandidates { [pscustomobject]@{ displayName = 'Selected app'; appId = 'client' } }
        Mock -ModuleName AgentMgmt Read-AmPick { $null }
        Invoke-AmMigrationExportUi
        Should -Invoke -ModuleName AgentMgmt Export-AmMigrationInventory -Times 0 -Exactly
    }
}
