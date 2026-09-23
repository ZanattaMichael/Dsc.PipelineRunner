Describe "Expand-CompositeResource" -Tag Unit, Runner, Configuration, Composite {

    BeforeAll {
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName

        # Datum hands back ordered dictionaries; build the fixtures the same way.
        function New-Definition {
            param([System.Collections.IDictionary]$Parameters, [object[]]$Resources)
            $definition = [ordered]@{}
            if ($null -ne $Parameters) { $definition.parameters = $Parameters }
            $definition.resources = $Resources
            return $definition
        }

        function Get-ByName {
            param([object[]]$Resources, [string]$Name)
            return $Resources | Where-Object { $_['name'] -eq $Name } | Select-Object -First 1
        }

        # A two-member composite with a required and a defaulted parameter, and an internal
        # dependsOn between its members.
        function New-StandardDefinitions {
            return @{
                StandardProject = New-Definition -Parameters ([ordered]@{
                        ProjectName = $null
                        Visibility  = [ordered]@{ defaultValue = 'private'; description = 'Project visibility.' }
                    }) -Resources @(
                    [ordered]@{
                        name       = 'Project'
                        type       = 'Stub/Project'
                        properties = [ordered]@{ ProjectName = '<composite=ProjectName>'; Visibility = '<composite=Visibility>' }
                    }
                    [ordered]@{
                        name       = 'Readers'
                        type       = 'Stub/Group'
                        dependsOn  = @('Stub/Project/Project')
                        properties = [ordered]@{ ProjectName = '<composite=ProjectName>'; GroupName = 'Readers' }
                    }
                )
            }
        }
    }

    Context "Pass-through" {

        It "emits nothing for `$null or empty input" {
            @(Expand-CompositeResource -Resources $null -Definitions $null).Count | Should -Be 0
            @(Expand-CompositeResource -Resources @() -Definitions @{}).Count | Should -Be 0
        }

        It "returns the same resource objects, in order, when there is no composite instance" {
            $first  = [ordered]@{ name = 'A'; type = 'Stub/A'; properties = @{} }
            $second = [ordered]@{ name = 'B'; type = 'Stub/B'; dependsOn = @('Stub/A/A') }

            $result = @(Expand-CompositeResource -Resources @($first, $null, $second) -Definitions (New-StandardDefinitions))

            $result.Count | Should -Be 2
            [object]::ReferenceEquals($result[0], $first)  | Should -BeTrue
            [object]::ReferenceEquals($result[1], $second) | Should -BeTrue
        }

        It "ignores resources without a type" {
            $untyped = [ordered]@{ name = 'NoType' }
            $result = @(Expand-CompositeResource -Resources @($untyped) -Definitions @{})
            [object]::ReferenceEquals($result[0], $untyped) | Should -BeTrue
        }
    }

    Context "Expanding an instance" {

        BeforeAll {
            $script:definitions = New-StandardDefinitions
            $script:resources = @(
                [ordered]@{ name = 'Org'; type = 'Stub/Org'; properties = @{} }
                [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'Team A' } }
                [ordered]@{ name = 'Tail'; type = 'Stub/Tail'; properties = @{} }
            )
            $script:result = @(Expand-CompositeResource -Resources $script:resources -Definitions $script:definitions)
        }

        It "replaces the instance in place with its members, in definition order" {
            ($script:result | ForEach-Object { "$($_['type'])/$($_['name'])" }) | Should -Be @(
                'Stub/Org/Org'
                'Stub/Project/TeamA::Project'
                'Stub/Group/TeamA::Readers'
                'Stub/Tail/Tail'
            )
        }

        It "substitutes supplied parameters and falls back to declared defaults" {
            $project = Get-ByName -Resources $script:result -Name 'TeamA::Project'
            $project['properties']['ProjectName'] | Should -Be 'Team A'
            $project['properties']['Visibility']  | Should -Be 'private'
        }

        It "rewrites a dependsOn between members to the expanded names" {
            $readers = Get-ByName -Resources $script:result -Name 'TeamA::Readers'
            @($readers['dependsOn']) | Should -Be @('Stub/Project/TeamA::Project')
        }

        It "does not modify the definition, which Datum shares between nodes" {
            $member = $script:definitions.StandardProject.resources[0]
            $member['name'] | Should -Be 'Project'
            $member['properties']['ProjectName'] | Should -Be '<composite=ProjectName>'
            @($script:definitions.StandardProject.resources[1]['dependsOn']) | Should -Be @('Stub/Project/Project')
        }

        It "does not modify the instance passed in" {
            $script:resources[1]['name'] | Should -Be 'TeamA'
            $script:resources[1]['type'] | Should -Be 'Composite/StandardProject'
        }

        It "gives two instances of one composite distinct resources" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                    [ordered]@{ name = 'TeamB'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'B'; Visibility = 'public' } }
                ))

            $result.Count | Should -Be 4
            (Get-ByName -Resources $result -Name 'TeamB::Project')['properties']['Visibility'] | Should -Be 'public'
            (Get-ByName -Resources $result -Name 'TeamA::Project')['properties']['Visibility'] | Should -Be 'private'
            @((Get-ByName -Resources $result -Name 'TeamB::Readers')['dependsOn']) | Should -Be @('Stub/Project/TeamB::Project')
        }

        It "matches the composite name and parameter names case-insensitively" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'T'; type = 'composite/standardproject'; properties = [ordered]@{ projectname = 'Lower' } }
                ))
            (Get-ByName -Resources $result -Name 'T::Project')['properties']['ProjectName'] | Should -Be 'Lower'
        }

        It "accepts a PSCustomObject instance" {
            $instance = [pscustomobject]@{ name = 'Obj'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'P' } }
            $result = @(Expand-CompositeResource -Resources @($instance) -Definitions $script:definitions)
            $result.Count | Should -Be 2
        }

        It "accepts a composite with a single member given as a mapping rather than a list" {
            $definitions = @{ Single = [ordered]@{ resources = [ordered]@{ name = 'Only'; type = 'Stub/Only' } } }
            $result = @(Expand-CompositeResource -Resources @([ordered]@{ name = 'S'; type = 'Composite/Single' }) -Definitions $definitions)
            $result.Count | Should -Be 1
            $result[0]['name'] | Should -Be 'S::Only'
        }
    }

    Context "Parameter tokens" {

        It "keeps the type of a whole-value token and interpolates an embedded one" {
            $definitions = @{
                Typed = New-Definition -Parameters ([ordered]@{
                        Tags    = [ordered]@{ defaultValue = @('a', 'b') }
                        Enabled = [ordered]@{ defaultValue = $true }
                        Name    = 'svc'
                        Nested  = [ordered]@{ defaultValue = [ordered]@{ Key = 'Value' } }
                    }) -Resources @(
                    [ordered]@{
                        name       = 'Member-<composite=Name>'
                        type       = 'Stub/Typed'
                        properties = [ordered]@{
                            Tags        = '<composite=Tags>'
                            Enabled     = '<composite=Enabled>'
                            Description = 'Service <composite=Name> (enabled: <composite=Enabled>)'
                            Settings    = '<composite=Nested>'
                            List        = @('<composite=Name>', 'literal', @('<composite=Name>'))
                            Runtime     = "`$(variables('X'))"
                            Params      = '<params=Y>'
                        }
                    }
                )
            }

            $result = @(Expand-CompositeResource -Resources @([ordered]@{ name = 'I'; type = 'Composite/Typed' }) -Definitions $definitions)
            $properties = $result[0]['properties']

            $result[0]['name'] | Should -Be 'I::Member-svc'
            , $properties['Tags'] | Should -BeOfType [object[]]
            @($properties['Tags']) | Should -Be @('a', 'b')
            $properties['Enabled'] | Should -BeOfType [bool]
            $properties['Enabled'] | Should -BeTrue
            $properties['Description'] | Should -Be 'Service svc (enabled: True)'
            $properties['Settings']['Key'] | Should -Be 'Value'
            $properties['List'][0] | Should -Be 'svc'
            $properties['List'][1] | Should -Be 'literal'
            $properties['List'][2][0] | Should -Be 'svc'

            # The runner's own run-time syntax is not the composite's business.
            $properties['Runtime'] | Should -Be "`$(variables('X'))"
            $properties['Params']  | Should -Be '<params=Y>'
        }

        It "gives each member its own copy of a structured parameter value" {
            $shared = [ordered]@{ Key = 'Value' }
            $definitions = @{
                Twice = New-Definition -Parameters ([ordered]@{ Settings = $null }) -Resources @(
                    [ordered]@{ name = 'One'; type = 'Stub/T'; properties = [ordered]@{ S = '<composite=Settings>' } }
                    [ordered]@{ name = 'Two'; type = 'Stub/T'; properties = [ordered]@{ S = '<composite=Settings>' } }
                )
            }
            $result = @(Expand-CompositeResource -Definitions $definitions -Resources @(
                    [ordered]@{ name = 'I'; type = 'Composite/Twice'; properties = [ordered]@{ Settings = $shared } }
                ))

            $result[0]['properties']['S']['Key'] = 'Changed'
            $result[1]['properties']['S']['Key'] | Should -Be 'Value'
            $shared['Key'] | Should -Be 'Value'
        }

        It "substitutes a `$null value for a parameter declared with defaultValue: null" {
            $definitions = @{
                Nullable = New-Definition -Parameters ([ordered]@{ Optional = [ordered]@{ defaultValue = $null } }) -Resources @(
                    [ordered]@{ name = 'M'; type = 'Stub/T'; properties = [ordered]@{ Value = '<composite=Optional>'; Text = 'x<composite=Optional>y' } }
                )
            }
            $result = @(Expand-CompositeResource -Resources @([ordered]@{ name = 'I'; type = 'Composite/Nullable' }) -Definitions $definitions)
            $result[0]['properties']['Value'] | Should -BeNullOrEmpty
            $result[0]['properties']['Text'] | Should -Be 'xy'
        }

        It "throws on a token naming an undeclared parameter" {
            $definitions = @{
                Bad = New-Definition -Parameters ([ordered]@{ Known = 'x' }) -Resources @(
                    [ordered]@{ name = 'M'; type = 'Stub/T'; properties = [ordered]@{ Value = '<composite=Unknown>' } }
                )
            }
            { Expand-CompositeResource -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) -Definitions $definitions } |
                Should -Throw "*'<composite=Unknown>'*Declared parameters: Known*"
        }

        It "throws on an undeclared token embedded in a string, and when nothing is declared" {
            $definitions = @{
                Bad = New-Definition -Resources @(
                    [ordered]@{ name = 'M'; type = 'Stub/T'; properties = [ordered]@{ Value = 'prefix-<composite=Unknown>' } }
                )
            }
            { Expand-CompositeResource -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) -Definitions $definitions } |
                Should -Throw "*'<composite=Unknown>'*(none)*"
        }

        It "throws when a structured value is embedded in a longer string" {
            $definitions = @{
                Bad = New-Definition -Parameters ([ordered]@{ Tags = [ordered]@{ defaultValue = @('a') } }) -Resources @(
                    [ordered]@{ name = 'M'; type = 'Stub/T'; properties = [ordered]@{ Value = 'tags: <composite=Tags>' } }
                )
            }
            { Expand-CompositeResource -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) -Definitions $definitions } |
                Should -Throw "*list or mapping*"
        }
    }

    Context "Parameter binding" {

        BeforeAll { $script:definitions = New-StandardDefinitions }

        It "throws naming every missing required parameter" {
            $definitions = @{
                TwoRequired = New-Definition -Parameters ([ordered]@{ A = $null; B = [ordered]@{ description = 'no default' } }) -Resources @(
                    [ordered]@{ name = 'M'; type = 'Stub/T' }
                )
            }
            { Expand-CompositeResource -Resources @([ordered]@{ name = 'I'; type = 'Composite/TwoRequired' }) -Definitions $definitions } |
                Should -Throw "*?Composite/TwoRequired/I?*required parameter(s) 'A', 'B'*"
        }

        It "throws on a property the composite does not declare" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'I'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'x'; Typo = 1 } }
                ) } | Should -Throw "*'Typo'*does not declare*ProjectName, Visibility*"
        }

        It "throws on a property when the composite declares no parameters" {
            $definitions = @{ NoParams = New-Definition -Resources @([ordered]@{ name = 'M'; type = 'Stub/T' }) }
            { Expand-CompositeResource -Definitions $definitions -Resources @(
                    [ordered]@{ name = 'I'; type = 'Composite/NoParams'; properties = [ordered]@{ X = 1 } }
                ) } | Should -Throw "*'X'*Declared parameters: (none)*"
        }

        It "throws when properties is not a mapping" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'I'; type = 'Composite/StandardProject'; properties = 'nope' }
                ) } | Should -Throw "*'properties' value that is not a mapping*"
        }

        It "throws when the definition's parameters is not a mapping" {
            $definitions = @{ Bad = [ordered]@{ parameters = @('A'); resources = @([ordered]@{ name = 'M'; type = 'Stub/T' }) } }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) } |
                Should -Throw "*'parameters' value that is not a mapping*"
        }

        It "throws when a parameter is declared as a list" {
            $definitions = @{ Bad = New-Definition -Parameters ([ordered]@{ A = @('x') }) -Resources @([ordered]@{ name = 'M'; type = 'Stub/T' }) }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) } |
                Should -Throw "*parameter 'A' is a list*"
        }

        It "throws on an unsupported key in a parameter specification" {
            $definitions = @{ Bad = New-Definition -Parameters ([ordered]@{ A = [ordered]@{ default = 'x' } }) -Resources @([ordered]@{ name = 'M'; type = 'Stub/T' }) }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) } |
                Should -Throw "*parameter 'A' has unsupported key(s) 'default'*"
        }
    }

    Context "Inheritance from the instance" {

        BeforeAll {
            $script:definitions = @{
                Pair = New-Definition -Resources @(
                    [ordered]@{ name = 'First'; type = 'Stub/T'; properties = @{} }
                    [ordered]@{
                        name               = 'Second'
                        type               = 'Stub/T'
                        DependsOn          = 'Stub/T/First'
                        condition          = "equals 1 1"
                        target             = [ordered]@{ action = 'Local' }
                        resourceCredential = [ordered]@{ action = 'Environment'; name = 'OWN' }
                        notify             = @('Stub/Own/Own')
                    }
                )
            }
            $script:result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Own'; type = 'Stub/Own' }
                    [ordered]@{ name = 'Up'; type = 'Stub/Up' }
                    [ordered]@{ name = 'Down'; type = 'Stub/Down' }
                    [ordered]@{
                        name               = 'P'
                        type               = 'Composite/Pair'
                        dependsOn          = @('Stub/Up/Up')
                        notify             = 'Stub/Down/Down'
                        preCondition       = "equals (variables 'Env') 'Prod'"
                        target             = [ordered]@{ action = 'WinRM'; computerName = 'srv01' }
                        resourceCredential = [ordered]@{ action = 'Environment'; name = 'INHERITED' }
                        description        = 'A pair.'
                    }
                ))
            $script:first  = Get-ByName -Resources $script:result -Name 'P::First'
            $script:second = Get-ByName -Resources $script:result -Name 'P::Second'
        }

        It "adds the instance's dependsOn to every member, after the member's own" {
            @($script:first['dependsOn'])  | Should -Be @('Stub/Up/Up')
            @($script:second['DependsOn']) | Should -Be @('Stub/T/P::First', 'Stub/Up/Up')
        }

        It "writes back under the member's own key spelling" {
            @($script:second.Keys) -ccontains 'DependsOn' | Should -BeTrue
            @($script:second.Keys) -ccontains 'dependsOn' | Should -BeFalse -Because 'the member spelled it DependsOn'
        }

        It "adds the instance's notify to every member" {
            @($script:first['notify'])  | Should -Be @('Stub/Down/Down')
            @($script:second['notify']) | Should -Be @('Stub/Own/Own', 'Stub/Down/Down')
        }

        It "sets the instance's preCondition on a member without one" {
            $script:first['preCondition'] | Should -Be "equals (variables 'Env') 'Prod'"
        }

        It "AND-s the instance's preCondition with the member's own, retiring the deprecated 'condition' key" {
            $script:second['preCondition'] | Should -Be "(equals (variables 'Env') 'Prod') -and (equals 1 1)"
            $script:second.Contains('condition') | Should -BeFalse
        }

        It "applies the instance's target and resourceCredential only where the member sets none" {
            $script:first['target']['computerName'] | Should -Be 'srv01'
            $script:first['resourceCredential']['name'] | Should -Be 'INHERITED'
            $script:second['target']['action'] | Should -Be 'Local'
            $script:second['resourceCredential']['name'] | Should -Be 'OWN'
        }

        It "gives every member its own copy of an inherited target" {
            $result = @(Expand-CompositeResource -Definitions (New-StandardDefinitions) -Resources @(
                    [ordered]@{ name = 'Q'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'Q' }; target = [ordered]@{ action = 'WinRM' } }
                ))
            (Get-ByName -Resources $result -Name 'Q::Project')['target']['action'] = 'SSH'
            (Get-ByName -Resources $result -Name 'Q::Readers')['target']['action'] | Should -Be 'WinRM'
        }

        It "uses the deprecated 'condition' key on an instance as its preCondition" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Own'; type = 'Stub/Own' }
                    [ordered]@{ name = 'C'; type = 'Composite/Pair'; condition = 'equals 2 2' }
                ))
            (Get-ByName -Resources $result -Name 'C::First')['preCondition'] | Should -Be 'equals 2 2'
        }

        It "leaves members alone when the instance sets no dependsOn, notify or preCondition" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Own'; type = 'Stub/Own' }
                    [ordered]@{ name = 'Bare'; type = 'Composite/Pair' }
                ))
            $bareFirst = Get-ByName -Resources $result -Name 'Bare::First'
            $bareFirst.Contains('dependsOn') | Should -BeFalse
            $bareFirst.Contains('notify') | Should -BeFalse
            $bareFirst.Contains('preCondition') | Should -BeFalse
            (Get-ByName -Resources $result -Name 'Bare::Second')['condition'] | Should -Be 'equals 1 1'
        }

        It "drops an empty dependsOn list rather than writing one back" {
            $definitions = @{ Empty = New-Definition -Resources @([ordered]@{ name = 'M'; type = 'Stub/T'; dependsOn = @(' ', $null) }) }
            $result = @(Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'E'; type = 'Composite/Empty' }))
            $result[0].Contains('dependsOn') | Should -BeFalse
        }

        It "rejects keys that only have meaning for a single resource" -ForEach @(
            @{ Key = 'postCondition' }
            @{ Key = 'preExecutionScript' }
            @{ Key = 'postExecutionScript' }
        ) {
            $instance = [ordered]@{ name = 'P'; type = 'Composite/Pair' }
            $instance[$Key] = 'x'
            { Expand-CompositeResource -Definitions $script:definitions -Resources @($instance) } |
                Should -Throw "*?Composite/Pair/P? sets '$Key', which is not supported on a composite instance*"
        }

        It "rejects an unknown instance key" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'P'; type = 'Composite/Pair'; propertes = @{} }
                ) } | Should -Throw "*sets 'propertes', which is not a composite instance key*"
        }
    }

    Context "Overrides" {

        BeforeAll { $script:definitions = New-StandardDefinitions }

        It "merges override properties key by key and replaces other keys" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Up'; type = 'Stub/Up' }
                    [ordered]@{
                        name       = 'O'
                        type       = 'Composite/StandardProject'
                        properties = [ordered]@{ ProjectName = 'P' }
                        overrides  = [ordered]@{
                            readers = [ordered]@{
                                properties   = [ordered]@{ GroupName = 'Custom Readers'; Extra = 1 }
                                dependsOn    = @('Stub/Up/Up', 'Stub/Project/Project')
                                preCondition = 'equals 1 1'
                            }
                            Project = [ordered]@{ postCondition = 'result().InDesiredState' }
                        }
                    }
                ))

            $readers = Get-ByName -Resources $result -Name 'O::Readers'
            $readers['properties']['GroupName']   | Should -Be 'Custom Readers'
            $readers['properties']['Extra']       | Should -Be 1
            $readers['properties']['ProjectName'] | Should -Be 'P'
            @($readers['dependsOn']) | Should -Be @('Stub/Up/Up', 'Stub/Project/O::Project') -Because 'an override that names a member is rewritten like the definition'
            $readers['preCondition'] | Should -Be 'equals 1 1'
            (Get-ByName -Resources $result -Name 'O::Project')['postCondition'] | Should -Be 'result().InDesiredState'
        }

        It "sets properties on a member that has none" {
            $definitions = @{ Bare = New-Definition -Resources @([ordered]@{ name = 'M'; type = 'Stub/T' }) }
            $result = @(Expand-CompositeResource -Definitions $definitions -Resources @(
                    [ordered]@{ name = 'B'; type = 'Composite/Bare'; overrides = [ordered]@{ M = [ordered]@{ properties = [ordered]@{ X = 1 } } } }
                ))
            $result[0]['properties']['X'] | Should -Be 1
        }

        It "throws on an override for a member the composite does not have" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'O'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'P' }; overrides = [ordered]@{ Writers = [ordered]@{} } }
                ) } | Should -Throw "*overrides 'Writers'*Its resources: Project, Readers*"
        }

        It "throws when an override tries to change a member's name or type" -ForEach @(
            @{ Key = 'name' }
            @{ Key = 'type' }
        ) {
            $override = [ordered]@{}
            $override[$Key] = 'x'
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'O'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'P' }; overrides = [ordered]@{ Project = $override } }
                ) } | Should -Throw "*sets '$Key'; a member's name and type*"
        }

        It "throws when overrides, or one override, is not a mapping" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'O'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'P' }; overrides = @('Project') }
                ) } | Should -Throw "*'overrides' value that is not a mapping*"
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'O'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'P' }; overrides = [ordered]@{ Project = 'x' } }
                ) } | Should -Throw "*override for 'Project' is not a mapping*"
        }
    }

    Context "References to a composite instance" {

        BeforeAll { $script:definitions = New-StandardDefinitions }

        It "replaces a dependsOn on an instance with every member of the instance" {
            $before = [ordered]@{ name = 'After'; type = 'Stub/After'; dependsOn = @('Stub/Org/Org', 'Composite/StandardProject/TeamA') }
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Org'; type = 'Stub/Org' }
                    $before
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                ))

            @((Get-ByName -Resources $result -Name 'After')['dependsOn']) | Should -Be @(
                'Stub/Org/Org'
                'Stub/Project/TeamA::Project'
                'Stub/Group/TeamA::Readers'
            )

            # The caller's resource object is copied, never rewritten in place.
            @($before['dependsOn']) | Should -Be @('Stub/Org/Org', 'Composite/StandardProject/TeamA')
        }

        It "replaces a notify on an instance, matching the reference case-insensitively" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [pscustomobject]@{ name = 'Source'; type = 'Stub/Source'; notify = 'composite/standardproject/teama' }
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                ))
            @((Get-ByName -Resources $result -Name 'Source')['notify']) | Should -Be @('Stub/Project/TeamA::Project', 'Stub/Group/TeamA::Readers')
        }

        It "lets one instance depend on another" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'A'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                    [ordered]@{ name = 'B'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'B' }; dependsOn = @('Composite/StandardProject/A') }
                ))
            @((Get-ByName -Resources $result -Name 'B::Project')['dependsOn']) | Should -Be @('Stub/Project/A::Project', 'Stub/Group/A::Readers')
            @((Get-ByName -Resources $result -Name 'B::Readers')['dependsOn']) | Should -Be @('Stub/Project/B::Project', 'Stub/Project/A::Project', 'Stub/Group/A::Readers')
        }

        It "throws on a reference to an instance that does not exist" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                    [ordered]@{ name = 'After'; type = 'Stub/After'; dependsOn = @('Composite/StandardProject/TeamB') }
                ) } | Should -Throw "*?Stub/After/After? dependsOn ?Composite/StandardProject/TeamB?*Composite instances: Composite/StandardProject/TeamA*"
        }
    }

    Context "Nested composites" {

        BeforeAll {
            $script:definitions = @{
                Outer = New-Definition -Parameters ([ordered]@{ ProjectName = $null }) -Resources @(
                    [ordered]@{ name = 'Project'; type = 'Stub/Project'; properties = [ordered]@{ ProjectName = '<composite=ProjectName>' } }
                    [ordered]@{
                        name       = 'Repos'
                        type       = 'Composite/Inner'
                        dependsOn  = @('Stub/Project/Project')
                        properties = [ordered]@{ Prefix = '<composite=ProjectName>' }
                    }
                    [ordered]@{ name = 'Pipeline'; type = 'Stub/Pipeline'; dependsOn = @('Composite/Inner/Repos') }
                )
                Inner = New-Definition -Parameters ([ordered]@{ Prefix = $null }) -Resources @(
                    [ordered]@{ name = 'Main'; type = 'Stub/Repo'; properties = [ordered]@{ Name = '<composite=Prefix>-main' } }
                    [ordered]@{ name = 'Docs'; type = 'Stub/Repo'; dependsOn = @('Stub/Repo/Main'); properties = [ordered]@{ Name = '<composite=Prefix>-docs' } }
                )
            }
            $script:result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Up'; type = 'Stub/Up' }
                    [ordered]@{ name = 'X'; type = 'Composite/Outer'; properties = [ordered]@{ ProjectName = 'Proj' }; dependsOn = @('Stub/Up/Up'); preCondition = 'equals 1 1' }
                    [ordered]@{ name = 'Last'; type = 'Stub/Last'; dependsOn = @('Composite/Outer/X') }
                ))
        }

        It "expands a nested composite with nested names and the outer parameters" {
            ($script:result | ForEach-Object { "$($_['type'])/$($_['name'])" }) | Should -Be @(
                'Stub/Up/Up'
                'Stub/Project/X::Project'
                'Stub/Repo/X::Repos::Main'
                'Stub/Repo/X::Repos::Docs'
                'Stub/Pipeline/X::Pipeline'
                'Stub/Last/Last'
            )
            (Get-ByName -Resources $script:result -Name 'X::Repos::Docs')['properties']['Name'] | Should -Be 'Proj-docs'
        }

        It "passes the outer inheritance down to the nested members" {
            $docs = Get-ByName -Resources $script:result -Name 'X::Repos::Docs'
            @($docs['dependsOn']) | Should -Be @('Stub/Repo/X::Repos::Main', 'Stub/Project/X::Project', 'Stub/Up/Up')
            $docs['preCondition'] | Should -Be 'equals 1 1'
        }

        It "resolves a member's reference to a nested instance" {
            @((Get-ByName -Resources $script:result -Name 'X::Pipeline')['dependsOn']) | Should -Be @(
                'Stub/Repo/X::Repos::Main'
                'Stub/Repo/X::Repos::Docs'
                'Stub/Up/Up'
            )
        }

        It "resolves a reference to the outer instance to every leaf, nested ones included" {
            @((Get-ByName -Resources $script:result -Name 'Last')['dependsOn']) | Should -Be @(
                'Stub/Project/X::Project'
                'Stub/Repo/X::Repos::Main'
                'Stub/Repo/X::Repos::Docs'
                'Stub/Pipeline/X::Pipeline'
            )
        }

        It "throws on a recursive composite, naming the chain" {
            $definitions = @{
                A = New-Definition -Resources @([ordered]@{ name = 'b'; type = 'Composite/B' })
                B = New-Definition -Resources @([ordered]@{ name = 'a'; type = 'Composite/A' })
            }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/A' }) } |
                Should -Throw "*Composite 'A' is recursive: A -> B -> A*"
        }

        It "throws when nesting is deeper than -MaxDepth" {
            { Expand-CompositeResource -Definitions $script:definitions -MaxDepth 1 -Resources @(
                    [ordered]@{ name = 'X'; type = 'Composite/Outer'; properties = [ordered]@{ ProjectName = 'P' } }
                ) } | Should -Throw "*nested 2 levels deep (Outer -> Inner), deeper than the limit of 1*"
        }
    }

    Context "Invalid instances and definitions" {

        BeforeAll { $script:definitions = New-StandardDefinitions }

        It "throws on an unknown composite, listing the defined ones" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Missing' }) } |
                Should -Throw "*?Composite/Missing/I? refers to composite 'Missing', which is not defined. Defined composites: StandardProject*"
        }

        It "throws helpfully when no composite is defined at all" {
            { Expand-CompositeResource -Definitions $null -Resources @([ordered]@{ name = 'I'; type = 'Composite/Missing' }) } |
                Should -Throw "*add Composites/<Name>.yml*"
            { Expand-CompositeResource -Definitions @{} -Resources @([ordered]@{ name = 'I'; type = 'Composite/Missing' }) } |
                Should -Throw "*add Composites/<Name>.yml*"
        }

        It "throws on a composite type that is not exactly Composite/<Name>" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Standard/Project' }) } |
                Should -Throw "*a composite type is exactly 'Composite/<Name>'*"
        }

        It "throws on an instance without a name" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @([ordered]@{ type = 'Composite/StandardProject' }) } |
                Should -Throw "*has no name*"
        }

        It "throws on a definition without resources" {
            $definitions = @{ Empty = [ordered]@{ parameters = [ordered]@{} ; resources = @() } }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Empty' }) } |
                Should -Throw "*'Empty' has no resources*"
        }

        It "throws on an unsupported definition key" {
            $definitions = @{ Bad = [ordered]@{ resource = @(); resources = @([ordered]@{ name = 'M'; type = 'Stub/T' }) } }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) } |
                Should -Throw "*unsupported key 'resource'*"
        }

        It "throws on a member that is not a mapping, or has no name or type" -ForEach @(
            @{ Member = 'just-a-string'; Expected = '*resource #1 is not a mapping*' }
            @{ Member = [ordered]@{ type = 'Stub/T' }; Expected = '*resource #1 (instance ?Composite/Bad/I?) has no name*' }
            @{ Member = [ordered]@{ name = @('a', 'b'); type = 'Stub/T' }; Expected = '*has no name*' }
            @{ Member = [ordered]@{ name = 'M' }; Expected = "*('M') has no type*" }
        ) {
            $definitions = @{ Bad = [ordered]@{ resources = @($Member) } }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Bad' }) } |
                Should -Throw $Expected
        }

        It "throws on a definition listing the same member twice" {
            $definitions = @{ Dup = New-Definition -Resources @([ordered]@{ name = 'M'; type = 'Stub/T' }, [ordered]@{ name = 'M'; type = 'Stub/T' }) }
            { Expand-CompositeResource -Definitions $definitions -Resources @([ordered]@{ name = 'I'; type = 'Composite/Dup' }) } |
                Should -Throw "*lists the resource ?Stub/T/M? more than once*"
        }

        It "throws when an expanded resource collides with an existing one" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'TeamA::Project'; type = 'Stub/Project' }
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                ) } | Should -Throw "*produced the resource ?Stub/Project/TeamA::Project? more than once*"
        }

        It "throws when the same instance is declared twice" {
            { Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'B' } }
                ) } | Should -Throw "*?Composite/StandardProject/TeamA? is declared more than once*"
        }

        It "leaves duplicate ordinary resources to the runner, as before" {
            $result = @(Expand-CompositeResource -Definitions $script:definitions -Resources @(
                    [ordered]@{ name = 'Same'; type = 'Stub/S' }
                    [ordered]@{ name = 'Same'; type = 'Stub/S' }
                    [ordered]@{ name = 'TeamA'; type = 'Composite/StandardProject'; properties = [ordered]@{ ProjectName = 'A' } }
                ))
            $result.Count | Should -Be 4
        }
    }
}
