Describe "ConvertTo-DscV3ConfigurationDocument Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        # The converter depends on the structural type validator.
        . (Get-FunctionPath 'Test-DscV3ResourceType.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscV3ConfigurationDocument.ps1').FullName
    }

    Context "Producing a schema-valid document" {

        It "Stamps the DSC v3 configuration-document schema" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Microsoft/OSInfo'; name = 'os'; properties = @{} }
            )
            $doc['$schema'] | Should -Match 'schemas/v3'
            $doc['$schema'] | Should -Match 'config/document'
        }

        It "Emits one document resource per input resource, in order" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Microsoft/OSInfo'; name = 'first'; properties = @{} }
                @{ type = 'Microsoft.Windows/Registry'; name = 'second'; properties = @{ ensure = 'Present' } }
            )
            $doc.resources.Count | Should -Be 2
            $doc.resources[0].name | Should -Be 'first'
            $doc.resources[1].name | Should -Be 'second'
            $doc.resources[1].type | Should -Be 'Microsoft.Windows/Registry'
            $doc.resources[1].properties.ensure | Should -Be 'Present'
        }

        It "Keeps only name/type/properties and drops pipeline-only keys" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{
                    type                = 'Microsoft/OSInfo'
                    name                = 'os'
                    properties          = @{ foo = 'bar' }
                    condition           = '1 -eq 1'
                    postExecutionScript = 'Stop-TaskProcessing'
                    dependsOn           = @('other')
                }
            )
            $keys = @($doc.resources[0].Keys)
            $keys | Should -Contain 'name'
            $keys | Should -Contain 'type'
            $keys | Should -Contain 'properties'
            $keys | Should -Not -Contain 'condition'
            $keys | Should -Not -Contain 'postExecutionScript'
            $keys | Should -Not -Contain 'dependsOn'
        }

        It "Defaults missing properties to an empty object" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Microsoft/OSInfo'; name = 'os' }
            )
            # An empty hashtable is emitted (Pester treats @{} as "empty", so assert the
            # shape and key-count rather than -Not -BeNullOrEmpty).
            $doc.resources[0].Contains('properties') | Should -BeTrue
            $doc.resources[0].properties | Should -BeOfType [System.Collections.IDictionary]
            @($doc.resources[0].properties.Keys).Count | Should -Be 0
        }

        It "Accepts pscustomobject resources as well as hashtables" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @(
                [pscustomobject]@{ type = 'Microsoft/OSInfo'; name = 'os'; properties = [pscustomobject]@{ x = 1 } }
            )
            $doc.resources[0].name | Should -Be 'os'
            $doc.resources[0].type | Should -Be 'Microsoft/OSInfo'
        }

        It "Returns an empty resources list for an empty input" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @()
            @($doc.resources).Count | Should -Be 0
        }
    }

    Context "Compliance validation" {

        It "Throws when a resource has no name" {
            { ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Microsoft/OSInfo'; properties = @{} }
            ) } | Should -Throw "*missing a non-empty 'name'*"
        }

        It "Throws when a resource has no type" {
            { ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ name = 'os'; properties = @{} }
            ) } | Should -Throw "*missing a non-empty 'type'*"
        }

        It "Throws when a resource type is not a DSC v3 identifier" {
            { ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Service'; name = 'svc'; properties = @{} }
            ) } | Should -Throw "*not a DSC v3 resource identifier*"
        }

        It "Aggregates every offending resource into a single throw" {
            $sb = { ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Service'; name = 'svc'; properties = @{} }
                @{ type = 'Microsoft/OSInfo'; properties = @{} }
            ) }
            $sb | Should -Throw "*2 resource(s) are not DSC v3 compliant*"
        }
    }

    Context "Existence check against a known resource set" {

        It "Passes when every type is in the available set" {
            $doc = ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Microsoft/OSInfo'; name = 'os'; properties = @{} }
            ) -AvailableResourceType @('Microsoft/OSInfo', 'Microsoft.Windows/Registry')
            $doc.resources[0].type | Should -Be 'Microsoft/OSInfo'
        }

        It "Throws when a structurally valid type is not available on the host" {
            { ConvertTo-DscV3ConfigurationDocument -Resource @(
                @{ type = 'Contoso.Widgets/Gadget'; name = 'g'; properties = @{} }
            ) -AvailableResourceType @('Microsoft/OSInfo') } |
                Should -Throw "*not available to dsc.exe on this host*"
        }
    }
}
