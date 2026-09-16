Function Split-RecurivePath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [int]$Times = 1
    )

    1 .. $Times | ForEach-Object {
        $Path = Split-Path -Path $Path -Parent
    }

    $Path
}

function New-MockFilePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    Join-Path (New-MockDirectoryPath) $FileName
    
}

Function New-MockDirectoryPath {
    param ()

    if ($null -eq $TestDrive) {
        $tempPath = Join-Path $env:TEMP 'Pester'
        $TestDrive = Join-Path $env:TEMP $tempPath
    }

    Join-Path $TestDrive 'Temp'

}



Function Get-FunctionPath {
    param(
        [string[]]$FileNames
    )

    # Locate the scriptroot for the module
    if ($Global:RepositoryRoot -eq $null) {
        $Global:RepositoryRoot = Split-RecurivePath $PSScriptRoot -Times 2
    }

    $ScriptRoot = $Global:RepositoryRoot

    if ($null -eq $Global:TestPaths) {
        $Global:TestPaths = Get-ChildItem -LiteralPath $ScriptRoot -Recurse -File -Include *.ps1 | Where-Object {
            ($_.FullName -notlike "*Tests.ps1") -and
            ($_.FullName -notlike '*\output\*') -and
            ($_.FullName -notlike '*\tests\*')
        }
    }

    # Perform a lookup for all BeforeEach FileNames. Prefer an exact, case-sensitive
    # match so files that differ only by case (e.g. the low-level DatumHelper 'git.ps1'
    # and the higher-level Source action 'Git.ps1') resolve to the intended one. Only
    # fall back to a case-insensitive match when no exact-case file exists, so existing
    # lookups keep working unchanged.
    $BeforeEachPath = @()
    ForEach ($FileName in $FileNames) {
        $exactMatches = $Global:TestPaths | Where-Object { $_.Name -ceq $FileName }
        if ($exactMatches) {
            $BeforeEachPath += $exactMatches
        }
        else {
            $BeforeEachPath += $Global:TestPaths | Where-Object { $_.Name -eq $FileName }
        }
    }

    return $BeforeEachPath

}

Function Find-Functions {
    param(
        [String]$TestFilePath
    )

    $files = @()

    #
    # Using the File path of the test file, work out the function that is being tested
    $FunctionName = (Get-Item -LiteralPath $TestFilePath).BaseName -replace '\.tests$', ''
    $files += "$($FunctionName).ps1"


    #
    # Load the function into the AST and look for the mock commands.

    # Parse the PowerShell script file
    $AST = [System.Management.Automation.Language.Parser]::ParseFile($TestFilePath, [ref]$null, [ref]$null)

    # Find all the Mock commands
    $MockCommands = $AST.FindAll({
        $args[0] -is [System.Management.Automation.Language.CommandAst] -and
        $args[0].CommandElements[0].Value -eq 'Mock'
    }, $true)

    # Iterate over the Mock commands and find the CommandName parameter
    foreach ($mockCommand in $MockCommands) {

        # Iterate over the CommandElements
        foreach ($element in $mockCommand.CommandElements) {

            # Check if the element is a CommandParameterAst and the parameter name is CommandName
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'CommandName') {
                $null = $element.Parent.Extent.Text -match '(-CommandName\s+(?<Function>[^\s]+))|(^Mock (?<Function>[^\s]+$))'
                $files += "$($matches.Function).ps1"
            }
        }
    }

    # Ignore the following list of functions
    $files = $files | Where-Object { $_ -notin @('Write-Error.ps1', 'Write-Output.ps1', 'Write-Verbose.ps1', 'Write-Warning.ps1') }
    # Return the unique list of functions
    $files = $files | Select-Object -Unique

    $files

}

Function Get-ClassFilePath {
    param(
        [string]$FileName
    )

    $Class = $Global:TestPaths | Where-Object { ($_.Name -eq $FileName) -or ($_.Name -eq "$FileName.ps1") }
    return $Class.FullName

}

Function Import-Enums {
    return ($Global:TestPaths | Where-Object { $_.Directory.Name -eq 'Enum' })
}

<#
.SYNOPSIS
Returns why the live WinRM integration suite cannot run here, or $null when it can.

.DESCRIPTION
Lives in this module, rather than inline in the test file, because Pester runs discovery and
execution in separate scopes: a variable assigned at a test file's top level is visible when
Pester evaluates an It's -Skip: argument (discovery) but NOT inside BeforeAll (execution). The
probe therefore has to be callable from both, which a module command is and a file-scope
variable is not.

It probes TWICE, and the second probe is the one that matters. A bare Test-WSMan sends an
ANONYMOUS WS-Man Identify: it answers as soon as a listener exists, without authenticating
anybody. The suite does not open anonymous connections - New-CimSession and New-PSSession
authenticate as the current user - so a host can pass a bare Test-WSMan and still refuse every
session the suite opens ("Access is denied"), which is a skip condition reported as four
failures. Adding -Authentication Negotiate makes the Identify go through the same
authentication the suite's own sessions use, so what this returns matches what the tests will
actually get. Keeping both probes is what lets the reason distinguish "no listener here" from
"a listener that will not authenticate this account".

scripts/Enable-SelfHostedWinRM.ps1 probes the same way, for the same reason: an anonymous
probe would let it declare a host already configured when the suite cannot use it.
#>
function Get-WinRMSkipReason {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME
    )

    if (-not $IsWindows) {
        return 'Target/WinRM requires a Windows host with a WinRM listener; this is not Windows.'
    }

    try {
        $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
    }
    catch {
        return "Test-WSMan against [$ComputerName] failed: $($_.Exception.Message)"
    }

    try {
        $null = Test-WSMan -ComputerName $ComputerName -Authentication Negotiate -ErrorAction Stop
    }
    catch {
        return "A WinRM listener on [$ComputerName] answered an anonymous Test-WSMan, but an authenticated one failed: $($_.Exception.Message)"
    }

    return $null
}

<#
.SYNOPSIS
Returns why the live SecretManagement vault integration suite cannot run here, or $null when it
can.

.DESCRIPTION
See Get-WinRMSkipReason for why this is a module command rather than a variable in the test file.

Two conditions. Both SecretManagement and the SecretStore extension must be installed, and
PIPELINERUNNER_ALLOW_SECRETSTORE_RESET must be 'true': configuring SecretStore for unattended
use means Reset-SecretStore, which erases the CURRENT USER's secrets. That is harmless on an
ephemeral CI agent and destructive on a developer's machine, so it never happens by default.
#>
function Get-LiveVaultSkipReason {
    [CmdletBinding()]
    param()

    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
        return 'Microsoft.PowerShell.SecretManagement is not installed.'
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretStore)) {
        return 'Microsoft.PowerShell.SecretStore (the vault extension used by this suite) is not installed.'
    }

    if ($env:PIPELINERUNNER_ALLOW_SECRETSTORE_RESET -ne 'true') {
        return 'PIPELINERUNNER_ALLOW_SECRETSTORE_RESET is not set to "true"; refusing to reset this user''s SecretStore.'
    }

    return $null
}

Export-ModuleMember -Function Split-RecurivePath, Get-FunctionPath, Find-Functions, Get-ClassFilePath, Import-Enums, New-MockDirectoryPath, New-MockFilePath, Get-WinRMSkipReason, Get-LiveVaultSkipReason
