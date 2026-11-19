<#
.SYNOPSIS
Warns when a configuration under a capability policy declares PipelineRunnerSettings versions
older than the ones the policy is documented against (issue #86, Part B).

.DESCRIPTION
The capability policy and its Settings block are documented against
PipelineRunnerSettings ConfigurationVersion 0.6 and PipelineRunnerVersion 1.2.0. A configuration
that still declares older values (for example 0.5 / 1.1.0) was written before the policy existed,
which usually means the pipeline or the module it installs was not upgraded with it. That is a
mistake worth surfacing, so this writes one warning that names Datum.yml's values and the fix.

It only warns. The policy is still loaded and enforced: turning a security control off because of
a version number would fail open.

A value that is missing or is not a version is left to Test-DatumConfiguration, which refuses it
during the compile.

.PARAMETER Settings
The PipelineRunnerSettings block from Datum.yml (Get-PipelineRunnerSetting), or $null.

.PARAMETER PolicyPath
The policy file in force, named in the warning.

.OUTPUTS
[bool] $true when the versions meet the minimum (or cannot be judged here), $false when a warning
was written.
#>
function Test-PolicyConfigurationVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [hashtable] $Settings,

        [string] $PolicyPath
    )

    $minimumConfigurationVersion = [Version]'0.6'
    $minimumPipelineRunnerVersion = [Version]'1.2.0'

    if ($null -eq $Settings) { return $true }

    # A [Version] parsed from '0.6' has no Build part (-1), so compare on Major.Minor[.Build] with a
    # missing part read as 0. That keeps '1.2' equal to '1.2.0'.
    $normalise = {
        param($Value)
        $version = [string]$Value -as [Version]
        if ($null -eq $version) { return $null }
        [Version]::new($version.Major, $version.Minor, [Math]::Max($version.Build, 0))
    }

    $configurationVersion = & $normalise $Settings['ConfigurationVersion']
    $pipelineRunnerVersion = & $normalise $Settings['PipelineRunnerVersion']
    if ($null -eq $configurationVersion -or $null -eq $pipelineRunnerVersion) { return $true }

    $minimumConfiguration = & $normalise $minimumConfigurationVersion
    $minimumPipelineRunner = & $normalise $minimumPipelineRunnerVersion
    if ($configurationVersion -ge $minimumConfiguration -and $pipelineRunnerVersion -ge $minimumPipelineRunner) {
        return $true
    }

    $policyName = if ($PolicyPath) { "'$PolicyPath'" } else { 'A capability policy' }
    Write-Warning ("[Capability policy] $policyName is in force, but Datum.yml declares PipelineRunnerSettings " +
        "ConfigurationVersion $($Settings['ConfigurationVersion']) and PipelineRunnerVersion $($Settings['PipelineRunnerVersion']). " +
        "The capability policy needs ConfigurationVersion $minimumConfigurationVersion and PipelineRunnerVersion $minimumPipelineRunnerVersion or later. " +
        "The policy is still enforced. To fix: update the Dsc.PipelineRunner module the pipeline installs, then set " +
        "ConfigurationVersion: $minimumConfigurationVersion and PipelineRunnerVersion: $minimumPipelineRunnerVersion in Datum.yml.")
    return $false
}
