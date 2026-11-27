BeforeAll {
    . (Join-Path $PSScriptRoot '..\setup\Setup-Session.ps1')
}

Describe 'Setup session' {
    BeforeEach {
        $script:fixtureStore = @{ 'Unrelated:Legacy' = 'synthetic-legacy' }
        Mock Read-SetupStore { return $script:fixtureStore.Clone() }
        Mock Write-SetupStore {
            param($Values)
            foreach ($key in $Values.Keys) { $script:fixtureStore[$key] = $Values[$key] }
        }

        Mock dotnet {
            if ($args[0] -ne 'user-secrets' -or $args[1] -ne 'remove') { throw 'Unexpected secret-store operation.' }
            [void]$script:fixtureStore.Remove([string]$args[2])
            $global:LASTEXITCODE = 0
        }
    }

    It 'resumes a failed or paused setup and removes only its own session entries on completion' {
        Start-SetupSession 'synthetic-root' 'Contoso' 'Product' 'development' '101'
        $session = $script:setupSessionId
        Save-SetupValue 'WorkloadTenantId' 'synthetic-tenant'
        Save-SetupValue 'Credential:synthetic-id' 'synthetic-secret'

        Start-SetupSession 'synthetic-root' 'Contoso' 'Product' 'development' '101'
        $script:setupSessionId | Should -Be $session
        $script:setupState['WorkloadTenantId'] | Should -Be 'synthetic-tenant'
        $script:setupState['Credential:synthetic-id'] | Should -Be 'synthetic-secret'

        Complete-SetupSession
        $script:fixtureStore.Count | Should -Be 1
        $script:fixtureStore['Unrelated:Legacy'] | Should -Be 'synthetic-legacy'
        Should -Invoke dotnet -Times 3 -Exactly
    }

    It 'does not remove state belonging to a different active session' {
        Start-SetupSession 'synthetic-root' 'Contoso' 'Product' 'development' '101'
        Save-SetupValue 'WorkloadTenantId' 'synthetic-tenant'
        $script:fixtureStore['ActiveSession'] = [guid]::NewGuid().ToString('N')
        { Complete-SetupSession } | Should -Throw '*active setup session changed*'
        Should -Invoke dotnet -Times 0 -Exactly
    }

    It 'preserves retry state when saving fails' {
        Start-SetupSession 'synthetic-root' 'Contoso' 'Product' 'development' '101'
        Mock Write-SetupStore { throw 'synthetic storage failure' }
        { Save-SetupValue 'WorkloadTenantId' 'synthetic-tenant' } | Should -Throw '*synthetic storage failure*'
        $script:fixtureStore['ActiveSession'] | Should -Be $script:setupSessionId
        Should -Invoke dotnet -Times 0 -Exactly
    }
}
