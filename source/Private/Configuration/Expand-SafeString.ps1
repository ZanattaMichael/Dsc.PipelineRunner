<#
.SYNOPSIS
Expands a configuration string (variables and $(...) sub-expressions) after proving the expansion is side-effect free.

.DESCRIPTION
Resource property values are expanded with $ExecutionContext.InvokeCommand.ExpandString, which
evaluates any $(...) sub-expression in the string as arbitrary PowerShell. Without a guard, a
configuration value such as '$(Remove-Item C:\data -Recurse)' would run in the runner's process
even when PipelineRunnerSettings.AllowExecutionScripts is false and even though conditions are
restricted by Assert-SafeConditionExpression.

Expand-SafeString closes that gap in two steps:

  1. Fast path - a string with no '$' and no backtick cannot contain an expansion, so it is
     returned untouched. This also skips the (comparatively slow) ExpandString call for the
     large majority of property values.
  2. Otherwise the string is parsed as an expandable string and every embedded expression is
     passed through Assert-SafeConditionExpression - the same allow-list conditions use (the
     function-language accessors such as variables(), parameters(), reference(), using(), plus
     operators and variable reads; no other commands, assignments or method calls). The check
     fails closed: anything that does not parse to exactly one expandable string is rejected.

.PARAMETER Value
The raw string from the configuration.

.OUTPUTS
[string] the expanded value.
#>
# [string]::IsNullOrEmpty / IsNullOrWhiteSpace are pure predicates and the shipped example
# configurations use them inside $(if ...). Conditions forbid every method call, so before an
# embedded expression is validated each such call is replaced by its (still-validated) argument
# list; every other method call is left in place and rejected.
function ConvertTo-ValidatableExpression {
    param([string] $Text)

    $pure = 'IsNullOrEmpty', 'IsNullOrWhiteSpace'
    while ($true) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $args[0].Static -and
            $args[0].Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $args[0].Expression.TypeName.FullName -in 'string', 'System.String' -and
            $args[0].Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $args[0].Member.Value -in $pure
        }, $true)
        if (-not $calls -or $calls.Count -eq 0) { return $Text }

        # The last-starting call cannot contain another allowed call, so its offsets stay valid.
        $call = $calls | Sort-Object { $_.Extent.StartOffset } | Select-Object -Last 1
        $argumentText = @($call.Arguments | ForEach-Object { $_.Extent.Text }) -join ', '
        $Text = $Text.Substring(0, $call.Extent.StartOffset) + '@(' + $argumentText + ')' +
                $Text.Substring($call.Extent.EndOffset)
    }
}

function Expand-SafeString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.IndexOfAny([char[]]@('$', '`')) -lt 0) {
        return $Value
    }

    # A here-string has the same expandable-string semantics as ExpandString (embedded double
    # quotes stay literal), so the parsed AST is exactly what ExpandString would evaluate.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        ("@`"`n{0}`n`"@" -f $Value), [ref]$tokens, [ref]$parseErrors)

    $statements = $ast.EndBlock.Statements
    $expandable = $null
    if (-not ($parseErrors -and $parseErrors.Count -gt 0) -and $statements.Count -eq 1 -and
        $statements[0] -is [System.Management.Automation.Language.PipelineAst] -and
        $statements[0].PipelineElements.Count -eq 1 -and
        $statements[0].PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $expandable = $statements[0].PipelineElements[0].Expression
    }

    if ($expandable -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        foreach ($nested in $expandable.NestedExpressions) {
            try {
                Assert-SafeConditionExpression -Expression (ConvertTo-ValidatableExpression -Text $nested.Extent.Text)
            }
            catch {
                throw "[Expand-SafeString] Refusing to expand a property value that runs code. $($_.Exception.Message)"
            }
        }
    }
    elseif ($null -eq $expandable -or $expandable -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
        throw "[Expand-SafeString] Refusing to expand a property value that does not parse as a single expandable string."
    }

    return $ExecutionContext.InvokeCommand.ExpandString($Value)
}
