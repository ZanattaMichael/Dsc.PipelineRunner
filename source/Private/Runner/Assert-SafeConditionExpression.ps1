<#
.SYNOPSIS
Validates that a resource `condition` expression is a side-effect-free predicate.

.DESCRIPTION
A `condition` on a resource is meant to be a pure predicate — it decides whether the
resource is evaluated, nothing more. Because Start-DscRunner turns the configured string
into a script block and runs it, an unconstrained condition could invoke commands, assign
variables, or call methods that mutate state (see issue #35). Assert-SafeConditionExpression
parses the expression and rejects it if it contains any of:

  - a command invocation whose name is not on the allow-list (CommandAst) e.g. `Stop-TaskProcessing`
  - a variable assignment                          (AssignmentStatementAst)   e.g. `$FailCounter = 0`
  - a method / member call                          (InvokeMemberExpressionAst) e.g. `$reporting.Clear()`

The function-language accessors `parameters()`, `variables()`, `reference()`, `equals()` and
`not()` are permitted command invocations — they are pure reads/comparisons designed to throw
on a missing key or reference, never to mutate runner state — so a condition may combine them
with ordinary operators. Every other command invocation is rejected, including one nested
inside an otherwise-allowed call (e.g. `equals (Get-Item C:\) 'x'`), since `FindAll` walks the
whole expression tree rather than only its top level.

Comparisons, logical operators, variable reads and property access (for example
`$Node.Project -eq 'X'`) remain permitted, which is all the example configurations rely on.
The check runs before the condition is executed, so a rejected condition never runs.

.PARAMETER Expression
The raw condition string taken from a resource's `condition`/`preCondition` key.

.PARAMETER AllowStopProcessing
Additionally allow-lists the `result` and `stopProcessing` function-language accessors
(#57 §2). Reserved for `postCondition`, which unlike a plain `condition`/`preCondition` is
allowed to read the engine's result and request that the run stop after this resource -
never pass this switch when validating a `condition`/`preCondition`, which must stay a
side-effect-free predicate (#35).

.EXAMPLE
Assert-SafeConditionExpression -Expression "$ProjectEnsure -eq 'Present'"
Passes: a comparison with no side effects.

.EXAMPLE
Assert-SafeConditionExpression -Expression 'Stop-TaskProcessing'
Throws: a condition may not invoke a command outside the allow-list.

.EXAMPLE
Assert-SafeConditionExpression -Expression "equals (variables 'Env') 'Prod'"
Passes: the function-language accessors are allow-listed command invocations.
#>
function Assert-SafeConditionExpression {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Expression,

        [switch] $AllowStopProcessing
    )

    # The function-language accessors are pure, side-effect-free reads/comparisons (they throw
    # on a missing key rather than mutate state), so they are allowed as command invocations
    # inside a condition. Everything else stays rejected.
    $allowedCommands = @('parameters', 'variables', 'reference', 'equals', 'not')

    # postCondition only (#57 §2): result() is a pure read of the engine outcome, but
    # stopProcessing() is a deliberate, narrowly-scoped side effect - see stopProcessing.ps1.
    if ($AllowStopProcessing) {
        $allowedCommands += @('result', 'stopProcessing')
    }

    # `result()` / `stopProcessing()` (#57 §2) do not parse as written - see
    # ConvertTo-NormalizedConditionExpression for why - so validate the same normalized text
    # that Start-DscRunner will actually turn into a script block.
    $normalizedExpression = ConvertTo-NormalizedConditionExpression -Expression $Expression

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($normalizedExpression, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "[Dsc.PipelineRunner] Invalid 'condition' expression [$Expression]: $($parseErrors[0].Message)"
    }

    # A condition is a predicate: it may read variables and properties and compare them, and
    # it may call the allow-listed function-language accessors, but it must not invoke any
    # other command, assign variables, or call methods (all of which can mutate the runner's
    # own state and its audit record — see #35).
    $forbidden = $ast.FindAll({
        (
            ($args[0] -is [System.Management.Automation.Language.CommandAst]) -and
            (-not (
                $args[0].GetCommandName() -and
                ($allowedCommands -contains $args[0].GetCommandName())
            ))
        ) -or
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -or
        $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true)

    if ($forbidden) {
        $offender = $forbidden[0]
        $kind = switch ($offender) {
            { $_ -is [System.Management.Automation.Language.CommandAst] }             { 'command invocation'; break }
            { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] } { 'variable assignment'; break }
            default                                                                  { 'method call' }
        }
        throw "[Dsc.PipelineRunner] A 'condition' must be a side-effect-free predicate. Rejected condition [$Expression] because it contains a $kind [$($offender.Extent.Text)]. Conditions may only call $($allowedCommands -join ', '); they may not invoke other commands, assign variables, or call methods."
    }
}
