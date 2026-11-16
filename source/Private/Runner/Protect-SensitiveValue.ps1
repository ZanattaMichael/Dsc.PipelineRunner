<#
.SYNOPSIS
Helpers for keeping sensitive configuration values out of the pipeline log.

.DESCRIPTION
DSC resource properties routinely carry secrets — passwords, tokens, keys, connection
strings. Pipeline logs are readable by a wider audience than the configuration repository
and are retained and forwarded (see issue #34), so a value that fails validation must not
be echoed verbatim. Test-SensitivePropertyName recognises conventionally-named sensitive
properties, and Protect-SensitiveValue returns a redacted placeholder for them so callers
can log a breadcrumb without leaking the secret.

.NOTES
Name matching is a heuristic, not a guarantee: the authoritative control is simply not to
print property values (the validation diagnostics name the property and resource only).
These helpers redact the opt-in, verbose breadcrumbs that remain.
#>

function Test-SensitivePropertyName {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name
    )

    # Substring, case-insensitive match against conventional secret-bearing names. Erring
    # toward redaction is deliberate: a false positive hides an innocuous value; a false
    # negative leaks a secret.
    $patterns = @(
        'password'
        'passphrase'
        'secret'
        'token'
        'key'
        'credential'
        'connectionstring'
    )

    foreach ($pattern in $patterns) {
        if ($Name -match [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Protect-SensitiveValue {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if (Test-SensitivePropertyName -Name $Name) {
        return '[REDACTED]'
    }

    if ($null -eq $Value) {
        return ''
    }

    return [string]$Value
}

<#
.SYNOPSIS
Converts a resource's desired or actual state into plain, redacted data that is safe to report.

.DESCRIPTION
State capture puts a resource's properties and its Get() output into a report, and a report can
leave the machine (a file, a webhook). Get() output in particular can hold secrets the runner was
never told are secret. ConvertTo-ReportState walks the value and returns only plain data
(ordered dictionaries, arrays, strings, numbers, booleans), applying these rules:

  * a value under a sensitive key name (Test-SensitivePropertyName) becomes '[REDACTED]',
    whatever its type, including a whole list or mapping under that key;
  * a [PSCredential] or [SecureString] becomes '[REDACTED]' wherever it appears;
  * every known secret value (and its JSON-escaped form) is replaced inside every string,
    longest first;
  * depth, collection size and string length are bounded, so one resource cannot flood a report.

It never throws for an unusual value: a property that cannot be read is reported as
'[UNREADABLE]'.

.PARAMETER InputObject
The state to convert.

.PARAMETER SecretValue
Known secret values to replace inside strings.

.PARAMETER Name
The key this value sits under (used for the sensitive-name rule). Callers leave it empty.
#>
function ConvertTo-ReportState {
    [CmdletBinding()]
    [OutputType([string], [object[]], [System.Collections.Specialized.OrderedDictionary], [bool], [long], [double], [decimal])]
    param (
        [AllowNull()]
        [object] $InputObject,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $SecretValue = @(),

        [AllowEmptyString()]
        [string] $Name = '',

        [ValidateRange(1, 32)]
        [int] $MaxDepth = 6,

        [ValidateRange(1, 100000)]
        [int] $MaxItems = 200,

        [ValidateRange(16, 1048576)]
        [int] $MaxStringLength = 4096,

        [int] $Depth = 0
    )

    if ($null -eq $InputObject) { return $null }

    if ($Name -and (Test-SensitivePropertyName -Name $Name)) { return '[REDACTED]' }

    if ($InputObject -is [System.Management.Automation.PSCredential] -or $InputObject -is [securestring]) {
        return '[REDACTED]'
    }

    if ($InputObject -is [string]) {
        $text = $InputObject
        foreach ($secret in @($SecretValue | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Property Length -Descending)) {
            $text = $text.Replace($secret, '[REDACTED]')
            $jsonEscaped = ([string](ConvertTo-Json -InputObject $secret -Compress)).Trim('"')
            if ($jsonEscaped -ne $secret) { $text = $text.Replace($jsonEscaped, '[REDACTED]') }
        }
        if ($text.Length -gt $MaxStringLength) { $text = $text.Substring(0, $MaxStringLength) + '...[TRUNCATED]' }
        return $text
    }

    if ($InputObject -is [bool] -or $InputObject -is [byte] -or $InputObject -is [int16] -or $InputObject -is [int] -or
        $InputObject -is [long] -or $InputObject -is [uint16] -or $InputObject -is [uint32] -or $InputObject -is [uint64] -or
        $InputObject -is [single] -or $InputObject -is [double] -or $InputObject -is [decimal]) {
        return $InputObject
    }
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [datetimeoffset]) { return $InputObject.ToString('o') }
    if ($InputObject -is [enum] -or $InputObject -is [guid] -or $InputObject -is [char] -or $InputObject -is [timespan] -or
        $InputObject -is [version] -or $InputObject -is [uri] -or $InputObject -is [type]) {
        return (ConvertTo-ReportState -InputObject ([string]$InputObject) -SecretValue $SecretValue -MaxStringLength $MaxStringLength)
    }
    if ($InputObject -is [byte[]]) { return "[BINARY: $($InputObject.Length) bytes]" }
    if ($InputObject -is [scriptblock]) { return '[SCRIPTBLOCK]' }

    if ($Depth -ge $MaxDepth) { return '[TRUNCATED: depth]' }

    $recurse = @{ SecretValue = $SecretValue; MaxDepth = $MaxDepth; MaxItems = $MaxItems; MaxStringLength = $MaxStringLength; Depth = $Depth + 1 }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $converted = [ordered]@{}
        $count = 0
        foreach ($key in @($InputObject.Keys)) {
            if ($count -ge $MaxItems) { $converted['[TRUNCATED]'] = "more than $MaxItems entries"; break }
            $converted[[string]$key] = ConvertTo-ReportState -InputObject $InputObject[$key] -Name ([string]$key) @recurse
            $count++
        }
        return $converted
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            if ($items.Count -ge $MaxItems) { $items.Add("[TRUNCATED: more than $MaxItems items]"); break }
            $items.Add((ConvertTo-ReportState -InputObject $item @recurse))
        }
        return , $items.ToArray()
    }

    # Any other object (PSCustomObject, a CIM instance, a .NET object): its readable properties.
    $converted = [ordered]@{}
    $count = 0
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -in 'CimClass', 'CimInstanceProperties', 'CimSystemProperties') { continue }
        if ($count -ge $MaxItems) { $converted['[TRUNCATED]'] = "more than $MaxItems properties"; break }
        try { $value = $property.Value } catch { $value = '[UNREADABLE]' }
        $converted[$property.Name] = ConvertTo-ReportState -InputObject $value -Name $property.Name @recurse
        $count++
    }
    return $converted
}
