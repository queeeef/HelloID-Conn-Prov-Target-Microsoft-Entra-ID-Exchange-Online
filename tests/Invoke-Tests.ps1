<#
    .SYNOPSIS
    Runs the Pester test suite (used by CI, also works locally).

    .EXAMPLE
    # Unit tests, no network or tenant needed
    ./tests/Invoke-Tests.ps1

    .EXAMPLE
    # Integration tests, with Dev Proxy running on port 8000 (see tests/README.md)
    $env:DEVPROXY_SCENARIO = 'transient'; $env:HTTPS_PROXY = 'http://127.0.0.1:8000'
    ./tests/Invoke-Tests.ps1 -Suite integration
#>
[CmdletBinding()]
param(
    [ValidateSet('unit', 'integration')]
    [string]
    $Suite = 'unit',

    [string]
    $ResultsPath = (Join-Path $PSScriptRoot "results/$Suite-$($PSVersionTable.PSEdition).xml")
)

$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5.0' } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester) {
    throw 'Pester 5.5.0 or later is required: Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser'
}
Import-Module $pester -Force

$resultsDirectory = Split-Path -Parent $ResultsPath
if (-not (Test-Path $resultsDirectory)) {
    $null = New-Item -ItemType Directory -Path $resultsDirectory
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot $Suite
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'JUnitXml'
$configuration.TestResult.OutputPath = $ResultsPath

Write-Host "Pester $($pester.Version) on PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Invoke-Pester -Configuration $configuration
