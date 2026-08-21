Describe "Azure DevOps environment lifecycle (DSC v2 and DSC v3 engines)" -Tag Integration {

    # This suite proves the runner can stand up ("build") and tear down a complete Azure DevOps
    # environment end-to-end, through BOTH execution engines the module ships:
    #
    #   * DscV2 -> Actions/Engine/DscV2.ps1  -> Invoke-DscResource   (Windows / PowerShell DSC)
    #   * DscV3 -> Actions/Engine/DscV3.ps1  -> Invoke-DscExecutable (dsc / dsc.exe, cross-platform)
    #
    # It drives the REAL runner and the REAL engine action files: Start-DscRunner is called with
    # -Engine 'DscV2' / -Engine 'DscV3' (no inline -EngineAction), so Invoke-EngineAction ->
    # Invoke-Action resolves and executes the genuine Actions/Engine/<Engine>.ps1 from the module
    # base. Get-Module is the only thing mocked there, pointing the loader at the repository root so
    # the real engine files are found on a CI runner with no installed module.
    #
    # Because real Azure DevOps (and a real dsc.exe / AzureDevOpsDsc provider) cannot run on a
    # hosted CI agent, the platform underneath each engine is replaced by an in-memory FAKE Azure
    # DevOps organization: a shared hashtable keyed by DSC resource type, holding which resources
    # currently "exist". The two provider seams are mocked to read and mutate that org:
    #
    #   * DscV2: Invoke-DscResource   is the stateful provider (Test reads existence, Set creates
    #            or removes, Get returns current Ensure).
    #   * DscV3: Invoke-DscExecutable returns DSC v3 JSON result shapes ({"inDesiredState":...},
    #            {"changedProperties":...}) and mutates the same org, so the real DscV3.ps1 mapping
    #            (verb selection, --input JSON, exit-code handling, JSON parsing) is exercised.
    #
    # Everything else is real: dependency ordering (Sort-DependsOn), parameter/variable seeding and
    # expansion, the engine seam and its [DscMethodResult] contract, Test-vs-Set drift handling, and
    # the structured run summary. The fake org therefore lets a single set of configurations model a
    # true lifecycle: a Present configuration in Set mode CREATES the project, group, repository and
    # permissions in dependency order (build), and an Absent configuration in Set mode REMOVES them
    # (teardown).

    BeforeAll {

        # --- Load the real dependency graph (class first, then the runner chain and engine seam) --
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName

        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName

        # Dot-sourced so Pester has real commands to Mock; the mocks below replace their bodies.
        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Module-script-scope state the runner reads/mutates (mirrors source/prefix.ps1).
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $script:SortDependsOnPath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

        # Point the engine-file loader (Invoke-Action's Get-Module 'Dsc.PipelineRunner') at the
        # repository root so it resolves the real Actions/Engine/DscV2.ps1 and DscV3.ps1.
        Mock -CommandName Get-Module -MockWith { return @{ ModuleBase = $Global:RepositoryRoot } }

        # Keep the runner's log off the test output; all real logic stays intact.
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        # Loader stand-ins (see the runner integration suite for the rationale). Invoke-CustomTask
        # runs the REAL Sort-DependsOn so dependency ordering is genuinely exercised.
        Mock -CommandName Invoke-CustomTask -MockWith {
            param(
                [Parameter(Mandatory = $true)] [Object[]]$Tasks,
                [Parameter(Mandatory = $true)] [String]$CustomTaskName
            )
            if ($CustomTaskName -eq 'Sort-DependsOn') {
                return (& $script:SortDependsOnPath -PipelineResources $Tasks)
            }
            return $Tasks
        }
        Mock -CommandName Invoke-PreParseRules  -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) }
        Mock -CommandName Invoke-FormatTasks    -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) return $Tasks }

        # --- The in-memory fake Azure DevOps organization ------------------------------------------
        # $Global: state so the provider mocks can write to it across the '&'-invoked engine-file
        # scope boundary (Assert-MockCalled cannot attribute those calls, but the mock body runs and
        # a $Global list/hashtable is writable from any session state — the same technique the engine
        # unit suites use). Keyed by DSC resource type ('Owner/Resource'); a present key means the
        # resource currently exists in the org.
        $Global:AdoOrg   = @{}
        $Global:AdoCalls = [System.Collections.Generic.List[object]]::new()

        # DSC v2 provider. The real Actions/Engine/DscV2.ps1 calls this; it reflects and mutates the
        # fake org. Absent desired-state inverts the Test result and makes Set a delete.
        Mock -CommandName Invoke-DscResource -MockWith {
            param($Name, $ModuleName, $Method, $Property)

            $type    = '{0}/{1}' -f $ModuleName, $Name
            $desired = if ($Property -is [System.Collections.IDictionary] -and $Property.Contains('Ensure')) { [string]$Property['Ensure'] } else { 'Present' }
            $exists  = $Global:AdoOrg.ContainsKey($type)
            $Global:AdoCalls.Add([pscustomobject]@{ Engine = 'DscV2'; Method = $Method; Type = $type })

            switch ($Method) {
                'Test' {
                    $inDesired = if ($desired -eq 'Absent') { -not $exists } else { $exists }
                    return [pscustomobject]@{ InDesiredState = [bool]$inDesired }
                }
                'Set' {
                    if ($desired -eq 'Absent') { [void]$Global:AdoOrg.Remove($type) } else { $Global:AdoOrg[$type] = @{ Ensure = 'Present' } }
                    return [pscustomobject]@{ RebootRequired = $false }
                }
                'Get' {
                    $cur = if ($Global:AdoOrg.ContainsKey($type)) { 'Present' } else { 'Absent' }
                    return [pscustomobject]@{ Ensure = $cur }
                }
            }
        }

        # DSC v3 provider. The real Actions/Engine/DscV3.ps1 calls this with the argument vector
        # @('resource', <verb>, '--resource', <type>, '--input', <json>). It returns DSC v3 JSON
        # result shapes and mutates the same org, so the engine's real verb mapping, --input
        # serialization, exit-code check and JSON parsing all run.
        Mock -CommandName Invoke-DscExecutable -MockWith {
            param($Arguments, $Executable)

            $verb      = $Arguments[1]
            $type      = $Arguments[3]
            $inputJson = $Arguments[5]
            $inputHash = $inputJson | ConvertFrom-Json -AsHashtable
            $desired   = if ($inputHash -is [System.Collections.IDictionary] -and $inputHash.Contains('Ensure')) { [string]$inputHash['Ensure'] } else { 'Present' }
            $exists    = $Global:AdoOrg.ContainsKey($type)
            $Global:AdoCalls.Add([pscustomobject]@{ Engine = 'DscV3'; Method = $verb; Type = $type })

            switch ($verb) {
                'test' {
                    $inDesired = if ($desired -eq 'Absent') { -not $exists } else { $exists }
                    $out = if ($inDesired) { '{"inDesiredState":true}' } else { '{"inDesiredState":false,"differingProperties":["Ensure"]}' }
                    return @{ ExitCode = 0; Output = $out }
                }
                'set' {
                    if ($desired -eq 'Absent') { [void]$Global:AdoOrg.Remove($type) } else { $Global:AdoOrg[$type] = @{ Ensure = 'Present' } }
                    return @{ ExitCode = 0; Output = '{"changedProperties":["Ensure"]}' }
                }
                'get' {
                    $cur = if ($Global:AdoOrg.ContainsKey($type)) { 'Present' } else { 'Absent' }
                    return @{ ExitCode = 0; Output = ('{{"actualState":{{"Ensure":"{0}"}}}}' -f $cur) }
                }
            }
        }

        # Writes a config to $TestDrive and returns its path.
        function New-ConfigFile {
            param([string]$Name, [string]$Json)
            $path = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
            return $path
        }

        # The desired Azure DevOps environment. A project, a group and a repository that both depend
        # on the project, and repository permissions that depend on the repository and the group.
        # A DependsOn entry names a resource by its full "Type/Name" identity (what Sort-DependsOn
        # keys on), e.g. the project (type "AzureDevOpsDsc/AzDoProject", name "DscProject") is
        # "AzureDevOpsDsc/AzDoProject/DscProject". ProjectName/Organization use $variable/$parameter
        # expansion so the real Expand-HashTable is exercised on the way to the engine.
        $script:PresentConfigPath = New-ConfigFile -Name 'ado-present.json' -Json @'
{
  "parameters": { "organizationName": { "defaultValue": "Contoso" } },
  "variables": { "projectName": "DscPipelineProject" },
  "resources": [
    { "type": "AzureDevOpsDsc/AzDoGitPermission", "name": "AppRepoPermissions",
      "dependsOn": [ "AzureDevOpsDsc/AzDoGitRepository/AppRepo", "AzureDevOpsDsc/AzDoProjectGroup/Contributors" ],
      "properties": { "Ensure": "Present", "RepositoryName": "app-repo" } },
    { "type": "AzureDevOpsDsc/AzDoProject", "name": "DscProject",
      "properties": { "Ensure": "Present", "ProjectName": "$projectName", "Organization": "$organizationName" } },
    { "type": "AzureDevOpsDsc/AzDoGitRepository", "name": "AppRepo",
      "dependsOn": [ "AzureDevOpsDsc/AzDoProject/DscProject" ],
      "properties": { "Ensure": "Present", "RepositoryName": "app-repo" } },
    { "type": "AzureDevOpsDsc/AzDoProjectGroup", "name": "Contributors",
      "dependsOn": [ "AzureDevOpsDsc/AzDoProject/DscProject" ],
      "properties": { "Ensure": "Present", "GroupName": "Contributors" } }
  ]
}
'@

        # The teardown configuration: the same resources, declared Absent so Set removes them.
        $script:AbsentConfigPath = New-ConfigFile -Name 'ado-absent.json' -Json @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "AzureDevOpsDsc/AzDoGitPermission", "name": "AppRepoPermissions",
      "dependsOn": [ "AzureDevOpsDsc/AzDoGitRepository/AppRepo", "AzureDevOpsDsc/AzDoProjectGroup/Contributors" ],
      "properties": { "Ensure": "Absent", "RepositoryName": "app-repo" } },
    { "type": "AzureDevOpsDsc/AzDoProject", "name": "DscProject",
      "properties": { "Ensure": "Absent", "ProjectName": "DscPipelineProject" } },
    { "type": "AzureDevOpsDsc/AzDoGitRepository", "name": "AppRepo",
      "dependsOn": [ "AzureDevOpsDsc/AzDoProject/DscProject" ],
      "properties": { "Ensure": "Absent", "RepositoryName": "app-repo" } },
    { "type": "AzureDevOpsDsc/AzDoProjectGroup", "name": "Contributors",
      "dependsOn": [ "AzureDevOpsDsc/AzDoProject/DscProject" ],
      "properties": { "Ensure": "Absent", "GroupName": "Contributors" } }
  ]
}
'@

        # The four resource types this environment is made of, and the order Sort-DependsOn must
        # produce: the project has no dependency, the group and repository depend on the project,
        # and the permissions depend on the repository and the group.
        $script:ProjectType    = 'AzureDevOpsDsc/AzDoProject'
        $script:GroupType       = 'AzureDevOpsDsc/AzDoProjectGroup'
        $script:RepositoryType  = 'AzureDevOpsDsc/AzDoGitRepository'
        $script:PermissionType  = 'AzureDevOpsDsc/AzDoGitPermission'
        $script:AllTypes        = @($script:ProjectType, $script:GroupType, $script:RepositoryType, $script:PermissionType)
    }

    AfterAll {
        Remove-Variable -Name AdoOrg   -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name AdoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        # A fresh, empty organization and a clean call log before every scenario.
        $Global:AdoOrg = @{}
        $Global:AdoCalls.Clear()
        $script:StopTaskProcessing = $false
    }

    Context "<engine> engine" -ForEach @(
        @{ engine = 'DscV2' }
        @{ engine = 'DscV3' }
    ) {

        It "builds the Azure DevOps environment: Set creates every resource in dependency order" {

            $build = Start-DscRunner -FilePath $script:PresentConfigPath -Mode 'Set' -Engine $engine

            # Every resource reconciled cleanly and the whole environment now exists.
            $build.Status         | Should -Be 'Completed'
            $build.TotalResources | Should -Be 4
            $build.PassCount      | Should -Be 4
            $build.FailCount      | Should -Be 0
            $Global:AdoOrg.Count  | Should -Be 4
            foreach ($type in $script:AllTypes) { $Global:AdoOrg.ContainsKey($type) | Should -BeTrue }

            # Dependency order: the project is created before the group/repository, and the
            # permissions (which depend on both) are created last.
            $testOrder = @($Global:AdoCalls | Where-Object { $_.Method -in 'Test', 'test' } | ForEach-Object { $_.Type })
            $testOrder[0]  | Should -Be $script:ProjectType
            $testOrder[-1] | Should -Be $script:PermissionType
            $testOrder.IndexOf($script:RepositoryType) | Should -BeGreaterThan $testOrder.IndexOf($script:ProjectType)
            $testOrder.IndexOf($script:GroupType)      | Should -BeGreaterThan $testOrder.IndexOf($script:ProjectType)
            $testOrder.IndexOf($script:PermissionType) | Should -BeGreaterThan $testOrder.IndexOf($script:RepositoryType)
            $testOrder.IndexOf($script:PermissionType) | Should -BeGreaterThan $testOrder.IndexOf($script:GroupType)

            # Remediation genuinely ran through the engine: a Set for each of the four resources.
            @($Global:AdoCalls | Where-Object { $_.Method -in 'Set', 'set' }).Count | Should -Be 4
        }

        It "tears the environment down: Set removes every resource declared Absent" {

            # Start from a fully built environment.
            foreach ($type in $script:AllTypes) { $Global:AdoOrg[$type] = @{ Ensure = 'Present' } }
            $Global:AdoOrg.Count | Should -Be 4

            $teardown = Start-DscRunner -FilePath $script:AbsentConfigPath -Mode 'Set' -Engine $engine

            $teardown.Status    | Should -Be 'Completed'
            $teardown.PassCount | Should -Be 4
            $teardown.FailCount | Should -Be 0

            # Nothing remains, and a Set (delete) was issued for each resource.
            $Global:AdoOrg.Count | Should -Be 0
            @($Global:AdoCalls | Where-Object { $_.Method -in 'Set', 'set' }).Count | Should -Be 4
        }

        It "completes a full build-then-teardown cycle, leaving the organization empty" {

            $build = Start-DscRunner -FilePath $script:PresentConfigPath -Mode 'Set' -Engine $engine
            $build.PassCount     | Should -Be 4
            $Global:AdoOrg.Count | Should -Be 4

            $teardown = Start-DscRunner -FilePath $script:AbsentConfigPath -Mode 'Set' -Engine $engine
            $teardown.PassCount  | Should -Be 4
            $Global:AdoOrg.Count | Should -Be 0
        }

        It "reports drift as failures in Test mode without provisioning anything" {

            # Test mode over an empty org: every Present resource is absent, so each is drift, and
            # the runner must NOT call Set (no resource is created).
            $test = Start-DscRunner -FilePath $script:PresentConfigPath -Mode 'Test' -Engine $engine

            $test.Status    | Should -Be 'Completed'
            $test.PassCount | Should -Be 0
            $test.FailCount | Should -Be 4

            $Global:AdoOrg.Count | Should -Be 0
            @($Global:AdoCalls | Where-Object { $_.Method -in 'Set', 'set' }).Count | Should -Be 0
        }
    }
}
