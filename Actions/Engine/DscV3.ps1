<#
.SYNOPSIS
Engine action: evaluate a resource through dsc.exe (DSC v3 — cross-platform).

.DESCRIPTION
Drives Microsoft's DSC v3 command-line engine (`dsc resource <verb>`), which runs on
Windows, Linux and macOS. This is what makes hosted Linux/macOS agents useful, since
Invoke-DscResource is Windows / PowerShell-DSC-v2 first.

Behavior:
  - maps Test/Set/Get to the dsc resource sub-command,
  - passes the desired-state Property hashtable as JSON on standard input (`--file -`),
    never as a command-line argument, so a resolved credential is not visible in the process table,
  - surfaces a non-zero dsc.exe exit as a thrown error, so the runner records the
    resource as failed (feeding the exit-code work in a later phase),
  - parses the JSON result into the normalized engine contract shape.

.PARAMETER Context
A hashtable with keys: Method ('Test'|'Set'|'Get'), ModuleName, Name, Property.

.OUTPUTS
An object exposing InDesiredState, RebootRequired, Message and Raw (normalized by the
runner into a [DscMethodResult]).
#>
[CmdletBinding()]
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

# DscV2/CIM marshals a [pscredential]-typed property natively (MSFT_Credential) over the
# encrypted WinRM transport. JSON has no credential type, so DSC v3 needs the plaintext
# resolved immediately before building the instance JSON (#57 §5) - this is the one place it is ever
# revealed, and only into the JSON payload sent either to the local dsc.exe process or, when
# $Context.Session is set, over the already-encrypted Invoke-Command -Session channel; it is
# never written to disk. A [pscredential] becomes {username, password}; a bare
# [securestring] becomes its plaintext value. Both cases are still covered by the
# Test-SensitivePropertyName redaction below, so the plaintext never reaches the log.
function ConvertTo-DscV3CredentialSafeProperty {
    param(
        [hashtable]$InputHashTable,
        [System.Collections.Generic.HashSet[string]]$ForceRedactKeys,
        [System.Collections.Generic.List[string]]$SecretValues
    )

    $resolved = @{}
    foreach ($key in $InputHashTable.Keys) {
        $value = $InputHashTable[$key]
        if ($value -is [System.Management.Automation.PSCredential]) {
            $plainPassword = Unprotect-SecureString -SecureString $value.Password
            $resolved[$key] = @{
                username = $value.UserName
                password = $plainPassword
            }
            $null = $ForceRedactKeys.Add($key)
            if (-not [string]::IsNullOrEmpty($plainPassword)) { $SecretValues.Add($plainPassword) }
        }
        elseif ($value -is [securestring]) {
            $plainValue = Unprotect-SecureString -SecureString $value
            $resolved[$key] = $plainValue
            $null = $ForceRedactKeys.Add($key)
            if (-not [string]::IsNullOrEmpty($plainValue)) { $SecretValues.Add($plainValue) }
        }
        elseif ($value -is [hashtable]) {
            $resolved[$key] = ConvertTo-DscV3CredentialSafeProperty -InputHashTable $value -ForceRedactKeys $ForceRedactKeys -SecretValues $SecretValues
        }
        else {
            $resolved[$key] = $value
        }
    }
    return $resolved
}

# Ground-truth secret keys (originally a [pscredential]/[securestring]) are force-redacted
# in the log below regardless of whether their name happens to match the
# Test-SensitivePropertyName heuristic (e.g. a property named 'SAPwd' would otherwise slip
# through the name-substring check).
$forceRedactKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
# Every plaintext secret revealed above, so dsc.exe's own output can be scrubbed of them before
# it is surfaced in a thrown error (dsc echoes the offending input on a schema failure).
$secretValues = [System.Collections.Generic.List[string]]::new()
$property = ConvertTo-DscV3CredentialSafeProperty -InputHashTable $property -ForceRedactKeys $forceRedactKeys -SecretValues $secretValues
$inputJson = $property | ConvertTo-Json -Depth 32 -Compress

# The instance JSON goes to dsc over STDIN (`--file -`), never as an `--input` argument: a
# command-line argument is visible to every local user through the process table
# (/proc/<pid>/cmdline, Win32_Process.CommandLine, Task Manager) and to process-creation
# auditing (Sysmon / 4688), which would expose a resolved credential for as long as dsc runs
# and in whatever retains those logs. Standard input is private to the two processes.
$arguments = @('resource', $verb, '--resource', $resourceType, '--file', '-')

function Protect-DscV3Output {
    param([AllowNull()][AllowEmptyString()][string]$Text, [System.Collections.Generic.List[string]]$Secrets)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $scrubbed = $Text
    foreach ($secret in $Secrets) {
        $scrubbed = $scrubbed.Replace($secret, '[REDACTED]')
        # dsc echoes input as JSON, so a secret containing '"' or '\' comes back escaped.
        $jsonEscaped = ([string](ConvertTo-Json -InputObject $secret -Compress)).Trim('"')
        if ($jsonEscaped -ne $secret) {
            $scrubbed = $scrubbed.Replace($jsonEscaped, '[REDACTED]')
        }
    }
    return $scrubbed
}

# Redact-for-logging only: the real instance JSON above is unredacted (dsc.exe needs the
# actual secret), but the verbose breadcrumb must not echo it. Routes through the same
# Test-SensitivePropertyName/Protect-SensitiveValue heuristic used elsewhere (#34), plus the
# ground-truth $forceRedactKeys collected above, rather than logging $inputJson directly,
# which used to leak every property value verbatim.
function ConvertTo-RedactedPropertyTable {
    param([hashtable]$InputHashTable, [System.Collections.Generic.HashSet[string]]$ForceRedactKeys)

    $redacted = @{}
    foreach ($key in $InputHashTable.Keys) {
        $value = $InputHashTable[$key]
        if ($ForceRedactKeys.Contains($key)) {
            $redacted[$key] = '[REDACTED]'
        }
        elseif ($value -is [hashtable]) {
            $redacted[$key] = ConvertTo-RedactedPropertyTable -InputHashTable $value -ForceRedactKeys $ForceRedactKeys
        }
        elseif (Test-SensitivePropertyName -Name $key) {
            $redacted[$key] = '[REDACTED]'
        }
        else {
            $redacted[$key] = $value
        }
    }
    return $redacted
}

if ($VerbosePreference -ne 'SilentlyContinue') {
    $redactedJson = (ConvertTo-RedactedPropertyTable -InputHashTable $property -ForceRedactKeys $forceRedactKeys) | ConvertTo-Json -Depth 32 -Compress
    Write-Verbose "[Actions/Engine/DscV3] dsc $($arguments -join ' ') <<< $redactedJson"
}
$remoteSession = $null
if ($null -ne $Context.Session -and $null -ne $Context.Session.PSSession) {
    $remoteSession = $Context.Session.PSSession
    Write-Verbose "[Actions/Engine/DscV3] Using remote PSSession for [$resourceType]."
}
$run = Invoke-DscExecutable -Arguments $arguments -StandardInput $inputJson -Session $remoteSession

if ($run.ExitCode -ne 0) {
    throw "[Actions/Engine/DscV3] 'dsc resource $verb' failed for [$resourceType] (exit $($run.ExitCode)): $(Protect-DscV3Output -Text $run.Output -Secrets $secretValues)"
}

$parsed = $null
if (-not [string]::IsNullOrWhiteSpace($run.Output)) {
    try {
        $parsed = $run.Output | ConvertFrom-Json
    }
    catch {
        throw "[Actions/Engine/DscV3] Could not parse dsc.exe output as JSON for [$resourceType]: $(Protect-DscV3Output -Text $_.Exception.Message -Secrets $secretValues)"
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

# Reboot-pending signal: dsc.exe's exact shape for this is not yet confirmed against a
# real resource that sets it (#57 §3), so this reads tolerantly from either of the shapes
# documented/observed for Microsoft.DSC-family resources rather than assuming one -
# a top-level 'rebootRequired' boolean, or a nested 'metadata.Microsoft.DSC.rebootRequired'
# (the dsc.exe metadata envelope some resources attach to their result). Absent either,
# this defaults to $false, matching today's behavior for every resource that never signals it.
$rebootRequired = $false
if ($null -ne $parsed) {
    if ($null -ne $parsed.PSObject.Properties['rebootRequired']) {
        $rebootRequired = [bool]$parsed.rebootRequired
    }
    elseif ($parsed.PSObject.Properties['metadata'] -and
            $parsed.metadata.PSObject.Properties['Microsoft.DSC'] -and
            $parsed.metadata.'Microsoft.DSC'.PSObject.Properties['rebootRequired']) {
        $rebootRequired = [bool]$parsed.metadata.'Microsoft.DSC'.rebootRequired
    }
}

return [pscustomobject]@{
    InDesiredState = $inDesiredState
    RebootRequired = $rebootRequired
    Message        = $message
    Raw            = $parsed
}
