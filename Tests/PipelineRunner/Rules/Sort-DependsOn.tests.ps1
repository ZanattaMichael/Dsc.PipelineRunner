
Describe "Sort-DependsOn" -Tag Unit, Runner, Rules, Sort {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

    }

    It "should return nothing when no resources are supplied" {
        $sortedResources = . $preParseFilePath -PipelineResources @()
        $sortedResources | Should -BeNullOrEmpty
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

    It "should order a diamond dependency so each resource follows all of its dependencies" {
        # A is the root; B and C depend on A; D depends on both B and C.
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'D'; DependsOn = @('Module/Resource/B', 'Module/Resource/C') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'B'; DependsOn = @('Module/Resource/A') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'C'; DependsOn = @('Module/Resource/A') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'A'; DependsOn = @() }
        )

        $names = (. $preParseFilePath -PipelineResources $resources | Select-Object -ExpandProperty Name)

        $names[0] | Should -Be 'A'
        $names[-1] | Should -Be 'D'
        $names.IndexOf('A') | Should -BeLessThan $names.IndexOf('B')
        $names.IndexOf('A') | Should -BeLessThan $names.IndexOf('C')
        $names.IndexOf('B') | Should -BeLessThan $names.IndexOf('D')
        $names.IndexOf('C') | Should -BeLessThan $names.IndexOf('D')
    }

    It "should order a wide fan-in so the sink follows every root" {
        # Five independent roots that a single sink depends on.
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Sink'; DependsOn = @(
                'Module/Resource/R1', 'Module/Resource/R2', 'Module/Resource/R3', 'Module/Resource/R4', 'Module/Resource/R5') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'R1'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'R2'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'R3'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'R4'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'R5'; DependsOn = @() }
        )

        $names = (. $preParseFilePath -PipelineResources $resources | Select-Object -ExpandProperty Name)

        # The sink is applied last; every root precedes it.
        $names[-1] | Should -Be 'Sink'
        foreach ($root in 'R1', 'R2', 'R3', 'R4', 'R5') {
            $names.IndexOf($root) | Should -BeLessThan $names.IndexOf('Sink')
        }
    }

    It "should throw a terminating error naming the resources in a cycle" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'A'; DependsOn = @('Module/Resource/B') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'B'; DependsOn = @('Module/Resource/C') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'C'; DependsOn = @('Module/Resource/A') }
        )

        $err = { . $preParseFilePath -PipelineResources $resources } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'Circular dependency'
        $err.Exception.Message | Should -Match 'Module/Resource/A'
        $err.Exception.Message | Should -Match 'Module/Resource/B'
        $err.Exception.Message | Should -Match 'Module/Resource/C'
    }

    It "should throw when a resource depends on a resource that is not present in the configuration" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task3') }
        )

        { . $preParseFilePath -PipelineResources $resources } | Should -Throw -ExpectedMessage '*not present in the configuration*'
    }

    It "should sort 500 resources with random dependencies in under a second" {
        # Build a guaranteed-acyclic graph: resource i may depend on any earlier resource,
        # so the edges always point backwards and no cycle can form.
        $resources = 1..500 | ForEach-Object {
            $i = $_
            $dependsOn = @()
            if ($i -gt 1) {
                $dependsOn = @("Module/Resource/Task$([int](Get-Random -Minimum 1 -Maximum $i))")
            }
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = "Task$i"; DependsOn = $dependsOn }
        }

        $elapsed = Measure-Command {
            $script:sorted500 = . $preParseFilePath -PipelineResources $resources
        }

        $script:sorted500.Count | Should -Be 500
        $elapsed.TotalSeconds | Should -BeLessThan 1
    }

}
