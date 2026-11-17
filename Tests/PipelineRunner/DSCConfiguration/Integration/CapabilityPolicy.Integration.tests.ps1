Describe "Capability policy provenance through a real Datum compile (preview)" -Tag Integration, HostedIntegration {

    # The capability policy (issue #86, Part B) depends on one thing no mock can prove: that asking
    # Datum for each layer on its own really shows which layer files contributed to each merged
    # resource. This suite writes a small two-layer configuration, compiles it with the genuine
    # New-DatumStructure + Resolve-DscDatumProject and a policy, and checks the provenance record
    # the compile leaves beside the compiled file, then checks that record against the policy.

    BeforeAll {
        foreach ($module in 'powershell-yaml', 'datum', 'datum.invokecommand') {
            Import-Module -Name $module -ErrorAction Stop
        }

        . (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName
        . (Get-FunctionPath 'Import-CapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Resolve-CapabilityPolicyPath.ps1').FullName
        . (Get-FunctionPath 'Get-PolicyLayer.ps1').FullName
        . (Get-FunctionPath 'Test-PolicyCapability.ps1').FullName
        . (Get-FunctionPath 'Get-ResourceProvenance.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Assert-DatumScriptBlockPolicy.ps1').FullName

        function New-ConfigurationTree {
            param([string]$Root, [hashtable]$Files)
            foreach ($relativePath in $Files.Keys) {
                $path = Join-Path $Root $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $Files[$relativePath] -Encoding UTF8
            }
        }

        # Compiles every node as DatumConfigurationScriptBlock does, with $Datum, $ProjectType,
        # $OutputPath and $CapabilityPolicyPath in scope for Resolve-DscDatumProject.
        function Invoke-PolicyCompile {
            param([string]$ConfigurationRoot, [string]$OutputDirectory, [string]$PolicyPath)
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
            $OutputPath = $OutputDirectory
            $CapabilityPolicyPath = $PolicyPath
            Push-Location -LiteralPath $ConfigurationRoot
            try {
                $Datum = New-DatumStructure -DefinitionFile 'Datum.yml'
                foreach ($ProjectType in $Datum.Projects.psobject.properties) {
                    foreach ($ProjectNode in $Datum.Projects."$($ProjectType.name)".psobject.properties) {
                        Resolve-DscDatumProject -NodeName $ProjectNode -AllNodes $Datum.Projects."$($ProjectType.name)"."$($ProjectNode.Name)"
                    }
                }
            }
            finally { Pop-Location }
        }

        $separator = [System.IO.Path]::DirectorySeparatorChar

        $datumYaml = @"
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

        # The platform layer: a resource of its own, and one a team is expected to adjust.
        $baselineYaml = @'
variables:
  Region: west
resources:
  - name: Platform only
    type: Stub/Thing
    target:
      action: SSH
      computerName: bastion.example.test
    properties:
      Setting: platform
  - name: Shared
    type: Stub/Thing
    target:
      action: SSH
      computerName: bastion.example.test
    properties:
      Setting: platform
'@

        # The team's node file. It redeclares the platform's 'Shared' (Datum's merge by name lets
        # the more specific layer's item replace the other), keeping the privileged Target and
        # changing a property; adds a resource; and instantiates a platform composite. It also
        # tries to claim a higher layer by writing stamps of its own.
        $appYaml = @'
layer: Platform
provenance:
  Layers: [ Platform ]
variables:
  Owner: team-app
resources:
  - name: Shared
    type: Stub/Thing
    layer: Platform
    provenance: [ Platform ]
    target:
      action: SSH
      computerName: bastion.example.test
    properties:
      Setting: changed by the team
  - name: Team only
    type: Stub/Thing
    properties:
      Setting: team
  - name: Block
    type: Composite/Block
    properties:
      Label: from the team
'@

        $blockYaml = @'
parameters:
  Label:
resources:
  - name: Member
    type: Stub/Thing
    properties:
      Setting: <composite=Label>
'@

        $policyYaml = @'
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'Baseline/**', 'Composites/**' ]
    Capabilities:
      Targets: [ '*' ]
      Engines: [ '*' ]
      ExecutionScripts: true
      DatumScriptBlocks: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local, WinRM ]
      Engines: [ DscV2, DscV3 ]
'@

        $script:ConfigurationRoot = Join-Path $TestDrive 'config'
        $script:CompiledDirectory = Join-Path $TestDrive 'compiled'
        $script:DatumYaml = $datumYaml
        $script:BaselineYaml = $baselineYaml
        $script:BlockYaml = $blockYaml
        $script:PolicyYaml = $policyYaml

        # The policy is a file of its own at the root of the configuration, beside Datum.yml.
        New-ConfigurationTree -Root $ConfigurationRoot -Files @{
            'Datum.yml'                = $datumYaml
            'Policy.yml'               = $policyYaml
            'Baseline/Common.yml'      = $baselineYaml
            'Composites/Block.yml'     = $blockYaml
            'Projects/Present/App.yml' = $appYaml
        }

        $script:PolicyPath = Resolve-CapabilityPolicyPath -ConfigurationPath $ConfigurationRoot
        $script:Policy = Import-CapabilityPolicy -Path $PolicyPath -ConfigurationPath $ConfigurationRoot
        Invoke-PolicyCompile -ConfigurationRoot $ConfigurationRoot -OutputDirectory $CompiledDirectory -PolicyPath $PolicyPath

        $script:CompiledFile = Join-Path $CompiledDirectory 'App.yml'
        $script:RecordFile = Join-Path $CompiledDirectory 'App.provenance.json'
        $script:Record = if (Test-Path -LiteralPath $RecordFile) { Get-Content -LiteralPath $RecordFile -Raw | ConvertFrom-Json -AsHashtable }
        $script:Compiled = Get-Content -LiteralPath $CompiledFile -Raw | ConvertFrom-Yaml
    }

    Context "The policy file is beside Datum.yml and outside the Datum hierarchy" {

        It "Is found at the root of the configuration without being named" {
            $PolicyPath | Should -Be (Join-Path $ConfigurationRoot 'Policy.yml')
        }

        It "Is not loaded by Datum, so nothing can be merged into it or from it" {
            Push-Location -LiteralPath $ConfigurationRoot
            try { $datum = New-DatumStructure -DefinitionFile 'Datum.yml' } finally { Pop-Location }
            $stores = if ($datum -is [System.Collections.IDictionary]) { @($datum.Keys) } else { @($datum.PSObject.Properties.Name) }
            $stores | Should -Not -Contain 'Policy'
            $stores | Should -Contain 'Projects'
        }

        It "Leaves no trace of itself in the compiled configuration" {
            $text = Get-Content -LiteralPath $CompiledFile -Raw
            $text | Should -Not -Match 'PolicyVersion'
            $text | Should -Not -Match 'Capabilities'
            $Compiled.Keys | Should -Not -Contain 'Layers'
        }
    }

    Context "The provenance record" {

        It "Is written beside the compiled file, under the policy that was used" {
            Test-Path -LiteralPath $RecordFile | Should -BeTrue
            $Record.SchemaVersion | Should -Be '1.0'
            $Record.PolicySha256 | Should -Be $Policy.Sha256
            $Record.Node | Should -Be 'App'
        }

        It "Maps each layer file of the node to its policy layer, in precedence order" {
            @($Record.Layers).Count | Should -Be 2
            $Record.Layers[0].Path | Should -Be 'Projects/Present/App'
            $Record.Layers[0].Layer | Should -Be 'Teams'
            $Record.Layers[1].Path | Should -Be 'Baseline/Common'
            $Record.Layers[1].Layer | Should -Be 'Platform'
            $Record.SettingsLayer | Should -Be 'Platform'
        }

        It "Attributes a resource only the platform declared to the platform alone" {
            @($Record.Resources['Stub/Thing/Platform only']) | Should -Be @('Platform')
        }

        It "Attributes a resource only the team declared to the team alone" {
            @($Record.Resources['Stub/Thing/Team only']) | Should -Be @('Teams')
        }

        It "Attributes a resource the platform declared and the team changed to both" {
            @($Record.Resources['Stub/Thing/Shared']) | Sort-Object | Should -Be @('Platform', 'Teams')
        }

        It "Attributes a composite member to the layer that instantiated it and the layer that defined it" {
            # A member is named '<instance>::<member>'.
            $Compiled.resources.name | Should -Contain 'Block::Member' -Because 'the composite must have been expanded'
            @($Record.Resources['Stub/Thing/Block::Member']) | Sort-Object | Should -Be @('Platform', 'Teams')
        }

        It "Has an entry for every resource that will run, and nothing else" {
            $compiledKeys = @($Compiled.resources | ForEach-Object { "$($_.type)/$($_.name)" }) | Sort-Object
            @($Record.Resources.Keys) | Sort-Object | Should -Be $compiledKeys
        }

        It "Lists every layer that contributed to the node" {
            @($Record.ContributingLayers) | Sort-Object | Should -Be @('Platform', 'Teams')
        }

        It "Ignores stamps a contributor wrote into its own file" {
            # App.yml says 'layer: Platform' at the top and on its resources. None of it counts.
            @($Record.Resources['Stub/Thing/Team only']) | Should -Not -Contain 'Platform'
            $Record.Layers[0].Layer | Should -Be 'Teams'
        }
    }

    Context "The record against the policy" {

        BeforeAll {
            $script:Check = Get-RunPolicyViolation -Policy $Policy -FilePath $CompiledFile -Task @($Compiled.resources) -DefaultTargetAction 'Local' -Engine 'DscV2'
            $script:Violations = $Check.Violations -join "`n"
        }

        It "Lets the platform's own resource use the Target only the platform may use" {
            $Violations | Should -Not -Match '\[Stub/Thing/Platform only\]'
        }

        It "Refuses that Target on the platform resource the team redeclared: least privilege" {
            # What will run is the team's version of 'Shared'. It cannot keep the platform's Target.
            ($Compiled.resources | Where-Object name -EQ 'Shared').properties.Setting | Should -Be 'changed by the team'
            $Violations | Should -Match "\[Stub/Thing/Shared\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
        }

        It "Lets the team's resources and the composite member use the default Target" {
            $Violations | Should -Not -Match '\[Stub/Thing/Team only\]'
            $Violations | Should -Not -Match 'Block::Member'
        }

        It "Refuses an engine the team may not use, because the team has resources in the file" {
            (Get-RunPolicyViolation -Policy $Policy -FilePath $CompiledFile -Task @($Compiled.resources) -DefaultTargetAction 'Local' -Engine 'Bespoke').Violations -join "`n" |
                Should -Match "engine 'Bespoke' is not allowed for layer\(s\) Teams"
        }
    }

    Context "Without a policy" {

        It "Writes no provenance record, so nothing changes for a configuration that does not use one" {
            $output = Join-Path $TestDrive 'compiled-no-policy'
            Invoke-PolicyCompile -ConfigurationRoot $ConfigurationRoot -OutputDirectory $output -PolicyPath $null
            Test-Path -LiteralPath (Join-Path $output 'App.yml') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $output 'App.provenance.json') | Should -BeFalse
        }
    }

    Context "The compile entry point" {

        It "Refuses a policy file placed in a layer's folder" {
            $inside = Join-Path $ConfigurationRoot 'Projects/Policy.yml'
            Copy-Item -LiteralPath $PolicyPath -Destination $inside
            try { { Import-CapabilityPolicy -Path $inside -ConfigurationPath $ConfigurationRoot } | Should -Throw '*sub-folder of the configuration*' }
            finally { Remove-Item -LiteralPath $inside }
        }

        It "Stops a team's Datum script block before anything is compiled" {
            $withBlock = Join-Path $TestDrive 'config-with-block'
            Copy-Item -LiteralPath $ConfigurationRoot -Destination $withBlock -Recurse
            Add-Content -LiteralPath (Join-Path $withBlock 'Projects/Present/App.yml') -Value "conditions:`n  Sneaky: '[x={ Set-Content -LiteralPath pwned.txt -Value 1 }=]'"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $withBlock -Policy $Policy } | Should -Throw "*'Projects/Present/App.yml' (layer Teams)*"
            Test-Path -LiteralPath (Join-Path $withBlock 'pwned.txt') | Should -BeFalse
        }
    }
}

Describe "A real runner pass under a capability policy (preview)" -Tag Integration, HostedIntegration {

    # The compile writes the provenance record; this suite proves the runner acts on it. A file
    # that complies runs; a file that does not is stopped before the engine is called once; and a
    # Target that is only known when the resource is reached is refused there, without the target
    # being contacted. The engine is an inline one that records what it was asked to do.

    BeforeAll {
        foreach ($module in 'powershell-yaml', 'datum', 'datum.invokecommand') {
            Import-Module -Name $module -ErrorAction Stop
        }

        . (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName
        . (Get-FunctionPath 'Import-CapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Resolve-CapabilityPolicyPath.ps1').FullName
        . (Get-FunctionPath 'Get-PolicyLayer.ps1').FullName
        . (Get-FunctionPath 'Test-PolicyCapability.ps1').FullName
        . (Get-FunctionPath 'Get-ResourceProvenance.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Assert-DatumScriptBlockPolicy.ps1').FullName

        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName
        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        . (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        . (Get-FunctionPath 'Resolve-PipelineParameter.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName
        . (Get-FunctionPath 'variables.ps1').FullName
        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Module-script-scope state the runner reads and mutates (mirrors source/prefix.ps1).
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $separator = [System.IO.Path]::DirectorySeparatorChar
        $script:RunDatumYaml = @"
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

        # The inline recording engine counts as an engine of its own, so this policy lets both
        # layers use any engine and restricts what the suite is about: Targets and scripts.
        $script:RunPolicyYaml = @'
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'Baseline/**' ]
    Capabilities:
      Targets: [ '*' ]
      Engines: [ '*' ]
      ExecutionScripts: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local ]
      Engines: [ '*' ]
'@

        $script:RunBaselineYaml = @'
variables:
  Hop: Local
resources:
  - name: Platform thing
    type: Stub/Thing
    properties:
      Setting: platform
'@

        # Writes a configuration whose team file is $TeamYaml, compiles it under the policy and
        # returns the compiled file's path.
        function New-CompiledNode {
            param([string]$TeamYaml, [string]$BaselineYaml = $script:RunBaselineYaml)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $files = @{
                'Datum.yml'                = $script:RunDatumYaml
                'Policy.yml'               = $script:RunPolicyYaml
                'Baseline/Common.yml'      = $BaselineYaml
                'Projects/Present/App.yml' = $TeamYaml
            }
            foreach ($relativePath in $files.Keys) {
                $path = Join-Path $root $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $files[$relativePath] -Encoding UTF8
            }

            $OutputPath = Join-Path $root '_compiled'
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            $CapabilityPolicyPath = Resolve-CapabilityPolicyPath -ConfigurationPath $root
            $script:RunPolicy = Import-CapabilityPolicy -Path $CapabilityPolicyPath -ConfigurationPath $root
            Assert-DatumScriptBlockPolicy -ConfigurationPath $root -Policy $script:RunPolicy
            Push-Location -LiteralPath $root
            try {
                $Datum = New-DatumStructure -DefinitionFile 'Datum.yml'
                foreach ($ProjectType in $Datum.Projects.psobject.properties) {
                    foreach ($ProjectNode in $Datum.Projects."$($ProjectType.name)".psobject.properties) {
                        Resolve-DscDatumProject -NodeName $ProjectNode -AllNodes $Datum.Projects."$($ProjectType.name)"."$($ProjectNode.Name)"
                    }
                }
            }
            finally { Pop-Location }
            return (Join-Path $OutputPath 'App.yml')
        }

        function New-RecordingEngine {
            param([System.Collections.Generic.List[object]]$Calls)
            return {
                param($Context)
                $Calls.Add([pscustomobject]@{ Method = $Context.Method; Name = $Context.Name; Property = $Context.Property })
                return @{ InDesiredState = $true; Message = "stub-$($Context.Method)" }
            }.GetNewClosure()
        }

        # Compile everything first, so Datum's own calls are untouched by the runner stand-ins.
        $script:CompliantFile = New-CompiledNode -TeamYaml @'
resources:
  - name: Team thing
    type: Stub/Thing
    properties:
      Setting: team
'@
        $script:CompliantPolicy = $script:RunPolicy

        $script:ViolatingFile = New-CompiledNode -TeamYaml @'
resources:
  - name: Team thing
    type: Stub/Thing
    properties:
      Setting: team
  - name: Team over SSH
    type: Stub/Thing
    target:
      action: SSH
      computerName: somewhere.example.test
    properties:
      Setting: team
  - name: Team with a script
    type: Stub/Thing
    postExecutionScript: Write-Verbose hi
    properties:
      Setting: team
'@
        $script:ViolatingPolicy = $script:RunPolicy

        # The platform's resource takes its Target from a variable; the team sets that variable.
        $script:SteeredFile = New-CompiledNode -BaselineYaml @'
variables:
  Hop: Local
resources:
  - name: Platform thing
    type: Stub/Thing
    target:
      action: $(variables('Hop'))
      computerName: somewhere.example.test
    properties:
      Setting: platform
'@ -TeamYaml @'
variables:
  Hop: SSH
resources:
  - name: Team thing
    type: Stub/Thing
    properties:
      Setting: team
'@
        $script:SteeredPolicy = $script:RunPolicy

        # --- Runner stand-ins ---
        Mock -CommandName Get-Module -ParameterFilter { $Name -eq 'Dsc.PipelineRunner' } -MockWith { return @{ ModuleBase = $Global:RepositoryRoot } }
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information
        Mock -CommandName Invoke-CustomTask -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks, [Parameter(Mandatory = $true)] [String]$CustomTaskName)
            return $Tasks
        }
        # The PreParse rules call Get-DscResource for resource types that do not exist here.
        Mock -CommandName Invoke-PreParseRules
        Mock -CommandName Invoke-FormatTasks -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) return $Tasks }
        # A Target action must never be reached for a resource the policy refuses.
        Mock -CommandName Invoke-Action -ParameterFilter { $Hook -eq 'Target' } -MockWith { throw 'A Target action was invoked.' }
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
        $script:Calls = [System.Collections.Generic.List[object]]::new()
    }

    It "Runs a file that complies with the policy" {
        $result = Start-DscRunner -FilePath $CompliantFile -EngineAction (New-RecordingEngine -Calls $Calls) -Policy $CompliantPolicy -RunnerSettings @{ AllowExecutionScripts = $true }
        $result.Status | Should -Be 'Completed'
        $result.FailCount | Should -Be 0
        @($Calls | Where-Object Method -EQ 'Test').Count | Should -Be 2
    }

    It "Does not start a file that breaks the policy, and names every violation" {
        $result = Start-DscRunner -FilePath $ViolatingFile -EngineAction (New-RecordingEngine -Calls $Calls) -Policy $ViolatingPolicy -RunnerSettings @{ AllowExecutionScripts = $true } -ErrorAction SilentlyContinue
        $result.Status | Should -Be 'AbortedByException'
        $result.ErrorMessage | Should -Match 'Capability policy: 2 violation\(s\); no resource was run'
        $result.ErrorMessage | Should -Match "\[Stub/Thing/Team over SSH\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
        $result.ErrorMessage | Should -Match "\[Stub/Thing/Team with a script\] has an execution script"
        $Calls.Count | Should -Be 0 -Because 'the engine must not be called for a file that is refused'
    }

    It "Runs the same violating file when no policy is supplied: the policy is what stops it" {
        # Without -Policy the runner behaves as it always has. The SSH resource then fails on its
        # own (the Target stand-in throws); the point is that the file is no longer refused up front.
        $result = Start-DscRunner -FilePath $ViolatingFile -EngineAction (New-RecordingEngine -Calls $Calls) -RunnerSettings @{ AllowExecutionScripts = $true } -ErrorAction SilentlyContinue
        [string]$result.ErrorMessage | Should -Not -Match 'Capability policy'
        $Calls.Count | Should -BeGreaterThan 0
    }

    It "Refuses, at the point of use, a Target a team steered a platform resource onto" {
        $result = Start-DscRunner -FilePath $SteeredFile -EngineAction (New-RecordingEngine -Calls $Calls) -Policy $SteeredPolicy -RunnerSettings @{ AllowExecutionScripts = $true } -ErrorAction SilentlyContinue
        # The file starts (the expression has no value before the run) ...
        $result.Status | Should -Not -Be 'AbortedByException'
        # ... the steered resource fails without its Target being contacted ...
        $steered = $result.FailedResources | Where-Object InstanceName -EQ 'Platform thing'
        $steered | Should -Not -BeNullOrEmpty
        $steered.ErrorMessage | Should -Match "uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
        Should -Invoke Invoke-Action -Times 0 -ParameterFilter { $Hook -eq 'Target' }
        @($Calls | Where-Object { $_.Property.Setting -eq 'platform' }).Count | Should -Be 0
        # ... and the rest of the file still runs.
        @($Calls | Where-Object { $_.Property.Setting -eq 'team' -and $_.Method -eq 'Test' }).Count | Should -Be 1
    }

    It "Fails closed when the provenance record has been removed" {
        $copy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $copy | Out-Null
        Copy-Item -LiteralPath $CompliantFile -Destination $copy
        $result = Start-DscRunner -FilePath (Join-Path $copy 'App.yml') -EngineAction (New-RecordingEngine -Calls $Calls) -Policy $CompliantPolicy -ErrorAction SilentlyContinue
        $result.Status | Should -Be 'AbortedByException'
        $result.ErrorMessage | Should -Match 'There is no provenance record'
        $Calls.Count | Should -Be 0
    }
}

Describe "The shipped example: Example Policy Configuration" -Tag Integration, HostedIntegration {

    # The example in the repository is documentation people will copy. This suite compiles it for
    # real and makes each change its README says is refused, so the example and the README cannot
    # drift from what the runner does.

    BeforeAll {
        foreach ($module in 'powershell-yaml', 'datum', 'datum.invokecommand') {
            Import-Module -Name $module -ErrorAction Stop
        }

        . (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName
        . (Get-FunctionPath 'Import-CapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Resolve-CapabilityPolicyPath.ps1').FullName
        . (Get-FunctionPath 'Get-PolicyLayer.ps1').FullName
        . (Get-FunctionPath 'Test-PolicyCapability.ps1').FullName
        . (Get-FunctionPath 'Get-ResourceProvenance.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Assert-DatumScriptBlockPolicy.ps1').FullName
        . (Get-FunctionPath 'Get-PipelineRunnerSetting.ps1').FullName

        $script:ExampleSource = Join-Path $Global:RepositoryRoot 'Example Policy Configuration'

        # A copy of the example, optionally with the team file changed. Datum splits the
        # ResolutionPrecedence entries on the platform's separator, so the copy's Datum.yml is
        # rewritten for the platform the test runs on.
        function New-ExampleCopy {
            param([scriptblock]$ChangeTeamFile)
            $copy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $script:ExampleSource -Destination $copy -Recurse
            $definition = Join-Path $copy 'Datum.yml'
            $text = Get-Content -LiteralPath $definition -Raw
            $text = [regex]::Replace($text, '(?m)^(  - \S.*)$', { param($m) $m.Value.Replace('\', [string][System.IO.Path]::DirectorySeparatorChar) })
            Set-Content -LiteralPath $definition -Value $text -Encoding UTF8
            if ($ChangeTeamFile) {
                $teamFile = Join-Path $copy 'Projects/Present/WebTeam.yml'
                Set-Content -LiteralPath $teamFile -Value (& $ChangeTeamFile (Get-Content -LiteralPath $teamFile -Raw)) -Encoding UTF8
            }
            return $copy
        }

        # Compiles a copy the way the runner does and returns the policy check for its node.
        function Test-Example {
            param([string]$Root)
            $policyPath = Resolve-CapabilityPolicyPath -ConfigurationPath $Root -Require
            $policy = Import-CapabilityPolicy -Path $policyPath -ConfigurationPath $Root
            Assert-DatumScriptBlockPolicy -ConfigurationPath $Root -Policy $policy

            $OutputPath = Join-Path $Root '_compiled'
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            $CapabilityPolicyPath = $policyPath
            Push-Location -LiteralPath $Root
            try {
                $Datum = New-DatumStructure -DefinitionFile 'Datum.yml'
                foreach ($ProjectType in $Datum.Projects.psobject.properties) {
                    foreach ($ProjectNode in $Datum.Projects."$($ProjectType.name)".psobject.properties) {
                        Resolve-DscDatumProject -NodeName $ProjectNode -AllNodes $Datum.Projects."$($ProjectType.name)"."$($ProjectNode.Name)"
                    }
                }
            }
            finally { Pop-Location }

            $compiledFile = Join-Path $OutputPath 'WebTeam.yml'
            $compiled = Get-Content -LiteralPath $compiledFile -Raw | ConvertFrom-Yaml
            $settings = Get-PipelineRunnerSetting -ConfigurationDirectory $Root
            $check = Get-RunPolicyViolation -Policy $policy -FilePath $compiledFile -Task @($compiled.resources) -DefaultTargetAction ([string]$settings['Target']) -Engine ([string]$settings['Engine'])
            return [pscustomobject]@{ Check = $check; Compiled = $compiled; Record = (Get-Content -LiteralPath (Join-Path $OutputPath 'WebTeam.provenance.json') -Raw | ConvertFrom-Json -AsHashtable) }
        }
    }

    It "Has its policy in Policy.yml beside Datum.yml" {
        Test-Path -LiteralPath (Join-Path $ExampleSource 'Datum.yml') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $ExampleSource 'Policy.yml') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $ExampleSource -Recurse -File -Filter 'Policy.y*ml').Count | Should -Be 1
    }

    It "Compiles and complies with its own policy as shipped" {
        $result = Test-Example -Root (New-ExampleCopy)
        $result.Check.Violations | Should -BeNullOrEmpty
        @($result.Compiled.resources).Count | Should -Be 4
    }

    It "Attributes its resources as the README's table says" {
        $record = (Test-Example -Root (New-ExampleCopy)).Record
        @($record.Resources['PSDscResources/Environment/Platform marker']) | Should -Be @('Platform')
        @($record.Resources['PSDscResources/Environment/Log level']) | Sort-Object | Should -Be @('Platform', 'Teams')
        @($record.Resources['PSDscResources/Environment/Site name']) | Should -Be @('Teams')
        @($record.Resources['PSDscResources/Environment/Site name on the web server']) | Should -Be @('Teams')
    }

    It "README change 1: refuses a Target the team may not use" {
        $root = New-ExampleCopy -ChangeTeamFile { param($text) $text -replace 'action: WinRM', 'action: SSH' }
        (Test-Example -Root $root).Check.Violations -join "`n" |
            Should -Match "\[PSDscResources/Environment/Site name on the web server\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
    }

    It "README change 2: refuses a team's copy of a platform resource that keeps its Target" {
        $root = New-ExampleCopy -ChangeTeamFile {
            param($text)
            $text + @'

  - name: Platform marker
    type: PSDscResources/Environment
    target:
      action: SSH
      computerName: bastion.contoso.example
    properties:
      Name: PLATFORM_BASELINE
      Value: taken over
      Ensure: Present
      Target:
        - Machine
'@
        }
        (Test-Example -Root $root).Check.Violations -join "`n" |
            Should -Match "\[PSDscResources/Environment/Platform marker\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
    }

    It "README change 3: refuses an execution script on a team's resource" {
        $root = New-ExampleCopy -ChangeTeamFile { param($text) $text -replace '(?m)^(  - name: Site name\r?\n)', "`$1    postExecutionScript: Write-Verbose hi`n" }
        (Test-Example -Root $root).Check.Violations -join "`n" |
            Should -Match "\[PSDscResources/Environment/Site name\] has an execution script, which is not allowed for layer\(s\) Teams"
    }

    It "README change 4: stops a team's Datum script block before anything is compiled" {
        $root = New-ExampleCopy -ChangeTeamFile { param($text) $text -replace 'SiteName: web-frontend', "SiteName: '[x={ Get-Date }=]'" }
        { Test-Example -Root $root } | Should -Throw "*'Projects/Present/WebTeam.yml' (layer Teams) contains a Datum script block*"
        Test-Path -LiteralPath (Join-Path $root '_compiled') | Should -BeFalse
    }
}
