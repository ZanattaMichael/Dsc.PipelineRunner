<#
.SYNOPSIS
Returns the name of the node whose configuration is currently running.

.DESCRIPTION
A compiled configuration file is per-node, and the runner already derives the node name from
that file's name - it is the NodeName recorded on every result row. `nodeName()` exposes the
same value to `properties`, `preCondition` and `postCondition`, so a configuration shared by
several nodes can branch on which one it is running for without a Datum handler baking the
answer in at compile time.

It is a zero-argument accessor, so like `result()` it is rewritten before a CONDITION is parsed
- see ConvertTo-NormalizedConditionExpression. That rewrite is part of condition validation and
does not reach property expansion, so the two places spell it differently:

  preCondition: startsWith (nodeName()) 'SRV'    # nodeName() or (nodeName)
  properties:   { who: $(nodeName) }             # bare - $(nodeName()) is a PARSE ERROR

`$( )` already supplies the grouping a zero-argument call needs, so the bare spelling is the
natural one inside a property; the empty parentheses are what PowerShell cannot parse.

Outside a run it returns $null. Start-DscRunner sets the value as it opens a configuration file
and clears it when the file is finished, so a value never leaks from one file into the next.

.EXAMPLE
PS> nodeName()
Returns e.g. 'SRV-APP-01' while running SRV-APP-01.yml.

.EXAMPLE
PS> startsWith (nodeName()) 'SRV-APP'
A condition that applies a resource only to the application-server nodes.

.EXAMPLE
PS> $(nodeName)
The node name used inside a resource property - bare, without the empty parentheses.
#>
function invoke-nodename {
    [CmdletBinding()]
    [Alias('nodeName')]
    param ()

    return $script:currentNodeName
}
