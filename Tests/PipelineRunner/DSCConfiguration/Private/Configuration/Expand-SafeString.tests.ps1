Describe "Expand-SafeString Function Tests" -Tag Unit, Runner, Configuration, Security {

    BeforeAll {
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName

        # Stand-in for the function-language accessor the runner provides.
        function variables { param($Name) @{ ProjectName = 'Blue' }[$Name] }
    }

    It "returns a string with no expansion syntax untouched" {
        Expand-SafeString -Value 'plain value' | Should -BeExactly 'plain value'
        Expand-SafeString -Value '' | Should -BeExactly ''
    }

    It "expands variables and function-language accessors" {
        $env:DSC_PR_SAFE = 'bar'
        try {
            Expand-SafeString -Value 'a $env:DSC_PR_SAFE' | Should -BeExactly 'a bar'
        }
        finally { Remove-Item Env:\DSC_PR_SAFE -ErrorAction SilentlyContinue }
        Expand-SafeString -Value 'P $(variables(''ProjectName''))' | Should -BeExactly 'P Blue'
    }

    It "keeps embedded double quotes literal, like ExpandString" {
        Expand-SafeString -Value 'say "hi" $(variables(''ProjectName''))' | Should -BeExactly 'say "hi" Blue'
    }

    It "refuses <Name>" -ForEach @(
        @{ Name = 'a command';          Value = '$(Remove-Item /tmp/never -Recurse)' }
        @{ Name = 'a method call';      Value = '$([IO.File]::ReadAllText("/etc/passwd"))' }
        @{ Name = 'an assignment';      Value = '$($x = 1)' }
        @{ Name = 'a here-string breakout'; Value = "x`n`"@`n`$(Get-Process)" }
    ) {
        { Expand-SafeString -Value $Value } | Should -Throw '*Refusing to expand*'
    }
}
