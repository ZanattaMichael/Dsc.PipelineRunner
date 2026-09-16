Describe "Assert-SafeConditionExpression Function Tests" -Tag Unit, Runner {

    BeforeAll {
        # Assert-SafeConditionExpression calls ConvertTo-NormalizedConditionExpression (#57 §2);
        # dot-source it too since this test loads the function standalone rather than through the
        # built module, where every Private function is dot-sourced together.
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
    }

    Context "permitted predicates" {

        It "allows a simple comparison" {
            { Assert-SafeConditionExpression -Expression "'a' -eq 'b'" } | Should -Not -Throw
        }

        It "allows a variable comparison" {
            { Assert-SafeConditionExpression -Expression '$ProjectEnsure -eq ''Present''' } | Should -Not -Throw
        }

        It "allows property access on a variable" {
            { Assert-SafeConditionExpression -Expression '$Node.Project -ne $null' } | Should -Not -Throw
        }

        It "allows logical operators and grouping" {
            { Assert-SafeConditionExpression -Expression '(1 -eq 1) -and ($x -ne 2)' } | Should -Not -Throw
        }

        It "allows a bare parameters() call" {
            { Assert-SafeConditionExpression -Expression "parameters('Environment')" } | Should -Not -Throw
        }

        It "allows a bare variables() call" {
            { Assert-SafeConditionExpression -Expression "variables('ProjectWorkBoardsStatus')" } | Should -Not -Throw
        }

        It "allows a bare reference() call" {
            { Assert-SafeConditionExpression -Expression "reference('Configuration Git Repository')" } | Should -Not -Throw
        }

        It "allows equals() combining parameters() and variables()" {
            { Assert-SafeConditionExpression -Expression "equals(parameters('Environment'), variables('ProjectWorkBoardsStatus'))" } | Should -Not -Throw
        }

        It "allows not() wrapping equals()" {
            { Assert-SafeConditionExpression -Expression "not(equals(variables('ProjectWorkBoardsStatus'), 'disabled'))" } | Should -Not -Throw
        }

        It "allows the whitelisted functions mixed with ordinary operators" {
            { Assert-SafeConditionExpression -Expression "(parameters('Environment') -eq 'Prod') -and (variables('ProjectWorkBoardsStatus') -eq 'enabled')" } | Should -Not -Throw
        }
    }

    Context "the extended accessor allow-list" {

        # Each accessor is tested for its own behaviour elsewhere (Arithmetic.tests.ps1,
        # StringFunctions.tests.ps1, RunContext.tests.ps1). What is under test HERE is only that
        # the validator lets it through - an accessor that works but is not allow-listed is
        # rejected before it ever runs, which is a failure mode no accessor-level test can see.

        It "allows the arithmetic accessors" {
            { Assert-SafeConditionExpression -Expression "(mod (variables 'NodeIndex') 2) -eq 0" }         | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "(add (sub 10 1) (mul 2 3)) -gt 5" }              | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "(div (float (variables 'A')) 2) -lt 0.9" }       | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "(max (min 1 2) (int '3')) -le 10" }              | Should -Not -Throw
        }

        It "allows the string and collection accessors" {
            { Assert-SafeConditionExpression -Expression "equals (toLower (variables 'Env')) 'production'" } | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "startsWith (variables 'Name') 'SRV-'" }            | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "contains (variables 'Flags') 'Boards'" }           | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "not (empty (coalesce (variables 'A') 'x'))" }      | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "equals (concat (variables 'A') '-db') 'x-db'" }    | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "equals (toUpper (variables 'A')) 'X'" }            | Should -Not -Throw
        }

        It "allows the run-context accessors" {
            { Assert-SafeConditionExpression -Expression "startsWith (nodeName()) 'SRV-APP'" }        | Should -Not -Throw
            { Assert-SafeConditionExpression -Expression "contains (configurationFile()) 'Prod'" }    | Should -Not -Throw
        }

        It "allows using() in a preCondition, nested as the parser requires" {
            # using() is gated by the source resource's own notify declaration, and the runner
            # sets $script:currentResourceKey before a preCondition is evaluated, so the gate
            # applies here exactly as it does during property expansion.
            { Assert-SafeConditionExpression -Expression "(using 'Module/Type/Name').Id -eq 'x'" } | Should -Not -Throw
        }

        It "rejects a bare, unnested using() with a parse error, not an allow-list error" {
            # `using` is a PowerShell reserved word as the first token of a statement, so this
            # never reaches the allow-list check at all.
            { Assert-SafeConditionExpression -Expression "using 'Module/Type/Name'" } |
                Should -Throw "*Invalid 'condition' expression*"
        }

        It "does not allow secret(), which is deliberately off the list" {
            # A condition is recorded verbatim in the run report and in every SKIP message it
            # produces, so a secret lookup must not be expressible in one.
            { Assert-SafeConditionExpression -Expression "equals (secret 'ApiKey') 'x'" } |
                Should -Throw '*command invocation*'
        }

        It "still rejects an unrelated command nested inside a new accessor" {
            { Assert-SafeConditionExpression -Expression "concat (Get-Item C:\) 'x'" } |
                Should -Throw '*command invocation*'
        }
    }

    Context "rejected side effects" {

        It "rejects a bare command invocation" {
            { Assert-SafeConditionExpression -Expression 'Stop-TaskProcessing' } |
                Should -Throw '*command invocation*'
        }

        It "rejects a command invocation nested in an expression" {
            { Assert-SafeConditionExpression -Expression '(Get-Item C:\).Name -eq ''x''' } |
                Should -Throw '*command invocation*'
        }

        It "rejects a non-whitelisted command nested inside an allowed function call" {
            { Assert-SafeConditionExpression -Expression "equals(Get-Item C:\, 'x')" } |
                Should -Throw '*command invocation*'
        }

        It "rejects stopProcessing(), which is not on the condition allow-list" {
            { Assert-SafeConditionExpression -Expression "parameters('X'); stopProcessing" } |
                Should -Throw '*command invocation*'
        }

        It "rejects a variable assignment" {
            { Assert-SafeConditionExpression -Expression '$FailCounter = 0' } |
                Should -Throw '*variable assignment*'
        }

        It "rejects a method call" {
            { Assert-SafeConditionExpression -Expression '$results.Clear()' } |
                Should -Throw '*method call*'
        }

        It "rejects a syntactically invalid expression" {
            { Assert-SafeConditionExpression -Expression '$x -eq' } |
                Should -Throw "*Invalid 'condition' expression*"
        }
    }

    Context "-AllowStopProcessing (postCondition only, #57 §2)" {

        It "still rejects stopProcessing() without the switch" {
            { Assert-SafeConditionExpression -Expression 'stopProcessing()' } |
                Should -Throw '*command invocation*'
        }

        It "still rejects result() without the switch" {
            { Assert-SafeConditionExpression -Expression 'result().InDesiredState' } |
                Should -Throw '*command invocation*'
        }

        It "allows stopProcessing() with the switch" {
            { Assert-SafeConditionExpression -Expression 'stopProcessing()' -AllowStopProcessing } |
                Should -Not -Throw
        }

        It "allows result() with the switch" {
            { Assert-SafeConditionExpression -Expression 'result().InDesiredState' -AllowStopProcessing } |
                Should -Not -Throw
        }

        It "allows the documented 'fail or stop' composition" {
            # This is the spelling README/wiki lead with, and it used to fail validation with a
            # PARSE error: stopProcessing() was rewritten to a bare `stopProcessing`, and a bare
            # command is not a valid operand of -or. The rewrite now produces
            # `(stopProcessing)`, which parses in both positions.
            { Assert-SafeConditionExpression -Expression 'result().InDesiredState -or stopProcessing()' -AllowStopProcessing } |
                Should -Not -Throw
        }

        It "still rejects an unrelated command even with the switch" {
            { Assert-SafeConditionExpression -Expression 'Stop-TaskProcessing' -AllowStopProcessing } |
                Should -Throw '*command invocation*'
        }

        It "still rejects a variable assignment even with the switch" {
            { Assert-SafeConditionExpression -Expression '$x = 1' -AllowStopProcessing } |
                Should -Throw '*variable assignment*'
        }
    }

    # Regression coverage for issue #57's threat model: a condition/preCondition/postCondition
    # string comes straight from a configuration file, so it must be treated as untrusted input.
    # Every payload below was run against the current implementation (post §2-§7) before this
    # test was written; none of them bypassed the allow-list. If any of these ever start
    # passing (i.e. Assert-SafeConditionExpression stops throwing), that is a real vulnerability,
    # not a broken test - do not relax the assertion, fix the guard.
    Context "Security: injection attempts" -Tag Security {

        Context "direct disallowed command invocation" {

            It "rejects Remove-Item with destructive parameters" {
                { Assert-SafeConditionExpression -Expression 'Remove-Item C:\ -Recurse -Force' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects Invoke-Expression on a variable" {
                { Assert-SafeConditionExpression -Expression 'Invoke-Expression $x' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects the 'iex' alias of Invoke-Expression" {
                # The allow-list check is purely syntactic (CommandAst.GetCommandName()), so it
                # sees the literal text 'iex', not the cmdlet it resolves to - and 'iex' is not on
                # the allow-list either, so it is rejected regardless.
                { Assert-SafeConditionExpression -Expression "iex 'whoami'" } |
                    Should -Throw '*command invocation*'
            }

            It "rejects the call operator invoking a parenthesized command expression" {
                # '& (Get-Process)' has no static command name (the name is itself an expression
                # to be evaluated), so GetCommandName() returns an empty string; the guard's
                # "-not (name -and allow-listed)" treats an empty/absent name as forbidden, and
                # separately the nested Get-Process CommandAst is caught by the same walk.
                { Assert-SafeConditionExpression -Expression '& (Get-Process)' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects a backtick-obfuscated command name" {
                # PowerShell's tokenizer resolves the backtick escape before Assert-SafeConditionExpression
                # ever sees a command name, so 'Rem`ove-Item' cannot be used to spell a name that
                # slips past the allow-list under a different string than what actually executes.
                { Assert-SafeConditionExpression -Expression 'Rem`ove-Item C:\' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects Start-Process" {
                { Assert-SafeConditionExpression -Expression 'Start-Process notepad' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects New-Object instantiating a networking type" {
                { Assert-SafeConditionExpression -Expression 'New-Object System.Net.WebClient' } |
                    Should -Throw '*command invocation*'
            }
        }

        Context "disallowed command nested inside an allowed call" {

            # #57 §1 explicitly walks the whole AST (FindAll(..., $true)), not just the top
            # level, so a disallowed command hidden as an argument to an allowed function-language
            # accessor must still be caught. These are regression tests proving that still holds
            # after the §2-§7 changes (postCondition accessors, lifecycle scripts, remote targets,
            # credentials) layered on top of the same guard.
            It "rejects Remove-Item nested inside equals()" {
                { Assert-SafeConditionExpression -Expression "equals(Remove-Item C:\, 'x')" } |
                    Should -Throw '*command invocation*'
            }

            It "rejects a bare disallowed command name with no arguments nested inside equals()" {
                # A bare 'Remove-Item' with no further arguments, used as one comma-separated
                # argument to equals(...), does not even parse as a valid expression term (PowerShell
                # requires an argument to be an expression, and a lone command name is not one in
                # that position) - so this is rejected one step earlier, as a parse error rather
                # than as a nested 'command invocation'. Both outcomes reject the payload before it
                # can run; documenting the parse-error shape here so it is not mistaken for a gap.
                { Assert-SafeConditionExpression -Expression "equals(Remove-Item, 'x')" } |
                    Should -Throw "*Invalid 'condition' expression*"
            }

            It "rejects Invoke-Expression nested inside not()" {
                { Assert-SafeConditionExpression -Expression "not(Invoke-Expression 'whoami')" } |
                    Should -Throw '*command invocation*'
            }
        }

        Context "variable assignment / exfiltration attempts" {

            It "rejects an assignment into `$env:PATH" {
                { Assert-SafeConditionExpression -Expression '$env:PATH = ''evil''' } |
                    Should -Throw '*variable assignment*'
            }

            It "rejects an assignment into a global-scoped variable sourced from parameters()" {
                { Assert-SafeConditionExpression -Expression "`${global:x} = (parameters('Y'))" } |
                    Should -Throw '*variable assignment*'
            }
        }

        Context "method-call injection" {

            It "rejects a chained GetType()/Assembly/Process.Start() reflection payload" {
                { Assert-SafeConditionExpression -Expression "(parameters('X')).GetType().Assembly.GetType('System.Diagnostics.Process').Start('cmd')" } |
                    Should -Throw '*method call*'
            }

            It "rejects any InvokeMemberExpressionAst-shaped call on an allow-listed accessor's result" {
                { Assert-SafeConditionExpression -Expression "(parameters('X')).Invoke()" } |
                    Should -Throw '*method call*'
            }
        }

        Context "string-based indirection attempting to smuggle a command past the allow-list" {

            It "rejects the call operator invoking a concatenated command name" {
                # '& ("Rem"+"ove-Item")' is structurally still a CommandAst whose name is an
                # expression rather than a static string, so GetCommandName() returns empty and
                # the guard rejects it outright - the AST does not even need to evaluate the
                # concatenation to know this is not an allow-listed command. This proves the
                # indirection technique is structurally caught, not merely untested.
                { Assert-SafeConditionExpression -Expression '& ("Rem"+"ove-Item")' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects Invoke-Expression built from concatenated string parts" {
                { Assert-SafeConditionExpression -Expression 'Invoke-Expression ("Rem"+"ove-Item C:\")' } |
                    Should -Throw '*command invocation*'
            }
        }

        Context "postCondition-only accessor scoping (privilege boundary, #57 §2)" {

            # result()/stopProcessing() are deliberately scoped to postCondition only - a plain
            # condition/preCondition must stay a side-effect-free predicate (#35) and must never be
            # able to request that the run stop or read the engine's result. -AllowStopProcessing
            # is the switch that lifts that restriction, and only Start-DscRunner's postCondition
            # call site passes it (verified end-to-end in Start-DscRunner.tests.ps1).
            It "rejects result() when used as an ordinary condition/preCondition (no switch)" {
                { Assert-SafeConditionExpression -Expression 'result().InDesiredState' } |
                    Should -Throw '*command invocation*'
            }

            It "rejects stopProcessing() when used as an ordinary condition/preCondition (no switch)" {
                { Assert-SafeConditionExpression -Expression 'stopProcessing()' } |
                    Should -Throw '*command invocation*'
            }
        }

        Context "postCondition injection variants (same allow-list applies, #57 §2)" {

            # postCondition reuses Assert-SafeConditionExpression with -AllowStopProcessing; that
            # switch only adds 'result'/'stopProcessing' to the allow-list, so every other
            # injection vector above must still be rejected identically for postCondition.
            It "rejects Remove-Item in a postCondition" {
                { Assert-SafeConditionExpression -Expression 'Remove-Item C:\' -AllowStopProcessing } |
                    Should -Throw '*command invocation*'
            }

            It "rejects Invoke-Expression in a postCondition" {
                { Assert-SafeConditionExpression -Expression 'Invoke-Expression $x' -AllowStopProcessing } |
                    Should -Throw '*command invocation*'
            }

            It "rejects a disallowed command nested inside equals() in a postCondition" {
                { Assert-SafeConditionExpression -Expression "equals(Remove-Item C:\, 'x')" -AllowStopProcessing } |
                    Should -Throw '*command invocation*'
            }

            It "rejects a variable assignment in a postCondition" {
                { Assert-SafeConditionExpression -Expression '$env:PATH = ''evil''' -AllowStopProcessing } |
                    Should -Throw '*variable assignment*'
            }

            It "rejects a reflection-based method-call payload built from result() in a postCondition" {
                { Assert-SafeConditionExpression -Expression "(result()).GetType().Assembly.GetType('System.Diagnostics.Process').Start('cmd')" -AllowStopProcessing } |
                    Should -Throw '*method call*'
            }

            It "rejects the call-operator string-concatenation indirection in a postCondition" {
                { Assert-SafeConditionExpression -Expression '& ("Rem"+"ove-Item")' -AllowStopProcessing } |
                    Should -Throw '*command invocation*'
            }
        }
    }
}
