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

.PARAMETER Environment
Optional environment variables for the local executable, as name = value. Each is set for the
call only and put back afterwards (a variable that did not exist is removed again). The DscV3
engine uses this to point dsc's resource discovery at one resource's manifest
(DSC_RESOURCE_PATH, see Resolve-DscV3ResourcePath). Ignored for a remote -Session.

.OUTPUTS
[hashtable] @{ ExitCode = <int>; Output = <string>; ErrorOutput = <string> }

Output is the executable's standard output only. ErrorOutput is its standard error. They are
kept apart because dsc writes its result (JSON) to standard output and its trace, warning and
error lines to standard error, and it can write a warning while still succeeding: merging the
two put a timestamped trace line in front of the JSON and made a successful result unparseable.
#>
function Invoke-DscExecutable {
    [CmdletBinding()]
    # The remote script block receives $RemoteExecutable/$RemoteArguments/$RemoteStandardInput
    # through its own param() block and -ArgumentList, which is the documented way to hand
    # values to Invoke-Command -Session. The rule only recognises $using: and reports those
    # param-declared variables as undeclared, so this is a false positive, not a missing scope.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'The remote script block declares its inputs in param() and receives them via -ArgumentList; the rule does not account for that pattern.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Executable = 'dsc',

        [AllowNull()]
        [object]$Session = $null,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StandardInput = $null,

        [hashtable]$Environment = $null
    )

    # A [string] parameter can never hold $null, so "no standard input" is tracked by whether
    # the caller bound it at all; the executable's stdin is left untouched in that case.
    $standardInputText = if ($PSBoundParameters.ContainsKey('StandardInput')) { $StandardInput } else { $null }

    if ($null -ne $Session) {
        # A $null standard input simply gives the executable an empty stdin, which is harmless
        # for dsc (the only caller) and keeps the remote block to one statement.
        $remoteResult = Invoke-Command -Session $Session -ScriptBlock {
            param($RemoteExecutable, $RemoteArguments, $RemoteStandardInput)
            $remoteOutput = $RemoteStandardInput | & $RemoteExecutable @RemoteArguments 2>&1
            $remoteExitCode = $LASTEXITCODE
            # Standard error arrives as ErrorRecord objects when it is redirected with 2>&1;
            # everything else is standard output. Split them here, on the far side, so only
            # strings cross the session.
            $remoteStdErr = @($remoteOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
            $remoteStdOut = @($remoteOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
            return @{
                ExitCode    = $remoteExitCode
                Output      = ($remoteStdOut | Out-String)
                ErrorOutput = ($remoteStdErr -join "`n")
            }
        } -ArgumentList $Executable, $Arguments, $standardInputText

        return @{
            ExitCode    = $remoteResult.ExitCode
            Output      = $remoteResult.Output
            ErrorOutput = [string]$remoteResult.ErrorOutput
        }
    }

    # A child process inherits this process's environment, so a variable for the call is set
    # here and put back in the finally, whatever the call does.
    $previousEnvironment = @{}
    if ($null -ne $Environment) {
        foreach ($name in $Environment.Keys) {
            $previousEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
            [System.Environment]::SetEnvironmentVariable($name, [string]$Environment[$name])
        }
    }
    try {
        if ($null -ne $standardInputText) {
            $output = $standardInputText | & $Executable @Arguments 2>&1
        }
        else {
            $output = & $Executable @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($name in $previousEnvironment.Keys) {
            # PowerShell passes $null to a [string] .NET parameter as '', which leaves the
            # variable set to an empty value instead of removing it - and an empty
            # DSC_RESOURCE_PATH makes every later dsc call find no resources at all.
            if ($null -eq $previousEnvironment[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                [System.Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name])
            }
        }
    }

    # Standard error arrives as ErrorRecord objects when it is redirected with 2>&1; everything
    # else is standard output. Keep them apart (see .OUTPUTS).
    $stdErr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    $stdOut = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return @{
        ExitCode    = $exitCode
        Output      = ($stdOut | Out-String)
        ErrorOutput = ($stdErr -join "`n")
    }
}
