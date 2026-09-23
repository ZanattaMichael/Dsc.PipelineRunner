Describe "Composite resources through a real Datum compile and a real runner pass" -Tag Integration, HostedIntegration {

    # Expand-CompositeResource.tests.ps1 covers the expansion rules against hand-built
    # dictionaries, and Resolve-DscDatumProject.tests.ps1 covers the wiring with Resolve-Datum
    # mocked. Neither proves the part that decides whether the feature works at all: that a real
    # Datum tree exposes Composites/<Name>.yml as $Datum.Composites, that an instance survives
    # Datum's UniqueKeyValTuples merge (and is overridden by name like any other resource), that
    # the expanded file round-trips through powershell-yaml, and that the runner then orders and
    # evaluates the members exactly like hand-written resources.
    #
    # So this suite writes a small configuration to TestDrive, compiles it with the genuine
    # New-DatumStructure + Resolve-DscDatumProject (the functions DatumConfigurationScriptBlock
    # runs in production), and runs Start-DscRunner over the result with the REAL
    # Expand-NotifyDependsOn and Sort-DependsOn rules and an inline engine that records what it
    # was asked to evaluate. Nothing needs Windows, Azure DevOps or dsc.exe.

    BeforeAll {

        # Hard imports, as in the other compile suites: a missing compile stack must fail loudly.
        # The hosted integration workflow installs these.
        foreach ($module in 'powershell-yaml', 'datum', 'datum.invokecommand') {
            Import-Module -Name $module -ErrorAction Stop
        }

        . (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName

        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName

        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        . (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        . (Get-FunctionPath 'Resolve-PipelineParameter.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName
        . (Get-FunctionPath 'variables.ps1').FullName
        . (Get-FunctionPath 'equals.ps1').FullName

        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Module-script-scope state the runner reads and mutates (mirrors source/prefix.ps1).
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $script:SortDependsOnPath     = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName
        $script:ExpandNotifyPath      = (Get-FunctionPath 'Expand-NotifyDependsOn.ps1').FullName
        $script:CompositeRulePath     = (Get-FunctionPath 'Test-CompositeResourcesExpanded.ps1').FullName

        # Writes a configuration tree: a map of relative path -> file content.
        function New-ConfigurationTree {
            param([string]$Root, [hashtable]$Files)
            foreach ($relativePath in $Files.Keys) {
                $path = Join-Path $Root $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $Files[$relativePath] -Encoding UTF8
            }
        }

        # Compiles every node under Projects/ exactly as DatumConfigurationScriptBlock does, with
        # $Datum, $ProjectType and $OutputPath in scope for Resolve-DscDatumProject. Returns the
        # Datum structure so a test can also inspect it.
        function Invoke-CompositeCompile {
            param([string]$ConfigurationRoot, [string]$OutputDirectory)
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
            $OutputPath = $OutputDirectory
            Push-Location -LiteralPath $ConfigurationRoot
            try {
                $Datum = New-DatumStructure -DefinitionFile 'Datum.yml'
                foreach ($ProjectType in $Datum.Projects.psobject.properties) {
                    foreach ($ProjectNode in $Datum.Projects."$($ProjectType.name)".psobject.properties) {
                        Resolve-DscDatumProject -NodeName $ProjectNode -AllNodes $Datum.Projects."$($ProjectType.name)"."$($ProjectNode.Name)"
                    }
                }
                return $Datum
            }
            finally {
                Pop-Location
            }
        }

        # Datum splits ResolutionPrecedence entries on the platform's directory separator.
        $separator = [System.IO.Path]::DirectorySeparatorChar

        $script:DatumYaml = @"
ResolutionPrecedence:
  - Projects$separator`$(`$Node.ProjectPresence)$separator`$(`$Node.Project)
  - Baseline${separator}Common

default_lookup_options: MostSpecific

PipelineRunnerSettings:
  ConfigurationVersion: 0.5
  PipelineRunnerVersion: 1.1.0

DatumHandlers:
  Datum.InvokeCommand::InvokeCommand:
    SkipDuringLoad: true

lookup_options:
  variables:
    merge_hash_array: deep
  resources:
    merge_hash_array: UniqueKeyValTuples
    merge_options:
      tuple_keys:
        - name
"@

        $script:StandardProjectYaml = @'
parameters:
  ProjectName:
    description: The project the group of resources is for.
  Visibility:
    defaultValue: private
resources:
  - name: Project
    type: Stub/Project
    properties:
      ProjectName: <composite=ProjectName>
      Visibility: <composite=Visibility>
  - name: Readers
    type: Stub/Group
    dependsOn:
      - Stub/Project/Project
    properties:
      ProjectName: <composite=ProjectName>
      GroupName: <composite=ProjectName> Readers
  - name: Repos
    type: Composite/RepoSet
    dependsOn:
      - Stub/Project/Project
    properties:
      Prefix: <composite=ProjectName>
'@

        $script:RepoSetYaml = @'
parameters:
  Prefix:
resources:
  - name: Main
    type: Stub/Repo
    properties:
      RepositoryName: <composite=Prefix>-main
  - name: Docs
    type: Stub/Repo
    dependsOn:
      - Stub/Repo/Main
    properties:
      RepositoryName: <composite=Prefix>-docs
'@

        $script:ConfigurationRoot = Join-Path $TestDrive 'config'
        $script:CompiledDirectory = Join-Path $TestDrive 'compiled'

        New-ConfigurationTree -Root $script:ConfigurationRoot -Files @{
            'Datum.yml'                         = $script:DatumYaml
            'Composites/StandardProject.yml'    = $script:StandardProjectYaml
            'Composites/RepoSet.yml'            = $script:RepoSetYaml
            # A sub-folder is not a definition: it must be ignored, not break the compile.
            'Composites/Drafts/Unused.yml'      = "resources: []"
            'Baseline/Common.yml'               = @'
variables:
  Environment: Prod
resources:
  - name: Org
    type: Stub/Org
    properties:
      Name: Contoso
  - name: Shared
    type: Composite/StandardProject
    dependsOn:
      - Stub/Org/Org
    properties:
      ProjectName: Shared
  - name: Audit
    type: Stub/Audit
    dependsOn:
      - Composite/StandardProject/Shared
    properties: {}
'@
            'Projects/Present/Magenta.yml'      = @'
resources:
  # Overrides the baseline's 'Shared' instance by name, exactly like any other resource.
  - name: Shared
    type: Composite/StandardProject
    dependsOn:
      - Stub/Org/Org
    properties:
      ProjectName: Shared-Magenta
      Visibility: public
  - name: Magenta
    type: Composite/StandardProject
    preCondition: equals (variables 'Environment') 'Prod'
    properties:
      ProjectName: Magenta
    overrides:
      Readers:
        properties:
          GroupName: Magenta Viewers
'@
        }

        $script:Datum = Invoke-CompositeCompile -ConfigurationRoot $script:ConfigurationRoot -OutputDirectory $script:CompiledDirectory -WarningAction SilentlyContinue
        $script:MagentaPath = Join-Path $script:CompiledDirectory 'Magenta.yml'
        $script:Compiled = Get-Content -LiteralPath $script:MagentaPath -Raw | ConvertFrom-Yaml

        function Get-CompiledResource {
            param([string]$Name)
            return $script:Compiled.resources | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        }

        # --- Runner stand-ins (installed after the compile, so Datum's own calls are untouched) ---
        Mock -CommandName Get-Module -ParameterFilter { $Name -eq 'Dsc.PipelineRunner' } -MockWith {
            return @{ ModuleBase = $Global:RepositoryRoot }
        }
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        # The REAL ordering rules, so composite members are sorted like any other resource.
        Mock -CommandName Invoke-CustomTask -MockWith {
            param(
                [Parameter(Mandatory = $true)] [Object[]]$Tasks,
                [Parameter(Mandatory = $true)] [String]$CustomTaskName
            )
            switch ($CustomTaskName) {
                'Expand-NotifyDependsOn' { return (& $script:ExpandNotifyPath -PipelineResources $Tasks) }
                'Sort-DependsOn'         { return (& $script:SortDependsOnPath -PipelineResources $Tasks) }
                default                  { return $Tasks }
            }
        }

        # Of the PreParse rules only the composite guard is run for real: the others call
        # Get-DscResource for resource types that do not exist here.
        Mock -CommandName Invoke-PreParseRules -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks, [hashtable]$Settings)
            . $script:CompositeRulePath -PipelineResources $Tasks
        }

        Mock -CommandName Invoke-FormatTasks -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks)
            return $Tasks
        }

        function New-RecordingEngine {
            param([System.Collections.Generic.List[object]]$Calls)
            return {
                param($Context)
                $Calls.Add([pscustomobject]@{ Method = $Context.Method; Name = $Context.Name; Property = $Context.Property })
                return @{ InDesiredState = $true; Message = "stub-$($Context.Method)" }
            }.GetNewClosure()
        }
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
    }

    Context "Compile" {

        It "finds the definitions in the real Datum store and ignores the sub-folder" {
            $definitions = Get-CompositeDefinition -Datum $script:Datum -WarningAction SilentlyContinue
            @($definitions.Keys | Sort-Object) | Should -Be @('RepoSet', 'StandardProject')
        }

        It "writes no composite instance to the compiled file" {
            Test-Path -LiteralPath $script:MagentaPath | Should -BeTrue
            @($script:Compiled.resources | Where-Object { $_.type -like 'Composite/*' }).Count | Should -Be 0
        }

        It "expands every instance, including the nested one, into its members" {
            # Where Datum's UniqueKeyValTuples merge places each tuple is Datum's business; what
            # composites guarantee is the set of resources and the order WITHIN an instance.
            @($script:Compiled.resources | ForEach-Object { "$($_.type)/$($_.name)" } | Sort-Object) | Should -Be @(
                'Stub/Audit/Audit'
                'Stub/Group/Magenta::Readers'
                'Stub/Group/Shared::Readers'
                'Stub/Org/Org'
                'Stub/Project/Magenta::Project'
                'Stub/Project/Shared::Project'
                'Stub/Repo/Magenta::Repos::Docs'
                'Stub/Repo/Magenta::Repos::Main'
                'Stub/Repo/Shared::Repos::Docs'
                'Stub/Repo/Shared::Repos::Main'
            )
        }

        It "keeps each instance's members together, in definition order, where the instance stood" {
            $names = @($script:Compiled.resources | ForEach-Object { [string]$_.name })
            foreach ($instance in 'Shared', 'Magenta') {
                $start = $names.IndexOf("$instance::Project")
                $start | Should -BeGreaterThan -1
                $names[$start..($start + 3)] | Should -Be @(
                    "$instance::Project"
                    "$instance::Readers"
                    "$instance::Repos::Main"
                    "$instance::Repos::Docs"
                )
            }
        }

        It "applies the node's override of the baseline instance before expanding it" {
            (Get-CompiledResource -Name 'Shared::Project').properties.ProjectName | Should -Be 'Shared-Magenta'
            (Get-CompiledResource -Name 'Shared::Project').properties.Visibility  | Should -Be 'public'
            (Get-CompiledResource -Name 'Shared::Repos::Docs').properties.RepositoryName | Should -Be 'Shared-Magenta-docs'
        }

        It "substitutes parameters, defaults and per-instance overrides" {
            (Get-CompiledResource -Name 'Magenta::Project').properties.Visibility | Should -Be 'private'
            (Get-CompiledResource -Name 'Magenta::Readers').properties.GroupName  | Should -Be 'Magenta Viewers'
            (Get-CompiledResource -Name 'Shared::Readers').properties.GroupName   | Should -Be 'Shared-Magenta Readers'
        }

        It "carries the instance's preCondition and dependsOn onto its members" {
            (Get-CompiledResource -Name 'Magenta::Repos::Main').preCondition | Should -Be "equals (variables 'Environment') 'Prod'"
            @((Get-CompiledResource -Name 'Shared::Project').dependsOn | Select-Object -Unique) | Should -Be @('Stub/Org/Org')
        }

        It "resolves a dependsOn on an instance to all of its members" {
            @((Get-CompiledResource -Name 'Audit').dependsOn) | Should -Be @(
                'Stub/Project/Shared::Project'
                'Stub/Group/Shared::Readers'
                'Stub/Repo/Shared::Repos::Main'
                'Stub/Repo/Shared::Repos::Docs'
            )
        }
    }

    Context "Run" {

        BeforeAll {
            $script:Calls = [System.Collections.Generic.List[object]]::new()
            $script:Result = Start-DscRunner -FilePath $script:MagentaPath -EngineAction (New-RecordingEngine -Calls $script:Calls)
            $script:TestOrder = @($script:Calls | Where-Object { $_.Method -eq 'Test' } | ForEach-Object { $_.Name })
        }

        It "evaluates every member resource and completes" {
            $script:Result.Status | Should -Be 'Completed'
            $script:Result.FailCount | Should -Be 0
            $script:Result.TotalResources | Should -Be 10
            $script:TestOrder.Count | Should -Be 10
        }

        It "orders members by their rewritten dependencies" {
            $script:TestOrder.IndexOf('Org') | Should -BeLessThan $script:TestOrder.IndexOf('Shared::Project')
            $script:TestOrder.IndexOf('Shared::Project') | Should -BeLessThan $script:TestOrder.IndexOf('Shared::Readers')
            $script:TestOrder.IndexOf('Shared::Repos::Main') | Should -BeLessThan $script:TestOrder.IndexOf('Shared::Repos::Docs')
            foreach ($member in 'Shared::Project', 'Shared::Readers', 'Shared::Repos::Main', 'Shared::Repos::Docs') {
                $script:TestOrder.IndexOf($member) | Should -BeLessThan $script:TestOrder.IndexOf('Audit')
            }
        }

        It "hands the engine the substituted properties" {
            $docs = $script:Calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'Magenta::Repos::Docs' } | Select-Object -First 1
            $docs.Property.RepositoryName | Should -Be 'Magenta-docs'
        }

        It "reports each member under its expanded name" {
            @($script:Result.Results | Where-Object { $_.InstanceName -eq 'Magenta::Readers' -and $_.ResourceType -eq 'Stub/Group' }).Status | Should -Be 'OK'
        }
    }

    Context "Failures" {

        It "fails the compile when an instance omits a required parameter" {
            $root = Join-Path $TestDrive 'missing-parameter'
            New-ConfigurationTree -Root $root -Files @{
                'Datum.yml'                      = $script:DatumYaml
                'Composites/StandardProject.yml' = $script:StandardProjectYaml
                'Composites/RepoSet.yml'         = $script:RepoSetYaml
                'Baseline/Common.yml'            = "resources: []"
                'Projects/Present/Blue.yml'      = @'
resources:
  - name: Blue
    type: Composite/StandardProject
    properties:
      Visibility: public
'@
            }

            { Invoke-CompositeCompile -ConfigurationRoot $root -OutputDirectory (Join-Path $root 'out') } |
                Should -Throw "*Composite/StandardProject/Blue*required parameter(s) 'ProjectName'*"
            Test-Path -LiteralPath (Join-Path $root 'out/Blue.yml') | Should -BeFalse
        }

        It "fails the compile when an instance names an undefined composite" {
            $root = Join-Path $TestDrive 'unknown-composite'
            New-ConfigurationTree -Root $root -Files @{
                'Datum.yml'                 = $script:DatumYaml
                'Baseline/Common.yml'       = "resources: []"
                'Projects/Present/Blue.yml' = @'
resources:
  - name: Blue
    type: Composite/Nope
'@
            }

            { Invoke-CompositeCompile -ConfigurationRoot $root -OutputDirectory (Join-Path $root 'out') } |
                Should -Throw "*composite 'Nope', which is not defined*"
        }

        It "stops the run before any resource is evaluated when a file carries an unexpanded instance" {
            $path = Join-Path $TestDrive 'unexpanded.json'
            Set-Content -LiteralPath $path -Encoding UTF8 -Value @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Stub/Org", "name": "Org", "properties": {} },
    { "type": "Composite/StandardProject", "name": "Raw", "properties": { "ProjectName": "Raw" } }
  ]
}
'@
            $calls = [System.Collections.Generic.List[object]]::new()

            { Start-DscRunner -FilePath $path -EngineAction (New-RecordingEngine -Calls $calls) } |
                Should -Throw '*Test-CompositeResourcesExpanded*Composite/StandardProject/Raw*'
            $calls.Count | Should -Be 0
        }
    }
}
