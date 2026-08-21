<#
.SYNOPSIS
Reads the PipelineRunnerSettings block from a configuration's Datum definition file.

.DESCRIPTION
Get-PipelineRunnerSetting loads the Datum definition file (Datum.yml by default) from a
configuration directory and returns its top-level PipelineRunnerSettings block. The runner
uses this to derive engine selection (PipelineRunnerSettings.Engine and the back-compat
DSCResourceVersion hint) without hard-coding a version gate into the core loop.

It is deliberately tolerant: a missing definition file, an unparseable document, or a
document with no PipelineRunnerSettings block all return $null so callers can fall back to
their defaults rather than fail the run.

.PARAMETER ConfigurationDirectory
Directory that contains the Datum definition file.

.PARAMETER DefinitionFileName
Name of the Datum definition file to read. Defaults to 'Datum.yml'.

.OUTPUTS
[hashtable] The PipelineRunnerSettings block, or $null when it cannot be resolved.
#>
function Get-PipelineRunnerSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationDirectory,

        [string]$DefinitionFileName = 'Datum.yml'
    )

    # Compose with [System.IO.Path]::Combine rather than Join-Path so a config directory
    # with a Windows-style drive qualifier does not throw on a Linux runner.
    $definitionPath = [System.IO.Path]::Combine($ConfigurationDirectory, $DefinitionFileName)

    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        Write-Verbose "[Get-PipelineRunnerSetting] No definition file at '$definitionPath'."
        return $null
    }

    $definition = Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Yaml

    # ConvertFrom-Yaml yields a hashtable for a mapping document; anything else (null,
    # a scalar, a sequence) has no settings block to read.
    if ($definition -isnot [System.Collections.IDictionary] -or -not $definition.Contains('PipelineRunnerSettings')) {
        Write-Verbose "[Get-PipelineRunnerSetting] No PipelineRunnerSettings block in '$definitionPath'."
        return $null
    }

    return [hashtable]$definition['PipelineRunnerSettings']
}
