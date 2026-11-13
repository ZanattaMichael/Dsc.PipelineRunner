Describe "Expand-Parameters Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        $expandExpandHashTableFilePath = (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        # Expand-HashTable / Expand-StringInArray expand strings through Expand-SafeString,
        # which validates embedded expressions with the condition allow-list.
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        $expandParameterInArrayFilePath = (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        
        $resolveParameterFilePath = (Get-FunctionPath 'Resolve-PipelineParameter.ps1').FullName

        . $preParseFilePath
        . $expandExpandHashTableFilePath
        . $expandParameterInArrayFilePath
        . $resolveParameterFilePath

        # Expand-HashTable delegates array handling to Expand-StringInArray, which the
        # two-pass chain below exercises.
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName

        # Define the script-scoped parameters hashtable
        $Script:parameters = @{
            example = 'ExpandedValue'
            anotherExample = 'AnotherExpandedValue'
            emptyExample = ''
            numericExample = 42
        }

    }

    Context "With Nested Hashtables" {
        It "should recursively expand nested hashtables" {
            $inputObj = @{
                outerKey = @{
                    innerKey = '<params=example>'
                }
            }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.outerKey.innerKey | Should -Be 'ExpandedValue'

        }
    }

    Context "With Single-Element Arrays" {
        # A one-entry array used to be routed to the scalar branch, where -match stringified
        # its element. PowerShell still unrolls a one-element collection on return, so the
        # value arrives as a scalar either way - what changed is that its contents are now
        # expanded.
        It "should expand a token in a one-entry array" {
            $inputObj = @{ listKey = @('<params=example>') }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.listKey | Should -Be 'ExpandedValue'
        }

        It "should expand a token inside a lone hashtable entry" {
            $inputObj = @{ listKey = @( @{ innerKey = '<params=example>' } ) }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.listKey.innerKey | Should -Be 'ExpandedValue'
        }
    }

    Context "Chained with Expand-HashTable as Start-DscRunner calls them" {
        It "should hand an array of hashtables through both passes intact" {
            # The runner resolves properties as
            # Expand-HashTable -InputHashTable (Expand-Parameters -InputHashTable ...).
            # Datum supplies a List`1, Expand-Parameters returns a plain object[], and the
            # second pass has to recognise that as a collection - otherwise it is flattened
            # into a single "System.Collections.Hashtable ..." string and no array-typed
            # resource property can bind it.
            $permissions = [System.Collections.Generic.List[Object]]::new()
            $permissions.Add(@{ Identity = '<params=example>'; Permission = 'Allow' })
            $permissions.Add(@{ Identity = 'Project Valid Users'; Permission = 'Allow' })

            $properties = @{ Permissions = $permissions; ProjectName = '<params=anotherExample>' }

            $result = Expand-HashTable -InputHashTable (Expand-Parameters -InputHashTable $properties)

            $result.Permissions -is [string] | Should -Be $false
            { [hashtable[]]$result.Permissions } | Should -Not -Throw
            ([hashtable[]]$result.Permissions).Count | Should -Be 2
            $result.Permissions[0].Identity | Should -Be 'ExpandedValue'
            $result.Permissions[1].Identity | Should -Be 'Project Valid Users'
            $result.ProjectName | Should -Be 'AnotherExpandedValue'
        }
    }

    Context "With Arrays Containing Strings" {
        It "should expand strings in arrays correctly" {
            $inputObj = @{
                listKey = @('<params=example>', 'RegularString')
            }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.listKey | Should -BeExactly @('ExpandedValue', 'RegularString')
        }
    }

    Context "With String Placeholders" {
        It "should replace placeholders with actual values" {
            $inputObj = @{
                key = '<params=example>'
            }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.key | Should -Be 'ExpandedValue'

        }

        It "should throw an error if placeholder is not found" {
            $inputObj = @{
                key = '<params=nonExistent>'
            }
            { Expand-Parameters -InputHashTable $inputObj } | Should -Throw "*Parameter 'nonExistent' not found in the parameters hashtable*"
        }
    }

    Context "With Mixed Types in Hashtable" {
        It "should handle mixed types correctly" {
            $inputObj = @{
                boolKey = $true
                stringKey = 'JustAString'
                paramKey = '<params=example>'
                listKey = @('<params=anotherExample>', 'String')
                hashKey = @{
                    nestedParam = '<params=example>'
                }
            }

            $result = Expand-Parameters -InputHashTable $inputObj

            $result.boolKey | Should -Be $true
            $result.stringKey | Should -Be 'JustAString'
            $result.paramKey | Should -Be 'ExpandedValue'
            $result.listKey | Should -BeExactly @('AnotherExpandedValue', 'String')
            $result.hashKey.nestedParam | Should -BeExactly 'ExpandedValue'

        }
    }

    Context "Parameter presence" {

        It "should resolve a parameter whose value is an empty string" {
            # Presence used to be tested with [String]::IsNullOrEmpty, so a parameter
            # legitimately declared as '' was reported as missing (#5).
            $result = Expand-Parameters -InputHashTable @{ key = '<params=emptyExample>' }

            $result.key | Should -Be ''
        }

        It "should preserve the parameter's type on a whole-scalar substitution" {
            $result = Expand-Parameters -InputHashTable @{ key = '<params=numericExample>' }

            $result.key | Should -Be 42
            $result.key | Should -BeOfType [int]
        }

        It "should name the missing parameter in the error" {
            { Expand-Parameters -InputHashTable @{ key = '<params=nonExistent>' } } |
                Should -Throw "*'nonExistent'*"
        }
    }

    Context "Nested expansion does not depend on the caller's scope" {

        It "should expand a list nested inside a hashtable without a caller-scope \$task" {
            # The List`1 branch read $task.properties[$key] from the *caller's* scope, so a
            # nested list expanded against the wrong values - or threw - outside the runner.
            $list = [System.Collections.Generic.List[object]]::new()
            $list.Add('<params=example>')
            $list.Add('RegularString')

            $inputObj = @{
                outerKey = @{
                    listKey = $list
                }
            }

            $result = Expand-Parameters -InputHashTable $inputObj

            $result.outerKey.listKey[0] | Should -Be 'ExpandedValue'
            $result.outerKey.listKey[1] | Should -Be 'RegularString'
        }

        It "should preserve nulls rather than throwing on them" {
            $result = Expand-Parameters -InputHashTable @{ key = $null }

            $result.Keys | Should -Contain 'key'
            $result.key | Should -BeNullOrEmpty
        }

        It "should keep boolean values as booleans" {
            $result = Expand-Parameters -InputHashTable @{ key = $true }

            $result.key | Should -BeOfType [bool]
            $result.key | Should -BeTrue
        }
    }
}
