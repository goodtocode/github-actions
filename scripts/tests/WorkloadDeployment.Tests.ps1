BeforeAll {
    $script:reader = Join-Path $PSScriptRoot '..\cd\Get-WorkloadDeployment.ps1'
    $script:migrator = Join-Path $PSScriptRoot '..\cd\Invoke-AzureSqlMigration.ps1'
}

Describe 'Workload deployment targets' {
    BeforeEach {
        $script:outputs = @{
            apiAppName = @{ type = 'String'; value = 'custom-api' }
            webAppName = @{ type = 'String'; value = 'custom-web' }
            apiEndpoint = @{ type = 'String'; value = 'https://actual-api-host.azurewebsites.net' }
            webEndpoint = @{ type = 'String'; value = 'https://actual-web-host.azurewebsites.net' }
            applicationInsightsResourceId = @{ type = 'String'; value = '/subscriptions/test/resourceGroups/monitoring/providers/Microsoft.Insights/components/insights' }
            sqlServerHost = @{ type = 'String'; value = 'external.database.windows.net' }
            sqlDatabaseName = @{ type = 'String'; value = 'product-db' }
            sqlServerKind = @{ type = 'String'; value = 'Existing' }
            apiPrincipalId = @{ type = 'String'; value = '11111111-1111-1111-1111-111111111111' }
            apiManagedIdentityClientId = @{ type = 'String'; value = '22222222-2222-2222-2222-222222222222' }
        }
        $outputsForMock = $script:outputs
        Mock az -MockWith { $global:LASTEXITCODE = 0; @{ provisioningState = 'Succeeded'; outputs = $outputsForMock } | ConvertTo-Json -Depth 5 }.GetNewClosure()
    }

    It 'uses exact deployment outputs instead of naming slots' {
        $result = & $reader -ResourceGroupName arbitrary-rg -DeploymentName exact-deployment
        $result.apiAppName | Should -Be 'custom-api'
        $result.apiEndpoint | Should -Be 'https://actual-api-host.azurewebsites.net'
        $result.sqlServerHost | Should -Be 'external.database.windows.net'
        $result.ResourceGroupName | Should -Be 'arbitrary-rg'
        Should -Invoke az -Times 1 -Exactly
    }

    It 'rejects missing contract fields' {
        $script:outputs.Remove('sqlServerHost')
        { & $reader -ResourceGroupName rg -DeploymentName deployment } | Should -Throw '*sqlServerHost*'
    }

    It 'rejects non-HTTPS API endpoints instead of reconstructing them' {
        $script:outputs.apiEndpoint.value = 'http://invalid.example'
        { & $reader -ResourceGroupName rg -DeploymentName deployment } | Should -Throw '*absolute HTTPS*'
    }

    It 'preserves deliberately omitted components' {
        $script:outputs.webAppName.value = ''
        (& $reader -ResourceGroupName rg -DeploymentName deployment).webAppName | Should -Be ''
    }

    It 'rejects multiline output before writing workflow environment values' {
        $script:outputs.apiAppName.value = "api`nINJECTED=value"
        { & $reader -ResourceGroupName rg -DeploymentName deployment } | Should -Throw '*single line*'
    }

    It 'fails explicitly when the deployment cannot be read' {
        Mock az { $global:LASTEXITCODE = 1 }
        { & $reader -ResourceGroupName rg -DeploymentName deployment } | Should -Throw '*Deploy infrastructure first*'
    }

    It 'rejects failed or unfinished infrastructure before consuming outputs' {
        Mock az { $global:LASTEXITCODE = 0; '{"provisioningState":"Failed","outputs":{}}' }
        { & $reader -ResourceGroupName rg -DeploymentName deployment } | Should -Throw '*has not succeeded*'
    }
}

Describe 'Deployment scripts' {
    It 'uses YAML or secret SQL inputs without GitHub Variables dependencies' {
        $iac = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-iac.yml" -Raw
        $app = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-app.yml" -Raw
        $selection = '${{ env.SQL_ENTRA_ADMIN_GROUP_OBJECT_ID || secrets.SQL_ENTRA_ADMIN_GROUP_OBJECT_ID }}'
        ([regex]::Matches($iac, [regex]::Escape($selection))).Count | Should -Be 4
        $iac | Should -Not -Match '\$\{\{\s*vars\.'
        $app | Should -Not -Match '\$\{\{\s*vars\.'
    }

    It 'rejects missing migrations before acquiring a token' {
        Mock az { throw 'Azure must not be called for a missing file.' }
        { & $migrator -ServerHost product.database.windows.net -DatabaseName product -ScriptPath "$TestDrive\missing.sql" } |
            Should -Throw '*does not exist*'
        Should -Invoke az -Times 0 -Exactly
    }

    Describe 'Referenced SQL server policy validation' {
        BeforeAll {
            $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-iac.yml" -Raw
            $step = [regex]::Match($workflow, '(?s)      - name: Validate referenced SQL authentication.*?        run: \|\r?\n(.*?)(?=\r?\n      - name:)')
            if (-not $step.Success) { throw 'Referenced SQL policy validation step is missing.' }
            $script:referenceCheck = [scriptblock]::Create(($step.Groups[1].Value -replace '(?m)^          ', ''))
        }

        It 'accepts only Entra-only references and fails closed on lookup errors' -ForEach @(
            @{ State = 'true'; ExitCode = 0; Accepted = $true },
            @{ State = 'false'; ExitCode = 0; Accepted = $false },
            @{ State = ''; ExitCode = 0; Accepted = $false },
            @{ State = ''; ExitCode = 1; Accepted = $false }
        ) {
            $testState = $State
            $testExit = $ExitCode
            Mock az -MockWith {
                if ($args[0] -eq 'bicep') {
                    $global:LASTEXITCODE = 0
                    @{ parametersJson = (@{ parameters = @{ sql = @{ value = @{
                        serverName = 'external-sql'
                        server = @{ kind = 'Existing'; resourceGroupName = 'external-rg'; subscriptionId = '11111111-1111-1111-1111-111111111111' }
                    } } } } | ConvertTo-Json -Depth 7) } | ConvertTo-Json
                }
                else {
                    $global:LASTEXITCODE = $testExit
                    $testState
                }
            }.GetNewClosure()
            if ($Accepted) { { & $referenceCheck } | Should -Not -Throw }
            else { { & $referenceCheck } | Should -Throw '*must already enforce Entra-only*' }
            Should -Invoke az -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -eq 'sql server ad-only-auth get --resource-group external-rg --name external-sql --subscription 11111111-1111-1111-1111-111111111111 --query azureADOnlyAuthentication --output tsv'
            }
        }

        It 'does not query or change server authentication for an owned server' {
            Mock az {
                $global:LASTEXITCODE = 0
                '{"parametersJson":"{\"parameters\":{\"sql\":{\"value\":{\"server\":{\"kind\":\"EntraOnly\"}}}}}"}'
            }
            & $referenceCheck
            Should -Invoke az -Times 1 -Exactly
        }
    }

    It 'parses deployment helpers without errors' {
        foreach ($path in @($reader, $migrator)) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }
    }

    Describe 'Migration execution' {
        BeforeAll {
            Import-Module SqlServer -MinimumVersion 22.0
        }

        BeforeEach {
            Set-Content -LiteralPath "$TestDrive\migration.sql" -Value 'SELECT 1;'
            Mock az { $global:LASTEXITCODE = 0; '{"accessToken":"synthetic-test-token"}' }
            Mock Invoke-Sqlcmd {}
        }

        It 'checks migration privileges before applying the file with encrypted token authentication' {
            & $migrator -ServerHost product.database.windows.net -DatabaseName product -ScriptPath "$TestDrive\migration.sql"
            Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
                $Query -like "*db_owner*db_ddladmin*" -and $AccessToken -eq 'synthetic-test-token' -and $Encrypt -eq 'Mandatory' -and $AbortOnError
            }
            Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
                $InputFile -eq "$TestDrive\migration.sql" -and $QueryTimeout -eq 600 -and $AccessToken -eq 'synthetic-test-token'
            }
        }

        It 'does not apply a migration when SQL rejects the principal' {
            Mock Invoke-Sqlcmd { throw 'Migration principal is not authorized.' } -ParameterFilter { $Query }
            { & $migrator -ServerHost product.database.windows.net -DatabaseName product -ScriptPath "$TestDrive\migration.sql" } |
                Should -Throw '*not authorized*'
            Should -Invoke Invoke-Sqlcmd -Times 0 -Exactly -ParameterFilter { $InputFile }
        }
    }

    Describe 'Entra deployment workflow ordering' {
        It 'configures application settings and database access before deploying binaries' {
            $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-app.yml" -Raw
            foreach ($component in @('API', 'WEB')) {
                $settings = $workflow.IndexOf('name: ${{ env.AZURE_' + $component + 'APP_NAME }} app settings')
                $deploy = $workflow.IndexOf('name: Deploy ${{ env.AZURE_' + $component + 'APP_NAME }}')
                $settings | Should -BeGreaterOrEqual 0
                $deploy | Should -BeGreaterThan $settings
            }
            $connection = $workflow.IndexOf('name: ${{ env.AZURE_APIAPP_NAME }} connection strings')
            $migration = $workflow.IndexOf('name: Deploy SQL script')
            $migration | Should -BeGreaterOrEqual 0
            $connection | Should -BeGreaterThan $migration
            $workflow.IndexOf('name: Deploy ${{ env.AZURE_APIAPP_NAME }}') | Should -BeGreaterThan $connection
        }

        It 'compiles and checks identity inputs before mutating Azure resources' {
            $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-iac.yml" -Raw
            $compile = $workflow.IndexOf('name: Compile workload contract and parameters')
            $identity = $workflow.IndexOf('name: Check Entra-only SQL administrator inputs')
            $create = $workflow.IndexOf('name: Create ${{ env.PRODUCT_RG_NAME }}')
            $compile | Should -BeGreaterOrEqual 0
            $identity | Should -BeGreaterThan $compile
            $create | Should -BeGreaterThan $identity
            $workflow | Should -Match "name: `"Az CLI login`"\r?\n\s+if: github.event_name != 'pull_request'"
            $reference = $workflow.IndexOf('name: Validate referenced SQL authentication')
            $reference | Should -BeGreaterThan $identity
            $reference | Should -BeLessThan $create
            $workflow | Should -Match "Referenced SQL server must already enforce Entra-only"
        }

        It 'deploys the final authentication policy without transition inputs or credential paths' {
            $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-iac.yml" -Raw
            $workflow | Should -Not -Match 'prepareSqlBootstrap|SQL_ENTRA_CUTOVER_READY|sqlEntraOnlyAuthentication|Resolve-AzureSqlAuthentication|SQL_ADMIN_PASSWORD|SQL_ADMIN_USER'
            $workflow | Should -Not -Match 'azureADOnlyAuthentication=false'
        }

        It 'serializes resource and application mutations for each environment' {
            foreach ($file in @('workload-digitalproduct-app.yml', 'workload-digitalproduct-iac.yml')) {
                $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\$file" -Raw
                $workflow | Should -Match 'group: workload-deployment-\$\{\{ matrix.environment \}\}'
                $workflow | Should -Match 'cancel-in-progress: false'
            }
        }

        It 'keeps artifacts environment-neutral and remaining authentication configuration explicit' {
            $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-app.yml" -Raw
            $workflow | Should -Not -Match 'variable-substitution|SQL_ADMIN_PASSWORD|SQL_ADMIN_USER|azure/sql-action'
            $workflow | Should -Match 'AzureOpenAI__Endpoint'
            $workflow | Should -Match 'EntraExternalId:Instance'
            $workflow | Should -Match 'EntraExternalId:ValidateAuthority'
        }
    }
}
