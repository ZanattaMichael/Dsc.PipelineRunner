<#
.SYNOPSIS
Validates and normalizes an engine's raw output into a [DscMethodResult].

.DESCRIPTION
The engine boundary is typed (see the DscMethodResult class). Engines return a loose
object (a [hashtable] or [pscustomobject]) so that drop-in engine files never need to
reference a module-internal class across scopes; this function enforces the contract
on the module side and constructs the concrete [DscMethodResult].

It accepts an object that already exposes the contract fields, coerces the required
booleans, and fills sensible defaults per method (a successful Set/Get is treated as
in the desired state unless the engine says otherwise). A $null result — or one
missing the state signal on a Test — is a contract violation and throws.

.PARAMETER InputObject
The raw object returned by the engine action.

.PARAMETER Method
The method that produced the result ('Test', 'Set', or 'Get'); governs the defaults.
#>
function ConvertTo-DscMethodResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('Test', 'Set', 'Get')]
        [string]$Method
    )

    if ($null -eq $InputObject) {
        throw "[ConvertTo-DscMethodResult] The '$Method' engine returned no result. An engine must return an object exposing InDesiredState, RebootRequired, Message and Raw."
    }

    # Already normalized — pass through unchanged.
    if ($InputObject -is [DscMethodResult]) {
        return $InputObject
    }

    # Read a field from either a hashtable or an object, returning $null when absent.
    $get = {
        param($obj, [string]$key)
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($key)) { return $obj[$key] }
            return $null
        }
        $prop = $obj.PSObject.Properties[$key]
        if ($prop) { return $prop.Value }
        return $null
    }

    $hasState = $false
    $stateValue = & $get $InputObject 'InDesiredState'
    if ($null -ne $stateValue) { $hasState = $true }

    # A Test must report the desired-state signal; Set/Get default to $true on success.
    if (-not $hasState) {
        if ($Method -eq 'Test') {
            throw "[ConvertTo-DscMethodResult] The 'Test' engine result did not include an 'InDesiredState' value, which is required by the engine contract."
        }
        $stateValue = $true
    }

    $rebootValue = & $get $InputObject 'RebootRequired'
    $messageValue = & $get $InputObject 'Message'
    $rawValue = & $get $InputObject 'Raw'
    if ($null -eq $rawValue) { $rawValue = $InputObject }

    return [DscMethodResult]@{
        InDesiredState = [bool]$stateValue
        RebootRequired = [bool]$rebootValue
        Message        = [string]$messageValue
        Raw            = $rawValue
    }
}
