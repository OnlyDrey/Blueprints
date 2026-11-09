#Requires -Version 5.1
<#
.SYNOPSIS
Preview or interactively delete completed GitHub Actions runs older than 30 days.
.DESCRIPTION
Requires authenticated GitHub CLI. Deletion removes logs and associated artifacts,
never workflow definitions. -DryRun is non-interactive and never deletes anything.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [ValidateRange(1,3650)][int]$RetentionDays = 30,
    [switch]$DryRun,
    [switch]$FailedOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Gh {
    param([string[]]$Arguments)
    $output = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI failed. Check authentication, repository access and network connectivity.' }
    return ($output -join "`n")
}

function Resolve-Repository {
    param([string]$Value, [bool]$Interactive)
    if ($Value) { return $Value }
    try { $Value = Invoke-Gh @('repo','view','--json','nameWithOwner','--jq','.nameWithOwner') } catch { $Value = '' }
    while ($Value -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        if (-not $Interactive) { throw 'Repository detection failed. Pass -Repository owner/repository.' }
        $Value = Read-Host 'Repository (owner/repository)'
    }
    return $Value
}

function Test-EligibleRun {
    param($Run, [DateTimeOffset]$Cutoff, [bool]$Failures)
    if ([string]$Run.id -notmatch '^\d+$') { throw 'Malformed GitHub run ID.' }
    $created = [DateTimeOffset]::Parse($Run.created_at, [Globalization.CultureInfo]::InvariantCulture)
    # A recently completed or rerun execution must also survive retention.
    $updated = [DateTimeOffset]::Parse($Run.updated_at, [Globalization.CultureInfo]::InvariantCulture)
    return ($Run.status -eq 'completed' -and $created -lt $Cutoff -and $updated -lt $Cutoff -and
        (-not $Failures -or $Run.conclusion -in @('failure','cancelled','timed_out')))
}

function Get-OldRuns {
    param([string]$Repo, [DateTimeOffset]$Cutoff, [bool]$Failures)
    $found = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $page = 1
    $expected = -1
    do {
        # Unfiltered listing avoids GitHub's 1,000-result cap on filtered searches.
        $data = (Invoke-Gh @('api','--method','GET',"repos/$Repo/actions/runs?per_page=100&page=$page")) | ConvertFrom-Json
        if ($null -eq $data.workflow_runs -or $null -eq $data.total_count) { throw 'Malformed GitHub inventory.' }
        if ($expected -eq -1) { $expected = [long]$data.total_count }
        if ([long]$data.total_count -ne $expected) { throw 'Run inventory changed during pagination. Retry; nothing deleted.' }
        $runs = @($data.workflow_runs)
        foreach ($run in $runs) {
            if ($seen.ContainsKey([string]$run.id)) { throw 'Duplicate run during pagination. Retry; nothing deleted.' }
            $seen[[string]$run.id] = $true
            if (Test-EligibleRun $run $Cutoff $Failures) { $found.Add($run) }
        }
        $page++
    } while ($runs.Count -eq 100)
    if ($seen.Count -ne $expected) { throw 'Incomplete GitHub inventory. Nothing deleted.' }
    return @($found | Sort-Object created_at,id)
}

function Invoke-Cleanup {
    param([string]$Repo, [int]$Days, [bool]$Failures, [bool]$Delete)
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-$Days)
    $selected = @(Get-OldRuns $Repo $cutoff $Failures)
    Write-Host "Repository: $Repo; retention: $Days days; UTC cutoff: $($cutoff.ToString('o'))"
    Write-Host "Eligible completed runs: $($selected.Count)"
    if ($selected.Count) { $selected | Select-Object id,name,created_at,updated_at,conclusion,html_url | Format-Table -AutoSize | Out-Host }
    if (-not $Delete -or $selected.Count -eq 0) { Write-Host 'PREVIEW ONLY - nothing deleted.'; return }
    Write-Warning 'Deletion permanently removes execution history, logs and associated artifacts. Review release/audit evidence before proceeding.'
    if ((Read-Host "Type DELETE to delete the displayed runs") -cne "DELETE") { Write-Host 'Cancelled. Nothing deleted.'; return }
    $deleted = 0
    $skipped = 0
    $failed = 0
    foreach ($run in $selected) {
        try {
            # Reruns and publication changes can happen after the preview.
            $current = (Invoke-Gh @('api','--method','GET',"repos/$Repo/actions/runs/$($run.id)")) | ConvertFrom-Json
            if ([string]$current.id -ne [string]$run.id -or -not (Test-EligibleRun $current $cutoff $Failures) -or $current.updated_at -ne $run.updated_at) {
                $skipped++; Write-Warning "Run $($run.id) changed; retained."; continue
            }
            $null = Invoke-Gh @('api','--method','DELETE',"repos/$Repo/actions/runs/$($run.id)")
            $deleted++
            Write-Host "Deleted $($run.id) ($deleted/$($selected.Count))"
        } catch {
            $failed++
            Write-Warning "Stopped at run $($run.id): $($_.Exception.Message)"
            break
        }
    }
    Write-Host "Summary: eligible=$($selected.Count); deleted=$deleted; changed/retained=$skipped; failed=$failed; unattempted=$($selected.Count-$deleted-$skipped-$failed)"
    if ($failed) { throw 'Cleanup stopped after an API failure; see summary. No automatic retry.' }
}

function Start-Cleanup {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Install GitHub CLI (gh) and run gh auth login.' }
    $null = Invoke-Gh @('auth','status')
    $repo = Resolve-Repository $Repository (-not $DryRun)
    if ($DryRun) { Invoke-Cleanup $repo $RetentionDays ([bool]$FailedOnly) $false; return }
    $days = $RetentionDays
    while ($true) {
        Write-Host "`nGitHub Actions Cleanup - $repo - retention $days days"
        Write-Host "1. Preview eligible runs`n2. Delete eligible runs`n3. Delete failed/cancelled/timed-out runs`n4. Change retention period`n5. Change repository`n0. Exit"
        try {
            switch (Read-Host 'Selection') {
                '1' { Invoke-Cleanup $repo $days ([bool]$FailedOnly) $false }
                '2' { Invoke-Cleanup $repo $days $false $true }
                '3' { Invoke-Cleanup $repo $days $true $true }
                '4' {
                    $value = Read-Host 'Retention days (1-3650)'
                    $parsed = 0
                    if ([int]::TryParse($value,[ref]$parsed) -and $parsed -ge 1 -and $parsed -le 3650) { $days = $parsed }
                    else { Write-Warning 'Enter a whole number from 1 to 3650.' }
                }
                '5' {
                    $value = Read-Host 'Repository (owner/repository)'
                    if ($value -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { $repo = $value }
                    else { Write-Warning 'Enter owner/repository.' }
                }
                '0' { return }
                default { Write-Warning 'Invalid menu selection.' }
            }
        } catch { Write-Warning $_.Exception.Message }
    }
}

# Dot-sourcing exposes functions for isolated mocked tests without starting a menu.
if ($MyInvocation.InvocationName -ne '.') {
    try { Start-Cleanup } catch { Write-Error $_.Exception.Message; exit 1 }
}
