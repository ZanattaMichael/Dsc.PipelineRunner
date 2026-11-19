Describe "Resolve-PassthroughPolicyContext Function Tests" -Tag Unit, Runner {

    # This decides whether a passthrough run is refused as governed (#106), so the cases that
    # matter are structural: where the two files sit relative to the document.

    BeforeAll {
        . (Get-FunctionPath 'Resolve-PassthroughPolicyContext.ps1').FullName

        function New-Dir {
            param([string] $Path)
            $null = [System.IO.Directory]::CreateDirectory($Path)
            return $Path
        }
        function New-File {
            param([string] $Path, [string] $Content = 'x')
            [System.IO.File]::WriteAllText($Path, $Content)
            return $Path
        }
        function New-Root {
            # A fresh, isolated root per case: the walk goes upward, so cases must not see each
            # other's definition files.
            return (New-Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))))
        }
    }

    Context "A governed configuration behind the document" {

        It "finds the two files at the configuration root when the document is two levels below" {
            # The documented layout: Datum.yml and Policy.yml at the root, node files under
            # Projects/<presence>/.
            $root = New-Root
            $null = New-File (Join-Path $root 'Datum.yml')
            $null = New-File (Join-Path $root 'Policy.yml')
            $nodeDir = New-Dir ([System.IO.Path]::Combine($root, 'Projects', 'Present'))
            $node = New-File ([System.IO.Path]::Combine($nodeDir, 'Magenta.yml'))

            $context = Resolve-PassthroughPolicyContext -ConfigurationFile @($node)

            $context.GovernedRoot | Should -Be $root
            $context.GovernedDatumPath | Should -Be (Join-Path $root 'Datum.yml')
            $context.GovernedPolicyPath | Should -Be (Join-Path $root 'Policy.yml')
        }

        It "finds them when the document sits at the configuration root itself" {
            $root = New-Root
            $null = New-File (Join-Path $root 'Datum.yml')
            $null = New-File (Join-Path $root 'Policy.yml')
            $node = New-File (Join-Path $root 'node.yml')

            (Resolve-PassthroughPolicyContext -ConfigurationFile @($node)).GovernedRoot | Should -Be $root
        }

        It "finds them for compiled output written inside the configuration it came from" {
            $root = New-Root
            $null = New-File (Join-Path $root 'Datum.yml')
            $null = New-File (Join-Path $root 'Policy.yml')
            $cache = New-Dir (Join-Path $root 'cache')
            $node = New-File (Join-Path $cache 'Magenta.yml')

            (Resolve-PassthroughPolicyContext -ConfigurationFile @($node)).GovernedRoot | Should -Be $root
        }

        It "recognises the .yaml spelling of both files" {
            $root = New-Root
            $null = New-File (Join-Path $root 'Datum.yaml')
            $null = New-File (Join-Path $root 'Policy.yaml')
            $node = New-File (Join-Path $root 'node.yml')

            (Resolve-PassthroughPolicyContext -ConfigurationFile @($node)).GovernedRoot | Should -Be $root
        }

        It "takes the strictest answer across several documents: one governed refuses the run" {
            $governed = New-Root
            $null = New-File (Join-Path $governed 'Datum.yml')
            $null = New-File (Join-Path $governed 'Policy.yml')
            $governedNode = New-File (Join-Path $governed 'node.yml')
            $plain = New-Root
            $plainNode = New-File (Join-Path $plain 'node.yml')

            (Resolve-PassthroughPolicyContext -ConfigurationFile @($plainNode, $governedNode)).GovernedRoot |
                Should -Be $governed
        }

        It "reads a path whose directory name contains wildcard characters" {
            $root = New-Dir ([System.IO.Path]::Combine((New-Root), 'has[bracket]'))
            $null = New-File ([System.IO.Path]::Combine($root, 'Datum.yml'))
            $null = New-File ([System.IO.Path]::Combine($root, 'Policy.yml'))
            $node = New-File ([System.IO.Path]::Combine($root, 'node.yml'))

            (Resolve-PassthroughPolicyContext -ConfigurationFile @($node)).GovernedRoot | Should -Be $root
        }
    }

    Context "Not governed" {

        It "reports a configuration root with no policy beside it, without calling it governed" {
            $root = New-Root
            $null = New-File (Join-Path $root 'Datum.yml')
            $node = New-File (Join-Path $root 'node.yml')

            $context = Resolve-PassthroughPolicyContext -ConfigurationFile @($node)

            $context.GovernedRoot | Should -BeNullOrEmpty
            $context.DatumRoot | Should -Be $root
        }

        It "does not count a policy in a sub-folder, which a constrained layer could have written" {
            # Resolve-CapabilityPolicyPath accepts a policy only beside Datum.yml, for this reason.
            $root = New-Root
            $null = New-File (Join-Path $root 'Datum.yml')
            $sub = New-Dir (Join-Path $root 'Projects')
            $null = New-File (Join-Path $sub 'Policy.yml')
            $node = New-File (Join-Path $sub 'node.yml')

            $context = Resolve-PassthroughPolicyContext -ConfigurationFile @($node)

            $context.GovernedRoot | Should -BeNullOrEmpty
            $context.DatumRoot | Should -Be $root
        }

        It "reports a bare output directory as clean" {
            $root = New-Root
            $node = New-File (Join-Path $root 'SRV-01.yml')

            $context = Resolve-PassthroughPolicyContext -ConfigurationFile @($node)

            $context.GovernedRoot | Should -BeNullOrEmpty
            $context.DatumRoot | Should -BeNullOrEmpty
            $context.StrayPolicyPath | Should -BeNullOrEmpty
        }
    }

    Context "The ambiguous case: a policy with no configuration above it" {

        It "reports a stray policy for a warning rather than as governed" {
            $root = New-Root
            $policy = New-File (Join-Path $root 'Policy.yml')
            $node = New-File (Join-Path $root 'SRV-01.yml')

            $context = Resolve-PassthroughPolicyContext -ConfigurationFile @($node)

            $context.GovernedRoot | Should -BeNullOrEmpty
            $context.StrayPolicyPath | Should -Be $policy
        }
    }

    Context "Nothing to look at" {

        It "is clean for <Case>" -ForEach @(
            @{ Case = 'no documents';      Files = @() }
            @{ Case = 'a null list';       Files = $null }
            @{ Case = 'an empty path';     Files = @('') }
            @{ Case = 'a whitespace path'; Files = @('   ') }
        ) {
            $context = Resolve-PassthroughPolicyContext -ConfigurationFile $Files

            $context.GovernedRoot | Should -BeNullOrEmpty
            $context.DatumRoot | Should -BeNullOrEmpty
            $context.StrayPolicyPath | Should -BeNullOrEmpty
        }
    }
}
