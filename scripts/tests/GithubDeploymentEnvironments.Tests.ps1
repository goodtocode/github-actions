BeforeAll {
    $script:helper = Join-Path $PSScriptRoot '..\repo\Set-GithubDeploymentEnvironments.ps1'
    function gh {
        [CmdletBinding(PositionalBinding = $false)]
        param(
            [Parameter(ValueFromPipeline)][object]$PipelineInput,
            [Parameter(ValueFromRemainingArguments)][string[]]$CommandArgs
        )
        process {
            $global:LASTEXITCODE = 0
            if ($CommandArgs[1] -eq 'repos/example/project') {
                return (@{ private = $global:GitHubEnvironmentTest.privateRepository; owner = @{ type = 'Organization' } } | ConvertTo-Json -Compress)
            }
            if ($CommandArgs[1] -eq 'orgs/example') {
                return (@{ plan = @{ name = $global:GitHubEnvironmentTest.plan } } | ConvertTo-Json -Compress)
            }
            if ($CommandArgs[1] -eq 'user') {
                return '{"id":42,"login":"operator"}'
            }
            if ($CommandArgs[1] -eq 'repos/example/project/environments?per_page=100') {
                if ($global:GitHubEnvironmentTest.failList) { $global:LASTEXITCODE = 1; return 'lookup failed' }
                return (ConvertTo-Json -InputObject @(@{ environments = $global:GitHubEnvironmentTest.environments }) -Depth 10 -Compress)
            }
            if ($CommandArgs[1] -eq '--method' -and $CommandArgs[2] -eq 'PUT') {
                $global:GitHubEnvironmentTest.puts += ,@($CommandArgs)
                if ($CommandArgs[3] -like '*/production') {
                    $global:GitHubEnvironmentTest.productionBody = $PipelineInput
                    if ($global:GitHubEnvironmentTest.failProduction) { $global:LASTEXITCODE = 1; return 'update failed' }
                    $body = $PipelineInput | ConvertFrom-Json
                    $rules = @()
                    if (-not $global:GitHubEnvironmentTest.omitReviewer) {
                        $rules += @{ type = 'required_reviewers'; reviewers = @(@{ type = 'User'; reviewer = @{ id = 42 } }) }
                    }
                    if ($body.PSObject.Properties['wait_timer']) { $rules += @{ type = 'wait_timer'; wait_timer = $body.wait_timer } }
                    $policy = if ($body.PSObject.Properties['deployment_branch_policy']) { $body.deployment_branch_policy } else { $null }
                    return (@{ name = 'production'; protection_rules = $rules; deployment_branch_policy = $policy; can_admins_bypass = $true } | ConvertTo-Json -Depth 10 -Compress)
                }
                return '{"name":"development"}'
            }
            throw "Unexpected gh invocation: $($CommandArgs -join ' ')"
        }
    }
}

Describe 'GitHub deployment environments' {
    BeforeEach {
        $global:GitHubEnvironmentTest = @{
            privateRepository = $false
            plan = 'enterprise'
            environments = @()
            puts = @()
            failList = $false
            failProduction = $false
            omitReviewer = $false
            productionBody = ''
        }
    }

    AfterEach {
        Remove-Variable -Name GitHubEnvironmentTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'creates development and production with the authenticated reviewer' {
        & $helper -Owner example -Repo project
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 2
        $body = $global:GitHubEnvironmentTest.productionBody | ConvertFrom-Json
        $body.reviewers[0].id | Should -Be 42
        $body.reviewers[0].type | Should -Be 'User'
        $body.prevent_self_review | Should -BeFalse
    }

    It 'does not modify existing protected environments on rerun' {
        $global:GitHubEnvironmentTest.environments = @(
            @{ name = 'development'; protection_rules = @(); deployment_branch_policy = $null },
            @{ name = 'production'; protection_rules = @(@{ type = 'required_reviewers'; reviewers = @(@{ type = 'Team'; reviewer = @{ id = 100 } }) }); deployment_branch_policy = $null }
        )
        & $helper -Owner example -Repo project
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 0
    }

    It 'preserves existing wait timer and branch policy when adding approval' {
        $global:GitHubEnvironmentTest.environments = @(
            @{ name = 'development'; protection_rules = @(); deployment_branch_policy = $null },
            @{ name = 'production'; protection_rules = @(@{ type = 'wait_timer'; wait_timer = 15 }); deployment_branch_policy = @{ protected_branches = $true; custom_branch_policies = $false }; can_admins_bypass = $true }
        )
        & $helper -Owner example -Repo project
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 1
        $body = $global:GitHubEnvironmentTest.productionBody | ConvertFrom-Json
        $body.wait_timer | Should -Be 15
        $body.deployment_branch_policy.protected_branches | Should -BeTrue
    }

    It 'fails without modifying environments when private reviewers are unsupported' {
        $global:GitHubEnvironmentTest.privateRepository = $true
        $global:GitHubEnvironmentTest.plan = 'team'
        { & $helper -Owner example -Repo project } | Should -Throw '*GitHub Enterprise plan*'
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 0
    }

    It 'configures approvals for an eligible private repository' {
        $global:GitHubEnvironmentTest.privateRepository = $true
        & $helper -Owner example -Repo project
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 2
    }

    It 'fails when GitHub rejects or does not confirm the production reviewer' -ForEach @(
        @{ Fail = $true; Omit = $false; Message = '*Cannot configure required production reviewers*' },
        @{ Fail = $false; Omit = $true; Message = '*did not confirm the required production reviewer*' }
    ) {
        $global:GitHubEnvironmentTest.failProduction = $Fail
        $global:GitHubEnvironmentTest.omitReviewer = $Omit
        { & $helper -Owner example -Repo project } | Should -Throw $Message
    }

    It 'does not create environments after a lookup failure' {
        $global:GitHubEnvironmentTest.failList = $true
        { & $helper -Owner example -Repo project } | Should -Throw '*Cannot list GitHub environments*'
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 0
    }

    It 'does not alter unsupported production protection rules' {
        $global:GitHubEnvironmentTest.environments = @(
            @{ name = 'development'; protection_rules = @(); deployment_branch_policy = $null },
            @{ name = 'production'; protection_rules = @(@{ type = 'custom_deployment_protection_rule' }); deployment_branch_policy = $null }
        )
        { & $helper -Owner example -Repo project } | Should -Throw '*additional protection rules*'
        $global:GitHubEnvironmentTest.puts.Count | Should -Be 0
    }
}
