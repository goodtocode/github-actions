BeforeAll {
    $script:reader = Join-Path $PSScriptRoot '..\cd\Get-WorkloadDeployment.ps1'
    $script:migrator = Join-Path $PSScriptRoot '..\cd\Invoke-AzureSqlMigration.ps1'
    $script:selector = Join-Path $PSScriptRoot '..\cd\Get-WorkloadSqlCreateMode.ps1'
    $script:passwordProvisioner = Join-Path $PSScriptRoot '..\cd\Set-AzureSqlPasswordUsers.ps1'
    $script:initializer = Join-Path $PSScriptRoot '..\setup\Initialize-Product.ps1'
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
        $selection = '${{ secrets.SQL_ENTRA_ADMIN_GROUP_OBJECT_ID || env.SQL_ENTRA_ADMIN_GROUP_OBJECT_ID }}'
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

    Describe 'SQL creation and ordinary updates' {
        BeforeEach {
            $script:configuration = [pscustomobject]@{ serverName = 'prototype-sql'; server = [pscustomobject]@{ kind = 'EntraOnly'; administratorLogin = 'prototype-admin' } }
            $script:sqlState = @{
                GroupExists = 'true'
                ServerList = '[{"name":"prototype-sql"}]'
                Details = '{"administratorLogin":"prototype-admin","administrators":{"azureADOnlyAuthentication":true}}'
            }
            $state = $script:sqlState
            Mock az -MockWith {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'group') { $state.GroupExists }
                elseif ($args[2] -eq 'list') { $state.ServerList }
                elseif ($args[2] -eq 'show') { $state.Details }
                else { throw 'Unexpected Azure mutation.' }
            }.GetNewClosure()
        }

        It 'selects ordinary updates for matching Entra-only servers' {
            (& $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription) | Should -BeFalse
        }

        It 'selects ordinary updates for matching SQL-auth servers without a creation password' {
            $configuration.server.kind = 'SqlAuth'
            $sqlState.Details = '{"administratorLogin":"prototype-admin","administrators":null}'
            (& $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription) | Should -BeFalse
        }

        It 'selects creation for a missing server or resource group' -ForEach @(
            @{ Group = 'true' }, @{ Group = 'false' }
        ) {
            $sqlState.GroupExists = $Group
            $sqlState.ServerList = '[]'
            (& $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription) | Should -BeTrue
        }

        It 'rejects SQL-auth creation without a password' {
            $configuration.server.kind = 'SqlAuth'
            $sqlState.ServerList = '[]'
            $saved = $env:SQL_ADMIN_PASSWORD
            try {
                $env:SQL_ADMIN_PASSWORD = ''
                { & $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription } | Should -Throw '*SQL_ADMIN_PASSWORD*'
            }
            finally { $env:SQL_ADMIN_PASSWORD = $saved }
        }

        It 'selects SQL-auth creation with an explicitly supplied credential' {
            $configuration.server.kind = 'SqlAuth'
            $sqlState.ServerList = '[]'
            $saved = $env:SQL_ADMIN_PASSWORD
            try {
                $env:SQL_ADMIN_PASSWORD = 'synthetic-example-only'
                (& $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription) | Should -BeTrue
            }
            finally { $env:SQL_ADMIN_PASSWORD = $saved }
        }

        It 'rejects both directions of authentication changes' -ForEach @(
            @{ Kind = 'SqlAuth'; Only = $true }, @{ Kind = 'EntraOnly'; Only = $false }
        ) {
            $configuration.server.kind = $Kind
            $sqlState.Details = @{ administratorLogin = 'prototype-admin'; administrators = @{ azureADOnlyAuthentication = $Only } } | ConvertTo-Json
            { & $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription } | Should -Throw '*never changes authentication modes*'
        }

        It 'rejects immutable SQL administrator login changes' {
            $configuration.server.kind = 'SqlAuth'
            $sqlState.Details = '{"administratorLogin":"different-admin","administrators":null}'
            { & $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription } | Should -Throw '*login is immutable*'
        }

        It 'fails closed instead of treating lookup failures as absent resources' {
            Mock az { $global:LASTEXITCODE = 1 }
            { & $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription } | Should -Throw '*lookup failed*'
        }

        It 'never creates an independently owned server' {
            $configuration.server = [pscustomobject]@{ kind = 'Existing'; resourceGroupName = 'shared-rg' }
            $sqlState.ServerList = '[]'
            { & $selector -SqlConfiguration $configuration -ResourceGroupName prototype-rg -SubscriptionId prototype-subscription } | Should -Throw '*must already exist*'
        }
    }

    It 'parses deployment helpers without errors' {
        foreach ($path in @($reader, $migrator, $selector, $passwordProvisioner, $initializer)) {
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

        It 'uses an explicit SQL migration credential without acquiring an Entra token' {
            $credential = [pscredential]::new('prototype-migrations', (ConvertTo-SecureString 'synthetic-example-only' -AsPlainText -Force))
            & $migrator -ServerHost product.database.windows.net -DatabaseName product -ScriptPath "$TestDrive\migration.sql" -SqlCredential $credential
            Should -Invoke az -Times 0 -Exactly
            Should -Invoke Invoke-Sqlcmd -Times 2 -Exactly -ParameterFilter { $Credential.UserName -eq 'prototype-migrations' -and -not $AccessToken -and $Encrypt -eq 'Mandatory' }
        }
    }

    Describe 'Entra deployment workflow ordering' {
        It 'provisions password users after infrastructure and before migrations without runtime secrets' {
            $iac = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-iac.yml" -Raw
            $app = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-app.yml" -Raw
            $iac.IndexOf('name: Provision SQL-auth database access') | Should -BeGreaterThan $iac.IndexOf('name: Deploy ${{ env.PRODUCT_RG_NAME }}')
            $app.IndexOf('name: Provision SQL-auth database access') | Should -BeGreaterThan $app.IndexOf('name: Read exact infrastructure deployment targets')
            $app.IndexOf('name: Deploy SQL script') | Should -BeGreaterThan $app.IndexOf('name: Provision SQL-auth database access')
            $app | Should -Not -Match 'SQL_RUNTIME_USER|SQL_RUNTIME_PASSWORD'
            foreach ($name in @('SQL_ADMIN_USER', 'SQL_ADMIN_PASSWORD', 'SQL_MIGRATION_USER', 'SQL_MIGRATION_PASSWORD')) {
                $app.Contains('secrets.' + $name) | Should -BeTrue
                $iac.Contains('secrets.' + $name) | Should -BeTrue
            }
        }

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
            $reference = $workflow.IndexOf('name: Select SQL creation or ordinary update')
            $reference | Should -BeGreaterThan $identity
            $reference | Should -BeLessThan $create
            $workflow | Should -Match 'Get-WorkloadSqlCreateMode.ps1'
        }

        It 'deploys the selected authentication policy without mode transition paths' {
            $workflow = Get-Content -LiteralPath "$PSScriptRoot\..\..\workflows\workload-digitalproduct-iac.yml" -Raw
            $workflow | Should -Not -Match 'prepareSqlBootstrap|SQL_ENTRA_CUTOVER_READY|sqlEntraOnlyAuthentication|Resolve-AzureSqlAuthentication'
            $workflow | Should -Match 'sqlCreateServer=\$env:SQL_CREATE_SERVER'
            $workflow | Should -Match 'secrets.SQL_ADMIN_PASSWORD'
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
            $workflow | Should -Not -Match 'variable-substitution|azure/sql-action'
            $workflow | Should -Match 'AzureOpenAI__Endpoint'
            $workflow | Should -Match 'EntraExternalId:Instance'
            $workflow | Should -Match 'EntraExternalId:ValidateAuthority'
        }
    }
}

Describe 'Root setup orchestration' {
    It 'ships a root launcher and optional development helper with the copy bundle' {
        $launcher = Join-Path $PSScriptRoot '..\..\Initialize-Installation.ps1'
        Test-Path $launcher | Should -BeTrue
        Test-Path (Join-Path $PSScriptRoot '..\setup\Initialize-Development.ps1') | Should -BeTrue
        foreach ($path in @($launcher, (Join-Path $PSScriptRoot '..\setup\Initialize-Development.ps1'))) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }
    }

    BeforeEach {
        $script:setupRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($directory in @('src/Presentation.Api', 'src/Presentation.Web', '.azure/scripts', '.github/scripts/cd')) {
            New-Item -ItemType Directory -Path (Join-Path $setupRoot $directory) -Force | Out-Null
        }
        foreach ($file in @('src/Presentation.Api/Presentation.Api.csproj', 'src/Presentation.Web/Presentation.Web.csproj', '.azure/scripts/New-EntraDotnetSolution.ps1', '.github/scripts/cd/New-Github-Azure-Federation.ps1')) {
            Set-Content (Join-Path $setupRoot $file) 'synthetic setup fixture'
        }
        Mock Get-Command { [pscustomobject]@{ Name = 'Available' } } -ParameterFilter { ($Name -join ',') -in @('dotnet', 'git', 'az', 'gh') }
        Mock Read-Host { throw 'Preflight must not prompt.' }
        Mock dotnet { throw 'Preflight must not change projects.' }
    }

    It 'discovers each supported product without changing configuration' -ForEach @(
        @{ Solution = 'Censic.Crucible.slnx'; Product = 'crucible' },
        @{ Solution = 'Censic.Compass.Web.slnx'; Product = 'compass' },
        @{ Solution = 'Goodtocode.AgentFramework.Web.slnx'; Product = 'agent' }
    ) {
        Set-Content (Join-Path $setupRoot $Solution) 'synthetic solution fixture'
        $output = & $initializer -RepositoryRoot $setupRoot -Mode Both -Stage Check 6>&1
        ($output | Out-String) | Should -Match "verified for $Product"
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke dotnet -Times 0 -Exactly
    }

    It 'runs the copied root launcher with the copied helper in a consuming repository' {
        Set-Content (Join-Path $setupRoot 'Goodtocode.AgentFramework.Web.slnx') 'synthetic solution fixture'
        $folder = Join-Path $setupRoot '.github/scripts/setup'
        New-Item -ItemType Directory $folder -Force | Out-Null
        Copy-Item $initializer (Join-Path $folder 'Initialize-Product.ps1')
        $launcher = Join-Path $setupRoot 'Initialize-Installation.ps1'
        Copy-Item (Join-Path $PSScriptRoot '..\..\Initialize-Installation.ps1') $launcher
        $output = & $launcher -Mode Local -Stage Check 6>&1
        ($output | Out-String) | Should -Match 'verified for agent'
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke dotnet -Times 0 -Exactly
    }

    It 'rejects local Complete before prompting or accessing credentials' {
        { & $initializer -RepositoryRoot $setupRoot -Mode Local -Stage Complete } | Should -Throw '*Local mode uses Prepare or Check*'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'does not install missing prerequisites in Check mode' {
        Set-Content (Join-Path $setupRoot 'Censic.Crucible.slnx') 'synthetic solution fixture'
        Mock Get-Command { $null } -ParameterFilter { ($Name -join ',') -eq 'dotnet' }
        { & $initializer -RepositoryRoot $setupRoot -Mode Local -Stage Check -InstallPrerequisites } | Should -Throw '*Install dotnet*'
        Should -Invoke dotnet -Times 0 -Exactly
    }

    It 'reuses a stored private value without prompting or rotating it' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($initializer, [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-PrivateSetting' }, $true)
        $body = $function.Body.Extent.Text
        $readPrivate = [scriptblock]::Create('param($Name, $Values, $Key)' + $body.Substring(1, $body.Length - 2))
        (& $readPrivate 'Synthetic fixture' @{ Existing = 'synthetic-example' } 'Existing') | Should -Be 'synthetic-example'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'verifies deployment before SQL provisioning and scopes state per environment and instance' {
        $source = Get-Content $initializer -Raw
        $source.IndexOf('Get-WorkloadDeployment.ps1') | Should -BeLessThan $source.IndexOf('Set-AzureSqlManagedIdentityUsers.ps1')
        $source | Should -Match 'Setup:\$\{Environment\}:\$\{Instance\}'
        $source | Should -Match 'Existing protection settings were not changed'
        $source | Should -Not -Match 'git (commit|push)|Remove-AzSql|DROP DATABASE'
    }
}

Describe 'Password user provisioning' {
    It 'parses its parameterized provisioning batch with the Microsoft T-SQL parser' {
        Import-Module SqlServer -MinimumVersion 22.0
        $assembly = Get-ChildItem (Get-Module SqlServer).ModuleBase -Filter Microsoft.SqlServer.TransactSql.ScriptDom.dll -Recurse | Select-Object -First 1
        Add-Type -Path $assembly.FullName
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($passwordProvisioner, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $query = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('SET XACT_ABORT ON;') }, $true).Value
        $parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true)
        $sqlErrors = $null
        $reader = [System.IO.StringReader]::new($query)
        [void]$parser.Parse($reader, [ref]$sqlErrors)
        $sqlErrors | Should -BeNullOrEmpty
    }

    It 'rejects shared administrator and migration credentials before accessing resources' {
        $credential = [pscredential]::new('prototype-admin', (ConvertTo-SecureString 'synthetic-example-only' -AsPlainText -Force))
        Mock az { throw 'Azure must not be called.' }
        { & $passwordProvisioner -ServerHost prototype.database.windows.net -DatabaseName prototype -Administrator $credential -Migration $credential } | Should -Throw '*distinct database user*'
        Should -Invoke az -Times 0 -Exactly
    }

    It 'fails closed when runtime credential storage cannot be read' {
        $administrator = [pscredential]::new('prototype-admin', (ConvertTo-SecureString 'synthetic-example-only' -AsPlainText -Force))
        $migration = [pscredential]::new('prototype-migration', (ConvertTo-SecureString 'synthetic-example-only' -AsPlainText -Force))
        Mock az { $global:LASTEXITCODE = 1 }
        { & $passwordProvisioner -ServerHost prototype.database.windows.net -DatabaseName prototype -Administrator $administrator -Migration $migration -ApiAppName prototype-api -ResourceGroupName prototype-rg } | Should -Throw '*No users were changed*'
        Should -Invoke az -Times 1 -Exactly
    }

    It 'rejects conflicting runtime configuration before connecting to SQL' {
        $administrator = [pscredential]::new('prototype-admin', (ConvertTo-SecureString 'synthetic-example-only' -AsPlainText -Force))
        $migration = [pscredential]::new('prototype-migration', (ConvertTo-SecureString 'synthetic-example-only' -AsPlainText -Force))
        Mock az { $global:LASTEXITCODE = 0; '[{"name":"DefaultConnection","connectionString":"Server=other.database.windows.net;Database=other;User Id=other;Password=synthetic-example-only"}]' }
        { & $passwordProvisioner -ServerHost prototype.database.windows.net -DatabaseName prototype -Administrator $administrator -Migration $migration -ApiAppName prototype-api -ResourceGroupName prototype-rg } | Should -Throw '*does not match*'
        Should -Invoke az -Times 1 -Exactly
    }

    It 'binds SQL inputs and restricts grants without storing administrator or migration passwords in the app' {
        $source = Get-Content $passwordProvisioner -Raw
        $source | Should -Match 'command.Parameters.Add'
        $source | Should -Match 'QUOTENAME\(@Name\)'
        $source | Should -Match 'authentication_type <> 2'
        $source | Should -Match "r.name = 'db_ddladmin'"
        $source | Should -Match 'COMMIT TRANSACTION'
        $source | Should -Match 'runtimePassword = \$runtimeConnection.get_Password\(\)'
        $source | Should -Match 'RandomNumberGenerator.*GetBytes\(48\)'
        $source | Should -Match '::add-mask::'
        $source | Should -Not -Match 'ALTER SERVER|ALTER ROLE \[db_owner\]'
        $source | Should -Not -Match 'DefaultConnection=.*(Administrator|Migration)'
    }
}
