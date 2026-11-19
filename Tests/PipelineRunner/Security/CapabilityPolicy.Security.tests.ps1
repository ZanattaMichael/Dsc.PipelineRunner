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
  * a missing provenance record, or one from another policy, fails closed - which is also what
    stops a passthrough document (#106), which has no layers, from ever half-enforcing a policy.

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
        . (Get-FunctionPath 'Get-RunPolicyViolation.ps1').FullName

        $script:PolicyYaml = @'
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'OrganizationPolicies/**', 'Composites/**' ]
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
                @{ SchemaVersion = '1.0'; PolicySha256 = $Sha256; ContributingLayers = $ContributingLayers; Resources = $Resources } |
                    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'Node.provenance.json')
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
                @{ type = 'M/R'; name = 'Platform only'; target = @{ action = 'SSH' }; preExecutionScript = 'Write-Verbose hi' }
                @{ type = 'M/R'; name = 'Shared'; target = @{ action = 'WinRM' } }
            )
            (Get-RunPolicyViolation -Policy $Policy -FilePath $file -Task $tasks -DefaultTargetAction 'Local' -Engine 'DscV2').Violations | Should -BeNullOrEmpty
        }

        It "Names every violation in one pass" {
            $file = New-CompiledFile -Resources @{ 'M/R/Shared' = @('Platform', 'Teams'); 'M/R/Team' = @('Teams') }
            $tasks = @(
                @{ type = 'M/R'; name = 'Shared'; target = @{ action = 'SSH' } }
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
            $script:ExpressionTasks = @(@{ type = 'M/R'; name = 'Platform resource'; target = @{ action = '$(variables(''TargetAction''))' } })
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

    Context "A passthrough document cannot half-enforce a policy (#106)" {

        # Invoke-DscRunner refuses -PolicyPath / -RequirePolicy for a passthrough configuration
        # outright (see Public/Invoke-DscRunner.tests.ps1). This is the second line of defence:
        # a document the compile never saw has no provenance record, so even a policy handed
        # straight to the run stops it rather than enforcing nothing in particular.

        It "Refuses a document with resources but no provenance record, naming the reason" {
            $handWritten = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.yml')
            Set-Content -LiteralPath $handWritten -Value 'resources: []' -Encoding UTF8

            $result = Get-RunPolicyViolation -Policy $Policy -FilePath $handWritten `
                -Task @(@{ type = 'M/R'; name = 'Passthrough resource'; target = @{ action = 'Local' } }) `
                -DefaultTargetAction 'Local' -Engine 'DscV2'

            $result.Violations | Should -Match 'There is no provenance record'
            ($result.Violations -join "`n") | Should -Match 'compiled with the same policy'
            $result.Provenance | Should -BeNullOrEmpty
        }

        It "Does not let a document supply its own layers by writing a provenance record beside itself" {
            # The record is written by the compile under a named policy and keyed to that policy's
            # hash. One written by anything else is rejected, so a passthrough author cannot
            # declare their document to be the most privileged layer.
            $handWritten = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.yml')
            Set-Content -LiteralPath $handWritten -Value 'resources: []' -Encoding UTF8
            $forged = @{
                SchemaVersion      = '1.0'
                PolicySha256       = ('f' * 64)
                SettingsLayer      = 'Platform'
                Layers             = @()
                ContributingLayers = @('Platform')
                Resources          = @{ 'M/R/Passthrough resource' = @('Platform') }
            }
            Set-Content -LiteralPath ($handWritten -replace '\.yml$', '.provenance.json') -Value ($forged | ConvertTo-Json -Depth 6) -Encoding UTF8

            $result = Get-RunPolicyViolation -Policy $Policy -FilePath $handWritten `
                -Task @(@{ type = 'M/R'; name = 'Passthrough resource'; target = @{ action = 'SSH' } }) `
                -DefaultTargetAction 'Local' -Engine 'DscV2'

            $result.Violations | Should -Match 'different policy'
            $result.Provenance | Should -BeNullOrEmpty
        }
    }
}
