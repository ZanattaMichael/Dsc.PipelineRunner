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
        . (Get-FunctionPath 'Test-ResourceCapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Get-CapabilityPolicyCoverage.ps1').FullName
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
      Resources: [ '*' ]
      Credentials: [ '*' ]
      RemoteTargets: [ '*' ]
      ExecutionScripts: true
      DatumScriptBlocks: true
      Notify: true
      Reboot: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local, WinRM ]
      Engines: [ DscV2, DscV3 ]
      Resources: [ 'Stub/*' ]
      Credentials: [ Environment ]
      RemoteTargets: [ '*.app.example.test' ]
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

        It "Also refuses the machine that resource reaches, which is not in the team's RemoteTargets" {
            # Two separate capabilities on one resource: the mechanism (SSH) and the destination.
            # Either one is enough to refuse it, and a reader is told about both.
            $Violations | Should -Match "\[Stub/Thing/Shared\] uses the remote Target computer 'bastion.example.test', which is not allowed for layer\(s\) Teams"
        }

        It "Names the files of the layer that refused, read from the record the compile wrote" {
            $Violations | Should -Match 'layer Teams owns Projects/Present/App'
        }
    }

    Context "The capabilities a resource's own content decides" {

        # Each of these compiles a team file for real and checks the refusal against the record
        # Datum's own merge produced, rather than a record written by the test.
        BeforeAll {
            function Test-TeamFile {
                param([string] $TeamYaml)
                $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                New-ConfigurationTree -Root $root -Files @{
                    'Datum.yml'                = $script:DatumYaml
                    'Policy.yml'               = $script:PolicyYaml
                    'Baseline/Common.yml'      = $script:BaselineYaml
                    'Composites/Block.yml'     = $script:BlockYaml
                    'Projects/Present/App.yml' = $TeamYaml
                }
                $policyPath = Resolve-CapabilityPolicyPath -ConfigurationPath $root
                $policy = Import-CapabilityPolicy -Path $policyPath -ConfigurationPath $root
                Assert-DatumScriptBlockPolicy -ConfigurationPath $root -Policy $policy
                $output = Join-Path $root '_compiled'
                Invoke-PolicyCompile -ConfigurationRoot $root -OutputDirectory $output -PolicyPath $policyPath
                $compiledFile = Join-Path $output 'App.yml'
                $compiled = Get-Content -LiteralPath $compiledFile -Raw | ConvertFrom-Yaml
                return ((Get-RunPolicyViolation -Policy $policy -FilePath $compiledFile -Task @($compiled.resources) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n")
            }
        }

        It "Refuses a resource type the team may not declare" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Payload
    type: PSDesiredStateConfiguration/Script
    properties:
      GetScript: '{ @{} }'
'@ | Should -Match "\[PSDesiredStateConfiguration/Script/Payload\] is of the resource type 'PSDesiredStateConfiguration/Script', which is not allowed for layer\(s\) Teams"
        }

        It "Allows a resource type it may" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Team only
    type: Stub/Thing
    properties:
      Setting: team
'@ | Should -Not -Match '\[Stub/Thing/Team only\]'
        }

        It "Refuses a machine outside the team's RemoteTargets, on a Target it may use" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Team remote
    type: Stub/Thing
    target:
      action: WinRM
      computerName: dc01.corp.example.test
    properties:
      Setting: team
'@ | Should -Match "\[Stub/Thing/Team remote\] uses the remote Target computer 'dc01.corp.example.test', which is not allowed for layer\(s\) Teams"
        }

        It "Allows a machine inside them" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Team remote
    type: Stub/Thing
    target:
      action: WinRM
      computerName: web01.app.example.test
    properties:
      Setting: team
'@ | Should -Not -Match '\[Stub/Thing/Team remote\]'
        }

        It "Refuses a Credential action the team may not use, in either block" {
            $violations = Test-TeamFile -TeamYaml @'
resources:
  - name: Team vault
    type: Stub/Thing
    target:
      action: WinRM
      computerName: web01.app.example.test
      credential:
        action: SecretManagement
        Name: platform-secret
    properties:
      Setting: team
  - name: Team static
    type: Stub/Thing
    resourceCredential:
      action: Static
      UserName: dummy
      Password: dummy
    properties:
      Setting: team
'@
            $violations | Should -Match "\[Stub/Thing/Team vault\] resolves a credential through the 'SecretManagement' Credential action \(target.credential\)"
            $violations | Should -Match "\[Stub/Thing/Team static\] resolves a credential through the 'Static' Credential action \(resourceCredential\)"
        }

        It "Allows the Credential action it may" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Team env
    type: Stub/Thing
    resourceCredential:
      action: Environment
      UserNameVariable: TEAM_USER
      PasswordVariable: TEAM_PASSWORD
    properties:
      Setting: team
'@ | Should -Not -Match '\[Stub/Thing/Team env\]'
        }

        It "Refuses a team's notify, which would force a platform resource to re-apply itself" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Team nudge
    type: Stub/Thing
    notify:
      - Stub/Thing/Platform only
    properties:
      Setting: team
'@ | Should -Match '\[Stub/Thing/Team nudge\] notifies 1 resource\(s\) \(Stub/Thing/Platform only\), forcing them to re-run Set\(\)'
        }

        It "Does not refuse a team's dependsOn, which only orders what was going to run" {
            Test-TeamFile -TeamYaml @'
resources:
  - name: Team after
    type: Stub/Thing
    dependsOn:
      - Stub/Thing/Platform only
    properties:
      Setting: team
'@ | Should -Not -Match '\[Stub/Thing/Team after\]'
        }
    }

    Context "The policy is legible before it bites, against the same configuration" {

        BeforeAll {
            . (Get-FunctionPath 'Format-CapabilityPolicyReport.ps1').FullName
            . (Get-FunctionPath 'Get-PipelineRunnerSetting.ps1').FullName
            . (Get-FunctionPath 'Get-DscCapabilityPolicyReport.ps1').FullName
            $script:StaticReport = Get-DscCapabilityPolicyReport -ConfigurationPath $ConfigurationRoot
        }

        It "Agrees with the compile about which layer owns each precedence entry" {
            # The record is written from the merge; the report is written from the files. The two
            # have to say the same thing about the hierarchy or one of them is lying.
            @($StaticReport.ResolutionPrecedence).Count | Should -Be @($Record.Layers).Count
            for ($i = 0; $i -lt @($Record.Layers).Count; $i++) {
                $StaticReport.ResolutionPrecedence[$i].Layer | Should -Be $Record.Layers[$i].Layer
            }
        }

        It "Agrees with the compile about which layer declared each resource" {
            ($StaticReport.Resources | Where-Object Name -EQ 'Platform only').DeclaringLayers | Should -Be @('Platform')
            @(($StaticReport.Resources | Where-Object Name -EQ 'Shared' | Select-Object -First 1).DeclaringLayers) | Sort-Object | Should -Be @('Platform', 'Teams')
        }

        It "Finds the team's SSH resource without compiling anything" {
            $shared = @($StaticReport.Resources | Where-Object { $_.Name -eq 'Shared' -and $_.DeclaredIn -like 'Projects/*' })
            $shared.Count | Should -Be 1
            $shared[0].Allowed | Should -BeFalse
            ($shared[0].Refusals -join ' ') | Should -Match "the Target 'SSH'"
        }

        It "Compiles nothing: no output and no provenance record appear in the configuration" {
            @(Get-ChildItem -LiteralPath $ConfigurationRoot -Recurse -File -Filter '*.provenance.json').Count | Should -Be 0
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
        . (Get-FunctionPath 'Test-ResourceCapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Get-CapabilityPolicyCoverage.ps1').FullName
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
        # layers use any engine, any resource type and any remote computer: what it restricts is
        # what this suite is about, which is Targets and execution scripts.
        $script:RunPolicyYaml = @'
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'Baseline/**' ]
    Capabilities:
      Targets: [ '*' ]
      Engines: [ '*' ]
      Resources: [ '*' ]
      Credentials: [ '*' ]
      RemoteTargets: [ '*' ]
      ExecutionScripts: true
      Notify: true
      Reboot: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local ]
      Engines: [ '*' ]
      Resources: [ '*' ]
      Credentials: [ '*' ]
      RemoteTargets: [ '*' ]
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

        # The platform's resource writes its Target as an expression, and the team sets the
        # variable it names. The runner does not expand an expression in target.action, so this
        # cannot steer the resource anywhere; the suite pins that.
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
        $result.ErrorMessage | Should -Match 'Capability policy: 2 violation\(s\) in node ''App''; no resource was run'
        $result.ErrorMessage | Should -Match 'Policy: ' -Because 'a pipeline log shows this message on its own, so it has to say which policy refused'
        $result.ErrorMessage | Should -Match "\[Stub/Thing/Team over SSH\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
        $result.ErrorMessage | Should -Match 'layer Teams owns Projects/Present/App' -Because 'naming the layer is only half of it: a reader needs the files it owns'
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

    It "Does not let a team steer a platform resource's Target through a variable" {
        $result = Start-DscRunner -FilePath $SteeredFile -EngineAction (New-RecordingEngine -Calls $Calls) -Policy $SteeredPolicy -RunnerSettings @{ AllowExecutionScripts = $true } -ErrorAction SilentlyContinue
        # The file starts: an expression is not a Target name the pre-run check can judge ...
        $result.Status | Should -Not -Be 'AbortedByException'
        # ... and when the resource is reached the Target is still the unexpanded text, never the
        # 'SSH' the team's variable holds. It is refused, checked against every layer that
        # contributed to the node, without any Target being contacted ...
        $steered = $result.FailedResources | Where-Object InstanceName -EQ 'Platform thing'
        $steered | Should -Not -BeNullOrEmpty
        $steered.ErrorMessage | Should -Match 'Capability policy: resource \[Stub/Thing/Platform thing\] uses the Target'
        $steered.ErrorMessage | Should -Match 'which is not allowed for layer\(s\) Teams'
        $steered.ErrorMessage | Should -Not -Match "uses the Target 'SSH'"
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
        . (Get-FunctionPath 'Test-ResourceCapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Get-CapabilityPolicyCoverage.ps1').FullName
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

    It "README change 5: refuses a resource type the team may not declare" {
        $root = New-ExampleCopy -ChangeTeamFile { param($text) $text -replace '(?m)^(  - name: Site name\r?\n)    type: PSDscResources/Environment', "`$1    type: PSDesiredStateConfiguration/Script" }
        (Test-Example -Root $root).Check.Violations -join "`n" |
            Should -Match "\[PSDesiredStateConfiguration/Script/Site name\] is of the resource type 'PSDesiredStateConfiguration/Script', which is not allowed for layer\(s\) Teams"
    }

    It "README change 6: refuses another machine, on a Target the team may still use" {
        $root = New-ExampleCopy -ChangeTeamFile { param($text) $text -replace 'web01\.app\.contoso\.example', 'bastion.contoso.example' }
        $violations = (Test-Example -Root $root).Check.Violations -join "`n"
        $violations | Should -Match "uses the remote Target computer 'bastion.contoso.example', which is not allowed for layer\(s\) Teams"
        $violations | Should -Not -Match "uses the Target 'WinRM'" -Because 'the mechanism is still allowed; it is the destination that is not'
    }

    It "README change 7: refuses a Credential action the team may not use: <Action>" -ForEach @(
        @{ Action = 'SecretManagement' }, @{ Action = 'Static' }
    ) {
        $replacement = $Action
        $root = New-ExampleCopy -ChangeTeamFile { param($text) $text -replace '(?m)^(        action: )Environment$', ("`$1" + $replacement) }
        (Test-Example -Root $root).Check.Violations -join "`n" |
            Should -Match "resolves a credential through the '$replacement' Credential action \(target.credential\)"
    }

    It "README change 8: refuses a team's notify, which would force a platform resource to re-apply" {
        $root = New-ExampleCopy -ChangeTeamFile {
            param($text)
            $text -replace '(?m)^(  - name: Site name\r?\n)', "`$1    notify:`n      - PSDscResources/Environment/Log level`n"
        }
        (Test-Example -Root $root).Check.Violations -join "`n" |
            Should -Match '\[PSDscResources/Environment/Site name\] notifies 1 resource\(s\) \(PSDscResources/Environment/Log level\), forcing them to re-run Set\(\)'
    }

    It "Shows the same policy as a report, without compiling or running anything" {
        . (Get-FunctionPath 'Get-CapabilityPolicyCoverage.ps1').FullName
        . (Get-FunctionPath 'Format-CapabilityPolicyReport.ps1').FullName
        . (Get-FunctionPath 'Get-DscCapabilityPolicyReport.ps1').FullName
        $report = Get-DscCapabilityPolicyReport -ConfigurationPath $ExampleSource -RequirePolicy
        @($report.Findings | Where-Object Severity -EQ 'Error') | Should -BeNullOrEmpty
        @($report.Resources | Where-Object { -not $_.Allowed }) | Should -BeNullOrEmpty
        @($report.Layers).Count | Should -Be 2
        ($report.Layers | Where-Object Name -EQ 'Teams').Capabilities['Reboot'] | Should -Be 'Deny (not listed; from Default)'
    }
}

Describe "A real runner pass: the capabilities checked at the point of use (preview)" -Tag Integration, HostedIntegration {

    # The pre-run gate reads the compiled file; these are the checks the runner makes again with
    # the value it is really about to use, immediately before using it. Two of them can refuse
    # something the pre-run gate allowed:
    #
    #   * a computer reached through a Target action that was only knowable at run time, which is
    #     judged against every layer that contributed to the node;
    #   * a restart of a remote target, which nothing in the compiled file announces - the engine
    #     asks for it after Set() has already run.
    #
    # The rest is defence in depth: the task object the gate inspected is the one the resource
    # runs from, and a module-resident pipeline rule runs between the two.

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
        . (Get-FunctionPath 'Test-ResourceCapabilityPolicy.ps1').FullName
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

        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $separator = [System.IO.Path]::DirectorySeparatorChar
        $script:UseDatumYaml = @"
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

        # Both layers may use any Target, so the Target check never masks the ones under test.
        # What the teams may not do is reach outside their own subnet, use the platform's vault,
        # or have a machine restarted.
        $script:UsePolicyYaml = @'
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'Baseline/**' ]
    Capabilities:
      Targets: [ '*' ]
      Engines: [ '*' ]
      Resources: [ '*' ]
      Credentials: [ '*' ]
      RemoteTargets: [ '*' ]
      Reboot: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ '*' ]
      Engines: [ '*' ]
      Resources: [ '*' ]
      Credentials: [ Environment ]
      RemoteTargets: [ '*.app.example.test' ]
'@

        function New-UseNode {
            param([string] $TeamYaml, [string] $BaselineYaml)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $files = @{
                'Datum.yml'                = $script:UseDatumYaml
                'Policy.yml'               = $script:UsePolicyYaml
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
            $script:UsePolicy = Import-CapabilityPolicy -Path $CapabilityPolicyPath -ConfigurationPath $root
            Assert-DatumScriptBlockPolicy -ConfigurationPath $root -Policy $script:UsePolicy
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

        # An engine that records the methods it was asked for. -Calls must be a PARAMETER:
        # GetNewClosure() captures the local scope's variables only, so a scriptblock literal
        # written inside an It captures nothing and $Calls - which BeforeEach sets in a parent
        # scope - reads as $null inside the closure. Same shape as New-RecordingEngine above.
        function New-UseEngine {
            param(
                [System.Collections.Generic.List[object]] $Calls,
                # Reports drift on Test and asks for a reboot after Set, as a resource that needs
                # a restart to finish does.
                [switch] $RebootAfterSet
            )
            if ($RebootAfterSet) {
                return {
                    param($Context)
                    $Calls.Add([string]$Context.Method)
                    return @{ InDesiredState = ($Context.Method -eq 'Get'); Message = 'drift'; RebootRequired = ($Context.Method -eq 'Set') }
                }.GetNewClosure()
            }
            return {
                param($Context)
                $Calls.Add([string]$Context.Method)
                return @{ InDesiredState = $true; Message = 'ok' }
            }.GetNewClosure()
        }

        $plainTeamYaml = @'
resources:
  - name: Team thing
    type: Stub/Thing
    properties:
      Setting: team
'@

        # The platform's resource names its Target with an expression and the team sets the
        # variable. The runner never expands anything in a 'target' block, so the action stays
        # that literal text - but the computer beside it is a real host name, and at the point of
        # use it is judged against the team's RemoteTargets as well as the platform's.
        $script:SteeredComputerFile = New-UseNode -BaselineYaml @'
variables:
  Hop: Local
resources:
  - name: Platform thing
    type: Stub/Thing
    target:
      action: $(variables('Hop'))
      computerName: dc01.corp.example.test
    properties:
      Setting: platform
'@ -TeamYaml @'
variables:
  Hop: WinRM
resources:
  - name: Team thing
    type: Stub/Thing
    properties:
      Setting: team
'@
        $script:SteeredComputerPolicy = $script:UsePolicy

        $script:TeamVaultFile = New-UseNode -BaselineYaml @'
resources: []
'@ -TeamYaml @'
resources:
  - name: Team thing
    type: Stub/Thing
    target:
      action: WinRM
      computerName: web01.app.example.test
      credential:
        action: SecretManagement
        Name: platform-secret
    properties:
      Setting: team
'@
        $script:TeamVaultPolicy = $script:UsePolicy

        $script:TeamRebootFile = New-UseNode -BaselineYaml @'
resources: []
'@ -TeamYaml @'
resources:
  - name: Team thing
    type: Stub/Thing
    target:
      action: WinRM
      computerName: web01.app.example.test
    properties:
      Setting: team
'@
        $script:TeamRebootPolicy = $script:UsePolicy

        $script:PlatformRebootFile = New-UseNode -TeamYaml $plainTeamYaml -BaselineYaml @'
resources:
  - name: Platform thing
    type: Stub/Thing
    target:
      action: WinRM
      computerName: dc01.corp.example.test
    properties:
      Setting: platform
'@
        $script:PlatformRebootPolicy = $script:UsePolicy

        # --- Runner stand-ins. Compiling is finished, so Datum's own calls are unaffected.
        Mock -CommandName Get-Module -ParameterFilter { $Name -eq 'Dsc.PipelineRunner' } -MockWith { return @{ ModuleBase = $Global:RepositoryRoot } }
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information
        Mock -CommandName Invoke-CustomTask -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks, [Parameter(Mandatory = $true)] [String]$CustomTaskName)
            return $Tasks
        }
        Mock -CommandName Invoke-PreParseRules
        Mock -CommandName Invoke-FormatTasks -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) return $Tasks }
        # A Target action hands back a remote session; a Credential action hands back a dummy
        # credential. Both record that they were reached, which for a refused resource they must
        # not be.
        Mock -CommandName Invoke-Action -ParameterFilter { $Hook -eq 'Target' } -MockWith {
            return [pscustomobject]@{ IsRemote = $true; ComputerName = [string]$Context.ComputerName; PSSession = $null }
        }
        Mock -CommandName Invoke-Action -ParameterFilter { $Hook -eq 'Credential' } -MockWith {
            return [System.Management.Automation.PSCredential]::new('dummy', (ConvertTo-SecureString 'dummy' -AsPlainText -Force))
        }
        # Nothing in this suite may restart anything; the mock is how that is proved.
        Mock -CommandName Restart-Computer
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
        $script:Calls = [System.Collections.Generic.List[object]]::new()
    }

    It "Refuses the machine a run-time Target would have reached, against every contributing layer" {
        $result = Start-DscRunner -FilePath $SteeredComputerFile -EngineAction (New-UseEngine -Calls $Calls) -Policy $SteeredComputerPolicy -ErrorAction SilentlyContinue
        # The file starts: the pre-run gate judged the computer against the platform, which may
        # reach anything.
        $result.Status | Should -Not -Be 'AbortedByException'
        $refused = $result.FailedResources | Where-Object InstanceName -EQ 'Platform thing'
        $refused | Should -Not -BeNullOrEmpty
        $refused.ErrorMessage | Should -Match "uses the remote Target computer 'dc01.corp.example.test'"
        $refused.ErrorMessage | Should -Match 'which is not allowed for layer\(s\) Teams'
        Should -Invoke Invoke-Action -Times 0 -ParameterFilter { $Hook -eq 'Target' }
        # ... and the rest of the file still runs.
        $result.PassCount | Should -Be 1
    }

    It "Stops a file whose Credential action the layer may not use, before any vault is reached" {
        $result = Start-DscRunner -FilePath $TeamVaultFile -EngineAction (New-UseEngine -Calls $Calls) -Policy $TeamVaultPolicy -ErrorAction SilentlyContinue
        $result.Status | Should -Be 'AbortedByException'
        $result.ErrorMessage | Should -Match "resolves a credential through the 'SecretManagement' Credential action \(target.credential\)"
        $Calls.Count | Should -Be 0
        Should -Invoke Invoke-Action -Times 0 -ParameterFilter { $Hook -eq 'Credential' }
    }

    It "Does not restart a remote target for a layer without the Reboot capability" {
        # Nothing in the compiled file says a restart will be wanted: the engine asks for one
        # after Set() has run, so this is the only place it can be refused.
        $result = Start-DscRunner -FilePath $TeamRebootFile -Mode Set -EngineAction (New-UseEngine -Calls $Calls -RebootAfterSet) -Policy $TeamRebootPolicy -ErrorAction SilentlyContinue
        $refused = $result.FailedResources | Where-Object InstanceName -EQ 'Team thing'
        $refused | Should -Not -BeNullOrEmpty
        $refused.ErrorMessage | Should -Match 'uses a restart of its remote Target, which is not allowed for layer\(s\) Teams'
        $refused.ErrorMessage | Should -Match 'has already been applied' -Because 'the operator has to know the machine is mid-change'
        Should -Invoke Restart-Computer -Times 0
        $Calls | Should -Contain 'Set' -Because 'the Set itself was allowed; only the restart was not'
    }

    It "Restarts it for a layer that has the capability" {
        $result = Start-DscRunner -FilePath $PlatformRebootFile -Mode Set -EngineAction (New-UseEngine -Calls $Calls -RebootAfterSet) -Policy $PlatformRebootPolicy -ErrorAction SilentlyContinue
        ($result.FailedResources | Where-Object InstanceName -EQ 'Platform thing') | Should -BeNullOrEmpty
        Should -Invoke Restart-Computer -Times 1 -ParameterFilter { $ComputerName -eq 'dc01.corp.example.test' }
    }

    It "Restarts it as it always has when no policy is supplied" {
        $null = Start-DscRunner -FilePath $TeamRebootFile -Mode Set -EngineAction (New-UseEngine -Calls $Calls -RebootAfterSet) -ErrorAction SilentlyContinue
        Should -Invoke Restart-Computer -Times 1 -ParameterFilter { $ComputerName -eq 'web01.app.example.test' }
    }
}
