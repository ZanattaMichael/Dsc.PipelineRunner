<#
.SYNOPSIS
Loads and validates a capability policy file (issue #86, Part B).

.DESCRIPTION
A capability policy says what each layer of a configuration is allowed to use.

Where it lives: in its own file, Policy.yml, at the root of the configuration, beside Datum.yml.
It is not part of Datum.yml and it is never merged: Datum builds its tree from the root's folders,
so a file at the root is outside the hierarchy and no layer can add to it or override it. It may
also be supplied from outside the configuration (-PolicyPath). What is refused is a policy file
in a sub-folder of the configuration, because those folders are the layers the policy constrains.

Protect Policy.yml the way Datum.yml is protected (CODEOWNERS, branch protection): whoever can
edit it decides what every layer may do.

The file is YAML:

    PolicyVersion: 1
    Default: Deny                  # what a layer may do with a capability it does not list
    Layers:
      - Name: Platform
        Paths: [ 'Datum.yml', 'OrganizationPolicies/**', 'Composites/**' ]
        Capabilities:
          Targets: [ '*' ]            # Target actions (Local, WinRM, SSH ...), wildcards allowed
          Engines: [ '*' ]            # Engine actions (DscV2, DscV3 ...)
          Resources: [ '*' ]          # resource types, written 'Module/Resource'
          Credentials: [ '*' ]        # Credential actions (Environment, SecretManagement, Static ...)
          RemoteTargets: [ '*' ]      # target.computerName a non-Local Target may be aimed at
          ExecutionScripts: true      # preExecutionScript / postExecutionScript
          DatumScriptBlocks: true     # [x={ ... }=] blocks evaluated during the Datum merge
          Notify: true                # 'notify', which forces another resource to re-run Set()
          Reboot: true                # restarting a remote target after a Set that asks for one
      - Name: Teams
        Paths: [ 'Projects/**' ]
        Capabilities:
          Targets: [ Local, WinRM ]
          Engines: [ DscV2, DscV3 ]
          Resources: [ 'PSDscResources/*' ]
          Credentials: [ Environment ]
          RemoteTargets: [ '*.app.contoso.example' ]
    Settings:                       # optional: the PipelineRunnerSettings values Datum.yml may hold
      AllowExecutionScripts: [ false ]
      Reboot: [ Fail ]
      Target: [ Local, WinRM ]
      Engine: [ DscV2, DscV3 ]

Paths are relative to the configuration root, with forward slashes, without the file extension
(the definition file is written as 'Datum.yml'). The first layer whose Paths match a file owns it.
A file no layer claims belongs to no layer and has no capabilities at all, whatever Default says.

Validation is strict and fails closed: an unknown key, a wrong type or a missing field is an
error, not a warning, because a policy that is silently misread is worse than none.

.PARAMETER Path
The policy file.

.PARAMETER ConfigurationPath
The configuration directory the policy will be applied to. The policy file must be at its root
(beside Datum.yml) or outside it, never in one of its sub-folders.

.OUTPUTS
[hashtable] The policy: PolicyVersion, Default, Layers (ordered), Settings, Path, Sha256.
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
        $insideConfiguration = $fullPath.StartsWith($configurationRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison)
        $atRoot = [string]::Equals([System.IO.Path]::GetDirectoryName($fullPath).TrimEnd('\', '/'), $configurationRoot, $comparison)
        if ($insideConfiguration -and -not $atRoot) {
            throw "$prefix The policy file is in a sub-folder of the configuration ('$fullPath'). The sub-folders are the layers a policy constrains, so a policy there could be changed by the layer it restricts. Keep it at the root of the configuration, beside Datum.yml (as Policy.yml), or outside the configuration."
        }
    }

    $text = Get-Content -LiteralPath $fullPath -Raw
    $document = $null
    try { $document = $text | ConvertFrom-Yaml -Ordered }
    catch { throw "$prefix The policy file is not valid YAML: $($_.Exception.Message)" }

    if ($document -isnot [System.Collections.IDictionary]) {
        throw "$prefix The policy file must be a mapping with PolicyVersion, Default and Layers."
    }

    $topLevelKeys = 'PolicyVersion', 'Default', 'Layers', 'Settings'
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

    # Keep these two lists in step with Test-PolicyCapability's ValidateSet and with the tables
    # in docs/capability-policy.md: they are the whole vocabulary a policy file may use.
    $listCapabilities = 'Targets', 'Engines', 'Resources', 'Credentials', 'RemoteTargets'
    $switchCapabilities = 'ExecutionScripts', 'DatumScriptBlocks', 'Notify', 'Reboot'
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
                    # A resource type is 'Module/Resource'. A bare module name is almost always a
                    # mistake that would allow nothing, so say so rather than deny silently.
                    if ([string]$capability -eq 'Resources') {
                        foreach ($pattern in @($values | Where-Object { $_ -is [string] })) {
                            if ($pattern -notmatch '/' -and $pattern -ne '*') {
                                throw "$prefix Layer '$name': the Resources pattern '$pattern' does not name a resource type. A resource type is written 'Module/Resource', so use '$pattern/*' to allow every resource of that module, or '*' for any."
                            }
                        }
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

    # Settings: which values Datum.yml's PipelineRunnerSettings block may hold. It is policy-wide,
    # not per layer, because Datum.yml is one file owned by one layer. A key the policy does not
    # list is not governed. See Assert-RunnerSettingsPolicy.
    $settings = @{}
    $settingsDocument = $document['Settings']
    if ($document.Contains('Settings')) {
        if ($settingsDocument -isnot [System.Collections.IDictionary]) {
            throw "$prefix Settings must be a mapping of PipelineRunnerSettings keys to the values Datum.yml may use, for example Settings: { Reboot: [ Fail ] }."
        }
        $settingKeys = 'AllowExecutionScripts', 'Engine', 'Reboot', 'Target'
        foreach ($key in $settingsDocument.Keys) {
            $known = @($settingKeys | Where-Object { $_ -eq [string]$key })
            if ($known.Count -eq 0) {
                throw "$prefix Settings: '$key' is not a setting a policy can govern. Known settings: $($settingKeys -join ', ')."
            }
            $value = $settingsDocument[$key]
            $values = @($value)
            if ($null -eq $value -or $value -is [System.Collections.IDictionary] -or $values.Count -eq 0) {
                throw "$prefix Settings: $($known[0]) must be a non-empty list of the values Datum.yml may use, for example [ $(if ($known[0] -eq 'AllowExecutionScripts') { 'false' } else { 'Fail' }) ]."
            }
            if ($known[0] -eq 'AllowExecutionScripts') {
                if ($values | Where-Object { $_ -isnot [bool] }) { throw "$prefix Settings: AllowExecutionScripts must be a list of true or false, for example [ false ]." }
                $settings['AllowExecutionScripts'] = [bool[]]$values
            }
            else {
                if ($values | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }) { throw "$prefix Settings: $($known[0]) must be a list of names (wildcards allowed), for example [ Local, WinRM ]." }
                $settings[$known[0]] = [string[]]$values
            }
        }
    }

    $sha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()

    return @{
        PolicyVersion = 1
        Default       = $default
        Layers        = $layers.ToArray()
        Settings      = $settings
        Path          = $fullPath
        Sha256        = $sha256
    }
}
