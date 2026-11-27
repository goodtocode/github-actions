function Read-SetupStore {
    $root = if ($IsWindows) {
        Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft/UserSecrets'
    }
    else {
        Join-Path $HOME '.microsoft/usersecrets'
    }
    $path = Join-Path (Join-Path $root $script:setupStoreId) 'secrets.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
}

function Write-SetupStore([hashtable]$Values) {
    $Values | ConvertTo-Json -Compress -Depth 10 | dotnet user-secrets set --id $script:setupStoreId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to save setup state. Values were not printed.' }
}

function Start-SetupSession([string]$RepositoryRoot, [string]$CompanyName, [string]$ProductName, [string]$Environment, [string]$Instance) {
    $identity = "$RepositoryRoot|$CompanyName|$ProductName|$Environment|$Instance"
    if ($IsWindows) { $identity = $identity.ToLowerInvariant() }
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $script:setupStoreId = "product-setup-$hash"
    $stored = Read-SetupStore
    $active = [string]$stored['ActiveSession']
    if ($active -and $active -notmatch '^[0-9a-f]{32}$') { throw 'The setup session identifier is invalid.' }
    if (-not $active) {
        $active = [guid]::NewGuid().ToString('N')
        Write-SetupStore @{ 'ActiveSession' = $active }
    }
    $script:setupSessionId = $active
    $script:setupState = @{}
    $prefix = "Session:${active}:"
    foreach ($key in $stored.Keys) {
        if ($key.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $script:setupState[$key.Substring($prefix.Length)] = $stored[$key]
        }
    }
}

function Save-SetupValue([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name cannot be empty." }
    if ($script:setupState[$Name] -ceq $Value) { return }
    Write-SetupStore @{ "Session:$($script:setupSessionId):$Name" = $Value }
    $script:setupState[$Name] = $Value
}

function Complete-SetupSession {
    $stored = Read-SetupStore
    if ($stored['ActiveSession'] -cne $script:setupSessionId) { throw 'The active setup session changed; no setup state was removed.' }
    $prefix = "Session:$($script:setupSessionId):"
    foreach ($key in @($stored.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })) {
        dotnet user-secrets remove $key --id $script:setupStoreId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clean this setup session. Remaining state was preserved for retry.' }
    }
    dotnet user-secrets remove 'ActiveSession' --id $script:setupStoreId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to complete setup session cleanup.' }
}
