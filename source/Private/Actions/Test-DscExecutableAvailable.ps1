<#
.SYNOPSIS
Reports whether the DSC v3 command-line executable (dsc / dsc.exe) is resolvable.

.DESCRIPTION
A single, mockable probe for the presence of the DSC v3 executable on PATH. Engine
auto-selection uses this to decide whether the DscV3 engine can actually run, and
unit tests mock it so the decision logic can be exercised without a real dsc.exe on
the box.

.PARAMETER Executable
The executable to probe for. Defaults to 'dsc' (resolved on PATH).

.OUTPUTS
[bool] $true when the executable resolves as an application command, otherwise $false.
#>
function Test-DscExecutableAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Executable = 'dsc'
    )

    return [bool](Get-Command -Name $Executable -CommandType Application -ErrorAction SilentlyContinue)
}
