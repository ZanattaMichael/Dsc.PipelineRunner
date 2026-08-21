Describe "Test-DscV3ResourceType Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Test-DscV3ResourceType.ps1').FullName
    }

    Context "Structurally valid DSC v3 identifiers" {

        It "Accepts a simple owner/name: <Type>" -TestCases @(
            @{ Type = 'Microsoft/OSInfo' }
            @{ Type = 'Microsoft.Windows/Registry' }
            @{ Type = 'Microsoft.DSC.Debug/Echo' }
            @{ Type = 'Contoso.Custom/My_Resource' }
        ) {
            param($Type)
            Test-DscV3ResourceType -Type $Type | Should -BeTrue
        }
    }

    Context "Non-compliant strings" {

        It "Rejects <Reason>: <Type>" -TestCases @(
            @{ Type = 'Service';                 Reason = 'a bare name with no slash' }
            @{ Type = 'PSDscResources/';         Reason = 'an empty name segment' }
            @{ Type = '/Registry';               Reason = 'an empty namespace segment' }
            @{ Type = 'Micro soft/OSInfo';       Reason = 'embedded whitespace' }
            @{ Type = 'a/b/c';                   Reason = 'more than one slash' }
            @{ Type = '1Owner/Resource';         Reason = 'a segment starting with a digit' }
            @{ Type = 'Owner/.Resource';         Reason = 'an empty leading dotted segment' }
        ) {
            param($Type, $Reason)
            Test-DscV3ResourceType -Type $Type | Should -BeFalse
        }

        It "Rejects an empty or whitespace string" {
            Test-DscV3ResourceType -Type '' | Should -BeFalse
            Test-DscV3ResourceType -Type '   ' | Should -BeFalse
        }

        It "Rejects a null value" {
            Test-DscV3ResourceType -Type $null | Should -BeFalse
        }
    }
}
