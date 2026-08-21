Describe "Test-ResourcesForIncorrectProperties" -Tag Unit, Runner, Rules, PreParse {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Test-ResourcesForIncorrectProperties.ps1').FullName
        . $preParseFilePath

        # #34: the rule routes its (verbose) value breadcrumb through the redaction helper.
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName

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

        Mock -CommandName Write-Host

    } 

    It "Should throw error if 'properties' key does not exist" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
            }
        )
        
        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*'Properties' key does not exist for resource:*" }

    }

    It "Should throw error if 'name' key does not exist" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                properties = @{
                    Property1 = 'Value1'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*'Name' key does not exist for resource:*" }
    }

    It "Should pass if all required keys exist and properties are correct" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = 'Value1'
                    Property2 = 'Value2'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources -Verbose } | Should -Not -Throw
    }

    It "Should throw error if resource is not found" {
        Mock -CommandName Get-DscResource -MockWith { $null }

        $resources = @(
            [PSCustomObject]@{
                type = 'Module/NonExistentResourceType'
                name = 'NonExistentResource'
                properties = @{
                    Property1 = 'Value1'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*Resource * was not found in module*" }

    }

    It "Should throw error if mandatory property is null" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = $null
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*is mandatory in resource*" }

    }

    It "Should throw error if property value does not match selected values" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = 'InvalidValue'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*does not match the selected values in resource*" }
    }

    It "Should throw error if property value is not of correct type" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = 123
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*does not match the selected values in resource*" }
    }

    It "Should not skip the property if it's a scriptblock" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = 'Value1'
                    Property2 = '{scriptblock}'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Not -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*is a caculated variable in resource*" } -Exactly 0

    }

    It "Should skip the property if it's a caculated property" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = 'Value1'
                    Property2 = '$($mock_variable)'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Not -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*is a caculated variable in resource*" }

    }

    It "Should skip both caculated properties" {
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{
                    Property1 = '$($mock_variable)'
                    Property2 = '$($mock_variable)'
                }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Not -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*is a caculated variable in resource*" } -Exactly 2

    }

    It "Should not print the offending property value in any output stream (#34)" {
        # A resource whose secret-bearing property carries a value outside the permitted set.
        Mock -CommandName Get-DscResource -MockWith {
            @{
                Name = 'MyResourceType'
                Properties = @(
                    [PSCustomObject]@{ Name = 'Password'; PropertyType = 'String'; IsMandatory = $false; Values = @('Vaulted') }
                )
            }
        }

        $secret = 'S3cr3t-Do-Not-Log'
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'MyResource'
                properties = @{ Password = $secret }
            }
        )

        $verboseMessages = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Verbose -MockWith { $verboseMessages.Add($Message) }

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw

        # The value must never reach the (default) Write-Host stream...
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*$secret*" } -Exactly 0
        # ...and the redacted verbose breadcrumb must mask a sensitively-named property too.
        ($verboseMessages -join "`n") | Should -Not -Match ([regex]::Escape($secret))
        # The diagnostic still names the property and resource.
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*does not match the selected values in resource*" }
    }

    It "Should report every invalid resource, not just the first" {
        # Three resources, each with a property the resource does not declare.
        # All three must be reported before the run stops (regression for #8).
        $resources = @(
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'ResourceA'
                properties = @{ Property1 = 'Value1'; InvalidProp = 'x' }
            }
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'ResourceB'
                properties = @{ Property1 = 'Value1'; InvalidProp = 'y' }
            }
            [PSCustomObject]@{
                type = 'Module/MyResourceType'
                name = 'ResourceC'
                properties = @{ Property1 = 'Value1'; InvalidProp = 'z' }
            }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Message -like "*does not exist in resource*" } -Exactly 3
    }

}
