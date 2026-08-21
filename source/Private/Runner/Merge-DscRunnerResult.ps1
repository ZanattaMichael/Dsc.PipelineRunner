<#
.SYNOPSIS
Aggregates the per-configuration results returned by Start-DscRunner into one run summary.

.DESCRIPTION
Invoke-DscRunner and Invoke-DscPipelineRunner call Start-DscRunner once per compiled
configuration file. Each call returns a structured [pscustomobject] describing that file's
outcome. Merge-DscRunnerResult folds those per-file records into a single machine-readable
summary for the whole run, so a caller (or a CI pipeline) can inspect one object instead of
re-deriving totals from the console log.

The summary carries an overall Status:

  * Completed        — every configuration finished and nothing failed.
  * PartialSuccess   — nothing failed, but at least one configuration stopped early
                       (Stop-TaskProcessing) or skipped resources.
  * Failed           — at least one resource failed.
  * Aborted          — at least one configuration was aborted by an unexpected exception.

When -ReportPath is supplied an aggregate report.json is written alongside the per-file
reports. When -FailOnError is supplied and the run did not succeed, the process exit code is
set to 1 so a pipeline step fails loudly; the switch is opt-in, so the default behaviour is
unchanged for callers that do not want a runner failure to fail their step.

.PARAMETER Result
The per-configuration result objects returned by Start-DscRunner. Null / empty entries are
ignored, so an empty run yields a Completed summary with zero counts.

.PARAMETER ReportPath
Optional directory. When supplied, an aggregate report.json is written into it.

.PARAMETER FailOnError
Opt-in switch. When the overall Status is Failed or Aborted, sets the process exit code to 1.

.OUTPUTS
[pscustomobject] with Status, TotalConfigurations, TotalResources, PassCount, FailCount,
SkipCount, DurationSeconds, FailedResources and the per-configuration Configurations.
#>
function Merge-DscRunnerResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $Result,

        [Parameter()]
        [string] $ReportPath,

        [Parameter()]
        [switch] $FailOnError
    )

    $infoTag = 'Dsc.PipelineRunner'

    # Drop null / empty entries so an empty run (no configuration files) still produces a
    # well-formed, Completed summary rather than throwing on missing properties.
    $configurations = @($Result | Where-Object { $null -ne $_ })

    $totalResources = 0
    $passCount      = 0
    $failCount      = 0
    $skipCount      = 0
    $durationSeconds = 0.0
    $failedResources = [System.Collections.Generic.List[object]]::new()
    $anyAborted     = $false
    $anyStopped     = $false

    foreach ($configuration in $configurations) {
        # Guard each read: a caller-supplied object (or a future engine) may not carry every
        # property, and a missing count must contribute zero rather than abort the summary.
        if ($null -ne $configuration.TotalResources) { $totalResources  += [int]$configuration.TotalResources }
        if ($null -ne $configuration.PassCount)      { $passCount       += [int]$configuration.PassCount }
        if ($null -ne $configuration.FailCount)      { $failCount       += [int]$configuration.FailCount }
        if ($null -ne $configuration.SkipCount)      { $skipCount       += [int]$configuration.SkipCount }
        if ($null -ne $configuration.DurationSeconds){ $durationSeconds += [double]$configuration.DurationSeconds }

        if ($configuration.Status -eq 'AbortedByException') { $anyAborted = $true }
        if ($configuration.Status -eq 'StoppedByRequest')   { $anyStopped = $true }

        foreach ($failed in $configuration.FailedResources) {
            if ($null -ne $failed) { $failedResources.Add($failed) }
        }
    }

    # Overall status, most-severe first: an abort outranks a resource failure, which outranks
    # an early stop / skip; a clean run is Completed.
    if ($anyAborted) {
        $status = 'Aborted'
    }
    elseif ($failCount -gt 0) {
        $status = 'Failed'
    }
    elseif ($anyStopped -or $skipCount -gt 0) {
        $status = 'PartialSuccess'
    }
    else {
        $status = 'Completed'
    }

    $summary = [pscustomobject]@{
        Status              = $status
        TotalConfigurations = $configurations.Count
        TotalResources      = $totalResources
        PassCount           = $passCount
        FailCount           = $failCount
        SkipCount           = $skipCount
        DurationSeconds     = [math]::Round($durationSeconds, 3)
        FailedResources     = $failedResources
        Configurations      = $configurations
    }

    # Aggregate report alongside the per-file reports Start-DscRunner already wrote.
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $reportFile = [System.IO.Path]::Combine($ReportPath, 'report.json')
        Write-Verbose "[Merge-DscRunnerResult] Writing aggregate report to $reportFile"
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportFile
    }

    Write-Information ("Run summary: {0} — {1} configuration(s), {2} passed, {3} failed, {4} skipped." -f `
            $status, $configurations.Count, $passCount, $failCount, $skipCount) -Tags $infoTag

    # Opt-in non-zero exit code on failure (#19). Only Failed / Aborted set the code, so a
    # PartialSuccess (early stop with no failures) does not fail the pipeline step.
    if ($FailOnError -and ($status -eq 'Failed' -or $status -eq 'Aborted')) {
        Write-Verbose "[Merge-DscRunnerResult] -FailOnError set and run status is '$status'; setting exit code 1."
        [System.Environment]::ExitCode = 1
    }

    return $summary
}
