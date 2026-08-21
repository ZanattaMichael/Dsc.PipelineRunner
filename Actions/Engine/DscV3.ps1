<#
.SYNOPSIS
Engine action: evaluate a resource through dsc.exe (DSC v3 — cross-platform).

.DESCRIPTION
Drives Microsoft's DSC v3 command-line engine (`dsc resource <verb>`), which runs on
Windows, Linux and macOS. This is what makes hosted Linux/macOS agents useful, since
Invoke-DscResource is Windows / PowerShell-DSC-v2 first.

Behavior:
  - maps Test/Set/Get to the dsc resource sub-command,
  - passes the desired-state Property hashtable as JSON on --input,
  - surfaces a non-zero dsc.exe exit as a thrown error, so the runner records the
    resource as failed (feeding the exit-code work in a later phase),
  - parses the JSON result into the normalized engine contract shape.

.PARAMETER Context
A hashtable with keys: Method ('Test'|'Set'|'Get'), ModuleName, Name, Property.

.OUTPUTS
An object exposing InDesiredState, RebootRequired, Message and Raw (normalized by the
runner into a [DscMethodResult]).
#>
param(
    [hashtable]$Context = @{}
)

# DSC v3 resource types are namespaced 'Owner/Resource', matching the runner's task type.
$resourceType = '{0}/{1}' -f $Context.ModuleName, $Context.Name

# Fail fast on a type that is not even shaped like a DSC v3 identifier. Without this the
# only signal is an opaque non-zero exit from dsc.exe ('resource not found'); this points the
# operator straight at the compiled configuration. The check is structural (namespace/name);
# whether the type truly exists is still confirmed by dsc.exe itself below. Kept inline so the
# engine action stays self-contained (it is also driven directly by the CI smoke test).
$v3TypePattern = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*/[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$'
if ($resourceType -notmatch $v3TypePattern) {
    throw "[Actions/Engine/DscV3] Resource type '$resourceType' is not a DSC v3 identifier. DSC v3 types are 'namespace/name' (for example 'Microsoft.Windows/Registry'); a compiled configuration targeting the DscV3 engine must use DSC v3 resource types."
}

$verb = switch ($Context.Method) {
    'Test' { 'test' }
    'Set'  { 'set' }
    'Get'  { 'get' }
    default { throw "[Actions/Engine/DscV3] Unsupported method '$($Context.Method)'." }
}

$property = $Context.Property
if ($null -eq $property) { $property = @{} }
$inputJson = $property | ConvertTo-Json -Depth 32 -Compress

$arguments = @('resource', $verb, '--resource', $resourceType, '--input', $inputJson)

Write-Verbose "[Actions/Engine/DscV3] dsc $($arguments -join ' ')"
$run = Invoke-DscExecutable -Arguments $arguments

if ($run.ExitCode -ne 0) {
    throw "[Actions/Engine/DscV3] 'dsc resource $verb' failed for [$resourceType] (exit $($run.ExitCode)): $($run.Output)"
}

$parsed = $null
if (-not [string]::IsNullOrWhiteSpace($run.Output)) {
    try {
        $parsed = $run.Output | ConvertFrom-Json
    }
    catch {
        throw "[Actions/Engine/DscV3] Could not parse dsc.exe output as JSON for [$resourceType]: $($_.Exception.Message)"
    }
}

# DSC v3 result shapes:
#   test -> { desiredState, actualState, inDesiredState, differingProperties }
#   set  -> { beforeState, afterState, changedProperties }
#   get  -> { actualState }  (or the state object directly)
$inDesiredState = $true
$message = $null

if ($Context.Method -eq 'Test') {
    if ($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['inDesiredState']) {
        $inDesiredState = [bool]$parsed.inDesiredState
    }
    if ($null -ne $parsed -and $parsed.PSObject.Properties['differingProperties'] -and $parsed.differingProperties) {
        $message = "Differing properties: {0}" -f ($parsed.differingProperties -join ', ')
    }
}
elseif ($Context.Method -eq 'Set') {
    if ($null -ne $parsed -and $parsed.PSObject.Properties['changedProperties'] -and $parsed.changedProperties) {
        $message = "Changed properties: {0}" -f ($parsed.changedProperties -join ', ')
    }
}

return [pscustomobject]@{
    InDesiredState = $inDesiredState
    RebootRequired = $false
    Message        = $message
    Raw            = $parsed
}
