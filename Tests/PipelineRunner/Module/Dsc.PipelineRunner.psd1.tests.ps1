Describe "Module manifest" -Tag Unit, Module {

    BeforeAll {
        # Resolve the repository root from this file's own location. $script:repositoryRoot is
        # populated lazily by Get-FunctionPath, so it is only set once some other suite has
        # called it - and file enumeration order is not stable across platforms, so on a Linux
        # agent this suite can run first and the global is still $null (#70 CI failure:
        # "Cannot bind argument to parameter 'Path' because it is null").
        $script:repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
        $script:manifestPath = Join-Path $script:repositoryRoot 'source/Dsc.PipelineRunner.psd1'

        # Read the manifest as data rather than through Test-ModuleManifest: the source
        # manifest points at a RootModule that only exists after a build, so Test-ModuleManifest
        # cannot load it from the repository. The export fields are what this guards.
        $script:manifest = Import-PowerShellDataFile -LiteralPath $script:manifestPath

        $script:publicFunctions = Get-ChildItem -LiteralPath (Join-Path $script:repositoryRoot 'source/Public') -Filter '*.ps1' |
            ForEach-Object {
                $tokens = $null; $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
                $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                    ForEach-Object { $_.Name }
            }
    }

    It "should parse as a valid data file" {
        $script:manifest | Should -Not -BeNullOrEmpty
        $script:manifest.RootModule | Should -Not -BeNullOrEmpty
    }

    It "should export every public function under FunctionsToExport" {
        # The seven public commands are advanced functions. They were listed under
        # CmdletsToExport with FunctionsToExport empty, so the built module exported nothing
        # and every documented entry point was unavailable after Import-Module (#16).
        foreach ($function in $script:publicFunctions) {
            $script:manifest.FunctionsToExport | Should -Contain $function
        }
    }

    It "should not list any function under CmdletsToExport" {
        # This module ships no binary cmdlets.
        @($script:manifest.CmdletsToExport).Where({ $_ }) | Should -BeNullOrEmpty
    }

    It "should not export any variables" {
        # VariablesToExport = '*' leaked the module's internal state ($references,
        # $variables, $parameters from prefix.ps1) into the caller's session.
        @($script:manifest.VariablesToExport).Where({ $_ }) | Should -BeNullOrEmpty
    }

    It "should not export any aliases" {
        # The module-internal aliases (parameters, variables, reference, GetDefaultValues)
        # resolve inside the module regardless, so exporting them only risks a collision.
        @($script:manifest.AliasesToExport).Where({ $_ }) | Should -BeNullOrEmpty
    }

    It "should point IconUri at the raw image, not a GitHub HTML page" {
        # A /blob/ URL serves an HTML page; a gallery listing renders a broken image.
        $script:manifest.PrivateData.PSData.IconUri | Should -Not -Match '/blob/'
        $script:manifest.PrivateData.PSData.IconUri | Should -Match '^https://raw\.githubusercontent\.com/'
    }

    It "should carry a project and licence URI" {
        $script:manifest.PrivateData.PSData.ProjectUri | Should -Match '^https://github\.com/'
        $script:manifest.PrivateData.PSData.LicenseUri | Should -Match '^https://github\.com/'
    }
}
