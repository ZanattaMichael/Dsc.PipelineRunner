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

        # The team's node file. It changes 'Shared', adds a resource and instantiates a platform
        # composite. It also tries to claim a higher layer by writing stamps of its own.
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
        $script:PolicyPath = Join-Path $TestDrive 'policy.yml'
        Set-Content -LiteralPath $PolicyPath -Value $policyYaml -Encoding UTF8

        New-ConfigurationTree -Root $ConfigurationRoot -Files @{
            'Datum.yml'                = $datumYaml
            'Baseline/Common.yml'      = $baselineYaml
            'Composites/Block.yml'     = $blockYaml
            'Projects/Present/App.yml' = $appYaml
        }

        $script:Policy = Import-CapabilityPolicy -Path $PolicyPath -ConfigurationPath $ConfigurationRoot
        Invoke-PolicyCompile -ConfigurationRoot $ConfigurationRoot -OutputDirectory $CompiledDirectory -PolicyPath $PolicyPath

        $script:CompiledFile = Join-Path $CompiledDirectory 'App.yml'
        $script:RecordFile = Join-Path $CompiledDirectory 'App.provenance.json'
        $script:Record = if (Test-Path -LiteralPath $RecordFile) { Get-Content -LiteralPath $RecordFile -Raw | ConvertFrom-Json -AsHashtable }
        $script:Compiled = Get-Content -LiteralPath $CompiledFile -Raw | ConvertFrom-Yaml
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
            $Compiled.resources.name | Should -Contain 'Member' -Because 'the composite must have been expanded'
            $memberKey = $Record.Resources.Keys | Where-Object { $_ -like 'Stub/Thing/*Member*' } | Select-Object -First 1
            $memberKey | Should -Not -BeNullOrEmpty
            @($Record.Resources[$memberKey]) | Sort-Object | Should -Be @('Platform', 'Teams')
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

        It "Refuses that Target on the resource the team changed: least privilege" {
            $Violations | Should -Match "\[Stub/Thing/Shared\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
        }

        It "Lets the team's resources and the composite member use the default Target" {
            $Violations | Should -Not -Match '\[Stub/Thing/Team only\]'
            $Violations | Should -Not -Match 'Member'
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

        It "Refuses a policy file placed inside the configuration" {
            $inside = Join-Path $ConfigurationRoot 'Projects/policy.yml'
            Copy-Item -LiteralPath $PolicyPath -Destination $inside
            try { { Import-CapabilityPolicy -Path $inside -ConfigurationPath $ConfigurationRoot } | Should -Throw '*inside the configuration directory*' }
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
