
Describe "Sort-DependsOn" -Tag Unit, Runner, Rules, Sort {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

    }

    It "should handle resources with no dependencies" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Task'; Name = 'Task1'; DependsOn = $null },
            [PSCustomObject]@{ Type = 'Task'; Name = 'Task2'; DependsOn = $null }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
        
        # Assert that the order remains unchanged since there are no dependencies
        $sortedResources.Count | Should -Be 2
        $sortedResources.Name | Sort-Object | Should -Be 'Task1', 'Task2'

    }

    It "should sort resources based on simple dependency" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task1') }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
        
        # Assert that Task1 comes before Task2
        $sortedResources[0].Name | Should -Be 'Task1'
        $sortedResources[1].Name | Should -Be 'Task2'
    }

    It "should handle complex single dependencies" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task2') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task4'; DependsOn = @('Module/Resource/Task3') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task5'; DependsOn = @('Module/Resource/Task4') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task6'; DependsOn = @('Module/Resource/Task5') }
        )
        
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources

        # Assert that Task1 comes before Task2 and Task2 comes before Task3
        $sortedResources[0].Name | Should -Be 'Task1'
        $sortedResources[1].Name | Should -Be 'Task2'
        $sortedResources[2].Name | Should -Be 'Task3'
        $sortedResources[3].Name | Should -Be 'Task4'
        $sortedResources[4].Name | Should -Be 'Task5'

    }

    It "should handle complex multiple dependencies arrays" {

        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task1', 'Module/Resource/Task2') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task4'; DependsOn = @('Module/Resource/Task1', 'Module/Resource/Task2', 'Module/Resource/Task3') }
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task5'; DependsOn = @('Module/Resource/Task1', 'Module/Resource/Task2', 'Module/Resource/Task3', 'Module/Resource/Task4') }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources

        # Assert that Task1 comes before Task2, Task2 comes before Task3, and Task3 comes before Task4
        $sortedResources[0].Name | Should -Be 'Task1'
        $sortedResources[1].Name | Should -Be 'Task2'
        $sortedResources[2].Name | Should -Be 'Task3'
        $sortedResources[3].Name | Should -Be 'Task4'
        $sortedResources[4].Name | Should -Be 'Task5'

    }

    It "should be able to format out of order dependencies" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task3') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
        
        # Assert that Task1 comes before Task3 and Task3 comes before Task2
        $sortedResources[0].Name | Should -Be 'Task1'
        $sortedResources[1].Name | Should -Be 'Task3'
        $sortedResources[2].Name | Should -Be 'Task2'
    }

    It "should add resources with multiple non-dependent resources to the top" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task3') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task4'; DependsOn = @() }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
        
        # Assert that Task1 and Task4 are at the top because they have no dependencies
        # We don't care about the order of Task1 and Task4 since they are not dependent on each other
        $sortedResources[0].Name | Should -match '(Task1|Task4)'
        $sortedResources[1].Name | Should -match '(Task1|Task4)'
        # Assert that Task3 comes before Task2, since Task2 depends on Task3
        $sortedResources[2].Name | Should -Be 'Task3'
        $sortedResources[3].Name | Should -Be 'Task2'
    
    }

    It "should add resources without DependsOn to the top" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task3') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
        
        # Assert that Task1 is at the top because it has no dependencies
        $sortedResources[0].Name | Should -Be 'Task1'
    }

    It "should throw an error if a resource depends on itself" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @('Module/Resource/Task1') }
        )
        
        { . $preParseFilePath -PipelineResources $resources } | Should -Throw
    }

    It "should handle multiple independent chains" {

        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task2') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task4'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task5'; DependsOn = @('Module/Resource/Task4') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task6'; DependsOn = @('Module/Resource/Task5') }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
            
        # Assert that Task1 comes before Task2 and Task2 comes before Task3
        $sortedResources[0].Name | Should -match '(Task1)|(Task4)'
        $sortedResources[1].Name | Should -match '(Task1)|(Task4)'

        # While the order will vary due to the multiple independent chains, ensure that the Tasks are in the correct order.

        # Ensure Task1 comes before Task2
        ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task1') | Should -BeLessThan ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task2')
        # Ensure Task2 comes before Task3
        ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task2') | Should -BeLessThan ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task3')
        # Ensure Task4 comes before Task5
        ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task4') | Should -BeLessThan ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task5')
        # Ensure Task5 comes before Task6
        ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task5') | Should -BeLessThan ($sortedResources | Select-Object -ExpandProperty Name).IndexOf('Task6')

    }

    It "should add the resource to the top if it depends on a resource that doesn't exist" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task3') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @('Module/Resource/Task1') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources
        
        # Assert that Task1 is at the top because it has no dependencies
        $sortedResources[0].Name | Should -Be 'Task1'
    }

    It "should add a resource to the end of the list if it has no dependencies" {

        Mock -CommandName Write-Verbose

        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task3') }
        )
        
        $sortedResources = . $preParseFilePath -PipelineResources $resources -Verbose
        
        # Assert that Task2 and Task3 are at the bottom because they have dependencies
        $sortedResources.Name | Should -Be 'Task2'
        Assert-MockCalled -CommandName Write-Verbose -ParameterFilter { $Message -like '*Adding resource to the end of the list*' }
    }

}
