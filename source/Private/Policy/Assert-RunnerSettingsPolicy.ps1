<#
.SYNOPSIS
Refuses a configuration whose PipelineRunnerSettings hold a value the capability policy does not
allow (issue #86, Part B).

.DESCRIPTION
PipelineRunnerSettings in Datum.yml decide how the runner behaves for the whole configuration:
whether execution scripts may run, what happens when a resource asks for a reboot, the default
Target and the engine. Policy.yml's optional Settings block lists the values each of those may
take. This check runs before the compile, so a refused value stops the run before Datum loads
anything, and every refused value is named in one pass.

What is judged is the value the runner will actually use:

  * a key Datum.yml sets is judged as the runner reads it (AllowExecutionScripts as a boolean,
    the others as text);
  * a key Datum.yml leaves out is judged by the runner's default for it (AllowExecutionScripts
    false, Reboot Fail, Target Local), so a policy that does not allow the default makes the
    key mandatory;
  * Engine is judged only when the configuration chooses the engine. When the pipeline chose it
    (-Engine or -EngineAction), Datum.yml's value is not used, and the pipeline is not governed:
    its owner is the policy's owner.

A key the policy's Settings block does not list is not governed. A policy with no Settings block
changes nothing here.

.PARAMETER Policy
The policy from Import-CapabilityPolicy.

.PARAMETER Settings
The PipelineRunnerSettings block from Datum.yml (Get-PipelineRunnerSetting), or $null.

.PARAMETER Engine
The engine the configuration selected, when the runner resolved it from Datum.yml (for example
through the back-compat DSCResourceVersion). Defaults to Settings.Engine.

.PARAMETER EngineFromPipeline
The pipeline chose the engine, so Datum.yml's Engine is not used and is not judged.
#>
function Assert-RunnerSettingsPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Policy,

        [AllowNull()]
        [System.Collections.IDictionary] $Settings,

        [string] $Engine,

        [switch] $EngineFromPipeline
    )

    $governed = $Policy['Settings']
    if ($null -eq $governed -or $governed.Count -eq 0) { return }

    $defaults = @{ AllowExecutionScripts = $false; Reboot = 'Fail'; Target = 'Local' }
    $violations = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @('AllowExecutionScripts', 'Engine', 'Reboot', 'Target')) {
        if (-not $governed.ContainsKey($key)) { continue }
        $allowed = @($governed[$key])

        $isSet = $Settings -and $Settings.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$Settings[$key])
        $origin = 'set in Datum.yml'
        if ($key -eq 'Engine') {
            if ($EngineFromPipeline) { continue }
            $value = if (-not [string]::IsNullOrWhiteSpace($Engine)) { $Engine } elseif ($isSet) { [string]$Settings[$key] } else { $null }
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if (-not $isSet) { $origin = 'selected from Datum.yml' }
        }
        elseif ($key -eq 'AllowExecutionScripts') {
            # The same reading Test-ExecutionScriptsAllowed gives it, so the policy judges what runs.
            $value = if ($isSet) { [bool]$Settings[$key] } else { $defaults[$key] }
        }
        else {
            $value = if ($isSet) { [string]$Settings[$key] } else { $defaults[$key] }
        }
        if (-not $isSet -and $key -ne 'Engine') { $origin = "the runner's default, because Datum.yml does not set it" }

        $permitted = if ($value -is [bool]) { $allowed -contains $value }
        else { @($allowed | Where-Object { $value -like [string]$_ }).Count -gt 0 }

        if (-not $permitted) {
            $shown = if ($value -is [bool]) { "$value".ToLowerInvariant() } else { $value }
            $list = ($allowed | ForEach-Object { if ($_ -is [bool]) { "$_".ToLowerInvariant() } else { $_ } }) -join ', '
            $violations.Add("PipelineRunnerSettings.$key is '$shown' ($origin); the policy allows: $list")
        }
    }

    if ($violations.Count -gt 0) {
        $layer = Get-PolicyLayer -Policy $Policy -RelativePath 'Datum.yml'
        $shortHash = ([string]$Policy['Sha256']).Substring(0, [Math]::Min(12, ([string]$Policy['Sha256']).Length))
        throw "[Assert-RunnerSettingsPolicy] The capability policy '$($Policy['Path'])' (sha256 $shortHash) refuses $($violations.Count) PipelineRunnerSettings value(s) of Datum.yml (layer '$layer'): $($violations -join '; '). Change Datum.yml, or ask the policy's owner to allow the value in Policy.yml's Settings block."
    }
}
