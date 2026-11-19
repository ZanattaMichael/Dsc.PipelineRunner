Describe "Resolve-PassthroughConfiguration Function Tests" -Tag Unit, Runner {

    BeforeAll {
        . (Get-FunctionPath 'Resolve-PassthroughConfiguration.ps1').FullName

        # Real files on disk: the function deliberately asks the file system directly rather
        # than going through Test-Path / Get-ChildItem, so there is nothing to mock.
        $script:docDir = Join-Path $TestDrive 'documents'
        $null = New-Item -Path $script:docDir -ItemType Directory -Force

        $script:Write = {
            param($Path, $Content = 'resources: []')
            [System.IO.File]::WriteAllText($Path, $Content)
            return $Path
        }

        $script:ymlPath   = & $script:Write (Join-Path $script:docDir 'b-node.yml')
        $script:yamlPath  = & $script:Write (Join-Path $script:docDir 'a-node.yaml')
        $script:jsonPath  = & $script:Write (Join-Path $script:docDir 'c-node.json') '{"resources":[]}'
        $script:txtPath   = & $script:Write (Join-Path $script:docDir 'readme.txt') 'not a configuration'
    }

    Context "A directory of documents" {

        It "returns every supported document in the directory, in name order" {
            $result = Resolve-PassthroughConfiguration -ConfigurationDirectory $script:docDir
            @($result | ForEach-Object { [System.IO.Path]::GetFileName($_) }) |
                Should -Be @('a-node.yaml', 'b-node.yml', 'c-node.json')
        }

        It "returns full paths, not the relative path it was given" {
            Push-Location $TestDrive
            try {
                $result = Resolve-PassthroughConfiguration -ConfigurationDirectory 'documents'
                foreach ($path in @($result)) { [System.IO.Path]::IsPathFullyQualified($path) | Should -BeTrue }
            }
            finally { Pop-Location }
        }

        It "ignores a file whose extension no loader understands" {
            $result = Resolve-PassthroughConfiguration -ConfigurationDirectory $script:docDir
            @($result) | Should -Not -Contain $script:txtPath
        }

        It "ignores the sidecar files the runner itself writes, so a report is never re-ingested" -ForEach @(
            @{ Sidecar = 'n1.report.json' }
            @{ Sidecar = 'n1.state.json' }
            @{ Sidecar = 'n1.rsop.json' }
            @{ Sidecar = 'n1.provenance.json' }
        ) {
            $sidecarDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -Path $sidecarDir -ItemType Directory -Force
            $null = & $script:Write (Join-Path $sidecarDir 'n1.yml')
            $null = & $script:Write (Join-Path $sidecarDir $Sidecar) '{}'

            $result = Resolve-PassthroughConfiguration -ConfigurationDirectory $sidecarDir
            @($result | ForEach-Object { [System.IO.Path]::GetFileName($_) }) | Should -Be @('n1.yml')
        }

        It "does not search the directory recursively" {
            $parent = Join-Path $TestDrive 'nested'
            $child = Join-Path $parent 'deeper'
            $null = New-Item -Path $child -ItemType Directory -Force
            $null = & $script:Write (Join-Path $parent 'top.yml')
            $null = & $script:Write (Join-Path $child 'buried.yml')

            $result = Resolve-PassthroughConfiguration -ConfigurationDirectory $parent
            @($result | ForEach-Object { [System.IO.Path]::GetFileName($_) }) | Should -Be @('top.yml')
        }

        It "reads a directory whose name contains wildcard characters" {
            # A configuration path is data. Get-ChildItem would read '[' as a wildcard here.
            $bracketDir = [System.IO.Path]::Combine($TestDrive, 'has[bracket]')
            $null = [System.IO.Directory]::CreateDirectory($bracketDir)
            $null = & $script:Write ([System.IO.Path]::Combine($bracketDir, 'bracketed.yml'))

            $result = Resolve-PassthroughConfiguration -ConfigurationDirectory $bracketDir
            @($result | ForEach-Object { [System.IO.Path]::GetFileName($_) }) | Should -Be @('bracketed.yml')
        }

        It "throws for a directory with no documents in it rather than reporting a clean run of nothing" {
            $emptyDir = Join-Path $TestDrive 'empty'
            $null = New-Item -Path $emptyDir -ItemType Directory -Force
            { Resolve-PassthroughConfiguration -ConfigurationDirectory $emptyDir } |
                Should -Throw "*contains no configuration document*"
        }

        It "throws for a directory that does not exist" {
            { Resolve-PassthroughConfiguration -ConfigurationDirectory (Join-Path $TestDrive 'nope') } |
                Should -Throw "*does not exist*"
        }

        It "names the other parameter when given a file" {
            { Resolve-PassthroughConfiguration -ConfigurationDirectory $script:ymlPath } |
                Should -Throw "*is a file; use -ConfigurationFile*"
        }
    }

    Context "Named documents" {

        It "keeps the order the caller listed them in" {
            $result = Resolve-PassthroughConfiguration -ConfigurationFile @($script:ymlPath, $script:yamlPath, $script:jsonPath)
            @($result | ForEach-Object { [System.IO.Path]::GetFileName($_) }) |
                Should -Be @('b-node.yml', 'a-node.yaml', 'c-node.json')
        }

        It "accepts a single document" {
            $result = @(Resolve-PassthroughConfiguration -ConfigurationFile $script:ymlPath)
            $result.Count | Should -Be 1
            $result[0] | Should -Be $script:ymlPath
        }

        It "resolves a relative path against the current directory and collapses '..'" {
            Push-Location $script:docDir
            try {
                $result = @(Resolve-PassthroughConfiguration -ConfigurationFile './b-node.yml')
                $result[0] | Should -Be $script:ymlPath
            }
            finally { Pop-Location }
        }

        It "names every bad path in one message rather than failing on the first" {
            $missingOne = Join-Path $script:docDir 'missing-one.yml'
            $missingTwo = Join-Path $script:docDir 'missing-two.yml'
            # One good path, two bad: both bad ones are reported together.
            { Resolve-PassthroughConfiguration -ConfigurationFile @($script:ymlPath, $missingOne, $missingTwo) } |
                Should -Throw "*2 problem(s)*missing-one.yml*missing-two.yml*"
        }

        It "throws for a document that does not exist" {
            { Resolve-PassthroughConfiguration -ConfigurationFile (Join-Path $script:docDir 'nope.yml') } |
                Should -Throw "*does not exist*"
        }

        It "throws for an extension no loader understands" {
            { Resolve-PassthroughConfiguration -ConfigurationFile $script:txtPath } |
                Should -Throw "*has the extension '.txt'*"
        }

        It "names the other parameter when given a directory" {
            { Resolve-PassthroughConfiguration -ConfigurationFile $script:docDir } |
                Should -Throw "*is a directory; use -ConfigurationDirectory*"
        }

        It "accepts a sidecar-shaped name when the caller named it explicitly" {
            # Excluded from a directory listing, where it would be implicit; an explicit name
            # is the caller saying what they meant.
            $explicit = & $script:Write (Join-Path $script:docDir 'explicit.report.json') '{"resources":[]}'
            $result = @(Resolve-PassthroughConfiguration -ConfigurationFile $explicit)
            $result[0] | Should -Be $explicit
        }
    }

    Context "The node name must be unique within a run" {

        It "throws when two documents share a file name, since the file name is the node name" {
            $otherDir = Join-Path $TestDrive 'other'
            $null = New-Item -Path $otherDir -ItemType Directory -Force
            $duplicate = & $script:Write (Join-Path $otherDir 'b-node.yml')

            { Resolve-PassthroughConfiguration -ConfigurationFile @($script:ymlPath, $duplicate) } |
                Should -Throw "*node name(s) are used by more than one document*"
        }

        It "throws when two documents in one directory differ only by extension" {
            $collisionDir = Join-Path $TestDrive 'collision'
            $null = New-Item -Path $collisionDir -ItemType Directory -Force
            $null = & $script:Write (Join-Path $collisionDir 'same.yml')
            $null = & $script:Write (Join-Path $collisionDir 'same.json') '{"resources":[]}'

            { Resolve-PassthroughConfiguration -ConfigurationDirectory $collisionDir } |
                Should -Throw "*node name(s) are used by more than one document*"
        }

        It "compares node names without regard to case" {
            $caseDir = Join-Path $TestDrive 'casing'
            $null = New-Item -Path $caseDir -ItemType Directory -Force
            $lower = & $script:Write (Join-Path $caseDir 'node.yml')
            $upper = & $script:Write (Join-Path $caseDir 'NODE.yaml')

            { Resolve-PassthroughConfiguration -ConfigurationFile @($lower, $upper) } |
                Should -Throw "*node name(s) are used by more than one document*"
        }
    }

    Context "Exactly one of the two inputs" {

        It "throws when both are supplied" {
            { Resolve-PassthroughConfiguration -ConfigurationFile $script:ymlPath -ConfigurationDirectory $script:docDir } |
                Should -Throw "*cannot both be supplied*"
        }

        It "throws when neither is supplied" {
            { Resolve-PassthroughConfiguration } | Should -Throw "*Supply either -ConfigurationFile or -ConfigurationDirectory*"
        }

        It "treats an empty or whitespace-only value as not supplied" -ForEach @(
            @{ Value = @() }
            @{ Value = @('') }
            @{ Value = @('   ') }
        ) {
            { Resolve-PassthroughConfiguration -ConfigurationFile $Value } |
                Should -Throw "*Supply either -ConfigurationFile or -ConfigurationDirectory*"
        }
    }
}
