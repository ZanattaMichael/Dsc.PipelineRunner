<#
Security regression suite: configuration `variables` cannot overwrite runner state or the
agent's environment.

Set-Variables turns every key of a configuration's `variables` section into a script-scope
variable and exports it to the process environment. Without limits, a configuration could name
a variable after the runner's own state (StopTaskProcessing, parameters, VerbosePreference...)
and silently disable enforcement or corrupt the session, or name one after an environment
variable that steers a child process (GIT_SSH_COMMAND, PATH, LD_PRELOAD) and so change what the
agent executes. Dummy values only.
#>
Describe "Security: configuration variables cannot overwrite runner state or the environment" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'SetVariables.ps1').FullName
    }

    BeforeEach {
        $script:RunnerExportedEnv = $null
        $script:StopTaskProcessing = $false
        $script:savedVerbose = $VerbosePreference
    }

    AfterEach {
        $VerbosePreference = $script:savedVerbose
        foreach ($name in 'PRE_EXISTING_SEC_X', 'NewSecVarY', 'GIT_SSH_COMMAND', 'HYPHEN_OK', 'DB_SEC_TEST') {
            Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name NewSecVarY, DB_SEC_TEST -Scope Script -ErrorAction SilentlyContinue
    }

    It "refuses the reserved name <Name> and writes nothing" -ForEach @(
        @{ Name = 'StopTaskProcessing' }
        @{ Name = 'parameters' }
        @{ Name = 'references' }
        @{ Name = 'variables' }
        @{ Name = 'VerbosePreference' }
        @{ Name = 'ErrorActionPreference' }
        @{ Name = 'currentNodeName' }
        @{ Name = 'RunnerExportedEnv' }
        @{ Name = 'Host' }
        @{ Name = 'PSScriptRoot' }
    ) {
        $target = @{}
        $source = [ordered]@{ HarmlessFirst = 'x'; $Name = 'evil' }

        { Set-Variables -Source $source -Target $target } | Should -Throw '*reserved*'

        # Validation happens before any write, so the harmless key before it was not applied.
        $target.Count | Should -Be 0
        $script:StopTaskProcessing | Should -BeFalse
    }

    It "keeps the preference variables and runner state untouched after a refusal" {
        $before = $VerbosePreference
        { Set-Variables -Source @{ VerbosePreference = 'Continue' } -Target @{} } | Should -Throw '*reserved*'
        $VerbosePreference | Should -Be $before
    }

    It "still accepts ordinary names, including dotted ones" {
        $target = @{}
        Set-Variables -Source @{ NewSecVarY = 'v'; 'Project_Service_GitRepositories' = 'enabled'; 'Key.With.Dot' = 'dot' } -Target $target

        $target['NewSecVarY'] | Should -Be 'v'
        $script:NewSecVarY | Should -Be 'v'
        $script:Key_With_Dot | Should -Be 'dot'
        Remove-Variable -Name Key_With_Dot, Project_Service_GitRepositories -Scope Script -ErrorAction SilentlyContinue
    }

    It "keeps a name that is not a valid variable in the table (for variables()) without creating a variable for it" {
        $target = @{}
        Set-Variables -Source @{ 'my-hyphen-key' = 'kept' } -Target $target

        $target['my-hyphen-key'] | Should -Be 'kept'
        $env:HYPHEN_OK | Should -BeNullOrEmpty
        (Get-Variable -Name 'my-hyphen-key' -Scope Script -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    Context "environment" {

        It "does not overwrite an environment variable the agent already had" {
            $env:PRE_EXISTING_SEC_X = 'original'

            Set-Variables -Source @{ PRE_EXISTING_SEC_X = 'evil'; NewSecVarY = 'v' } -Target @{} 3>$null

            $env:PRE_EXISTING_SEC_X | Should -Be 'original'
            $env:NewSecVarY | Should -Be 'v'
        }

        It "never exports a name that steers a child process, even when it is not already set" {
            Remove-Item -Path env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue

            Set-Variables -Source @{ GIT_SSH_COMMAND = 'sh -c evil' } -Target @{} 3>$null

            $env:GIT_SSH_COMMAND | Should -BeNullOrEmpty
        }

        It "does not put the value in the warning it raises" {
            $warnings = Set-Variables -Source @{ GIT_SSH_COMMAND = 'secret-value-8821' } -Target @{} 3>&1 | Out-String

            $warnings | Should -Match 'GIT_SSH_COMMAND'
            $warnings | Should -Not -Match 'secret-value-8821'
        }

        It "tracks what it exported so the runner can remove it again" {
            Set-Variables -Source @{ DB_SEC_TEST = 'x' } -Target @{}

            $script:RunnerExportedEnv.Contains('DB_SEC_TEST') | Should -BeTrue
        }
    }
}
