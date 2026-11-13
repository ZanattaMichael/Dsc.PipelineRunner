<#
Security regression suite: a preCondition/postCondition can never carry a side effect.

Assert-SafeConditionExpression is the only thing standing between a configuration author and
arbitrary code in a field that is documented as a pure predicate (#35). The 2026-10 audit found
four shapes (file redirection, exit, break/continue, ++/--) that carried a side effect without
any command, assignment or method call. This corpus enumerates every side-effecting shape the
PowerShell grammar offers, so adding a new accessor or loosening the walk cannot silently
re-open one of them. The end-to-end proofs (payloads run through the real Start-DscRunner loop)
live in Start-DscRunner.tests.ps1, Context "Security: injection attempts are neutralized".
#>
Describe "Security: condition expressions cannot cause side effects" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
    }

    $sideEffects = @(
        # command invocation, direct and obfuscated
        @{ Kind = 'bare command';                        Expression = 'Remove-Item C:\ -Recurse -Force' }
        @{ Kind = 'command in subexpression';            Expression = '$($x = Get-Item C:\)' }
        @{ Kind = 'command in expandable string';        Expression = '"$(Get-Date)" -eq ''x''' }
        @{ Kind = 'call operator on string';             Expression = '& ("Rem"+"ove-Item") C:\' }
        @{ Kind = 'call operator on variable';           Expression = '& $cmd' }
        @{ Kind = 'dot-source';                          Expression = '. $script' }
        @{ Kind = 'Invoke-Expression';                   Expression = 'Invoke-Expression $payload' }
        @{ Kind = 'iex alias';                           Expression = 'iex $payload' }
        @{ Kind = 'backtick-obfuscated name';            Expression = 'Inv`oke-Expression $payload' }
        @{ Kind = 'pipeline into command';               Expression = '$secret | Out-File C:\x' }
        @{ Kind = 'nested in allowed accessor';          Expression = "equals (Get-Content C:\x) 'y'" }
        @{ Kind = 'command inside -replace scriptblock'; Expression = "'a' -replace 'a', { Remove-Item C:\x }" }
        @{ Kind = 'command inside -split scriptblock';   Expression = "'a' -split { Remove-Item C:\x }" }
        @{ Kind = 'command inside trap';                 Expression = 'trap { Remove-Item C:\x } 1/0' }
        @{ Kind = 'function definition then call';      Expression = 'function f { Remove-Item C:\x }; f' }
        @{ Kind = 'New-Object';                          Expression = "(New-Object Net.WebClient).DownloadString('http://x')" }
        # assignment and mutation
        @{ Kind = 'variable assignment';                 Expression = '$FailCounter = 0' }
        @{ Kind = 'env assignment';                      Expression = '$env:PATH = ''evil''' }
        @{ Kind = 'global assignment';                   Expression = '$global:StopTaskProcessing = $true' }
        @{ Kind = 'compound assignment';                 Expression = '$x += 1' }
        @{ Kind = 'property assignment';                 Expression = '$obj.Prop = 1' }
        @{ Kind = 'postfix increment';                   Expression = '$x++' }
        @{ Kind = 'prefix increment';                    Expression = '++$x' }
        @{ Kind = 'postfix decrement';                   Expression = '$x--' }
        @{ Kind = 'prefix decrement';                    Expression = '--$x' }
        # method calls
        @{ Kind = 'instance method';                     Expression = '$reporting.Clear()' }
        @{ Kind = 'static method';                       Expression = "[System.IO.File]::Delete('C:\x')" }
        @{ Kind = 'static constructor';                  Expression = "[System.Net.WebClient]::new().DownloadString('http://x')" }
        @{ Kind = 'scriptblock Create + Invoke';         Expression = "[scriptblock]::Create('whoami').Invoke()" }
        @{ Kind = 'reflection chain';                    Expression = "''.GetType().Assembly.GetType('System.Diagnostics.Process').Start('cmd')" }
        @{ Kind = 'InvokeCommand on ExecutionContext';   Expression = "`$ExecutionContext.InvokeCommand.InvokeScript('whoami')" }
        @{ Kind = 'Environment.Exit';                    Expression = '[System.Environment]::Exit(1)' }
        # statements with effects outside the predicate
        @{ Kind = 'file redirection';                    Expression = "'pwned' > C:\owned.txt" }
        @{ Kind = 'append redirection';                  Expression = "'pwned' >> C:\owned.txt" }
        @{ Kind = 'error-stream redirection to file';    Expression = '$x 2> C:\owned.txt' }
        @{ Kind = 'all-streams redirection to file';     Expression = '$x *> C:\owned.txt' }
        @{ Kind = 'redirection inside expression';       Expression = "`$true -and ('a' > /dev/null)" }
        @{ Kind = 'exit';                                Expression = 'exit 3' }
        @{ Kind = 'break';                               Expression = 'break' }
        @{ Kind = 'labelled break';                      Expression = 'break outer' }
        @{ Kind = 'continue';                            Expression = 'continue' }
        @{ Kind = 'break inside expression';             Expression = 'if ($true) { break }' }
    )

    Context "every side-effecting shape is rejected before it can run" {

        It "rejects <Kind> in a preCondition" -TestCases $sideEffects {
            param($Kind, $Expression)
            { Assert-SafeConditionExpression -Expression $Expression } | Should -Throw
        }

        It "rejects <Kind> in a postCondition (the wider allow-list does not widen the grammar)" -TestCases $sideEffects {
            param($Kind, $Expression)
            { Assert-SafeConditionExpression -Expression $Expression -AllowStopProcessing } | Should -Throw
        }
    }

    Context "the postCondition-only accessors stay out of preCondition" {

        It "rejects <Accessor> in a preCondition" -TestCases @(
            @{ Accessor = 'stopProcessing()' }
            @{ Accessor = 'result().InDesiredState' }
            @{ Accessor = "not(stopProcessing())" }
            @{ Accessor = "equals (result()).Message 'x'" }
        ) {
            param($Accessor)
            { Assert-SafeConditionExpression -Expression $Accessor } | Should -Throw
        }
    }

    Context "secret() is never reachable from a condition" {

        It "rejects secret() in a preCondition and a postCondition" {
            { Assert-SafeConditionExpression -Expression "equals (secret 'DbPassword') 'x'" } | Should -Throw
            { Assert-SafeConditionExpression -Expression "equals (secret 'DbPassword') 'x'" -AllowStopProcessing } | Should -Throw
        }
    }

    Context "the documented pure predicates still pass (no over-blocking regression)" {

        It "accepts <Expression>" -TestCases @(
            @{ Expression = "`$ProjectEnsure -eq 'Present'" }
            @{ Expression = "`$Node.Project -eq 'X' -and -not `$Flag" }
            @{ Expression = "equals (variables 'Env') 'Prod'" }
            @{ Expression = "not (equals (parameters 'Mode') 'Dry')" }
            @{ Expression = "(reference 'Project').Id -ne `$null" }
            @{ Expression = "(mod (variables 'NodeIndex') 2) -eq 0" }
            @{ Expression = "startsWith (nodeName()) 'SRV'" }
            @{ Expression = "contains (variables 'Roles') 'web'" }
            @{ Expression = "(int (variables 'Port')) -gt 1024 -and (int (variables 'Port')) -lt 65535" }
            @{ Expression = "!`$Flag -or (`$Count -ge 2)" }
            @{ Expression = "(-`$Offset) -lt 0" }
            @{ Expression = "`$x -gt 2 -and `$x -lt 10" }
        ) {
            param($Expression)
            { Assert-SafeConditionExpression -Expression $Expression } | Should -Not -Throw
        }

        It "accepts the documented postCondition composition" {
            { Assert-SafeConditionExpression -Expression 'result().InDesiredState -or stopProcessing()' -AllowStopProcessing } | Should -Not -Throw
        }
    }
}
