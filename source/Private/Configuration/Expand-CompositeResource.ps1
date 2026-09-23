<#
.SYNOPSIS
Expands composite resource instances into their member resources at compile time.

.DESCRIPTION
A composite resource is a named, parameterised group of ordinary resources. It is defined
once, as data, in Composites/<Name>.yml:

    parameters:
      ProjectName:                       # no defaultValue - required
      Visibility:
        defaultValue: private
    resources:
      - name: Project
        type: AzureDevOpsDscNative/AzDoProject
        properties:
          ProjectName: <composite=ProjectName>
          Visibility:  <composite=Visibility>
      - name: Readers
        type: AzureDevOpsDscNative/AzDoProjectGroup
        dependsOn:
          - AzureDevOpsDscNative/AzDoProject/Project
        properties:
          ProjectName: <composite=ProjectName>
          GroupName:   Readers

and instantiated from any layer of the Datum hierarchy like any other resource:

    resources:
      - name: TeamA
        type: Composite/StandardProject
        properties:
          ProjectName: Team A

Datum has no notion of a template, so the instance survives hierarchy resolution as an ordinary
resource entry (it merges and overrides by 'name' exactly like any other). This function then
replaces it with the definition's members, so the compiled per-node file - and therefore the
runner, its rules, its engines and its report - only ever sees ordinary resources. Nothing
changes at run time.

For each instance, a deep copy of every member is taken and:

  * every `<composite=Name>` token is substituted. A value that is exactly one token is replaced
    by the parameter's value with its type intact (a list stays a list, a boolean stays a
    boolean); a token embedded in a longer string is interpolated as text. An undeclared
    token name is an error.
  * the member is renamed '<instance>::<member>', so two instances of the same composite never
    collide and every resource in the report names the instance it came from.
  * a dependsOn/notify entry naming another member of the same definition is rewritten to that
    member's new name; any other entry is left as written (it may name a resource outside the
    composite).
  * the instance's dependsOn and notify are added to every member, the instance's preCondition
    (or the deprecated 'condition') is AND-ed with the member's own, and the instance's target
    and resourceCredential apply to every member that does not set its own.
  * the instance's optional 'overrides' block - keyed by member name - is applied: 'properties'
    merge key by key, any other key replaces the member's own. It is the escape hatch for
    per-instance differences a parameter was not declared for.
  * a member that is itself a composite instance is expanded in turn (names nest as
    'outer::inner'), so composites compose. A recursive definition, or nesting deeper than
    -MaxDepth, is an error.

Finally every dependsOn/notify entry in the whole configuration that names a composite instance
('Composite/<Name>/<instance>') is replaced by that instance's member resources, so ordering
against a group works exactly like ordering against a single resource.

Every mistake is a compile-time error naming the instance: an unknown composite, a missing
required parameter, a property the composite does not declare, a reference to an instance that
does not exist, a run-time-only key (postCondition, preExecutionScript, postExecutionScript)
on an instance, or two expanded resources with the same type and name. A composite never
silently produces a partial group.

Composite definitions are data. Datum handlers such as Datum.InvokeCommand ([x= ... =]) are not
evaluated inside a definition; use the runner's function language ($(variables('X')),
parameters(), ...) in member properties, which is evaluated at run time as usual.

.PARAMETER Resources
The node's resolved resources (the output of Resolve-Datum -PropertyPath 'resources').

.PARAMETER Definitions
The composite definitions, as returned by Get-CompositeDefinition: name -> definition.

.PARAMETER MaxDepth
The deepest composite nesting allowed. Defaults to 10.

.OUTPUTS
The expanded resources, in order: each instance is replaced in place by its members, in the
order the definition lists them. When no resource is a composite instance the input objects
are emitted unchanged.

.EXAMPLE
$resources = @(Expand-CompositeResource -Resources $configuration.resources -Definitions (Get-CompositeDefinition -Datum $Datum))
#>
function Expand-CompositeResource {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [Object[]] $Resources,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Definitions,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int] $MaxDepth = 10
    )

    $logPrefix      = '[Expand-CompositeResource]'
    $compositeTypeRegex = '^Composite/'
    $tokenRegex     = '<composite=([^<>]*)>'
    $wholeTokenRegex = '^<composite=([^<>]*)>$'

    # Keys an instance may carry. The run-time-only lifecycle keys are rejected with their own
    # message: they describe one resource's evaluation and have no sound meaning for a group.
    $instanceKeys   = @('name', 'type', 'properties', 'dependsOn', 'notify', 'preCondition', 'condition',
                        'target', 'resourceCredential', 'overrides', 'description')
    $runTimeOnlyKeys = @('postCondition', 'preExecutionScript', 'postExecutionScript')
    $definitionKeys = @('description', 'parameters', 'resources')
    $parameterSpecKeys = @('defaultValue', 'description')

    #region helpers

    # Case-insensitive key lookup that returns the key as the dictionary spells it (or $null), so
    # a value is read and written back under the author's own spelling (dependsOn / DependsOn).
    function Get-EntryKey {
        param ([System.Collections.IDictionary] $Dictionary, [string] $Name)
        foreach ($existingKey in $Dictionary.Keys) {
            if ([string]$existingKey -eq $Name) { return $existingKey }
        }
        return $null
    }

    function Get-EntryValue {
        param ([System.Collections.IDictionary] $Dictionary, [string] $Name)
        $existingKey = Get-EntryKey -Dictionary $Dictionary -Name $Name
        if ($null -eq $existingKey) { return $null }
        $value = $Dictionary[$existingKey]
        if ($value -is [System.Collections.IList]) { return , $value }
        return $value
    }

    function Set-EntryValue {
        param ([System.Collections.IDictionary] $Dictionary, [string] $Name, $Value)
        $existingKey = Get-EntryKey -Dictionary $Dictionary -Name $Name
        if ($null -eq $existingKey) { $existingKey = $Name }
        $Dictionary[$existingKey] = $Value
    }

    function Remove-Entry {
        param ([System.Collections.IDictionary] $Dictionary, [string] $Name)
        $existingKey = Get-EntryKey -Dictionary $Dictionary -Name $Name
        if ($null -ne $existingKey) { $Dictionary.Remove($existingKey) }
    }

    # Deep copy. Datum caches each file's parsed data and hands the same objects to every node,
    # so a definition must never be modified in place.
    function Copy-CompositeValue {
        param ($Value)
        if ($Value -is [System.Collections.IDictionary]) {
            $copy = [ordered]@{}
            foreach ($entryKey in $Value.Keys) { $copy[$entryKey] = Copy-CompositeValue -Value $Value[$entryKey] }
            return $copy
        }
        if ($Value -is [System.Collections.IList]) {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Value) { $items.Add((Copy-CompositeValue -Value $item)) }
            return , $items.ToArray()
        }
        return $Value
    }

    # A resource read from a hand-written test double may be a PSCustomObject rather than the
    # dictionary Datum produces; normalise so the rest of the function handles one shape.
    function ConvertTo-ResourceDictionary {
        param ($Resource)
        if ($Resource -is [System.Collections.IDictionary]) { return $Resource }
        $dictionary = [ordered]@{}
        foreach ($property in $Resource.PSObject.Properties) { $dictionary[$property.Name] = $property.Value }
        return $dictionary
    }

    function Get-ResourceType {
        param ($Resource)
        if ($null -eq $Resource) { return $null }
        if ($Resource -is [System.Collections.IDictionary]) { return [string](Get-EntryValue -Dictionary $Resource -Name 'type') }
        return [string]$Resource.type
    }

    function Test-CompositeResource {
        param ($Resource)
        $resourceType = Get-ResourceType -Resource $Resource
        return (-not [string]::IsNullOrEmpty($resourceType)) -and ($resourceType -match $compositeTypeRegex)
    }

    # dependsOn / notify accept a single string or a list; always work with a list of trimmed,
    # non-empty strings.
    function ConvertTo-ReferenceList {
        param ($Value)
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in @($Value)) {
            if ($null -eq $entry) { continue }
            $text = ([string]$entry).Trim()
            if ($text.Length -gt 0) { $list.Add($text) }
        }
        return , $list
    }

    function Add-UniqueReference {
        param ([System.Collections.Generic.List[string]] $List, [string] $Reference)
        if (-not $List.Contains($Reference)) { $List.Add($Reference) }
    }

    function Resolve-CompositeToken {
        param ($Value, [hashtable] $ParameterValues, [string] $Context)

        if ($Value -is [string]) {
            $whole = [regex]::Match($Value, $wholeTokenRegex)
            if ($whole.Success) {
                $parameterName = $whole.Groups[1].Value.Trim()
                if (-not $ParameterValues.ContainsKey($parameterName)) {
                    throw "$logPrefix $Context uses the token '<composite=$parameterName>', but the composite declares no parameter named '$parameterName'. Declared parameters: $(if ($ParameterValues.Count) { ($ParameterValues.Keys | Sort-Object) -join ', ' } else { '(none)' })."
                }
                $typedValue = Copy-CompositeValue -Value $ParameterValues[$parameterName]
                if ($typedValue -is [System.Collections.IList]) { return , $typedValue }
                return $typedValue
            }

            $tokenMatches = [regex]::Matches($Value, $tokenRegex)
            if ($tokenMatches.Count -eq 0) { return $Value }

            $builder = [System.Text.StringBuilder]::new()
            $position = 0
            foreach ($tokenMatch in $tokenMatches) {
                $parameterName = $tokenMatch.Groups[1].Value.Trim()
                if (-not $ParameterValues.ContainsKey($parameterName)) {
                    throw "$logPrefix $Context uses the token '<composite=$parameterName>', but the composite declares no parameter named '$parameterName'. Declared parameters: $(if ($ParameterValues.Count) { ($ParameterValues.Keys | Sort-Object) -join ', ' } else { '(none)' })."
                }
                $parameterValue = $ParameterValues[$parameterName]
                if ($parameterValue -is [System.Collections.IDictionary] -or $parameterValue -is [System.Collections.IList]) {
                    throw "$logPrefix $Context embeds '<composite=$parameterName>' inside a longer string, but the parameter's value is a list or mapping. Use the token as the whole value to pass a structured value."
                }
                [void]$builder.Append($Value, $position, $tokenMatch.Index - $position)
                [void]$builder.Append([string]$parameterValue)
                $position = $tokenMatch.Index + $tokenMatch.Length
            }
            [void]$builder.Append($Value, $position, $Value.Length - $position)
            return $builder.ToString()
        }

        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($entryKey in @($Value.Keys)) {
                $Value[$entryKey] = Resolve-CompositeToken -Value $Value[$entryKey] -ParameterValues $ParameterValues -Context $Context
            }
            return $Value
        }

        if ($Value -is [System.Collections.IList]) {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Value) { $items.Add((Resolve-CompositeToken -Value $item -ParameterValues $ParameterValues -Context $Context)) }
            return , $items.ToArray()
        }

        return $Value
    }

    # Binds the instance's properties to the definition's declared parameters.
    function Resolve-CompositeParameterValue {
        param ([System.Collections.IDictionary] $Definition, [System.Collections.IDictionary] $Instance,
               [string] $CompositeName, [string] $InstanceKey)

        $declared = Get-EntryValue -Dictionary $Definition -Name 'parameters'
        if ($null -ne $declared -and $declared -isnot [System.Collections.IDictionary]) {
            throw "$logPrefix Composite definition '$CompositeName' has a 'parameters' value that is not a mapping of parameter name to specification."
        }
        if ($null -eq $declared) { $declared = @{} }

        $supplied = Get-EntryValue -Dictionary $Instance -Name 'properties'
        if ($null -ne $supplied -and $supplied -isnot [System.Collections.IDictionary]) {
            throw "$logPrefix Composite instance [$InstanceKey] has a 'properties' value that is not a mapping of parameter name to value."
        }
        if ($null -eq $supplied) { $supplied = @{} }

        $values = @{}

        $unknown = @($supplied.Keys | Where-Object { $null -eq (Get-EntryKey -Dictionary $declared -Name ([string]$_)) })
        if ($unknown.Count -gt 0) {
            throw "$logPrefix Composite instance [$InstanceKey] sets $(($unknown | ForEach-Object { "'$_'" }) -join ', '), which composite '$CompositeName' does not declare. Declared parameters: $(if ($declared.Count) { ($declared.Keys | Sort-Object) -join ', ' } else { '(none)' })."
        }

        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($parameterName in $declared.Keys) {
            $specification = $declared[$parameterName]
            $hasDefault = $false
            $defaultValue = $null

            if ($specification -is [System.Collections.IDictionary]) {
                $unsupported = @($specification.Keys | Where-Object { [string]$_ -notin $parameterSpecKeys })
                if ($unsupported.Count -gt 0) {
                    throw "$logPrefix Composite definition '$CompositeName' parameter '$parameterName' has unsupported key(s) $(($unsupported | ForEach-Object { "'$_'" }) -join ', '). Supported keys: $($parameterSpecKeys -join ', ')."
                }
                $defaultKey = Get-EntryKey -Dictionary $specification -Name 'defaultValue'
                if ($null -ne $defaultKey) {
                    $hasDefault = $true
                    $defaultValue = $specification[$defaultKey]
                }
            }
            elseif ($specification -is [System.Collections.IList]) {
                throw "$logPrefix Composite definition '$CompositeName' parameter '$parameterName' is a list. Declare a list default as 'defaultValue:' under the parameter."
            }
            elseif ($null -ne $specification) {
                # Shorthand: 'Visibility: private' is 'Visibility: { defaultValue: private }'.
                $hasDefault = $true
                $defaultValue = $specification
            }

            $suppliedKey = Get-EntryKey -Dictionary $supplied -Name ([string]$parameterName)
            if ($null -ne $suppliedKey) {
                $values[[string]$parameterName] = $supplied[$suppliedKey]
            }
            elseif ($hasDefault) {
                $values[[string]$parameterName] = $defaultValue
            }
            else {
                $missing.Add([string]$parameterName)
            }
        }

        if ($missing.Count -gt 0) {
            throw "$logPrefix Composite instance [$InstanceKey] does not set the required parameter(s) $(($missing | ForEach-Object { "'$_'" }) -join ', ') of composite '$CompositeName'."
        }

        return $values
    }

    # Expands one instance and returns the keys of the leaf resources it produced. $Instance's
    # name is already the full, nested instance name.
    function Expand-CompositeInstance {
        param ([System.Collections.IDictionary] $Instance, [string[]] $Chain,
               [System.Collections.Generic.List[object]] $Output)

        $instanceType = Get-ResourceType -Resource $Instance
        $instanceName = [string](Get-EntryValue -Dictionary $Instance -Name 'name')
        $instanceKey  = "$instanceType/$instanceName"

        if ([string]::IsNullOrWhiteSpace($instanceName)) {
            throw "$logPrefix A composite instance of type '$instanceType' has no name. Every composite instance needs a name, like any other resource."
        }

        $typeMatch = [regex]::Match($instanceType, '^Composite/([^/]+)$', 'IgnoreCase')
        if (-not $typeMatch.Success) {
            throw "$logPrefix Composite instance [$instanceKey] has type '$instanceType'; a composite type is exactly 'Composite/<Name>'."
        }
        $requestedName = $typeMatch.Groups[1].Value

        $compositeName = $null
        if ($null -ne $Definitions) { $compositeName = Get-EntryKey -Dictionary $Definitions -Name $requestedName }
        if ($null -eq $compositeName) {
            $known = if ($null -ne $Definitions -and $Definitions.Count -gt 0) { ($Definitions.Keys | Sort-Object) -join ', ' } else { '(none - add Composites/<Name>.yml to the configuration)' }
            throw "$logPrefix Composite instance [$instanceKey] refers to composite '$requestedName', which is not defined. Defined composites: $known."
        }
        $compositeName = [string]$compositeName

        if ($Chain -contains $compositeName) {
            throw "$logPrefix Composite '$compositeName' is recursive: $((@($Chain) + $compositeName) -join ' -> '). A composite may not contain itself, directly or indirectly."
        }
        $chainHere = @($Chain) + $compositeName
        if ($chainHere.Count -gt $MaxDepth) {
            throw "$logPrefix Composite instance [$instanceKey] is nested $($chainHere.Count) levels deep ($($chainHere -join ' -> ')), deeper than the limit of $MaxDepth."
        }

        foreach ($key in $Instance.Keys) {
            if ([string]$key -in $runTimeOnlyKeys) {
                throw "$logPrefix Composite instance [$instanceKey] sets '$key', which is not supported on a composite instance: it describes the evaluation of a single resource. Set it on the member resource in the composite definition, or through the instance's 'overrides' block."
            }
            if ([string]$key -notin $instanceKeys) {
                throw "$logPrefix Composite instance [$instanceKey] sets '$key', which is not a composite instance key. Supported keys: $($instanceKeys -join ', ')."
            }
        }

        $definition = $Definitions[$compositeName]
        foreach ($key in $definition.Keys) {
            if ([string]$key -notin $definitionKeys) {
                throw "$logPrefix Composite definition '$compositeName' has the unsupported key '$key'. Supported keys: $($definitionKeys -join ', ')."
            }
        }

        $members = Get-EntryValue -Dictionary $definition -Name 'resources'
        if ($members -is [System.Collections.IDictionary]) { $members = , $members }
        if ($null -eq $members -or @($members).Count -eq 0) {
            throw "$logPrefix Composite definition '$compositeName' has no resources. A composite must list at least one member resource under 'resources'."
        }

        $parameterValues = Resolve-CompositeParameterValue -Definition $definition -Instance $Instance -CompositeName $compositeName -InstanceKey $instanceKey

        # Members: copy, substitute tokens, then work out their original and expanded identities.
        $prepared = [System.Collections.Generic.List[object]]::new()
        $memberKeyMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        $memberByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $memberIndex = 0
        foreach ($member in @($members)) {
            $memberIndex++
            if ($member -isnot [System.Collections.IDictionary]) {
                throw "$logPrefix Composite definition '$compositeName' resource #$memberIndex is not a mapping."
            }
            $context = "Composite definition '$compositeName' resource #$memberIndex (instance [$instanceKey])"
            $copy = Resolve-CompositeToken -Value (Copy-CompositeValue -Value $member) -ParameterValues $parameterValues -Context $context

            $memberName = Get-EntryValue -Dictionary $copy -Name 'name'
            $memberType = Get-EntryValue -Dictionary $copy -Name 'type'
            if ($memberName -is [System.Collections.IDictionary] -or $memberName -is [System.Collections.IList] -or [string]::IsNullOrWhiteSpace([string]$memberName)) {
                throw "$logPrefix $context has no name."
            }
            if ($memberType -is [System.Collections.IDictionary] -or $memberType -is [System.Collections.IList] -or [string]::IsNullOrWhiteSpace([string]$memberType)) {
                throw "$logPrefix $context ('$memberName') has no type."
            }
            $memberName = [string]$memberName
            $memberType = [string]$memberType

            $originalKey = "$memberType/$memberName"
            if ($memberKeyMap.ContainsKey($originalKey)) {
                throw "$logPrefix Composite definition '$compositeName' lists the resource [$originalKey] more than once."
            }
            $expandedName = "$instanceName::$memberName"
            $memberKeyMap[$originalKey] = "$memberType/$expandedName"

            $prepared.Add([pscustomobject]@{ Resource = $copy; Name = $memberName; ExpandedName = $expandedName })
            if (-not $memberByName.ContainsKey($memberName)) { $memberByName[$memberName] = $copy }
        }

        # Per-instance overrides, keyed by the member's name in the definition.
        $overrides = Get-EntryValue -Dictionary $Instance -Name 'overrides'
        if ($null -ne $overrides) {
            if ($overrides -isnot [System.Collections.IDictionary]) {
                throw "$logPrefix Composite instance [$instanceKey] has an 'overrides' value that is not a mapping of member name to settings."
            }
            foreach ($overrideTarget in $overrides.Keys) {
                if (-not $memberByName.ContainsKey([string]$overrideTarget)) {
                    throw "$logPrefix Composite instance [$instanceKey] overrides '$overrideTarget', which is not a resource of composite '$compositeName'. Its resources: $(($prepared | ForEach-Object Name) -join ', ')."
                }
                $settings = $overrides[$overrideTarget]
                if ($settings -isnot [System.Collections.IDictionary]) {
                    throw "$logPrefix Composite instance [$instanceKey] override for '$overrideTarget' is not a mapping."
                }
                $target = $memberByName[[string]$overrideTarget]
                foreach ($settingKey in $settings.Keys) {
                    if ([string]$settingKey -in @('name', 'type')) {
                        throw "$logPrefix Composite instance [$instanceKey] override for '$overrideTarget' sets '$settingKey'; a member's name and type come from the composite definition and cannot be overridden."
                    }
                    $settingValue = Copy-CompositeValue -Value $settings[$settingKey]
                    $existingValue = Get-EntryValue -Dictionary $target -Name ([string]$settingKey)
                    if ([string]$settingKey -eq 'properties' -and $existingValue -is [System.Collections.IDictionary] -and $settingValue -is [System.Collections.IDictionary]) {
                        foreach ($propertyKey in $settingValue.Keys) {
                            Set-EntryValue -Dictionary $existingValue -Name ([string]$propertyKey) -Value $settingValue[$propertyKey]
                        }
                    }
                    else {
                        Set-EntryValue -Dictionary $target -Name ([string]$settingKey) -Value $settingValue
                    }
                }
            }
        }

        # What the instance passes down to every member.
        $instanceDependsOn = ConvertTo-ReferenceList -Value (Get-EntryValue -Dictionary $Instance -Name 'dependsOn')
        $instanceNotify    = ConvertTo-ReferenceList -Value (Get-EntryValue -Dictionary $Instance -Name 'notify')
        $instancePreCondition = Get-EntryValue -Dictionary $Instance -Name 'preCondition'
        if ($null -eq $instancePreCondition) { $instancePreCondition = Get-EntryValue -Dictionary $Instance -Name 'condition' }
        $instanceTarget     = Get-EntryValue -Dictionary $Instance -Name 'target'
        $instanceCredential = Get-EntryValue -Dictionary $Instance -Name 'resourceCredential'

        $leafKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $prepared) {
            $resource = $entry.Resource
            Set-EntryValue -Dictionary $resource -Name 'name' -Value $entry.ExpandedName

            foreach ($referenceKey in @('dependsOn', 'notify')) {
                $references = [System.Collections.Generic.List[string]]::new()
                foreach ($reference in (ConvertTo-ReferenceList -Value (Get-EntryValue -Dictionary $resource -Name $referenceKey))) {
                    if ($memberKeyMap.ContainsKey($reference)) { Add-UniqueReference -List $references -Reference $memberKeyMap[$reference] }
                    else { Add-UniqueReference -List $references -Reference $reference }
                }
                $inherited = if ($referenceKey -eq 'dependsOn') { $instanceDependsOn } else { $instanceNotify }
                foreach ($reference in $inherited) { Add-UniqueReference -List $references -Reference $reference }

                if ($references.Count -gt 0) {
                    Set-EntryValue -Dictionary $resource -Name $referenceKey -Value $references.ToArray()
                }
                elseif ($null -ne (Get-EntryKey -Dictionary $resource -Name $referenceKey)) {
                    Remove-Entry -Dictionary $resource -Name $referenceKey
                }
            }

            if ($null -ne $instancePreCondition -and -not [string]::IsNullOrWhiteSpace([string]$instancePreCondition)) {
                $memberPreCondition = Get-EntryValue -Dictionary $resource -Name 'preCondition'
                if ($null -eq $memberPreCondition) { $memberPreCondition = Get-EntryValue -Dictionary $resource -Name 'condition' }
                Remove-Entry -Dictionary $resource -Name 'condition'
                if ($null -eq $memberPreCondition -or [string]::IsNullOrWhiteSpace([string]$memberPreCondition)) {
                    Set-EntryValue -Dictionary $resource -Name 'preCondition' -Value ([string]$instancePreCondition)
                }
                else {
                    Set-EntryValue -Dictionary $resource -Name 'preCondition' -Value "($instancePreCondition) -and ($memberPreCondition)"
                }
            }

            if ($null -ne $instanceTarget -and $null -eq (Get-EntryKey -Dictionary $resource -Name 'target')) {
                Set-EntryValue -Dictionary $resource -Name 'target' -Value (Copy-CompositeValue -Value $instanceTarget)
            }
            if ($null -ne $instanceCredential -and $null -eq (Get-EntryKey -Dictionary $resource -Name 'resourceCredential')) {
                Set-EntryValue -Dictionary $resource -Name 'resourceCredential' -Value (Copy-CompositeValue -Value $instanceCredential)
            }

            if (Test-CompositeResource -Resource $resource) {
                foreach ($nestedKey in (Expand-CompositeInstance -Instance $resource -Chain $chainHere -Output $Output)) {
                    $leafKeys.Add($nestedKey)
                }
            }
            else {
                $Output.Add($resource)
                $leafKeys.Add("$(Get-ResourceType -Resource $resource)/$($entry.ExpandedName)")
                [void]$expandedKeys.Add("$(Get-ResourceType -Resource $resource)/$($entry.ExpandedName)")
            }
        }

        $aliasKey = "Composite/$compositeName/$instanceName"
        if ($aliases.ContainsKey($aliasKey)) {
            throw "$logPrefix The composite instance [$aliasKey] is declared more than once."
        }
        $aliases[$aliasKey] = $leafKeys

        Write-Verbose "$logPrefix Expanded [$instanceKey] into $($leafKeys.Count) resource(s)."
        return , $leafKeys
    }

    #endregion helpers

    $items = @($Resources | Where-Object { $null -ne $_ })

    # Fast path: a configuration without composite instances is emitted exactly as it came in.
    if (-not ($items | Where-Object { Test-CompositeResource -Resource $_ })) {
        return $items
    }

    $aliases      = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $expandedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $expanded     = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $items) {
        if (Test-CompositeResource -Resource $item) {
            $instance = Copy-CompositeValue -Value (ConvertTo-ResourceDictionary -Resource $item)
            [void](Expand-CompositeInstance -Instance $instance -Chain @() -Output $expanded)
        }
        else {
            $expanded.Add($item)
        }
    }

    # Point every reference to a composite instance at the resources it expanded into.
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($resource in $expanded) {
        $resourceType = Get-ResourceType -Resource $resource
        $resourceName = if ($resource -is [System.Collections.IDictionary]) { [string](Get-EntryValue -Dictionary $resource -Name 'name') } else { [string]$resource.name }
        $resourceKey = "$resourceType/$resourceName"
        $current = $resource

        foreach ($referenceKey in @('dependsOn', 'notify')) {
            $raw = if ($resource -is [System.Collections.IDictionary]) { Get-EntryValue -Dictionary $resource -Name $referenceKey } else { $resource.$referenceKey }
            $existing = ConvertTo-ReferenceList -Value $raw
            if ($existing.Count -eq 0) { continue }

            $rewritten = [System.Collections.Generic.List[string]]::new()
            $changed = $false
            foreach ($reference in $existing) {
                if ($aliases.ContainsKey($reference)) {
                    foreach ($leafKey in $aliases[$reference]) { Add-UniqueReference -List $rewritten -Reference $leafKey }
                    $changed = $true
                }
                elseif ($reference -match $compositeTypeRegex) {
                    $knownInstances = if ($aliases.Count) { ($aliases.Keys | Sort-Object) -join ', ' } else { '(none)' }
                    throw "$logPrefix Resource [$resourceKey] $referenceKey [$reference], which is not a composite instance in this configuration. Composite instances: $knownInstances."
                }
                else {
                    Add-UniqueReference -List $rewritten -Reference $reference
                }
            }

            if ($changed) {
                # Never modify a resource object the caller still owns (a non-composite resource
                # passed straight through): copy it first.
                if ([object]::ReferenceEquals($current, $resource) -and -not $expandedKeys.Contains($resourceKey)) {
                    $current = Copy-CompositeValue -Value (ConvertTo-ResourceDictionary -Resource $resource)
                }
                Set-EntryValue -Dictionary $current -Name $referenceKey -Value $rewritten.ToArray()
            }
        }

        $result.Add($current)
    }

    # Two resources with the same identity would be merged by nothing downstream - the runner
    # keeps the first and drops the rest. An expansion that produces one is always a mistake.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($resource in $result) {
        $resourceType = Get-ResourceType -Resource $resource
        $resourceName = if ($resource -is [System.Collections.IDictionary]) { [string](Get-EntryValue -Dictionary $resource -Name 'name') } else { [string]$resource.name }
        $resourceKey = "$resourceType/$resourceName"
        if (-not $seen.Add($resourceKey) -and $expandedKeys.Contains($resourceKey)) {
            throw "$logPrefix Expanding composite resources produced the resource [$resourceKey] more than once. Rename the composite instance or the colliding resource."
        }
    }

    Write-Verbose "$logPrefix Expanded $($aliases.Count) composite instance(s); $($items.Count) resource(s) in, $($result.Count) out."
    return $result.ToArray()
}
