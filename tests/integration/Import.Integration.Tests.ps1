#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    End-to-end test of an import script against a mocked Microsoft Graph served by Dev Proxy
    (https://aka.ms/devproxy), which also injects throttling (429) and transient (5xx) errors.

    The import script runs unmodified, exactly as HelloID would run it. Only $actionContext is
    provided by this harness. All Graph and login.microsoftonline.com traffic goes through Dev Proxy
    (HTTPS_PROXY), which answers from tests/integration/devproxy/mocks.json: 25 groups, each with
    3 members spread over 2 pages.

    Scenarios (set DEVPROXY_SCENARIO to the one Dev Proxy was started with):
      transient   20% of $batch and pagination calls fail with 429/5xx (devproxyrc.transient.json).
                  The import must still return complete data.
      persistent  every $batch call is throttled (devproxyrc.persistent.json).
                  The import must fail loudly instead of reporting groups without members.
#>

BeforeDiscovery {
    $script:scenario = $env:DEVPROXY_SCENARIO
    $script:skipIntegration = [string]::IsNullOrEmpty($script:scenario)
}

Describe 'groups/importPermission.ps1 against Dev Proxy (<Scenario> errors)' -ForEach @(@{ Scenario = $scenario }) -Skip:$skipIntegration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $script:importScript = Join-Path $repoRoot 'permissions/groups/importPermission.ps1'
        $script:groupCount = 25
        $script:expectedMembers = @('user-1', 'user-2', 'user-3')

        # Self-signed certificate so the connector can build its client assertion like it does in production
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $certificateRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=HelloID-Connector-Tests',
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $certificateRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        $pfxPassword = 'connector-tests'
        $pfxBytes = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxPassword)

        # Picked up by the import script through dynamic scoping, like the HelloID runtime provides it
        $actionContext = [pscustomobject]@{
            Configuration = [pscustomobject]@{
                AppId                      = '11111111-1111-1111-1111-111111111111'
                TenantID                   = '22222222-2222-2222-2222-222222222222'
                AppCertificateBase64String = [System.Convert]::ToBase64String($pfxBytes)
                AppCertificatePassword     = $pfxPassword
            }
        }

        $ErrorActionPreference = 'Continue'
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $records = @(& $importScript 2>&1 3>&1 6>$null)
        $stopwatch.Stop()

        $script:errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $script:warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $script:permissions = @($records | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('PermissionReference') })

        Write-Host "Scenario [$Scenario] finished in $([int]$stopwatch.Elapsed.TotalSeconds)s: $($permissions.Count) permissions, $($warnings.Count) warnings, $($errors.Count) errors"
        foreach ($warning in $warnings) { Write-Host "  WARNING: $($warning.Message)" }
        foreach ($errorRecord in $errors) { Write-Host "  ERROR: $errorRecord" }
    }

    Context 'Transient errors' -Skip:($scenario -ne 'transient') {
        It 'completes without errors' {
            $errors | Should -BeNullOrEmpty
        }

        It 'returns every group (M365 and security)' {
            $permissions.Count | Should -Be ($groupCount * 2)
        }

        It 'returns all members, across both pages, for every group' {
            foreach ($permission in $permissions) {
                @($permission.AccountReferences | Sort-Object) | Should -Be $expectedMembers -Because "$($permission.DisplayName) must not lose members to throttling"
            }
        }
    }

    Context 'Persistent throttling' -Skip:($scenario -ne 'persistent') {
        It 'fails the import instead of silently returning incomplete data' {
            $errors.Count | Should -BeGreaterThan 0 -Because 'HelloID must see that the import failed'
        }

        It 'does not report any group as having no or partial members' {
            foreach ($permission in $permissions) {
                @($permission.AccountReferences | Sort-Object) | Should -Be $expectedMembers
            }
        }
    }
}
