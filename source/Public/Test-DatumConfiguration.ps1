<#
.SYNOPSIS
    Validates the Datum Configuration to ensure it meets the required standards.

.DESCRIPTION
    The Test-DatumConfiguration function validates the Datum Configuration object to ensure it contains the necessary properties and that the versioning is correct. 
    It checks for the presence of the PipelineRunnerSettings property, validates the versioning of the Datum Configuration, and ensures that the versions are within the acceptable range.

.PARAMETER Datum
    The Datum Configuration object that needs to be validated. This parameter is mandatory.

.EXAMPLE
    $datumConfig = Get-DatumConfiguration
    Test-DatumConfiguration -Datum $datumConfig

    This example retrieves a Datum Configuration object and validates it using the Test-DatumConfiguration function.

.NOTES
    The function throws an error if the Datum Configuration is invalid or if any of the version checks fail. It also provides verbose output for each validation step and a warning if the Datum Configuration version is two or more minor versions behind the current PSDesiredStateConfiguration version.

#>
function Test-DatumConfiguration {   
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [Object]
        $Datum
    )

    Write-Verbose "[Test-DatumConfiguration] Validating the Datum Configuration."

    # Validate that the Datum Configuration meets the requirements for the Datum Configuration.
    if ($null -eq $Datum.__Definition.PipelineRunnerSettings) {
        throw "[Test-DatumConfiguration] The Datum Configuration does not contain the PipelineRunnerSettings property. The Datum Configuration is invalid and cannot be processed."
    }

    # Validate that the Datum Configuration Versioning is the correct version. If not, throw an error.

    # Get the Datum Configuration Version
    $runnerConfig = @{
        DatumConfigurationVersion   = $Datum.__Definition.PipelineRunnerSettings.ConfigurationVersion -as [Version]
        PipelineRunnerVersion              = $Datum.__Definition.PipelineRunnerSettings.PipelineRunnerVersion -as [Version]
        YAMLConfigurationMinimumVersion = $ModuleConfigurationData.YAMLConfigurationMinimumVersion -as [Version]
        YAMLConfigurationMaximumVersion = $ModuleConfigurationData.YAMLConfigurationMaximumVersion -as [Version]
    }

    $CurrentPSDesiredStateConfigurationVersion = (Get-Module PSDesiredStateConfiguration | Select-Object -First 1).Version
    $CurrentPipelineRunnerVersion = (Get-Module Dsc.PipelineRunner | Select-Object -First 1).Version

    Write-Verbose "[Test-DatumConfiguration] Datum Configuration Version: $($runnerConfig.DatumConfigurationVersion)"

    # Confirm that all the Datum Configuration Versions have been safely typecasted to the [Version] type.
    foreach ($runnerConfigKey in $runnerConfig.Keys) {
        Write-Verbose "[Test-DatumConfiguration] Validating Datum Configuration Version for $runnerConfigKey."
        if ($null -eq $runnerConfig[$runnerConfigKey]) {
            throw "[Test-DatumConfiguration] The Datum Configuration Version for $runnerConfigKey is not a valid version. The Datum Configuration is invalid and cannot be processed. Please ensure that the Datum Configuration Version is a valid version."
        }
    }

    #
    # Validate the Datum Configuration Versioning
    #

    $supportedConfigurationMaxMajorVersion = $runnerConfig.YAMLConfigurationMaximumVersion.Major
    $supportedConfigurationMaxMinorVersion = $runnerConfig.YAMLConfigurationMaximumVersion.Minor
    $supportedConfigurationMinMajorVersion = $runnerConfig.YAMLConfigurationMinimumVersion.Major
    $supportedConfigurationMinMinorVersion = $runnerConfig.YAMLConfigurationMinimumVersion.Minor

    $datumConfigurationMajorVersion = $runnerConfig.DatumConfigurationVersion.Major
    $datumConfigurationMinorVersion = $runnerConfig.DatumConfigurationVersion.Minor

    # Combine the Major and Minor versions as a decimal number to compare the versions.
    $maxSupportedVersion = [decimal]::Parse("$supportedConfigurationMaxMajorVersion.$supportedConfigurationMaxMinorVersion")
    $minSupportedVersion = [decimal]::Parse("$supportedConfigurationMinMajorVersion.$supportedConfigurationMinMinorVersion")

    $currentVersion = [decimal]::Parse("$datumConfigurationMajorVersion.$datumConfigurationMinorVersion")
    
    # Throw an error if the Datum Configuration Version is outside the valid range of the Datum Configuration Versions.
    if (($currentVersion -lt $minSupportedVersion) -or ($currentVersion -gt $maxSupportedVersion)) {
        throw "[Test-DatumConfiguration] The Datum Configuration Version $($runnerConfig.DatumConfigurationVersion) is outside the valid range ($($runnerConfig.YAMLConfigurationMinimumVersion) to $($runnerConfig.YAMLConfigurationMaximumVersion)). The Datum Configuration is invalid and cannot be processed."
    }

    # Check if the Datum Configuration Version is two or more minor versions behind the current PSDesiredStateConfiguration version.
    # If it is, write a warning.
    if ($currentVersion -ge ($maxSupportedVersion - 0.2)) {
        Write-Warning "[Test-DatumConfiguration] The Datum Configuration Version $($runnerConfig.DatumConfigurationVersion) is two or more minor versions behind the current PSDesiredStateConfiguration version $($runnerConfig.CurrentPSDesiredStateConfigurationVersion). Consider updating to a more recent version."
    }

    #
    # Validate the PSDesiredStateConfiguration Versions
    #

    $PSDesiredStateConfigurationMinimumVersion = $ModuleConfigurationData.PSDesiredStateConfigurationMinimumVersion -as [Version]
    $PSDesiredStateConfigurationMaximumVersion = $ModuleConfigurationData.PSDesiredStateConfigurationMaximumVersion -as [Version]

    # Ensure that the Module PSDesiredStateConfiguration Version is within the valid range of the Datum Configuration Versions.
    if ($CurrentPSDesiredStateConfigurationVersion -lt $PSDesiredStateConfigurationMinimumVersion -or 
        $CurrentPSDesiredStateConfigurationVersion -gt $PSDesiredStateConfigurationMaximumVersion) {
        throw "[Test-DatumConfiguration] The PSDesiredStateConfiguration Version $($CurrentPSDesiredStateConfigurationVersion) is outside the valid range ($($PSDesiredStateConfigurationMinimumVersion) to $($PSDesiredStateConfigurationMaximumVersion)). The Datum Configuration is invalid and cannot be processed."
    }

    #
    # Validate the Dsc.PipelineRunner Versions
    #

    # Read the configured bounds from ModuleConfigurationData. Previously this check
    # compared $runnerConfig.PipelineRunnerMinimumVersion / .CurrentPipelineRunnerVersion,
    # neither of which was ever populated, so it was a permanent no-op ($x -lt $null is
    # always $false). Use the real installed version and the configured bounds, and warn
    # (rather than silently pass) when a bound cannot be determined.
    $PipelineRunnerMinimumVersion = $ModuleConfigurationData.DSCResourceMinimumVersion -as [Version]
    $PipelineRunnerMaximumVersion = $ModuleConfigurationData.DSCResourceMaximumVersion -as [Version]

    if (($null -eq $PipelineRunnerMinimumVersion) -or ($null -eq $PipelineRunnerMaximumVersion)) {
        Write-Warning "[Test-DatumConfiguration] The Dsc.PipelineRunner minimum/maximum version bounds are not configured; skipping the Dsc.PipelineRunner version check."
    }
    elseif ($null -eq $CurrentPipelineRunnerVersion) {
        Write-Warning "[Test-DatumConfiguration] The installed Dsc.PipelineRunner module version could not be determined; skipping the Dsc.PipelineRunner version check."
    }
    elseif ($CurrentPipelineRunnerVersion -lt $PipelineRunnerMinimumVersion -or
            $CurrentPipelineRunnerVersion -gt $PipelineRunnerMaximumVersion) {
        throw "[Test-DatumConfiguration] The Dsc.PipelineRunner Version $CurrentPipelineRunnerVersion is outside the valid range ($PipelineRunnerMinimumVersion to $PipelineRunnerMaximumVersion). The Datum Configuration is invalid and cannot be processed."
    }

}
