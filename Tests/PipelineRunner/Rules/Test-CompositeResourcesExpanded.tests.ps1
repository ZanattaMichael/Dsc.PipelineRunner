Describe "Test-CompositeResourcesExpanded" -Tag Unit, Runner, Rules, PreParse, Composite {

    BeforeAll {
        $preParseFilePath = (Get-FunctionPath 'Test-CompositeResourcesExpanded.ps1').FullName
    }

    It "passes silently when no resource is a composite instance" {
        $resources = @(
            [PSCustomObject]@{ type = 'Module/MyResourceType'; name = 'MyResource'; properties = @{} }
            @{ type = 'Module/Other'; name = 'CompositeLookingName'; properties = @{} }
            $null
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Not -Throw
    }

    It "passes an empty configuration" {
        { . $preParseFilePath -PipelineResources @() } | Should -Not -Throw
    }

    It "throws once, naming every unexpanded composite instance" {
        $resources = @(
            [PSCustomObject]@{ type = 'Composite/StandardProject'; name = 'TeamA'; properties = @{} }
            [PSCustomObject]@{ type = 'Module/B'; name = 'ResourceB'; properties = @{} }
            @{ type = 'composite/RepoSet'; name = 'Repos'; properties = @{} }
        )

        { . $preParseFilePath -PipelineResources $resources } |
            Should -Throw '*2 composite resource instance(s) reached the runner unexpanded*Composite/StandardProject/TeamA*composite/RepoSet/Repos*'
    }

    It "sorts ahead of Test-ResourcesForIncorrectProperties, so it reports first" {
        $rules = @(Get-ChildItem -LiteralPath (Split-Path -Parent $preParseFilePath) -Filter '*.ps1' | Sort-Object Name | ForEach-Object Name)
        $rules.IndexOf('Test-CompositeResourcesExpanded.ps1') | Should -BeLessThan $rules.IndexOf('Test-ResourcesForIncorrectProperties.ps1')
    }
}
