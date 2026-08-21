<#
.SYNOPSIS
Resolves the concrete engine action name (DscV2 / DscV3) to run for a task.

.DESCRIPTION
Encapsulates the engine-selection policy in one place so Start-DscRunner does not
grow branching logic. The policy is deliberately conservative:

- An explicit engine (anything other than 'Auto') is always honoured verbatim so a
  caller who names an engine gets exactly that engine, with no probing or surprises.
- 'Auto' opts in to detection. When a resource version hint is supplied it drives the
  choice by major version (major >= 3 -> DscV3, major 2 -> DscV2). Absent a decisive
  version, DscV3 is preferred only when the dsc executable is actually resolvable,
  otherwise the well-supported DscV2 engine is chosen.

When the version asks for DscV3 but no dsc executable is present a warning is emitted
so the mismatch is visible; selection still returns DscV3 so the downstream engine can
surface the concrete failure rather than this function silently rewriting intent.

.PARAMETER Engine
The requested engine. 'Auto' enables detection; any other value is returned unchanged.

.PARAMETER Version
Optional resource version hint (e.g. from DSCResourceMinimumVersion) used to bias the
'Auto' decision by major version. Non-parseable or empty values are ignored.

.PARAMETER Executable
The DSC v3 executable name passed through to the availability probe. Defaults to 'dsc'.

.OUTPUTS
[string] The resolved engine action name ('DscV2' or 'DscV3').
#>
function Resolve-DscEngine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Engine = 'Auto',

        [string]$Version,

        [string]$Executable = 'dsc'
    )

    # Explicit engine selection wins outright - never probe or override a named engine.
    if ($Engine -ne 'Auto') {
        return $Engine
    }

    # Try to read a decisive major version from the supplied hint.
    $parsed = [Version]'0.0'
    $hasVersion = -not [string]::IsNullOrWhiteSpace($Version) -and [Version]::TryParse($Version, [ref]$parsed)

    if ($hasVersion -and $parsed.Major -ge 3) {
        if (-not (Test-DscExecutableAvailable -Executable $Executable)) {
            Write-Warning "Resource version '$Version' selects the DSC v3 engine, but the '$Executable' executable was not found on PATH. The DSC v3 engine will surface the failure when it runs."
        }
        return 'DscV3'
    }

    if ($hasVersion -and $parsed.Major -eq 2) {
        return 'DscV2'
    }

    # No decisive version hint: prefer DSC v3 only when its executable is present.
    if (Test-DscExecutableAvailable -Executable $Executable) {
        return 'DscV3'
    }

    return 'DscV2'
}
