Describe "Azure DevOps environment lifecycle against the Example Configuration (DSC v2 and DSC v3 engines)" -Tag Integration {

    # This suite proves the runner can authenticate to Azure DevOps and then stand up ("build") and
    # tear down a complete Azure DevOps environment end-to-end, through BOTH execution engines the
    # module ships, driven by the REAL Example Configuration shipped in this repository:
    #
    #   * DscV2 -> Actions/Engine/DscV2.ps1  -> Invoke-DscResource   (Windows / PowerShell DSC)
    #   * DscV3 -> Actions/Engine/DscV3.ps1  -> Invoke-DscExecutable (dsc / dsc.exe, cross-platform)
    #
    # It is modeled against the actual "Example Configuration" tree, not invented fixtures. The real
    # Datum pipeline compiles the hierarchy exactly as production does (New-DatumStructure over the
    # real Datum.yml ResolutionPrecedence, Resolve-Datum merging the Projects\<Presence>\<Project>
    # node with the ProjectPolicies/OrganizationPolicies fragments, and the Datum.InvokeCommand
    # handlers resolving the [x={ $Node.* }=] expressions). The two shipped nodes drive the lifecycle:
    #
    #   * Projects/Present/Magenta  -> BUILD    (Project Ensure = Present; every resource is created)
    #   * Projects/Absent/Blue      -> TEARDOWN (Project Ensure = Absent; the Project resource's
    #                                            postExecutionScript calls Stop-TaskProcessing, so
    #                                            removing the project halts the rest of the file —
    #                                            the real "delete the project, everything under it
    #                                            cascades" teardown model).
    #
    # Authentication is modeled through the REAL Connect seam the provider-agnostic runner uses
    # (Invoke-DscRunner calls Invoke-Action -Hook Connect). The genuine Actions/Connect/AzureDevOps.ps1
    # runs and calls New-AzDoAuthenticationProvider; because AzureDevOpsDsc.Common cannot be installed
    # on a hosted CI agent, that provider cmdlet is the single auth boundary that is faked (a stub is
    # defined so it resolves, then mocked to record the organization / PAT it was handed). No real
    # Azure DevOps call is made.
    #
    # Because real Azure DevOps (and a real dsc.exe / AzureDevOpsDsc provider) cannot run on a hosted
    # CI agent, the platform underneath each engine is replaced by an in-memory FAKE Azure DevOps
    # organization: a shared hashtable keyed by DSC resource type, holding which resource types
    # currently "exist". The two provider seams are mocked to read and mutate that org:
    #
    #   * DscV2: Invoke-DscResource   is the stateful provider (Test reads existence, Set creates or
    #            removes, Get returns current Ensure).
    #   * DscV3: Invoke-DscExecutable returns DSC v3 JSON result shapes and mutates the same org, so
    #            the real DscV3.ps1 mapping (verb selection, --input JSON, exit-code and JSON parsing)
    #            is exercised.
    #
    # Everything else is real: the Datum compile of the shipped configuration, the Connect action,
    # dependency ordering (Sort-DependsOn), variable seeding/expansion, per-resource conditions, the
    # engine seam and its [DscMethodResult] contract, the postExecutionScript / Stop-TaskProcessing
    # teardown control flow, and the structured run summary.

    BeforeAll {

        # --- External compile dependencies. These are installed in the CI test job (see
        # .github/workflows/CodeCoverage.yml) exactly as Invoke-DscPipelineRunner requires them. A
        # hard import (rather than a skip) keeps this integration test honest: if the compile stack is
        # missing, the failure is explicit instead of silently passing.
        foreach ($module in 'powershell-yaml', 'datum', 'datum.invokecommand') {
            Import-Module -Name $module -ErrorAction Stop
        }

        # --- Load the real dependency graph (class first, then the runner chain and engine seam) ----
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

        # ------------------------------------------------------------------------------------------
        # Compile the REAL Example Configuration through the REAL Datum pipeline (no mocks active yet,
        # so nothing here is faked). This is the same New-DatumStructure + Resolve-Datum merge that
        # Build-DatumConfiguration/DatumConfigurationScriptBlock run in production; it is performed
        # inline (rather than via the runspace) so it works dot-sourced on a Linux CI agent without a
        # by-name module install. The Organization name is read from the real OrganizationPolicies so
        # the authentication step below is tied to the shipped configuration too.
        # ------------------------------------------------------------------------------------------
        $script:ExampleConfigPath = Join-Path $Global:RepositoryRoot 'Example Configuration'
        $script:CompiledDir       = Join-Path $TestDrive 'compiled'
        New-Item -ItemType Directory -Path $script:CompiledDir -Force | Out-Null

        # Compiles a single node exactly as Resolve-DscDatumProject does: build the $Node identity
        # ({ Project; ProjectPresence } plus node-local keys), resolve each Datum property path for
        # that node, run the Datum.InvokeCommand handlers over the variables, and write the merged
        # per-node configuration to YAML.
        function Build-CompiledNode {
            param($Datum, [string]$ProjectPresence, [string]$ProjectName, [string]$OutputDirectory)

            $node = @{ Project = $ProjectName; ProjectPresence = $ProjectPresence }

            $resolved = @{
                resources  = Resolve-Datum -PropertyPath 'resources'  -DatumStructure $Datum -Variable $node
                parameters = Resolve-Datum -PropertyPath 'parameters' -DatumStructure $Datum -Variable $node
                conditions = Resolve-Datum -PropertyPath 'conditions' -DatumStructure $Datum -Variable $node
                variables  = Resolve-Datum -PropertyPath 'variables'  -DatumStructure $Datum -Variable $node
            }

            # Resolve any Datum.InvokeCommand ([x={ ... }=]) handlers in the variables, mirroring
            # Resolve-DscDatumProject: this turns Project_Ensure/ProjectName into concrete node values.
            $variablesOut = @{}
            foreach ($key in $resolved.variables.Keys) {
                $value = $resolved.variables[$key]
                if ($value | Test-InvokeCommandFilter) {
                    $variablesOut[$key] = $value | Invoke-InvokeCommandAction -Node $node
                }
                else {
                    $variablesOut[$key] = $value
                }
            }

            $compiled = @{
                resources  = $resolved.resources
                parameters = $resolved.parameters
                conditions = $resolved.conditions
                variables  = $variablesOut
            }

            $outputPath = Join-Path $OutputDirectory ("{0}.yml" -f $ProjectName)
            $compiled | ConvertTo-Yaml | Set-Content -LiteralPath $outputPath -Encoding UTF8
            return $outputPath
        }

        Push-Location $script:ExampleConfigPath
        try {
            $datum = New-DatumStructure -DefinitionFile 'Datum.yml'

            # The Azure DevOps organization the environment lives in, straight from the shipped
            # OrganizationPolicies/Organization.yml (Organization_Name).
            $script:OrganizationName = [string](Resolve-Datum -PropertyPath 'variables' -DatumStructure $datum `
                    -Variable @{ Project = 'Magenta'; ProjectPresence = 'Present' })['Organization_Name']

            $script:MagentaConfigPath = Build-CompiledNode -Datum $datum -ProjectPresence 'Present' -ProjectName 'Magenta' -OutputDirectory $script:CompiledDir
            $script:BlueConfigPath    = Build-CompiledNode -Datum $datum -ProjectPresence 'Absent'  -ProjectName 'Blue'    -OutputDirectory $script:CompiledDir
        }
        finally {
            Pop-Location
        }

        # A realistic-looking (but entirely fake) Personal Access Token for the auth step.
        $script:FakePatToken = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOP'

        # ------------------------------------------------------------------------------------------
        # From here on, install the fakes that stand in for real Azure DevOps / dsc.exe.
        # ------------------------------------------------------------------------------------------

        # Point ONLY the engine/connect-file loader (Invoke-Action's Get-Module 'Dsc.PipelineRunner')
        # at the repository root so it resolves the real Actions/<Hook>/<Name>.ps1 on a CI runner with
        # no installed module. The parameter filter keeps Datum's own Get-Module calls untouched.
        Mock -CommandName Get-Module -ParameterFilter { $Name -eq 'Dsc.PipelineRunner' } -MockWith {
            return @{ ModuleBase = $Global:RepositoryRoot }
        }

        # Keep the runner's log off the test output; all real logic stays intact.
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        # Loader stand-ins. Invoke-CustomTask runs the REAL Sort-DependsOn so dependency ordering is
        # genuinely exercised over the compiled Example Configuration resources.
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
        Mock -CommandName Invoke-PreParseRules -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) }
        Mock -CommandName Invoke-FormatTasks   -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) return $Tasks }

        # --- Azure DevOps authentication boundary ---------------------------------------------------
        # The real Actions/Connect/AzureDevOps.ps1 resolves New-AzDoAuthenticationProvider via
        # Get-Command; define a stub so it resolves on an agent without AzureDevOpsDsc.Common, then
        # mock it to record how the runner authenticated. The mock body writes to a $Global list so it
        # is observable across the '&'-invoked action-file scope boundary.
        function New-AzDoAuthenticationProvider {
            param([string]$OrganizationName, [string]$PersonalAccessToken, [switch]$useManagedIdentity)
        }
        $Global:AuthCalls = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName New-AzDoAuthenticationProvider -MockWith {
            param([string]$OrganizationName, [string]$PersonalAccessToken, [switch]$useManagedIdentity)
            $Global:AuthCalls.Add([pscustomobject]@{
                Organization = $OrganizationName
                PATToken     = $PersonalAccessToken
                AuthType     = if ($useManagedIdentity) { 'ManagedIdentity' } else { 'PAT' }
            })
        }

        # --- The in-memory fake Azure DevOps organization ------------------------------------------
        # $Global: state so the provider mocks can write to it across the '&'-invoked engine-file
        # scope boundary. Keyed by DSC resource type ('Owner/Resource'); a present key means at least
        # one resource of that type currently exists in the org. The AzDoProject is the singleton the
        # lifecycle turns on, so a type key is a faithful stand-in for it.
        $Global:AdoOrg   = @{}
        $Global:AdoCalls = [System.Collections.Generic.List[object]]::new()

        # DSC v2 provider. The real Actions/Engine/DscV2.ps1 calls this; it reflects and mutates the
        # fake org. Absent desired-state inverts the Test result and makes Set a delete.
        Mock -CommandName Invoke-DscResource -MockWith {
            param($Name, $ModuleName, $Method, $Property)

            $type    = '{0}/{1}' -f $ModuleName, $Name
            $desired = if ($Property -is [System.Collections.IDictionary] -and $Property.Contains('Ensure')) { [string]$Property['Ensure'] } else { 'Present' }
            $exists  = $Global:AdoOrg.ContainsKey($type)
            $Global:AdoCalls.Add([pscustomobject]@{ Kind = 'engine'; Engine = 'DscV2'; Method = $Method; Type = $type })

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
            $Global:AdoCalls.Add([pscustomobject]@{ Kind = 'engine'; Engine = 'DscV3'; Method = $verb; Type = $type })

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

        # The Azure DevOps resource type the environment turns on. The Project is created first (every
        # other resource depends on it) and, when declared Absent, its removal stops the run.
        $script:ProjectType = 'AzureDevOpsDsc/AzDoProject'
        $script:GroupType   = 'AzureDevOpsDsc/AzDoProjectGroup'

        # Establishes the ambient Azure DevOps session the way the provider-agnostic runner does:
        # Invoke-DscRunner calls Invoke-Action -Hook Connect, which runs the real Connect action file.
        function Connect-FakeAzureDevOps {
            param([string]$AuthenticationType = 'PAT')
            $context = @{ OrganizationName = $script:OrganizationName; AuthenticationType = $AuthenticationType }
            if ($AuthenticationType -eq 'PAT') { $context['PATToken'] = $script:FakePatToken }
            $null = Invoke-Action -Hook Connect -Name 'AzureDevOps' -Context $context
        }
    }

    AfterAll {
        Remove-Variable -Name AdoOrg    -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name AdoCalls  -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name AuthCalls -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        # A fresh, empty organization, clean call logs and a reset stop-flag before every scenario.
        $Global:AdoOrg = @{}
        $Global:AdoCalls.Clear()
        $Global:AuthCalls.Clear()
        $script:StopTaskProcessing = $false
    }

    Context "the Datum compile of the shipped Example Configuration" {

        It "resolves the Present node (Magenta) to a Project marked Present with its own git repository" {
            $magenta = Get-Content -LiteralPath $script:MagentaConfigPath -Raw | ConvertFrom-Yaml

            # The [x={ $Node.* }=] handlers resolved to this node's identity.
            $magenta.variables.ProjectName   | Should -Be 'Magenta'
            $magenta.variables.Project_Ensure | Should -Be 'Present'

            # The policy fragments merged in (the Project) alongside the node's own resource.
            $names = @($magenta.resources | ForEach-Object { $_.name })
            $names | Should -Contain 'Project'
            $names | Should -Contain 'Configuration Git Repository'
        }

        It "resolves the Absent node (Blue) to a Project marked Absent with no project-specific repository" {
            $blue = Get-Content -LiteralPath $script:BlueConfigPath -Raw | ConvertFrom-Yaml

            $blue.variables.ProjectName    | Should -Be 'Blue'
            $blue.variables.Project_Ensure | Should -Be 'Absent'

            $names = @($blue.resources | ForEach-Object { $_.name })
            $names | Should -Contain 'Project'
            # Blue's own resources are empty, so the Magenta-only git repository must not appear.
            $names | Should -Not -Contain 'Configuration Git Repository'
        }
    }

    Context "Azure DevOps authentication (Connect seam)" {

        It "authenticates to the Example Configuration's organization with a Personal Access Token" {
            Connect-FakeAzureDevOps -AuthenticationType 'PAT'

            $Global:AuthCalls.Count      | Should -Be 1
            $Global:AuthCalls[0].Organization | Should -Be $script:OrganizationName
            $Global:AuthCalls[0].AuthType     | Should -Be 'PAT'
            $Global:AuthCalls[0].PATToken     | Should -Be $script:FakePatToken
        }

        It "supports Managed Identity authentication" {
            Connect-FakeAzureDevOps -AuthenticationType 'ManagedIdentity'

            $Global:AuthCalls.Count       | Should -Be 1
            $Global:AuthCalls[0].AuthType | Should -Be 'ManagedIdentity'
        }

        It "refuses PAT authentication when no token is supplied" {
            {
                Invoke-Action -Hook Connect -Name 'AzureDevOps' -Context @{
                    OrganizationName   = $script:OrganizationName
                    AuthenticationType = 'PAT'
                }
            } | Should -Throw '*PATToken*'
        }
    }

    Context "<engine> engine" -ForEach @(
        @{ engine = 'DscV2' }
        @{ engine = 'DscV3' }
    ) {

        It "authenticates, then builds the Azure DevOps environment from the Present node (Magenta)" {

            # 1. Authenticate to Azure DevOps first, exactly as the provider-agnostic runner does.
            Connect-FakeAzureDevOps -AuthenticationType 'PAT'
            $Global:AuthCalls.Count           | Should -Be 1
            $Global:AuthCalls[0].Organization | Should -Be $script:OrganizationName

            # 2. Provision the environment: Set over an empty org creates every resource.
            $build = Start-DscRunner -FilePath $script:MagentaConfigPath -Mode 'Set' -Engine $engine

            # A Present Project never triggers Stop-TaskProcessing, so the whole file runs to the end.
            $build.Status    | Should -Be 'Completed'
            $build.FailCount | Should -Be 0

            # The Project is provisioned, and it is provisioned first — every other resource depends
            # on it, so Sort-DependsOn must schedule it ahead of them.
            $engineCalls = @($Global:AdoCalls | Where-Object { $_.Kind -eq 'engine' })
            $testCalls   = @($engineCalls | Where-Object { $_.Method -in 'Test', 'test' })
            $testCalls[0].Type | Should -Be $script:ProjectType
            @($engineCalls | Where-Object { $_.Method -in 'Set', 'set' -and $_.Type -eq $script:ProjectType }).Count | Should -BeGreaterThan 0
            $Global:AdoOrg.ContainsKey($script:ProjectType) | Should -BeTrue

            # A per-resource condition really gated a resource: 'CON Board Administrators' carries
            # condition "$ProjectWorkBoardsStatus -eq 'enabled'", which is unset for Magenta, so it is
            # skipped and only 'CON Readers' of the two project groups reaches the engine.
            $build.SkipCount | Should -BeGreaterThan 0
            @($testCalls | Where-Object { $_.Type -eq $script:GroupType }).Count | Should -Be 1
        }

        It "authenticates, then tears the environment down from the Absent node (Blue)" {

            # Authenticate, then start from an already-provisioned project.
            Connect-FakeAzureDevOps -AuthenticationType 'PAT'
            $Global:AdoOrg[$script:ProjectType] = @{ Ensure = 'Present' }

            $teardown = Start-DscRunner -FilePath $script:BlueConfigPath -Mode 'Set' -Engine $engine

            # The Absent Project's postExecutionScript calls Stop-TaskProcessing, so the run halts.
            $teardown.Status    | Should -Be 'StoppedByRequest'
            $teardown.SkipCount | Should -BeGreaterThan 0

            # The project was removed (the delete Set ran), and processing stopped right after it: the
            # only resource type that reached the engine is the Project itself.
            $engineCalls = @($Global:AdoCalls | Where-Object { $_.Kind -eq 'engine' })
            @($engineCalls | Where-Object { $_.Method -in 'Set', 'set' -and $_.Type -eq $script:ProjectType }).Count | Should -BeGreaterThan 0
            @($engineCalls | ForEach-Object { $_.Type } | Select-Object -Unique) | Should -Be $script:ProjectType
            $Global:AdoOrg.ContainsKey($script:ProjectType) | Should -BeFalse
        }

        It "completes a full authenticate -> build -> teardown cycle" {

            # Build.
            Connect-FakeAzureDevOps -AuthenticationType 'PAT'
            $build = Start-DscRunner -FilePath $script:MagentaConfigPath -Mode 'Set' -Engine $engine
            $build.Status | Should -Be 'Completed'
            $Global:AdoOrg.ContainsKey($script:ProjectType) | Should -BeTrue

            # Teardown.
            $teardown = Start-DscRunner -FilePath $script:BlueConfigPath -Mode 'Set' -Engine $engine
            $teardown.Status | Should -Be 'StoppedByRequest'
            $Global:AdoOrg.ContainsKey($script:ProjectType) | Should -BeFalse
        }

        It "reports drift as failures in Test mode without provisioning anything (Present node)" {

            Connect-FakeAzureDevOps -AuthenticationType 'PAT'

            # Test mode over an empty org: the Project (and every unconditional resource) is absent, so
            # each is drift, and the runner must NOT call Set.
            $test = Start-DscRunner -FilePath $script:MagentaConfigPath -Mode 'Test' -Engine $engine

            $test.Status    | Should -Be 'Completed'
            $test.FailCount | Should -BeGreaterThan 0

            $Global:AdoOrg.Count | Should -Be 0
            @($Global:AdoCalls | Where-Object { $_.Kind -eq 'engine' -and $_.Method -in 'Set', 'set' }).Count | Should -Be 0
        }
    }
}
