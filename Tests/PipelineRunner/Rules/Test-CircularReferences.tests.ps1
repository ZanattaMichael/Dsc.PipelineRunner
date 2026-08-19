Describe "Test-CircularReferences" -Tag Unit, Runner, Rules, PreParse {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Test-CircularReferences.ps1').FullName

        # Mock Get-DscResource for testing purposes
        Mock -CommandName Get-DscResource -MockWith {
            @{
                Name = 'MyResourceType'
                Properties = @(
                    [PSCustomObject]@{ Name = 'Property1'; PropertyType = 'String'; IsMandatory = $true; Values = @('Value1', 'Value2') },
                    [PSCustomObject]@{ Name = 'Property2'; PropertyType = 'String'; IsMandatory = $false; Values = @() }
                )
            }
        }

        # Mock data for testing
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @("ResourceType3/ResourceName3")
            },
            [PSCustomObject]@{
                Type = "ResourceType3"
                Name = "ResourceName3"
                DependsOn = @()
            }
        )

        Mock -CommandName Write-Host

    }

    It "Should not detect any circular dependencies when none exist" {
        $params = @{
            Resource = $PipelineResources[0]
            Visited = @()
            Stack = @()
        }

        { . $preParseFilePath -PipelineResources $resources } | Should -Not -Throw
    }

    It "Should detect a circular dependency" {
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @("ResourceType1/ResourceName1")
            }
        )

        $params = @{
            Resource = $PipelineResources[0]
            Visited = @()
            Stack = @()
        }

        { . $preParseFilePath -PipelineResources $PipelineResources } | Should -Throw "*Circular dependency detected with Resource*"

    }

    It "Should handle multiple resources without circular dependencies" {
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @("ResourceType3/ResourceName3")
            },
            [PSCustomObject]@{
                Type = "ResourceType3"
                Name = "ResourceName3"
                DependsOn = @()
            },
            [PSCustomObject]@{
                Type = "ResourceType4"
                Name = "ResourceName4"
                DependsOn = @("ResourceType5/ResourceName5")
            },
            [PSCustomObject]@{
                Type = "ResourceType5"
                Name = "ResourceName5"
                DependsOn = @()
            }
        )

        ForEach ($Resource in $PipelineResources) {
            $params = @{
                Resource = $Resource
                Visited = @()
                Stack = @()
            }

            { . $preParseFilePath -PipelineResources $resources } | Should -Not -Throw
        }
    }

    It "Should detect nested circular dependencies" {
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @("ResourceType3/ResourceName3")
            },
            [PSCustomObject]@{
                Type = "ResourceType3"
                Name = "ResourceName3"
                DependsOn = @("ResourceType1/ResourceName1")
            }
        )

        $params = @{
            Resource = $PipelineResources[0]
            Visited = @()
            Stack = @()
        }

        { . $preParseFilePath -PipelineResources $PipelineResources } | Should -Throw "*Circular dependency detected with Resource*"

    }

    It "Should detect nested circular dependencies with smaller loops" {
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @("ResourceType3/ResourceName3")
            },
            [PSCustomObject]@{
                Type = "ResourceType3"
                Name = "ResourceName3"
                DependsOn = @("ResourceType2/ResourceName2")
            }
        )

        $params = @{
            Resource = $PipelineResources[0]
            Visited = @()
            Stack = @()
        }

        { . $preParseFilePath -PipelineResources $PipelineResources } | Should -Throw "*Circular dependency detected with Resource*"

    }

    It "Should detect complex circular dependencies" {
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @("ResourceType3/ResourceName3")
            },
            [PSCustomObject]@{
                Type = "ResourceType3"
                Name = "ResourceName3"
                DependsOn = @("ResourceType1/ResourceName1")
            },
            [PSCustomObject]@{
                Type = "ResourceType4"
                Name = "ResourceName4"
                DependsOn = @("ResourceType5/ResourceName5")
            },
            [PSCustomObject]@{
                Type = "ResourceType5"
                Name = "ResourceName5"
            }
        )

        $params = @{
            Resource = $PipelineResources[0]
            Visited = @()
            Stack = @()
        }

        { . $preParseFilePath -PipelineResources $PipelineResources } | Should -Throw "*Circular dependency detected with Resource*"

    }

    It "Should detect complex circular dependencies" {
        $PipelineResources = @(
            [PSCustomObject]@{
                Type = "ResourceType1"
                Name = "ResourceName1"
                DependsOn = @("ResourceType2/ResourceName2")
            },
            [PSCustomObject]@{
                Type = "ResourceType2"
                Name = "ResourceName2"
                DependsOn = @(
                    "ResourceType3/ResourceName3"
                    "ResourceType4/ResourceName4"
                    "ResourceType5/ResourceName5"
                )
            },
            [PSCustomObject]@{
                Type = "ResourceType3"
                Name = "ResourceName3"
                DependsOn = @(
                    "ResourceType4/ResourceName4"
                    "ResourceType5/ResourceName5"
                )
            },
            [PSCustomObject]@{
                Type = "ResourceType4"
                Name = "ResourceName4"
                DependsOn = @(
                    "ResourceType5/ResourceName5"
                )
            },
            [PSCustomObject]@{
                Type = "ResourceType5"
                Name = "ResourceName5"
            }
        )

        $params = @{
            Resource = $PipelineResources[0]
            Visited = @()
            Stack = @()
        }

        { . $preParseFilePath -PipelineResources $PipelineResources } | Should -Throw "*Circular dependency detected with Resource*"

    }

}
