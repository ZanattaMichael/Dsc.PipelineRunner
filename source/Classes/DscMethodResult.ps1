<#
.SYNOPSIS
The normalized result contract every execution engine must return.

.DESCRIPTION
DscMethodResult is the typed boundary between the engine-agnostic runner loop and a
pluggable execution engine (Actions/Engine/<Name>.ps1). Whether a resource is
evaluated through Invoke-DscResource (DSC v2) or dsc.exe (DSC v3) or a custom engine,
the loop only ever sees this shape, so the report and the exit code stay engine
independent.

Fields:
  InDesiredState - [bool]   Test result. For Set/Get, engines report the post-method
                            state (Set defaults to $true on success).
  RebootRequired - [bool]   Whether the method signalled a pending reboot.
  Message        - [string] Human-readable summary for the report.
  Raw            - [object] The engine's untouched output (Invoke-DscResource object,
                            parsed dsc.exe JSON, ...). Stored verbatim in the runner's
                            references table so downstream expansion is unchanged.
#>
class DscMethodResult {
    [bool]   $InDesiredState
    [bool]   $RebootRequired
    [string] $Message
    [object] $Raw
}
