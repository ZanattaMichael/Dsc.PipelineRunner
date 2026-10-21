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

.PARAMETER Session
Optional remote session (a [System.Management.Automation.Runspaces.PSSession] in real use;
typed [object] here rather than pinned to that sealed class so a mock/test double can stand
in for it without a live remoting connection - #57 §4). When supplied, the executable is
invoked on the far side of the session via Invoke-Command rather than as a local process -
this is how the DscV3 engine reaches a WinRM/SSH remote target, since dsc.exe has no native
remoting of its own and must be installed on the target machine (see
scripts/Install-DscV3.ps1's remote-invocation form). $null (the default) runs locally,
today's behavior.

.PARAMETER StandardInput
Optional text written to the executable's standard input. The DscV3 engine passes the resource
instance JSON this way (with `--file -`) rather than as an `--input` argument, so a resolved
credential inside that JSON never appears on the process command line, where any local user
can read it from the process table.

.OUTPUTS
[hashtable] @{ ExitCode = <int>; Output = <string> }
#>
function Invoke-DscExecutable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Executable = 'dsc',

        [AllowNull()]
        [object]$Session = $null,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StandardInput = $null
    )

    # A [string] parameter can never hold $null, so "no standard input" is tracked by whether
    # the caller bound it at all; the executable's stdin is left untouched in that case.
    $standardInputText = if ($PSBoundParameters.ContainsKey('StandardInput')) { $StandardInput } else { $null }

    if ($null -ne $Session) {
        # Kept to a single straight-line statement: PSScriptAnalyzer's
        # UseUsingScopeModifierInNewRunspaces rule misreads param-declared variables that are
        # referenced inside a nested if/else within a remote script block. Piping a $null
        # standard input simply gives the executable an empty stdin, which is harmless for dsc.
        $remoteResult = Invoke-Command -Session $Session -ScriptBlock {
            param($RemoteExecutable, $RemoteArguments, $RemoteStandardInput)
            $remoteOutput = $RemoteStandardInput | & $RemoteExecutable @RemoteArguments 2>&1
            return @{
                ExitCode = $LASTEXITCODE
                Output   = ($remoteOutput | Out-String)
            }
        } -ArgumentList $Executable, $Arguments, $standardInputText

        return @{
            ExitCode = $remoteResult.ExitCode
            Output   = $remoteResult.Output
        }
    }

    if ($null -ne $standardInputText) {
        $output = $standardInputText | & $Executable @Arguments 2>&1
    }
    else {
        $output = & $Executable @Arguments 2>&1
    }
    return @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}
