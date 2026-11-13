Describe "Get-CompositeDefinition" -Tag Unit, Runner, Configuration, Composite {

    BeforeAll {
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName

        # Stands in for Datum's FileProvider: each file is a ScriptProperty returning the parsed
        # document, a sub-folder is a ScriptProperty returning another provider, and the class
        # carries its own ordinary properties alongside them.
        function New-FileProviderDouble {
            param([hashtable]$Files)
            $provider = [pscustomobject]@{}
            $provider.PSObject.Properties.Add([psnoteproperty]::new('Path', '/config/Composites'))
            foreach ($name in $Files.Keys) {
                $value = $Files[$name]
                $provider | Add-Member -MemberType ScriptProperty -Name $name -Value ({ $value }.GetNewClosure())
            }
            return $provider
        }
    }

    It "returns an empty table for a `$null Datum" {
        $result = Get-CompositeDefinition -Datum $null
        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It "returns an empty table when the Datum structure has no Composites store" {
        (Get-CompositeDefinition -Datum @{ Projects = @{} }).Count | Should -Be 0
        (Get-CompositeDefinition -Datum ([pscustomobject]@{ Projects = @{} })).Count | Should -Be 0
        (Get-CompositeDefinition -Datum @{ Composites = $null }).Count | Should -Be 0
    }

    It "reads every definition from a Datum-style store of ScriptProperty members" {
        $datum = @{
            Composites = New-FileProviderDouble -Files @{
                StandardProject = [ordered]@{ resources = @([ordered]@{ name = 'P'; type = 'Stub/P' }) }
                RepoSet         = [ordered]@{ resources = @() }
            }
        }

        $result = Get-CompositeDefinition -Datum $datum -WarningAction SilentlyContinue

        @($result.Keys | Sort-Object) | Should -Be @('RepoSet', 'StandardProject')
        $result['StandardProject']['resources'][0]['name'] | Should -Be 'P'
    }

    It "does not treat the provider's own properties as definitions" {
        $datum = @{ Composites = New-FileProviderDouble -Files @{ One = [ordered]@{ resources = @() } } }
        $warnings = @()
        $result = Get-CompositeDefinition -Datum $datum -WarningVariable warnings -WarningAction SilentlyContinue

        # 'Path' is a NoteProperty on the double, and a string - ignored with a warning, never a definition.
        $result.ContainsKey('Path') | Should -BeFalse
        $result.ContainsKey('One') | Should -BeTrue
    }

    It "looks definitions up case-insensitively" {
        $datum = @{ Composites = @{ StandardProject = [ordered]@{ resources = @() } } }
        $result = Get-CompositeDefinition -Datum $datum
        $result.ContainsKey('standardproject') | Should -BeTrue
    }

    It "accepts a PSCustomObject Datum and a dictionary store" {
        $datum = [pscustomobject]@{ Composites = [ordered]@{ Web = [ordered]@{ resources = @() } } }
        (Get-CompositeDefinition -Datum $datum).ContainsKey('Web') | Should -BeTrue
    }

    It "skips, with a warning, an entry that is not a definition (a sub-folder or a non-mapping file)" {
        $datum = @{
            Composites = New-FileProviderDouble -Files @{
                Archive = New-FileProviderDouble -Files @{ Old = [ordered]@{ resources = @() } }
                Notes   = 'just text'
                Real    = [ordered]@{ resources = @() }
            }
        }
        $warnings = @()
        $result = Get-CompositeDefinition -Datum $datum -WarningVariable warnings -WarningAction SilentlyContinue

        @($result.Keys) | Should -Be @('Real')
        ($warnings -join "`n") | Should -BeLike '*Composites/Archive is not a composite definition*'
        ($warnings -join "`n") | Should -BeLike '*Composites/Notes is not a composite definition*'
    }
}
