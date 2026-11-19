<#
Security regression suite: the capability policy (preview, issue #86 Part B).

A capability policy lets the pipeline's owner say what each layer of a configuration may use, so
several teams can contribute configuration without each being fully trusted. These tests pin the
properties that make it worth having:

  * the policy is a file of its own beside Datum.yml (Policy.yml), outside the Datum hierarchy, so
    no layer can merge into it or override it; a policy file in a sub-folder of the configuration
    (a layer) is refused; and a policy that cannot be read exactly is an error, never a guess;
  * a layer is decided by where a file is, never by what the file says about itself;
  * a file no layer claims has no capabilities, whatever the policy's Default;
  * least privilege: what several layers contributed to is allowed only if every one of them is;
  * a Datum script block in a layer that may not use one stops the compile before Datum loads it;
  * a file that breaks the policy does not start, and every violation is named in one pass;
  * a Target written as an expression is checked when it is known, against every layer that
    could have supplied its value;
  * a missing provenance record, or one from another policy, fails closed;
  * what a resource may *be* is governed too: a resource type, the machine a remote Target may
    reach, the Credential actions a layer may resolve, a 'notify' that forces another layer's
    resource to re-apply, and restarting a remote target - each denied by default under
    Default: Deny, each named in the violation together with the layer and the files it owns;
  * the report (Get-DscCapabilityPolicyReport) describes the policy without compiling anything,
    and finds the ways a policy ends up quietly ineffective.

Dummy values only.
#>
Describe "Security: capability policy (preview)" -Tag Unit, Security {

    BeforeAll {
        Import-Module -Name 'powershell-yaml' -ErrorAction Stop

        . (Get-FunctionPath 'Import-CapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Resolve-CapabilityPolicyPath.ps1').FullName
        . (Get-FunctionPath 'Get-PolicyLayer.ps1').FullName
        . (Get-FunctionPath 'Test-PolicyCapability.ps1').FullName
        . (Get-FunctionPath 'Assert-DatumScriptBlockPolicy.ps1').FullName
        . (Get-FunctionPath 'Test-ResourceCapabilityPolicy.ps1').FullName
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName
        . (Get-FunctionPath 'Get-CapabilityPolicyCoverage.ps1').FullName
        . (Get-FunctionPath 'Format-CapabilityPolicyReport.ps1').FullName
        . (Get-FunctionPath 'Get-PipelineRunnerSetting.ps1').FullName
        . (Get-FunctionPath 'Get-DscCapabilityPolicyReport.ps1').FullName

        $script:PolicyYaml = @'
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'OrganizationPolicies/**', 'Composites/**' ]
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
      Resources: [ 'M/*' ]
      Credentials: [ Environment ]
      RemoteTargets: [ '*.contoso.example' ]
'@

        function New-PolicyFile {
            param([string] $Content = $script:PolicyYaml)
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.policy.yml')
            Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
            return $path
        }

        # A compiled file with its provenance record, as the compile step leaves them.
        function New-CompiledFile {
            param([hashtable] $Resources, [string[]] $ContributingLayers = @('Platform', 'Teams'), [string] $Sha256 = $script:Policy.Sha256)
            $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $directory
            if ($null -ne $Resources) {
                @{
                    SchemaVersion      = '1.0'
                    PolicySha256       = $Sha256
                    ContributingLayers = $ContributingLayers
                    # As the compile writes it: each precedence entry with the layer it mapped to.
                    # A violation message names the files of the layer that refused, so a reader
                    # knows where to look without opening the record.
                    Layers             = @(
                        @{ Path = 'Projects/Present/App'; Layer = 'Teams' }
                        @{ Path = 'OrganizationPolicies/Organization'; Layer = 'Platform' }
                    )
                    Resources          = $Resources
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'Node.provenance.json')
            }
            return (Join-Path $directory 'Node.yml')
        }

        $script:Policy = Import-CapabilityPolicy -Path (New-PolicyFile)
    }

    Context "Where the policy lives: its own file beside Datum.yml, never merged" {

        BeforeEach {
            $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Join-Path $Root 'Projects/Present') -Force
            Set-Content -LiteralPath (Join-Path $Root 'Datum.yml') -Value 'ResolutionPrecedence: []'
        }

        It "Finds Policy.yml at the root of the configuration without being told" {
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value $PolicyYaml
            Resolve-CapabilityPolicyPath -ConfigurationPath $Root | Should -Be (Join-Path $Root 'Policy.yml')
        }

        It "Also accepts the .yaml spelling" {
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yaml') -Value $PolicyYaml
            Resolve-CapabilityPolicyPath -ConfigurationPath $Root | Should -Be (Join-Path $Root 'Policy.yaml')
        }

        It "Reports no policy when the configuration has none" {
            Resolve-CapabilityPolicyPath -ConfigurationPath $Root | Should -BeNullOrEmpty
        }

        It "Does not pick up a Policy.yml that a layer put in its own folder" {
            Set-Content -LiteralPath (Join-Path $Root 'Projects/Policy.yml') -Value $PolicyYaml
            Set-Content -LiteralPath (Join-Path $Root 'Projects/Present/Policy.yml') -Value $PolicyYaml
            Resolve-CapabilityPolicyPath -ConfigurationPath $Root | Should -BeNullOrEmpty
        }

        It "Lets a policy the pipeline names win over the one in the configuration" {
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value $PolicyYaml
            $external = New-PolicyFile
            Resolve-CapabilityPolicyPath -ConfigurationPath $Root -PolicyPath $external | Should -Be $external
        }

        It "Fails when a policy is required and there is none" {
            { Resolve-CapabilityPolicyPath -ConfigurationPath $Root -Require } | Should -Throw '*A policy is required*'
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value $PolicyYaml
            { Resolve-CapabilityPolicyPath -ConfigurationPath $Root -Require } | Should -Not -Throw
        }

        It "Fails for a named policy file that does not exist, instead of falling back" {
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value $PolicyYaml
            { Resolve-CapabilityPolicyPath -ConfigurationPath $Root -PolicyPath (Join-Path $TestDrive 'missing.yml') } | Should -Throw '*does not exist*'
        }

        It "Loads the policy from the root of the configuration" {
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value $PolicyYaml
            (Import-CapabilityPolicy -Path (Join-Path $Root 'Policy.yml') -ConfigurationPath $Root).Layers.Count | Should -Be 2
        }

        It "Refuses a policy file in a sub-folder of the configuration: <Folder>" -ForEach @(
            @{ Folder = 'Projects' }, @{ Folder = 'Projects/Present' }
        ) {
            $inside = Join-Path $Root "$Folder/Policy.yml"
            Set-Content -LiteralPath $inside -Value $PolicyYaml
            { Import-CapabilityPolicy -Path $inside -ConfigurationPath $Root } | Should -Throw '*sub-folder of the configuration*'
        }

        It "Does not treat the policy file as a layer file when looking for script blocks" {
            # Datum never loads a root file, so the marker in a comment of Policy.yml is not a violation.
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value ($PolicyYaml + "`n# a layer without DatumScriptBlocks may not write [x={ ... }=]")
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Root -Policy $Policy } | Should -Not -Throw
        }

        It "Still checks a file named Policy.yml inside a layer's folder" {
            Set-Content -LiteralPath (Join-Path $Root 'Projects/Present/Policy.yml') -Value "v: '[x={ 1 }=]'"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Root -Policy $Policy } | Should -Throw '*Projects/Present/Policy.yml*'
        }

        It "Refuses a Datum.yml that declares a store for the policy file, which would let it be merged" {
            Set-Content -LiteralPath (Join-Path $Root 'Policy.yml') -Value $PolicyYaml
            Set-Content -LiteralPath (Join-Path $Root 'Datum.yml') -Value "ResolutionPrecedence: [ Policy ]`nDatumStructure:`n  - StoreName: Policy`n    StoreProvider: Datum::File`n    StoreOptions:`n      Path: ./Policy.yml"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Root -Policy $Policy } | Should -Throw '*must stay outside the Datum hierarchy*'
        }
    }

    Context "The policy file is read exactly or not at all" {

        It "Loads a valid policy" {
            $Policy.Default | Should -Be 'Deny'
            $Policy.Layers.Count | Should -Be 2
            $Policy.Layers[0].Name | Should -Be 'Platform'
            $Policy.Layers[1].Capabilities['Targets'] | Should -Be @('Local', 'WinRM')
            $Policy.Sha256 | Should -Match '^[0-9a-f]{64}$'
        }

        It "Accepts a policy file kept outside the configuration altogether" {
            $configuration = Join-Path $TestDrive 'config-beside'
            $null = New-Item -ItemType Directory -Path $configuration -Force
            { Import-CapabilityPolicy -Path (New-PolicyFile) -ConfigurationPath $configuration } | Should -Not -Throw
        }

        It "Rejects <Why>" -ForEach @(
            @{ Why = 'an unknown top-level key';        Yaml = "PolicyVersion: 1`nDefault: Deny`nAllowEverything: true`nLayers:`n  - Name: A`n    Paths: [ '*' ]"; Message = '*Unknown key*' }
            @{ Why = 'a version it does not understand'; Yaml = "PolicyVersion: 2`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '*' ]"; Message = '*PolicyVersion must be 1*' }
            @{ Why = 'a missing Default';                Yaml = "PolicyVersion: 1`nLayers:`n  - Name: A`n    Paths: [ '*' ]"; Message = '*Default must be Deny or Allow*' }
            @{ Why = 'a misspelt Default';               Yaml = "PolicyVersion: 1`nDefault: Permit`nLayers:`n  - Name: A`n    Paths: [ '*' ]"; Message = '*Default must be Deny or Allow*' }
            @{ Why = 'no layers';                        Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers: []"; Message = '*Layers must be a non-empty list*' }
            @{ Why = 'a layer with an unknown key';      Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Trusted: true"; Message = '*unknown key*' }
            @{ Why = 'an unknown capability';            Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      Everything: true"; Message = "*unknown capability 'Everything'*" }
            @{ Why = 'a list capability given as a flag'; Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      Targets: { any: true }"; Message = '*Targets must be a list*' }
            @{ Why = 'a flag capability given as text';  Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      ExecutionScripts: 'yes'"; Message = '*ExecutionScripts must be true or false*' }
            @{ Why = 'two layers with one name';         Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ 'x/*' ]`n  - Name: a`n    Paths: [ 'y/*' ]"; Message = '*used more than once*' }
            @{ Why = 'a path pattern that climbs out';   Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '../*' ]"; Message = "*no '..'*" }
            @{ Why = 'a layer with no paths';            Yaml = "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: []"; Message = '*Paths must be a non-empty list*' }
            @{ Why = 'a file that is not a mapping';     Yaml = "- just`n- a list"; Message = '*must be a mapping*' }
        ) {
            { Import-CapabilityPolicy -Path (New-PolicyFile -Content $Yaml) } | Should -Throw $Message
        }

        It "Fails for a policy file that does not exist" {
            { Import-CapabilityPolicy -Path (Join-Path $TestDrive 'no-such-policy.yml') } | Should -Throw '*does not exist*'
        }

        It "Gives a different fingerprint to a different policy" {
            $other = Import-CapabilityPolicy -Path (New-PolicyFile -Content ($PolicyYaml -replace 'Local, WinRM', 'Local, WinRM, SSH'))
            $other.Sha256 | Should -Not -Be $Policy.Sha256
        }
    }

    Context "A layer is decided by where a file is" {

        It "Maps <Path> to <Layer>" -ForEach @(
            @{ Path = 'Datum.yml'; Layer = 'Platform' }
            @{ Path = 'OrganizationPolicies/Organization'; Layer = 'Platform' }
            @{ Path = 'OrganizationPolicies\Groups\Admins'; Layer = 'Platform' }
            @{ Path = 'organizationpolicies/organization'; Layer = 'Platform' }
            @{ Path = 'Composites/StandardProject'; Layer = 'Platform' }
            @{ Path = 'Projects/Present/Magenta'; Layer = 'Teams' }
            @{ Path = 'Projects\Absent\Blue'; Layer = 'Teams' }
            @{ Path = 'SomewhereElse/File'; Layer = '(unclaimed)' }
            @{ Path = 'ProjectsButNot/File'; Layer = '(unclaimed)' }
        ) {
            Get-PolicyLayer -Policy $Policy -RelativePath $Path | Should -Be $Layer
        }

        It "Gives a path that climbs out of the configuration to nobody: <Path>" -ForEach @(
            @{ Path = '../OrganizationPolicies/Organization' }
            @{ Path = 'Projects/../OrganizationPolicies/Organization' }
            @{ Path = 'Projects\..\OrganizationPolicies\Organization' }
            @{ Path = '' }
        ) {
            Get-PolicyLayer -Policy $Policy -RelativePath $Path | Should -Be '(unclaimed)'
        }

        It "Uses the first matching layer, in the order the policy lists them" {
            $overlapping = Import-CapabilityPolicy -Path (New-PolicyFile -Content "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: Narrow`n    Paths: [ 'Projects/Special/*' ]`n  - Name: Wide`n    Paths: [ 'Projects/**' ]")
            Get-PolicyLayer -Policy $overlapping -RelativePath 'Projects/Special/One' | Should -Be 'Narrow'
            Get-PolicyLayer -Policy $overlapping -RelativePath 'Projects/Other/One' | Should -Be 'Wide'
        }
    }

    Context "Least privilege" {

        It "Allows what every contributing layer is allowed" {
            (Test-PolicyCapability -Policy $Policy -Layer 'Platform', 'Teams' -Capability Targets -Value 'WinRM').Allowed | Should -BeTrue
            (Test-PolicyCapability -Policy $Policy -Layer 'Platform' -Capability Targets -Value 'SSH').Allowed | Should -BeTrue
        }

        It "Denies a resource a lower layer touched what only the higher layer may do" {
            $decision = Test-PolicyCapability -Policy $Policy -Layer 'Platform', 'Teams' -Capability Targets -Value 'SSH'
            $decision.Allowed | Should -BeFalse
            $decision.DeniedBy | Should -Be @('Teams')
        }

        It "Matches names without regard to case, and honours wildcards" {
            (Test-PolicyCapability -Policy $Policy -Layer 'Teams' -Capability Targets -Value 'winrm').Allowed | Should -BeTrue
            (Test-PolicyCapability -Policy $Policy -Layer 'Teams' -Capability Engines -Value 'DscV9').Allowed | Should -BeFalse
            (Test-PolicyCapability -Policy $Policy -Layer 'Platform' -Capability Engines -Value 'Anything').Allowed | Should -BeTrue
        }

        It "Falls back to Default for a capability a layer does not list" {
            (Test-PolicyCapability -Policy $Policy -Layer 'Teams' -Capability ExecutionScripts).Allowed | Should -BeFalse
            $allowByDefault = Import-CapabilityPolicy -Path (New-PolicyFile -Content ($PolicyYaml -replace 'Default: Deny', 'Default: Allow'))
            (Test-PolicyCapability -Policy $allowByDefault -Layer 'Teams' -Capability ExecutionScripts).Allowed | Should -BeTrue
        }

        It "Lets a listed rule win over Default: Allow" {
            $allowByDefault = Import-CapabilityPolicy -Path (New-PolicyFile -Content ($PolicyYaml -replace 'Default: Deny', 'Default: Allow'))
            (Test-PolicyCapability -Policy $allowByDefault -Layer 'Teams' -Capability Targets -Value 'SSH').Allowed | Should -BeFalse
        }

        It "Denies the unclaimed layer everything, even with Default: Allow" {
            $allowByDefault = Import-CapabilityPolicy -Path (New-PolicyFile -Content ($PolicyYaml -replace 'Default: Deny', 'Default: Allow'))
            (Test-PolicyCapability -Policy $allowByDefault -Layer '(unclaimed)' -Capability Targets -Value 'Local').Allowed | Should -BeFalse
            (Test-PolicyCapability -Policy $allowByDefault -Layer 'Platform', '(unclaimed)' -Capability Targets -Value 'Local').Allowed | Should -BeFalse
        }

        It "Denies what cannot be attributed to any layer" {
            (Test-PolicyCapability -Policy $Policy -Layer @() -Capability Targets -Value 'Local').Allowed | Should -BeFalse
            (Test-PolicyCapability -Policy $Policy -Layer 'NoSuchLayer' -Capability Targets -Value 'Local').Allowed | Should -BeFalse
        }

        It "Treats an empty list as allowing nothing" {
            $none = Import-CapabilityPolicy -Path (New-PolicyFile -Content "PolicyVersion: 1`nDefault: Allow`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      Targets: []")
            (Test-PolicyCapability -Policy $none -Layer 'A' -Capability Targets -Value 'Local').Allowed | Should -BeFalse
        }
    }

    Context "Datum script blocks are stopped before Datum loads them" {

        BeforeEach {
            $script:Configuration = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($folder in 'Projects/Present', 'OrganizationPolicies', 'Loose') { $null = New-Item -ItemType Directory -Path (Join-Path $Configuration $folder) -Force }
            Set-Content -LiteralPath (Join-Path $Configuration 'Datum.yml') -Value 'ResolutionPrecedence: []'
        }

        It "Allows a script block in a layer that has the capability" {
            Set-Content -LiteralPath (Join-Path $Configuration 'OrganizationPolicies/Organization.yml') -Value "variables:`n  Now: '[x={ Get-Date }=]'"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Configuration -Policy $Policy } | Should -Not -Throw
        }

        It "Stops a script block in a layer that does not, naming the file and the layer" {
            Set-Content -LiteralPath (Join-Path $Configuration 'Projects/Present/App.yml') -Value "variables:`n  Pwned: '[x={ Remove-Item -Recurse / }=]'"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Configuration -Policy $Policy } | Should -Throw "*'Projects/Present/App.yml' (layer Teams)*"
        }

        It "Stops a script block in a file no layer claims" {
            Set-Content -LiteralPath (Join-Path $Configuration 'Loose/Anything.yaml') -Value "v: '[x={ 1 }=]'"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Configuration -Policy $Policy } | Should -Throw "*(layer (unclaimed))*"
        }

        It "Reports every offending file in one pass" {
            Set-Content -LiteralPath (Join-Path $Configuration 'Projects/Present/One.yml') -Value "v: '[x={ 1 }=]'"
            Set-Content -LiteralPath (Join-Path $Configuration 'Projects/Present/Two.json') -Value '{ "v": "[x={ 2 }=]" }'
            $message = $null
            try { Assert-DatumScriptBlockPolicy -ConfigurationPath $Configuration -Policy $Policy } catch { $message = $_.Exception.Message }
            $message | Should -Match '2 violation\(s\)'
            $message | Should -Match 'One\.yml'
            $message | Should -Match 'Two\.json'
        }

        It "Is not dodged by YAML that hides the marker from a parser: <Why>" -ForEach @(
            @{ Why = 'a folded scalar'; Content = "v: >-`n  [x={ 1 }=]" }
            @{ Why = 'a comment-looking key'; Content = "'[x={ 1 }=]': value" }
            @{ Why = 'a nested list'; Content = "a:`n  - b:`n      - '[x={ 1 }=]'" }
        ) {
            Set-Content -LiteralPath (Join-Path $Configuration 'Projects/Present/Hidden.yml') -Value $Content
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Configuration -Policy $Policy } | Should -Throw '*Hidden.yml*'
        }

        It "Passes a configuration with no script blocks at all" {
            Set-Content -LiteralPath (Join-Path $Configuration 'Projects/Present/App.yml') -Value "variables:`n  Plain: text"
            { Assert-DatumScriptBlockPolicy -ConfigurationPath $Configuration -Policy $Policy } | Should -Not -Throw
        }
    }

    Context "A file that breaks the policy does not start" {

        It "Passes a file that complies" {
            $file = New-CompiledFile -Resources @{ 'M/R/Platform only' = @('Platform'); 'M/R/Shared' = @('Platform', 'Teams') }
            $tasks = @(
                @{ type = 'M/R'; name = 'Platform only'; target = @{ action = 'SSH'; computerName = 'bastion.contoso.example' }; preExecutionScript = 'Write-Verbose hi' }
                @{ type = 'M/R'; name = 'Shared'; target = @{ action = 'WinRM'; computerName = 'web01.contoso.example' } }
            )
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task $tasks -DefaultTargetAction 'Local' -Engine 'DscV2').Violations | Should -BeNullOrEmpty
        }

        It "Names every violation in one pass" {
            $file = New-CompiledFile -Resources @{ 'M/R/Shared' = @('Platform', 'Teams'); 'M/R/Team' = @('Teams') }
            $tasks = @(
                @{ type = 'M/R'; name = 'Shared'; target = @{ action = 'SSH'; computerName = 'web01.contoso.example' } }
                @{ type = 'M/R'; name = 'Team'; postExecutionScript = 'Stop-TaskProcessing' }
            )
            $violations = (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task $tasks -DefaultTargetAction 'Local' -Engine 'Custom').Violations
            $violations.Count | Should -Be 3
            ($violations -join "`n") | Should -Match "engine 'Custom' is not allowed for layer\(s\) Teams"
            ($violations -join "`n") | Should -Match "\[M/R/Shared\] uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
            ($violations -join "`n") | Should -Match "\[M/R/Team\] has an execution script"
        }

        It "Checks the file's default Target for a resource that names none" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            $tasks = @(@{ type = 'M/R'; name = 'Team' })
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task $tasks -DefaultTargetAction 'SSH' -Engine 'DscV2').Violations | Should -Match "Target 'SSH'"
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task $tasks -DefaultTargetAction 'Local' -Engine 'DscV2').Violations | Should -BeNullOrEmpty
        }

        It "Treats an inline engine script block as an engine of its own" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team' }) -DefaultTargetAction 'Local' -Engine 'DscV2' -HasEngineAction).Violations |
                Should -Match 'inline engine script block'
        }

        It "Gives a resource that is in the file but not in the record no capabilities" {
            $file = New-CompiledFile -Resources @{ 'M/R/Known' = @('Platform') }
            $violations = (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Smuggled' }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations
            ($violations -join "`n") | Should -Match "\[M/R/Smuggled\] uses the Target 'Local', which is not allowed for layer\(s\) \(unclaimed\)"
        }

        It "Fails closed without a provenance record" {
            $file = New-CompiledFile -Resources $null
            $result = Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @() -DefaultTargetAction 'Local' -Engine 'DscV2'
            $result.Violations | Should -Match 'There is no provenance record'
            $result.Provenance | Should -BeNullOrEmpty
        }

        It "Fails closed on a provenance record written under another policy" {
            $file = New-CompiledFile -Resources @{ 'M/R/A' = @('Platform') } -Sha256 ('0' * 64)
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @() -DefaultTargetAction 'Local' -Engine 'DscV2').Violations | Should -Match 'different policy'
        }

        It "Fails closed on a provenance record that cannot be read" {
            $file = New-CompiledFile -Resources $null
            Set-Content -LiteralPath ($file -replace '\.yml$', '.provenance.json') -Value '{ this is not json'
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @() -DefaultTargetAction 'Local' -Engine 'DscV2').Violations | Should -Match 'cannot be read'
        }
    }

    Context "A Target written as an expression is checked when it is known" {

        BeforeAll {
            $script:ExpressionFile = New-CompiledFile -Resources @{ 'M/R/Platform resource' = @('Platform') } -ContributingLayers 'Platform', 'Teams'
            $script:ExpressionTasks = @(@{ type = 'M/R'; name = 'Platform resource'; target = @{ action = '$(variables(''TargetAction''))'; computerName = 'bastion.contoso.example' } })
            $script:ExpressionCheck = Get-RunPolicyViolation -Policy $Policy -FilePath $ExpressionFile -Task $ExpressionTasks -DefaultTargetAction 'Local' -Engine 'DscV2'
        }

        It "Does not guess before the run: it records the resource for the point-of-use check" {
            $ExpressionCheck.Violations | Should -BeNullOrEmpty
            $ExpressionCheck.ExpressionTargets.Keys | Should -Be @('M/R/Platform resource')
        }

        It "Then checks the resolved value against every layer that could have supplied it" {
            # The resource is the platform's, but a team's variable may have decided the Target.
            Test-ResourceTargetPolicy -Policy $Policy -Provenance $ExpressionCheck.Provenance -ResourceKey 'M/R/Platform resource' -TargetAction 'SSH' -FromExpression |
                Should -Match "uses the Target 'SSH', which is not allowed for layer\(s\) Teams"
            Test-ResourceTargetPolicy -Policy $Policy -Provenance $ExpressionCheck.Provenance -ResourceKey 'M/R/Platform resource' -TargetAction 'WinRM' -FromExpression |
                Should -BeNullOrEmpty
        }

        It "Checks a literal Target at the point of use against the resource's own layers" {
            Test-ResourceTargetPolicy -Policy $Policy -Provenance $ExpressionCheck.Provenance -ResourceKey 'M/R/Platform resource' -TargetAction 'SSH' | Should -BeNullOrEmpty
            Test-ResourceTargetPolicy -Policy $Policy -Provenance $ExpressionCheck.Provenance -ResourceKey 'M/R/Not in the record' -TargetAction 'Local' | Should -Match '\(unclaimed\)'
        }
    }

    Context "What a resource may be: the Resources capability" {

        It "Allows a resource type the layer lists" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team' }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }

        It "Refuses a resource type the layer does not, naming the type, the layer and the layer's files" {
            # A Script resource is arbitrary code: a layer that could declare one would not be
            # constrained by the Target, Credential or script capabilities at all.
            $file = New-CompiledFile -Resources @{ 'PSDesiredStateConfiguration/Script/Payload' = @('Teams') }
            $violations = (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'PSDesiredStateConfiguration/Script'; name = 'Payload' }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n"
            $violations | Should -Match "is of the resource type 'PSDesiredStateConfiguration/Script', which is not allowed for layer\(s\) Teams"
            $violations | Should -Match 'layer Teams owns Projects/Present/App'
        }

        It "Holds a resource several layers contributed to to the narrower list" {
            $file = New-CompiledFile -Resources @{ 'Other/Thing/Shared' = @('Platform', 'Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'Other/Thing'; name = 'Shared' }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n" |
                Should -Match "resource type 'Other/Thing', which is not allowed for layer\(s\) Teams"
        }

        It "Refuses every resource of a layer that has no Resources rule under Default: Deny" {
            $narrow = Import-CapabilityPolicy -Path (New-PolicyFile -Content "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: Teams`n    Paths: [ 'Projects/**' ]`n    Capabilities:`n      Targets: [ Local ]")
            (Test-PolicyCapability -Policy $narrow -Layer 'Teams' -Capability Resources -Value 'M/R').Allowed | Should -BeFalse
        }

        It "Refuses a Resources pattern that is not a resource type, instead of silently allowing nothing" {
            # 'PSDscResources' matches no 'Module/Resource' type, so a policy written that way
            # would deny everything while reading as though it allowed a module.
            { Import-CapabilityPolicy -Path (New-PolicyFile -Content "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      Resources: [ PSDscResources ]") } |
                Should -Throw "*does not name a resource type*"
        }
    }

    Context "Which machine a layer may reach: the RemoteTargets capability" {

        It "Allows a computer the layer's patterns cover" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; target = @{ action = 'WinRM'; computerName = 'web01.contoso.example' } }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }

        It "Refuses a computer outside them, even on a Target the layer may use" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; target = @{ action = 'WinRM'; computerName = 'dc01.corp.example' } }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n" |
                Should -Match "uses the remote Target computer 'dc01.corp.example', which is not allowed for layer\(s\) Teams"
        }

        It "Does not judge a Local Target against it" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; target = @{ action = 'Local' } }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }

        It "Refuses a non-Local Target that names no computer at all" {
            # There is nothing for the policy to allow, and the built-in Target actions refuse it
            # too; saying so here means the reason names the policy rather than the connection.
            $file = New-CompiledFile -Resources @{ 'M/R/Platform only' = @('Platform') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Platform only'; target = @{ action = 'SSH' } }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n" |
                Should -Match 'uses a remote Target with no computerName'
        }

        It "Checks the computer even when the Target action is an expression" {
            # The action is not knowable before the run; the computer is, and it is literal text
            # either way - the runner never expands anything inside a 'target' block.
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            $check = Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; target = @{ action = '$(variables(''Hop''))'; computerName = 'dc01.corp.example' } }) -DefaultTargetAction 'Local' -Engine 'DscV2'
            $check.ExpressionTargets.Keys | Should -Be @('M/R/Team')
            ($check.Violations -join "`n") | Should -Match "uses the remote Target computer 'dc01.corp.example'"
            ($check.Violations -join "`n") | Should -Not -Match 'uses the Target'
        }

        It "Allows no computer at all for a layer with an empty RemoteTargets list" {
            $none = Import-CapabilityPolicy -Path (New-PolicyFile -Content "PolicyVersion: 1`nDefault: Allow`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      RemoteTargets: []")
            (Test-PolicyCapability -Policy $none -Layer 'A' -Capability RemoteTargets -Value 'anything.example').Allowed | Should -BeFalse
        }

        It "Never matches an empty computer name, not even against '*'" {
            (Test-PolicyCapability -Policy $Policy -Layer 'Platform' -Capability RemoteTargets -Value '').Allowed | Should -BeFalse
        }
    }

    Context "Which credentials a layer may resolve: the Credentials capability" {

        It "Allows the Credential action the layer lists, in either block" {
            $file = New-CompiledFile -Resources @{ 'M/R/A' = @('Teams'); 'M/R/B' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(
                    @{ type = 'M/R'; name = 'A'; target = @{ action = 'WinRM'; computerName = 'web01.contoso.example'; credential = @{ action = 'Environment' } } }
                    @{ type = 'M/R'; name = 'B'; resourceCredential = @{ action = 'Environment'; UserNameVariable = 'U' } }
                ) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations | Should -BeNullOrEmpty
        }

        It "Refuses a Credential action the layer does not, and says which block asked for it" {
            $file = New-CompiledFile -Resources @{ 'M/R/A' = @('Teams'); 'M/R/B' = @('Teams') }
            $violations = (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(
                    @{ type = 'M/R'; name = 'A'; target = @{ action = 'WinRM'; computerName = 'web01.contoso.example'; credential = @{ action = 'SecretManagement'; Name = 'platform' } } }
                    @{ type = 'M/R'; name = 'B'; resourceCredential = @{ action = 'Static'; UserName = 'u'; Password = 'dummy' } }
                ) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n"
            $violations | Should -Match "resolves a credential through the 'SecretManagement' Credential action \(target.credential\)"
            $violations | Should -Match "resolves a credential through the 'Static' Credential action \(resourceCredential\)"
        }

        It "Treats a credential block with no action as the 'Environment' default, which is what the runner does" {
            $file = New-CompiledFile -Resources @{ 'M/R/B' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'B'; resourceCredential = @{ UserNameVariable = 'U' } }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }

        It "Lets a layer use no credential at all" {
            $none = Import-CapabilityPolicy -Path (New-PolicyFile -Content "PolicyVersion: 1`nDefault: Allow`nLayers:`n  - Name: A`n    Paths: [ '*' ]`n    Capabilities:`n      Credentials: []")
            (Test-PolicyCapability -Policy $none -Layer 'A' -Capability Credentials -Value 'Environment').Allowed | Should -BeFalse
        }
    }

    Context "Forcing another resource to re-apply: the Notify capability" {

        It "Refuses a notify from a layer that does not have it, naming what would be forced" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; notify = @('M/R/Platform only') }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations -join "`n" |
                Should -Match 'notifies 1 resource\(s\) \(M/R/Platform only\), forcing them to re-run Set\(\)'
        }

        It "Allows a notify from a layer that has it" {
            $file = New-CompiledFile -Resources @{ 'M/R/Platform only' = @('Platform') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Platform only'; notify = @('M/R/Team') }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }

        It "Does not restrict dependsOn, which only orders resources that were going to run" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; dependsOn = @('M/R/Platform only') }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }

        It "Ignores an empty notify list" {
            $file = New-CompiledFile -Resources @{ 'M/R/Team' = @('Teams') }
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task @(@{ type = 'M/R'; name = 'Team'; notify = @() }) -DefaultTargetAction 'Local' -Engine 'DscV2').Violations |
                Should -BeNullOrEmpty
        }
    }

    Context "The point-of-use gate for every capability it guards" {

        BeforeAll {
            $script:PointOfUse = @{
                Resources          = @{ 'M/R/Platform resource' = @('Platform'); 'M/R/Team resource' = @('Teams') }
                ContributingLayers = @('Platform', 'Teams')
                Layers             = @(@{ Path = 'Projects/Present/App'; Layer = 'Teams' })
            }
        }

        It "Refuses <Capability> at the point of use for a layer that may not use it" -ForEach @(
            @{ Capability = 'RemoteTargets'; Value = 'dc01.corp.example'; Subject = 'the remote Target computer'; Match = "uses the remote Target computer 'dc01.corp.example'" }
            @{ Capability = 'Credentials'; Value = 'Static'; Subject = 'the Credential action'; Match = "uses the Credential action 'Static'" }
            @{ Capability = 'Reboot'; Value = $null; Subject = 'a restart of its remote Target'; Match = 'uses a restart of its remote Target' }
        ) {
            $arguments = @{ Policy = $Policy; Provenance = $PointOfUse; ResourceKey = 'M/R/Team resource'; Capability = $Capability; Subject = $Subject }
            if ($null -ne $Value) { $arguments.Value = $Value }
            $message = Test-ResourceCapabilityPolicy @arguments
            $message | Should -Match $Match
            $message | Should -Match 'which is not allowed for layer\(s\) Teams'
            $message | Should -Match 'layer Teams owns Projects/Present/App'
        }

        It "Allows the same thing for a layer that may" {
            Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $PointOfUse -ResourceKey 'M/R/Platform resource' -Capability Reboot | Should -BeNullOrEmpty
            Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $PointOfUse -ResourceKey 'M/R/Platform resource' -Capability Credentials -Value 'SecretManagement' | Should -BeNullOrEmpty
        }

        It "Widens to every contributing layer for a value that came from an expression" {
            # The resource is the platform's, but any layer's variable could have decided a value
            # the pre-run check could not read.
            Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $PointOfUse -ResourceKey 'M/R/Platform resource' -Capability RemoteTargets -Value 'dc01.corp.example' |
                Should -BeNullOrEmpty
            Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $PointOfUse -ResourceKey 'M/R/Platform resource' -Capability RemoteTargets -Value 'dc01.corp.example' -FromExpression |
                Should -Match 'not allowed for layer\(s\) Teams'
        }

        It "Gives a resource that is not in the record no capabilities" {
            Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $PointOfUse -ResourceKey 'M/R/Smuggled' -Capability Reboot | Should -Match '\(unclaimed\)'
        }
    }

    Context "The policy is legible before it bites: Get-DscCapabilityPolicyReport" {

        BeforeAll {
            # A configuration with one thing wrong in each category the report is meant to find.
            $script:ReportRoot = Join-Path $TestDrive 'report-config'
            foreach ($folder in 'OrganizationPolicies', 'Projects/Present', 'Loose') {
                $null = New-Item -ItemType Directory -Path (Join-Path $ReportRoot $folder) -Force
            }
            Set-Content -LiteralPath (Join-Path $ReportRoot 'Datum.yml') -Value "ResolutionPrecedence:`n  - Projects/`$(`$Node.ProjectPresence)/`$(`$Node.Project)`n  - OrganizationPolicies/Organization`nPipelineRunnerSettings:`n  Target: Local"
            Set-Content -LiteralPath (Join-Path $ReportRoot 'Policy.yml') -Value $PolicyYaml
            Set-Content -LiteralPath (Join-Path $ReportRoot 'OrganizationPolicies/Organization.yml') -Value "resources:`n  - name: Platform only`n    type: M/R`n    target:`n      action: SSH`n      computerName: bastion.contoso.example`n    properties:`n      Setting: platform"
            Set-Content -LiteralPath (Join-Path $ReportRoot 'Projects/Present/App.yml') -Value "resources:`n  - name: Team payload`n    type: PSDesiredStateConfiguration/Script`n    properties:`n      Setting: team"
            Set-Content -LiteralPath (Join-Path $ReportRoot 'Loose/Stray.yml') -Value 'resources: []'

            $script:Report = Get-DscCapabilityPolicyReport -ConfigurationPath $ReportRoot
        }

        It "Names the policy it read and its fingerprint" {
            $Report.PolicyPath | Should -Be (Join-Path $ReportRoot 'Policy.yml')
            $Report.PolicySha256 | Should -Match '^[0-9a-f]{64}$'
            $Report.Default | Should -Be 'Deny'
        }

        It "Shows the effective rule for a capability a layer does not list, not a blank" {
            $teams = $Report.Layers | Where-Object Name -EQ 'Teams'
            $teams.Capabilities['Notify'] | Should -Be 'Deny (not listed; from Default)'
            $teams.Capabilities['ExecutionScripts'] | Should -Be 'Deny (not listed; from Default)'
            $teams.Capabilities['Targets'] | Should -Be 'Local, WinRM'
            ($Report.Layers | Where-Object Name -EQ 'Platform').Capabilities['Reboot'] | Should -Be 'Allow'
        }

        It "Maps each file to its layer, and leaves the policy file out of the mapping" {
            $byFile = @{}
            foreach ($file in $Report.Files) { $byFile[$file.File] = $file.Layer }
            $byFile['Datum.yml'] | Should -Be 'Platform'
            $byFile['OrganizationPolicies/Organization.yml'] | Should -Be 'Platform'
            $byFile['Projects/Present/App.yml'] | Should -Be 'Teams'
            $byFile['Loose/Stray.yml'] | Should -Be '(unclaimed)'
            $byFile.ContainsKey('Policy.yml') | Should -BeFalse
        }

        It "Maps each ResolutionPrecedence entry to its layer, placeholders and all" {
            @($Report.ResolutionPrecedence).Count | Should -Be 2
            $Report.ResolutionPrecedence[0].Layer | Should -Be 'Teams'
            $Report.ResolutionPrecedence[1].Layer | Should -Be 'Platform'
        }

        It "Judges each resource declaration against the layers that declare it" {
            ($Report.Resources | Where-Object Name -EQ 'Platform only').Allowed | Should -BeTrue
            $refused = $Report.Resources | Where-Object Name -EQ 'Team payload'
            $refused.Allowed | Should -BeFalse
            ($refused.Refusals -join ' ') | Should -Match "resource type 'PSDesiredStateConfiguration/Script'"
        }

        It "Reports a file no layer claims as an error" {
            $Report.HasError | Should -BeTrue
            @($Report.Findings | Where-Object Code -EQ 'UnclaimedFile').Message | Should -Match 'Loose/Stray.yml'
        }

        It "Reports a refused declaration as an error" {
            @($Report.Findings | Where-Object Code -EQ 'DeclarationRefused').Message | Should -Match 'Team payload'
        }

        It "Says which layer owns the definition file, because that layer controls the merge" {
            @($Report.Findings | Where-Object Code -EQ 'DefinitionFileOwner').Message | Should -Match "layer 'Platform'"
        }

        It "Warns about a layer whose Paths match no file: the one way a policy is silently ineffective" {
            $typo = Join-Path $TestDrive 'typo-config'
            $null = New-Item -ItemType Directory -Path (Join-Path $typo 'Projects') -Force
            Set-Content -LiteralPath (Join-Path $typo 'Datum.yml') -Value 'ResolutionPrecedence: []'
            Set-Content -LiteralPath (Join-Path $typo 'Policy.yml') -Value "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: Platform`n    Paths: [ 'Platfrom/**' ]`n    Capabilities:`n      Resources: [ '*' ]`n  - Name: Teams`n    Paths: [ 'Projects/**' ]`n    Capabilities:`n      Resources: [ '*' ]"
            Set-Content -LiteralPath (Join-Path $typo 'Projects/App.yml') -Value 'resources: []'
            $finding = @((Get-DscCapabilityPolicyReport -ConfigurationPath $typo).Findings | Where-Object Code -EQ 'LayerMatchesNothing')
            $finding.Count | Should -Be 1
            $finding[0].Message | Should -Match "Layer 'Platform' matches no file"
        }

        It "Warns about a layer that may use a remote Target but may reach no computer" {
            $odd = Join-Path $TestDrive 'no-computer-config'
            $null = New-Item -ItemType Directory -Path (Join-Path $odd 'Projects') -Force
            Set-Content -LiteralPath (Join-Path $odd 'Datum.yml') -Value 'ResolutionPrecedence: []'
            Set-Content -LiteralPath (Join-Path $odd 'Policy.yml') -Value "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: Teams`n    Paths: [ 'Projects/**' ]`n    Capabilities:`n      Targets: [ Local, WinRM ]`n      Resources: [ '*' ]"
            Set-Content -LiteralPath (Join-Path $odd 'Projects/App.yml') -Value 'resources: []'
            @((Get-DscCapabilityPolicyReport -ConfigurationPath $odd).Findings | Where-Object Code -EQ 'RemoteTargetWithoutComputer').Count | Should -Be 1
        }

        It "Warns about a layer that owns files but may declare no resource type" {
            $odd = Join-Path $TestDrive 'no-resources-config'
            $null = New-Item -ItemType Directory -Path (Join-Path $odd 'Projects') -Force
            Set-Content -LiteralPath (Join-Path $odd 'Datum.yml') -Value 'ResolutionPrecedence: []'
            Set-Content -LiteralPath (Join-Path $odd 'Policy.yml') -Value "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: Teams`n    Paths: [ 'Projects/**' ]`n    Capabilities:`n      Targets: [ Local ]"
            Set-Content -LiteralPath (Join-Path $odd 'Projects/App.yml') -Value 'resources: []'
            @((Get-DscCapabilityPolicyReport -ConfigurationPath $odd).Findings | Where-Object Code -EQ 'LayerDeclaresNothing').Count | Should -Be 1
        }

        It "Warns about Default: Allow" {
            $permissive = Join-Path $TestDrive 'permissive-config'
            $null = New-Item -ItemType Directory -Path (Join-Path $permissive 'Projects/Present') -Force
            Set-Content -LiteralPath (Join-Path $permissive 'Datum.yml') -Value 'ResolutionPrecedence: []'
            Set-Content -LiteralPath (Join-Path $permissive 'Policy.yml') -Value ($PolicyYaml -replace 'Default: Deny', 'Default: Allow')
            @((Get-DscCapabilityPolicyReport -ConfigurationPath $permissive).Findings | Where-Object Code -EQ 'DefaultAllow').Count | Should -Be 1
        }

        It "Reports the same refusal the compile would make for a Datum script block, without compiling" {
            $blocky = Join-Path $TestDrive 'block-config'
            $null = New-Item -ItemType Directory -Path (Join-Path $blocky 'Projects/Present') -Force
            Set-Content -LiteralPath (Join-Path $blocky 'Datum.yml') -Value 'ResolutionPrecedence: []'
            Set-Content -LiteralPath (Join-Path $blocky 'Policy.yml') -Value $PolicyYaml
            Set-Content -LiteralPath (Join-Path $blocky 'Projects/Present/App.yml') -Value "variables:`n  Sneaky: '[x={ Get-Date }=]'"
            $finding = @((Get-DscCapabilityPolicyReport -ConfigurationPath $blocky).Findings | Where-Object Code -EQ 'PreCompileRefusal')
            $finding.Count | Should -Be 1
            $finding[0].Message | Should -Match 'contains a Datum script block'
        }

        It "Reports a configuration with no policy as having none, and does not call that an error" {
            $bare = Join-Path $TestDrive 'bare-config'
            $null = New-Item -ItemType Directory -Path $bare -Force
            $bareReport = Get-DscCapabilityPolicyReport -ConfigurationPath $bare
            $bareReport.PolicyPath | Should -BeNullOrEmpty
            $bareReport.HasError | Should -BeFalse
            @($bareReport.Findings | Where-Object Code -EQ 'NoPolicy').Count | Should -Be 1
        }

        It "Still fails when a policy is required and there is none" {
            $bare = Join-Path $TestDrive 'bare-required-config'
            $null = New-Item -ItemType Directory -Path $bare -Force
            { Get-DscCapabilityPolicyReport -ConfigurationPath $bare -RequirePolicy } | Should -Throw '*A policy is required*'
        }

        It "Renders as text for a person, with the capabilities and the findings in it" {
            $text = Get-DscCapabilityPolicyReport -ConfigurationPath $ReportRoot -AsText
            $joined = $text -join "`n"
            $joined | Should -Match 'What the policy permits'
            $joined | Should -Match 'Deny \(not listed; from Default\)'
            $joined | Should -Match 'Findings'
            $joined | Should -Match 'REFUSED'
            $joined | Should -Match 'does not perform Datum''s merge'
        }

        It "Reads nothing and writes nothing outside the configuration: no compile, no output files" {
            $before = @(Get-ChildItem -LiteralPath $ReportRoot -Recurse -File).Count
            $null = Get-DscCapabilityPolicyReport -ConfigurationPath $ReportRoot
            @(Get-ChildItem -LiteralPath $ReportRoot -Recurse -File).Count | Should -Be $before
        }
    }

    Context "The shipped example is its own regression test" {

        It "Has a policy whose layers all match files, and no refused declaration" {
            $report = Get-DscCapabilityPolicyReport -ConfigurationPath (Join-Path $Global:RepositoryRoot 'Example Policy Configuration') -RequirePolicy
            @($report.Findings | Where-Object Severity -EQ 'Error') | Should -BeNullOrEmpty
            @($report.Resources | Where-Object { -not $_.Allowed }) | Should -BeNullOrEmpty
            $report.Default | Should -Be 'Deny'
        }

        It "Grants every capability explicitly to the platform, so a new capability is a deliberate choice" {
            $report = Get-DscCapabilityPolicyReport -ConfigurationPath (Join-Path $Global:RepositoryRoot 'Example Policy Configuration')
            $platform = $report.Layers | Where-Object Name -EQ 'Platform'
            foreach ($capability in $platform.Capabilities.Keys) {
                $platform.Capabilities[$capability] | Should -Not -Match 'from Default' -Because "the example's most trusted layer should list $capability explicitly"
            }
        }
    }
}
