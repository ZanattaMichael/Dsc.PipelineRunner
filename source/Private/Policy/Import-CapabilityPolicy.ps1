<#
.SYNOPSIS
Loads and validates a capability policy file (issue #86, Part B; preview).

.DESCRIPTION
A capability policy says what each layer of a configuration is allowed to use. It is supplied by
the pipeline (Invoke-DscRunner -PolicyPath), never by the configuration it constrains: a policy a
constrained layer could edit would constrain nothing. For that reason a policy file that lives
inside the configuration directory is refused.

The file is YAML:

    PolicyVersion: 1
    Default: Deny                  # what a layer may do with a capability it does not list
    Layers:
      - Name: Platform
        Paths: [ 'Datum.yml', 'OrganizationPolicies/**', 'Composites/**' ]
        Capabilities:
          Targets: [ '*' ]         # Target actions (Local, WinRM, SSH ...), wildcards allowed
          Engines: [ '*' ]         # Engine actions (DscV2, DscV3 ...)
          ExecutionScripts: true   # preExecutionScript / postExecutionScript
          DatumScriptBlocks: true  # [x={ ... }=] blocks evaluated during the Datum merge
      - Name: Teams
        Paths: [ 'Projects/**' ]
        Capabilities:
          Targets: [ Local, WinRM ]
          Engines: [ DscV2, DscV3 ]

Paths are relative to the configuration root, with forward slashes, without the file extension
(the definition file is written as 'Datum.yml'). The first layer whose Paths match a file owns it.
A file no layer claims belongs to no layer and has no capabilities at all, whatever Default says.

Validation is strict and fails closed: an unknown key, a wrong type or a missing field is an
error, not a warning, because a policy that is silently misread is worse than none.

.PARAMETER Path
The policy file.

.PARAMETER ConfigurationPath
The configuration directory the policy will be applied to. The policy must not be inside it.

.OUTPUTS
[hashtable] The policy: PolicyVersion, Default, Layers (ordered), Path, Sha256.
#>
function Import-CapabilityPolicy {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $ConfigurationPath
    )

    $prefix = '[Import-CapabilityPolicy]'

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$prefix The policy file '$Path' does not exist."
    }
    $fullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath)

    if (-not [string]::IsNullOrWhiteSpace($ConfigurationPath) -and (Test-Path -LiteralPath $ConfigurationPath)) {
        $configurationRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ConfigurationPath).ProviderPath).TrimEnd('\', '/')
        $comparison = if ($IsWindows -or $null -eq $IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if ($fullPath.StartsWith($configurationRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw "$prefix The policy file is inside the configuration directory it constrains ('$configurationRoot'). A policy the configuration's contributors can edit constrains nothing: keep it outside the configuration (another repository, or a path protected from them) and pass it with -PolicyPath."
        }
    }

    $text = Get-Content -LiteralPath $fullPath -Raw
    $document = $null
    try { $document = $text | ConvertFrom-Yaml -Ordered }
    catch { throw "$prefix The policy file is not valid YAML: $($_.Exception.Message)" }

    if ($document -isnot [System.Collections.IDictionary]) {
        throw "$prefix The policy file must be a mapping with PolicyVersion, Default and Layers."
    }

    $topLevelKeys = 'PolicyVersion', 'Default', 'Layers'
    $unknown = @($document.Keys | Where-Object { [string]$_ -notin $topLevelKeys })
    if ($unknown.Count -gt 0) { throw "$prefix Unknown key(s) $(($unknown | ForEach-Object { "'$_'" }) -join ', '). Allowed keys: $($topLevelKeys -join ', ')." }

    if ([string]$document['PolicyVersion'] -ne '1') {
        throw "$prefix PolicyVersion must be 1 (found '$($document['PolicyVersion'])'). This version of the runner understands version 1 only."
    }

    $default = [string]$document['Default']
    if ($default -notin 'Deny', 'Allow') {
        throw "$prefix Default must be Deny or Allow (found '$default'). It decides what a layer may do with a capability it does not list; Deny is recommended."
    }

    $layerDocuments = $document['Layers']
    if ($layerDocuments -isnot [System.Collections.IList] -or $layerDocuments.Count -eq 0) {
        throw "$prefix Layers must be a non-empty list."
    }

    $listCapabilities = 'Targets', 'Engines'
    $switchCapabilities = 'ExecutionScripts', 'DatumScriptBlocks'
    $layerKeys = 'Name', 'Paths', 'Capabilities'
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $layers = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($layerDocument in $layerDocuments) {
        if ($layerDocument -isnot [System.Collections.IDictionary]) { throw "$prefix Every entry of Layers must be a mapping with Name, Paths and Capabilities." }

        $unknown = @($layerDocument.Keys | Where-Object { [string]$_ -notin $layerKeys })
        if ($unknown.Count -gt 0) { throw "$prefix A layer has unknown key(s) $(($unknown | ForEach-Object { "'$_'" }) -join ', '). Allowed keys: $($layerKeys -join ', ')." }

        $name = [string]$layerDocument['Name']
        if ($name -notmatch '\A[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}\z') { throw "$prefix A layer Name must be 1 to 64 letters, digits, spaces, '_', '.' or '-' (found '$name')." }
        if (-not $names.Add($name)) { throw "$prefix The layer name '$name' is used more than once." }

        $paths = @($layerDocument['Paths'])
        if ($layerDocument['Paths'] -is [string] -or $paths.Count -eq 0 -or ($paths | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) })) {
            throw "$prefix Layer '$name': Paths must be a non-empty list of path patterns."
        }
        foreach ($pattern in $paths) {
            if ($pattern -match '\\' -or $pattern -match '(^|/)\.\.(/|$)' -or $pattern.StartsWith('/')) {
                throw "$prefix Layer '$name': the path pattern '$pattern' must be relative to the configuration root, use forward slashes and contain no '..'."
            }
        }

        $capabilities = @{}
        $capabilityDocument = $layerDocument['Capabilities']
        if ($null -ne $capabilityDocument) {
            if ($capabilityDocument -isnot [System.Collections.IDictionary]) { throw "$prefix Layer '$name': Capabilities must be a mapping." }
            foreach ($capability in $capabilityDocument.Keys) {
                $value = $capabilityDocument[$capability]
                if ([string]$capability -in $listCapabilities) {
                    $values = @($value)
                    if ($value -is [System.Collections.IDictionary] -or ($values | Where-Object { $_ -isnot [string] })) {
                        throw "$prefix Layer '$name': $capability must be a list of names (wildcards allowed), for example [ Local, WinRM ]. An empty list allows none."
                    }
                    $capabilities[[string]$capability] = [string[]]@($values | Where-Object { $null -ne $_ })
                }
                elseif ([string]$capability -in $switchCapabilities) {
                    if ($value -isnot [bool]) { throw "$prefix Layer '$name': $capability must be true or false." }
                    $capabilities[[string]$capability] = [bool]$value
                }
                else {
                    throw "$prefix Layer '$name': unknown capability '$capability'. Known capabilities: $(($listCapabilities + $switchCapabilities) -join ', ')."
                }
            }
        }

        $layers.Add(@{ Name = $name; Paths = [string[]]$paths; Capabilities = $capabilities })
    }

    $sha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()

    return @{
        PolicyVersion = 1
        Default       = $default
        Layers        = $layers.ToArray()
        Path          = $fullPath
        Sha256        = $sha256
    }
}
