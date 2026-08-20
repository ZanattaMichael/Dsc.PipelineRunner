<#
.SYNOPSIS
Thin, mockable wrapper around the DSC v3 command-line executable (dsc / dsc.exe).

.DESCRIPTION
Isolates the single native-process call the DSC v3 engine makes, so the engine's
mapping logic can be unit-tested without a real dsc.exe on the box (tests mock this
function) and so executable discovery lives in one place.

.PARAMETER Arguments
The argument vector passed to the executable.

.PARAMETER Executable
The executable to run. Defaults to 'dsc' (resolved on PATH).

.OUTPUTS
[hashtable] @{ ExitCode = <int>; Output = <string> }
#>
function Invoke-DscExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Executable = 'dsc'
    )

    $output = & $Executable @Arguments 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}
