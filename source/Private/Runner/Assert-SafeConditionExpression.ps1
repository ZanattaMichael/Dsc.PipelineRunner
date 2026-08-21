<#
.SYNOPSIS
Validates that a resource `condition` expression is a side-effect-free predicate.

.DESCRIPTION
A `condition` on a resource is meant to be a pure predicate — it decides whether the
resource is evaluated, nothing more. Because Start-DscRunner turns the configured string
into a script block and runs it, an unconstrained condition could invoke commands, assign
variables, or call methods that mutate state (see issue #35). Assert-SafeConditionExpression
parses the expression and rejects it if it contains any of:

  - a command invocation      (CommandAst)              e.g. `Stop-TaskProcessing`
  - a variable assignment     (AssignmentStatementAst)  e.g. `$FailCounter = 0`
  - a method / member call     (InvokeMemberExpressionAst) e.g. `$reporting.Clear()`

Comparisons, logical operators, variable reads and property access (for example
`$Node.Project -eq 'X'`) remain permitted, which is all the example configurations rely on.
The check runs before the condition is executed, so a rejected condition never runs.

.PARAMETER Expression
The raw condition string taken from a resource's `condition` key.

.EXAMPLE
Assert-SafeConditionExpression -Expression "$ProjectEnsure -eq 'Present'"
Passes: a comparison with no side effects.

.EXAMPLE
Assert-SafeConditionExpression -Expression 'Stop-TaskProcessing'
Throws: a condition may not invoke a command.
#>
function Assert-SafeConditionExpression {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Expression
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Expression, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "[Dsc.PipelineRunner] Invalid 'condition' expression [$Expression]: $($parseErrors[0].Message)"
    }

    # A condition is a predicate: it may read variables and properties and compare them,
    # but it must not invoke commands, assign variables, or call methods (all of which can
    # mutate the runner's own state and its audit record — see #35).
    $forbidden = $ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.CommandAst] -or
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
        throw "[Dsc.PipelineRunner] A 'condition' must be a side-effect-free predicate. Rejected condition [$Expression] because it contains a $kind [$($offender.Extent.Text)]. Conditions may not invoke commands, assign variables, or call methods."
    }
}
