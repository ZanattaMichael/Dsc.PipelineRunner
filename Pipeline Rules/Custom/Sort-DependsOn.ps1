<#
.SYNOPSIS
Sorts pipeline resources based on their DependsOn property.

.DESCRIPTION
This script takes an array of pipeline resources and sorts them into an ordered list based on their DependsOn property. 
Resources without a DependsOn property are added to the top of the list, while resources with a DependsOn property are 
inserted in the correct order to ensure that dependencies are resolved.

.PARAMETER PipelineResources
An array of pipeline resources to be sorted. Each resource is expected to have a Type, Name, and optionally a DependsOn property.

.OUTPUTS
[System.Collections.ArrayList]
Returns an ArrayList of pipeline resources sorted based on their DependsOn property.

.EXAMPLE
$resources = @(
    [PSCustomObject]@{ Type = 'Task'; Name = 'Task1'; DependsOn = @() },
    [PSCustomObject]@{ Type = 'Task'; Name = 'Task2'; DependsOn = @('Task/Task1') }
)
$sortedResources = .\Sort-DependsOn.ps1 -PipelineResources $resources
Write-Output $sortedResources

.NOTES

#>
[CmdletBinding()]
[OutputType([System.Collections.ArrayList])]
param(
    [Object[]]$PipelineResources
)

#
# Order the Tasks according to DependsOn Property

Write-Verbose "[Sort-DependsOn] Separating resources with and without DependsOn property"
$ResourcesWithoutDependsOn, $ResourcesWithDependsOn = $PipelineResources.Where({ ($null -eq $_.DependsOn) -or ($_.DependsOn.Count -eq 0) }, 'Split')

#
# Format the DependsOn Property by ensuring the Resource parent is before the child.

Write-Verbose "[Sort-DependsOn] Initializing task list as an ArrayList"
$TaskList = [System.Collections.ArrayList]::New()

#
# Enumerate the Resources with DependsOn Property

ForEach ($ResourceObject in $ResourcesWithDependsOn) {

    Write-Verbose "[Sort-DependsOn] Processing resource: [$($ResourceObject.Type)/$($ResourceObject.Name)]"

    # Get the DependsOn Property and format it into a hashtable.
    [Array]$DependsOn = $ResourceObject.DependsOn | ForEach-Object {
        $split = $_.Split("/")
        @{
            Type = "{0}/{1}" -f $split[0], $split[1]
            Name = $split[2..$split.length] -join "/"
        }
    }

    #
    # Test to see if the Resource DependsOn is the current Resource. If so, throw an error.

    foreach ($dependency in $DependsOn) {
        if (($dependency.Name -eq $ResourceObject.Name) -and ($dependency.Type -eq $ResourceObject.Type)) {
            throw "Resource [$($ResourceObject.Type)/$($ResourceObject.Name)] DependsOn Resource cannot be the same Resource."
        }
    }

    #
    # Determine if the Resource exists within ResourcesWithoutDependsOn

    [Array]$ResourceWithoutDependsOnTopIndex = $ResourcesWithoutDependsOn | ForEach-Object {
        $ht = $_
        # Locate the index position of the Resource within DependsOn. 
        0 .. ($DependsOn.Count - 1) | Where-Object {
            ($ht.Type -eq $DependsOn[$_].Type) -and
            ($ht.Name -eq $DependsOn[$_].Name)
        }
    }
    
    $ResourceWithDependsOnTopIndex = 0 .. ($TaskList.Count - 1) | ForEach-Object {

        $ht = $TaskList[$_]
        $count = $_

        $foundInTaskList = 0 .. ($DependsOn.Count - 1) | Where-Object {
            ($ht.Type -eq $DependsOn[$_].Type) -and
            ($ht.Name -eq $DependsOn[$_].Name)
        }
        if ($foundInTaskList.Count -gt 0) { $count }
    } | Sort-Object -Descending | Select-Object -First 1

    # If the ResourceWithDependsOnTopIndex is not null, calculate the index position to insert the Resource.
    if ($null -ne $ResourceWithDependsOnTopIndex) {
        $insertIndexPosition = ([int]$ResourceWithDependsOnTopIndex) + 1
    } else {
        $insertIndexPosition = 0
    }

    # If $ResourceWithDependsOnTopIndex is not null and $ResourceWithoutDependsOnTopIndex is null add to the top of the list.
    if (($ResourceWithDependsOnTopIndex.Count -ne 0) -and ($ResourceWithoutDependsOnTopIndex.count -eq 0)) {
        Write-Verbose "[Sort-DependsOn] Adding resource to the top of the list: [$($ResourceObject.Type)/$($ResourceObject.Name)]"
        $null = $TaskList.Insert($insertIndexPosition, $ResourceObject)
        continue
    }
    # If $ResourceWithDependsOnTopIndex is null and $ResourceWithoutDependsOnTopIndex is not null, insert it after the Resource.
    if (($ResourceWithDependsOnTopIndex.Count -eq 0) -and ($ResourceWithoutDependsOnTopIndex.Count -ne 0)) {
        #Wait-Debugger

        $TaskList.Insert(0, $ResourceObject)
        continue

    }
    # If both $ResourceWithDependsOnTopIndex and $ResourceWithoutDependsOnTopIndex are null, add to the end of the list.
    if (($ResourceWithDependsOnTopIndex.Count -eq 0) -and ($ResourceWithoutDependsOnTopIndex.count -eq 0)) {
        Write-Verbose "[Sort-DependsOn] Adding resource to the end of the list: [$($ResourceObject.Type)/$($ResourceObject.Name)]"
        $null = $TaskList.Add($ResourceObject)
        continue
    }
    # If both $ResourceWithDependsOnTopIndex and $ResourceWithoutDependsOnTopIndex are not null, insert it after the ResourceWithDependsOnTopIndex.
    if (($ResourceWithDependsOnTopIndex.Count -ne 0) -and ($ResourceWithoutDependsOnTopIndex.Count -ne 0)) {
        # If insertIndexPosition is greater than the count of the TaskList, add to the end of the list.
        if ($insertIndexPosition -gt $TaskList.Count) {
            Write-Verbose "[Sort-DependsOn] Adding resource to the end of the list: [$($ResourceObject.Type)/$($ResourceObject.Name)]"
            $null = $TaskList.Add($ResourceObject)
        } else {
            Write-Verbose "[Sort-DependsOn] Inserting resource before calculated index position: $insertIndexPosition"
            $null = $TaskList.Insert($insertIndexPosition, $ResourceObject)
        }
        
        continue

    }

}

#
# Add ResourcesWithoutDependsOn to the top of the task list.
Write-Verbose "[Sort-DependsOn] Adding resources without DependsOn to the top of the task list"
$ResourcesWithoutDependsOn | ForEach-Object {
    $null = $TaskList.Insert(0, $_)
}

$TaskList
