# Shared helpers for the dry-run harness scripts.

function New-DryRunConfiguration {
    # A self-signed certificate so the connector builds and signs its client assertion like in production
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=HelloID-Connector-DryRun', $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(2))
    $password = 'connector-dryrun'
    [pscustomobject]@{
        AppId                      = '11111111-1111-1111-1111-111111111111'
        TenantID                   = '22222222-2222-2222-2222-222222222222'
        AppCertificateBase64String = [System.Convert]::ToBase64String($certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
        AppCertificatePassword     = $password
    }
}

function Get-FakeJson {
    param([string] $Uri, [string] $Method = 'GET')
    Invoke-RestMethod -Uri $Uri -Method $Method -Verbose:$false
}

function Get-FakeMembership {
    param([string] $BaseUrl, [string] $GroupId, [string] $UserId)
    Get-FakeJson -Uri "$BaseUrl/_fake/member?group=$GroupId&user=$UserId"
}
