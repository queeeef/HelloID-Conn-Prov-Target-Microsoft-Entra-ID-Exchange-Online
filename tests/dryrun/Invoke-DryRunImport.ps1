<#
    .SYNOPSIS
    Runs an import script unmodified against the fake Graph tenant and saves what it reported,
    so it can be compared with the tenant's real state (/_fake/snapshot).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScriptPath,
    [Parameter(Mandatory)] [string] $OutFile,
    [string] $Label = 'import'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DryRunCommon.ps1')

$actionContext = [pscustomobject]@{ Configuration = (New-DryRunConfiguration); DryRun = $false }

$ErrorActionPreference = 'Continue'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$records = @(& $ScriptPath 2>&1 3>&1 6>$null)
$stopwatch.Stop()
$ErrorActionPreference = 'Stop'

$permissions = @{}
$duplicates = 0
foreach ($record in $records) {
    if ($record -is [hashtable] -and $record.ContainsKey('PermissionReference')) {
        $id = $record.PermissionReference.Id
        if ($permissions.ContainsKey($id)) { $duplicates++ }
        $permissions[$id] = @($record.AccountReferences | Sort-Object)
    }
}
$errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
$warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })

[ordered]@{
    label             = $Label
    script            = $ScriptPath
    seconds           = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    permissionCount   = $permissions.Count
    duplicates        = $duplicates
    errors            = $errors
    warningCount      = $warnings.Count
    warningSamples    = @($warnings | Select-Object -First 5)
    permissions       = $permissions
} | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $OutFile -Encoding utf8NoBOM

Write-Host ("[{0}] {1} groups with members reported in {2:N1}s, {3} warnings, {4} errors" -f $Label, $permissions.Count, $stopwatch.Elapsed.TotalSeconds, $warnings.Count, $errors.Count)
