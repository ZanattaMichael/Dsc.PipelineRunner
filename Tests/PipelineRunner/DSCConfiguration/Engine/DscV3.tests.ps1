Describe "Actions/Engine/DscV3 Tests" -Tag Unit, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
        $script:DscV3Path = (Get-FunctionPath 'DscV3.ps1').FullName
    }

    It "Maps the method to the dsc resource sub-command and namespaces the resource type" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            param($Arguments, $Executable)
            return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
        }

        $null = & $script:DscV3Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'test' -and
            $Arguments -contains 'Mod/Res'
        }
    }

    It "Returns inDesiredState from the parsed test output" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            return @{ ExitCode = 0; Output = '{"inDesiredState":false,"differingProperties":["Ensure"]}' }
        }

        $result = & $script:DscV3Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

        $result.InDesiredState | Should -BeFalse
        $result.Message | Should -BeLike '*Ensure*'
    }

    It "Throws when dsc.exe exits non-zero" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            return @{ ExitCode = 2; Output = 'boom' }
        }

        { & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} } } |
            Should -Throw "*exit 2*"
    }

    It "Throws when dsc.exe output is not valid JSON" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            return @{ ExitCode = 0; Output = 'not-json' }
        }

        { & $script:DscV3Path -Context @{ Method = 'Get'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} } } |
            Should -Throw "*Could not parse*"
    }
}
