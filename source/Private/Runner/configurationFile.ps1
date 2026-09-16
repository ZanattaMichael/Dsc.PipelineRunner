<#
.SYNOPSIS
Returns the full path of the configuration file currently running.

.DESCRIPTION
`configurationFile()` is `nodeName()`'s companion: where `nodeName()` gives the file's name
without its extension, this gives the whole path the runner was pointed at. It is the value
recorded as ConfigurationFile on every result row.

Its normal use is diagnostic - putting the originating file into a resource property so an
applied artefact says where it came from - rather than for branching, since a condition that
depends on a full path is usually better expressed against `nodeName()`.

It is a zero-argument accessor, so it is rewritten before a CONDITION is parsed in the same way
`result()` and `nodeName()` are; see ConvertTo-NormalizedConditionExpression. As with
`nodeName()`, that rewrite does not reach property expansion, so inside `properties` it is
written bare - `$(configurationFile)`, not `$(configurationFile())`.

Outside a run it returns $null. Start-DscRunner sets it as it opens a configuration file and
clears it when the file is finished.

.EXAMPLE
PS> configurationFile()
Returns e.g. 'C:\Configs\SRV-APP-01.yml'.

.EXAMPLE
PS> contains (configurationFile()) 'Production'
A condition that branches on a segment of the configuration file's path.
#>
function invoke-configurationfile {
    [CmdletBinding()]
    [Alias('configurationFile')]
    param ()

    return $script:currentConfigurationFile
}
