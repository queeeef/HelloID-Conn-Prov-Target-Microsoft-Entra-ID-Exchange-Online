<#
    .SYNOPSIS
    Runs a list of grant/revoke operations through the unmodified connector scripts, as HelloID would,
    against the fake Graph tenant, and records for every operation what the connector reported and what
    actually happened in the tenant.

    Every operation is classified:
      ok                    reported success and the tenant is in the desired state
      silent_failure        reported success, but the tenant is NOT in the desired state   (worst case)
      failed_but_applied    reported failure, but the change was made
      reported_failure      reported failure and nothing changed (visible to the HelloID operator)
      dryrun_wrote          a HelloID DryRun operation changed the tenant                   (must never happen)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OpsFile,
    [Parameter(Mandatory)] [string] $TenantFile,
    [Parameter(Mandatory)] [string] $ResultsFile,
    [Parameter(Mandatory)] [string] $RepoRoot,
    [string] $FakeBaseUrl = 'https://graph.microsoft.com'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DryRunCommon.ps1')

$scripts = @{
    grant  = Join-Path $RepoRoot 'permissions/groups/grantPermission.ps1'
    revoke = Join-Path $RepoRoot 'permissions/groups/revokePermission.ps1'
}
$configuration = New-DryRunConfiguration
$ops = Get-Content -Path $OpsFile -Raw | ConvertFrom-Json

# Shadow state of the memberships this worker owns (workers own disjoint groups), used as the "before" state
$tenant = Get-Content -Path $TenantFile -Raw | ConvertFrom-Json -AsHashtable
$shadow = @{}
foreach ($op in $ops) {
    if (-not $shadow.ContainsKey($op.permissionId)) {
        $set = [System.Collections.Generic.HashSet[string]]::new()
        if ($tenant.members.ContainsKey($op.permissionId)) {
            foreach ($memberId in $tenant.members[$op.permissionId]) { [void]$set.Add($memberId) }
        }
        $shadow[$op.permissionId] = $set
    }
}
$tenant = $null

$writer = [System.IO.StreamWriter]::new($ResultsFile, $false, [System.Text.UTF8Encoding]::new($false))
$stopwatch = [System.Diagnostics.Stopwatch]::new()
$done = 0
$total = @($ops).Count
$started = Get-Date
try {
    foreach ($op in $ops) {
        $actionContext = [pscustomobject]@{
            Configuration         = $configuration
            DryRun                = [bool]$op.dryRun
            PermissionDisplayName = $op.permissionDisplayName
            References            = [pscustomobject]@{
                Account    = $op.account
                Permission = [pscustomobject]@{ Id = $op.permissionId }
            }
        }
        $outputContext = [pscustomobject]@{
            Success   = $false
            AuditLogs = [System.Collections.Generic.List[object]]::new()
        }

        $before = $shadow[$op.permissionId].Contains($op.account)
        $stopwatch.Restart()
        try {
            & $scripts[$op.action] *> $null
            $scriptError = $null
        }
        catch {
            $scriptError = "$_"
        }
        $stopwatch.Stop()

        $probe = Get-FakeMembership -BaseUrl $FakeBaseUrl -GroupId $op.permissionId -UserId $op.account
        $after = [bool]$probe.member
        if ($after) { [void]$shadow[$op.permissionId].Add($op.account) } else { [void]$shadow[$op.permissionId].Remove($op.account) }

        $success = [bool]$outputContext.Success
        $desired = $op.action -eq 'grant'
        $changed = $before -ne $after
        $classification = if ($op.dryRun) {
            if ($changed) { 'dryrun_wrote' } else { 'ok' }
        }
        elseif ($success) {
            # A grant/revoke for an account that no longer exists is reported by the connector itself
            if (-not $probe.userExists -or -not $probe.groupExists) { 'ok' }
            elseif ($after -eq $desired) { 'ok' }
            else { 'silent_failure' }
        }
        else {
            if ($changed -and $after -eq $desired) { 'failed_but_applied' } else { 'reported_failure' }
        }

        $auditText = (@($outputContext.AuditLogs) | ForEach-Object { $_.Message }) -join ' | '
        $result = [ordered]@{
            seq            = $op.seq
            kind           = $op.kind
            action         = $op.action
            dryRun         = [bool]$op.dryRun
            success        = $success
            before         = $before
            after          = $after
            groupExists    = [bool]$probe.groupExists
            userExists     = [bool]$probe.userExists
            classification = $classification
            ms             = [int]$stopwatch.Elapsed.TotalMilliseconds
            audit          = if ($classification -eq 'ok' -and $success) { $null } else { $auditText.Substring(0, [Math]::Min(400, $auditText.Length)) }
            scriptError    = $scriptError
        }
        $writer.WriteLine(($result | ConvertTo-Json -Compress))

        $done++
        if ($done % 2500 -eq 0) {
            $rate = $done / ((Get-Date) - $started).TotalSeconds
            Write-Host ("[{0}] {1}/{2} operations, {3:N1} ops/s" -f (Split-Path $OpsFile -Leaf), $done, $total, $rate)
            $writer.Flush()
        }
    }
}
finally {
    $writer.Dispose()
}
Write-Host ("[{0}] finished {1} operations in {2:N0}s" -f (Split-Path $OpsFile -Leaf), $done, ((Get-Date) - $started).TotalSeconds)
