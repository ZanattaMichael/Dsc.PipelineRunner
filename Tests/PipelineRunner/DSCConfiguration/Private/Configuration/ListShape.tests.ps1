Describe "A list-valued resource property keeps its shape through loading and expansion" -Tag Unit, Runner, Configuration {

    # PowerShell unrolls an array that a function returns with a plain `return`: one element
    # arrives as a scalar and none as $null. Three places did that to a resource property, so a
    # one-item list reached the engine as a single value (and, for the DSC v3 engine, was sent to
    # `dsc` as a JSON scalar/object instead of an array):
    #
    #   * ConvertTo-CaseInsensitiveHashtable   (JSON configurations, at load)
    #   * Expand-ParameterInArray / Expand-StringInArray (both formats, at expansion)
    #   * Resolve-PipelineParameter            (a `<params=Name>` token naming a list parameter)
    #
    # These tests load the same document as JSON and as YAML exactly the way Start-DscRunner
    # does, run the runner's two expansion passes, and compare each property's JSON form, which
    # tells a list (`["one"]`) from a collapsed value (`"one"`).

    BeforeDiscovery {

        $script:Formats = @(
            @{ Format = 'JSON' }
            @{ Format = 'YAML' }
        )

        # Each mapping has a single key so its JSON form does not depend on key order.
        $script:Cases = @(
            @{ Property = 'tags';          Expected = '["one"]';                   Because = 'a one-item list of scalars' }
            @{ Property = 'users';         Expected = '[{"login":"a"}]';           Because = 'a one-item list of mappings' }
            @{ Property = 'tokenList';     Expected = '["svc"]';                   Because = 'a one-item list holding a <params=Name> token' }
            @{ Property = 'tokenMapping';  Expected = '[{"login":"svc"}]';         Because = 'a one-item list whose mapping holds a <params=Name> token' }
            @{ Property = 'exprList';      Expected = '["2"]';                     Because = 'a one-item list holding a $(...) expression' }
            @{ Property = 'exprMapping';   Expected = '[{"login":"n-2"}]';         Because = 'a one-item list whose mapping holds a $(...) expression' }
            @{ Property = 'listParam';     Expected = '["solo"]';                  Because = 'a <params=Name> token naming a one-item list parameter' }
            @{ Property = 'listParamItem'; Expected = '["solo"]';                  Because = 'a one-item list whose item names a one-item list parameter' }
            @{ Property = 'nested';        Expected = '{"inner":["one"]}';         Because = 'a one-item list inside a nested mapping' }
            @{ Property = 'empty';         Expected = '[]';                        Because = 'an empty list' }
            @{ Property = 'emptyParam';    Expected = '[]';                        Because = 'a <params=Name> token naming an empty list parameter' }
            @{ Property = 'two';           Expected = '["a","b"]';                 Because = 'a two-item list of scalars' }
            @{ Property = 'twoMappings';   Expected = '[{"login":"a"},{"login":"b"}]'; Because = 'a two-item list of mappings' }
            @{ Property = 'twoParam';      Expected = '["x","y"]';                 Because = 'a <params=Name> token naming a two-item list parameter' }
            @{ Property = 'scalar';        Expected = '"plain"';                   Because = 'a scalar is still a scalar' }
        )
    }

    BeforeAll {

        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        . (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        . (Get-FunctionPath 'Resolve-PipelineParameter.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName

        $script:Documents = @{
            JSON = @'
{
  "parameters": {
    "Login":   { "defaultValue": "svc" },
    "Members": { "defaultValue": [ "solo" ] },
    "Pair":    { "defaultValue": [ "x", "y" ] },
    "None":    { "defaultValue": [] }
  },
  "properties": {
    "tags":          [ "one" ],
    "users":         [ { "login": "a" } ],
    "tokenList":     [ "<params=Login>" ],
    "tokenMapping":  [ { "login": "<params=Login>" } ],
    "exprList":      [ "$(1 + 1)" ],
    "exprMapping":   [ { "login": "n-$(1 + 1)" } ],
    "listParam":     "<params=Members>",
    "listParamItem": [ "<params=Members>" ],
    "nested":        { "inner": [ "one" ] },
    "empty":         [],
    "emptyParam":    "<params=None>",
    "two":           [ "a", "b" ],
    "twoMappings":   [ { "login": "a" }, { "login": "b" } ],
    "twoParam":      "<params=Pair>",
    "scalar":        "plain"
  }
}
'@
            YAML = @'
parameters:
  Login:   { defaultValue: svc }
  Members: { defaultValue: [ solo ] }
  Pair:    { defaultValue: [ x, y ] }
  None:    { defaultValue: [] }
properties:
  tags:          [ one ]
  users:         [ { login: a } ]
  tokenList:     [ '<params=Login>' ]
  tokenMapping:  [ { login: '<params=Login>' } ]
  exprList:      [ '$(1 + 1)' ]
  exprMapping:   [ { login: 'n-$(1 + 1)' } ]
  listParam:     '<params=Members>'
  listParamItem: [ '<params=Members>' ]
  nested:        { inner: [ one ] }
  empty:         []
  emptyParam:    '<params=None>'
  two:           [ a, b ]
  twoMappings:   [ { login: a }, { login: b } ]
  twoParam:      '<params=Pair>'
  scalar:        plain
'@
        }

        # Loads a document the way Start-DscRunner does and runs its two expansion passes.
        function Resolve-TestProperty {
            param([string]$Format)

            if ($Format -eq 'YAML') {
                $pipeline = $script:Documents.YAML | ConvertFrom-Yaml
            }
            else {
                $pipeline = ConvertTo-CaseInsensitiveHashtable -InputObject ($script:Documents.JSON | ConvertFrom-Json -AsHashtable)
            }

            # Resolve-PipelineParameter reads $parameters through the scope chain.
            $parameters = Get-DefaultValues -Source $pipeline.parameters
            return Expand-HashTable -InputHashTable (Expand-Parameters -InputHashTable $pipeline.properties)
        }
    }

    Context "<Format> configuration" -ForEach $script:Formats {

        BeforeAll {
            $resolved = Resolve-TestProperty -Format $Format
        }

        It "resolves '<Property>' to <Expected> (<Because>)" -ForEach $script:Cases {
            ConvertTo-Json -InputObject $resolved[$Property] -Compress -Depth 5 | Should -BeExactly $Expected -Because $Because
        }

        It "hands '<Property>' over as a list, not as its only element" -ForEach ($script:Cases | Where-Object { $_.Expected.StartsWith('[') }) {
            # A string or a hashtable also answers .Count, so the type is what is asserted.
            ($resolved[$Property] -is [System.Collections.IList]) | Should -BeTrue -Because $Because
        }
    }

    Context "the functions on their own" {

        BeforeAll {
            $parameters = @{ One = @('solo'); None = @(); Scalar = 'svc' }
        }

        It "<Function> returns a <Count>-item list for a <Count>-item list" -ForEach @(
            @{ Function = 'Expand-StringInArray';    Count = 0; Items = @() }
            @{ Function = 'Expand-StringInArray';    Count = 1; Items = @('one') }
            @{ Function = 'Expand-StringInArray';    Count = 2; Items = @('one', 'two') }
            @{ Function = 'Expand-ParameterInArray'; Count = 0; Items = @() }
            @{ Function = 'Expand-ParameterInArray'; Count = 1; Items = @('one') }
            @{ Function = 'Expand-ParameterInArray'; Count = 2; Items = @('one', 'two') }
        ) {
            $result = & $Function -InputArray $Items
            ($result -is [object[]]) | Should -BeTrue
            $result.Count | Should -Be $Count
        }

        It "ConvertTo-CaseInsensitiveHashtable keeps a <Count>-item list inside a dictionary" -ForEach @(
            @{ Count = 0; Json = '{"list":[]}' }
            @{ Count = 1; Json = '{"list":["one"]}' }
            @{ Count = 1; Json = '{"list":[{"k":"v"}]}' }
            @{ Count = 2; Json = '{"list":["one","two"]}' }
        ) {
            $result = ConvertTo-CaseInsensitiveHashtable -InputObject ($Json | ConvertFrom-Json -AsHashtable)
            ($result.list -is [object[]]) | Should -BeTrue
            $result.list.Count | Should -Be $Count
            ConvertTo-Json -InputObject $result -Compress -Depth 5 | Should -BeExactly $Json
        }

        It "ConvertTo-CaseInsensitiveHashtable keeps a list nested in a list as one element" {
            $result = ConvertTo-CaseInsensitiveHashtable -InputObject ('{"list":[["a"],["b","c"]]}' | ConvertFrom-Json -AsHashtable)
            ConvertTo-Json -InputObject $result -Compress -Depth 5 | Should -BeExactly '{"list":[["a"],["b","c"]]}'
        }

        It "Resolve-PipelineParameter returns a one-item list parameter as a list" {
            $result = Resolve-PipelineParameter -Name 'One'
            ($result -is [object[]]) | Should -BeTrue
            $result.Count | Should -Be 1
        }

        It "Resolve-PipelineParameter returns an empty list parameter as an empty list" {
            $result = Resolve-PipelineParameter -Name 'None'
            ($result -is [object[]]) | Should -BeTrue
            $result.Count | Should -Be 0
        }

        It "Resolve-PipelineParameter still returns a scalar parameter as a scalar" {
            Resolve-PipelineParameter -Name 'Scalar' | Should -BeExactly 'svc'
        }
    }
}
