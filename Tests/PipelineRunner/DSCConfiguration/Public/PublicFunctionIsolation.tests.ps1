Describe "Public function load isolation (#26)" -Tag Unit {

    # Acceptance criterion for #26: each public function can be dot-sourced on its own,
    # in a clean session, without depending on any other file having been loaded first.
    # A regression here (top-level code that calls a sibling function at load time) would
    # make the module load-order sensitive and hard to test in isolation.

    BeforeDiscovery {
        # This test file lives at Tests/PipelineRunner/DSCConfiguration/Public/ — four levels
        # below the repository root. Resolve the Public source directory from there so discovery
        # does not depend on any global the harness may or may not have set yet.
        $repoRoot = $PSScriptRoot
        1..4 | ForEach-Object { $repoRoot = Split-Path -Path $repoRoot -Parent }
        $publicSourceDir = Join-Path $repoRoot 'source/Public'

        $publicFileCases = Get-ChildItem -LiteralPath $publicSourceDir -File -Filter '*.ps1' | ForEach-Object {
            @{
                Name = $_.Name
                Path = $_.FullName
                # Only files whose basename is a Verb-Noun name are expected to define a matching
                # function. VersionConfiguration.ps1 is a top-level Data block, not a function.
                FunctionName = if ($_.BaseName -match '^\w+-\w+') { $_.BaseName } else { $null }
            }
        }
    }

    It "dot-sources <Name> in a clean runspace with no errors" -TestCases $publicFileCases {
        param($Name, $Path, $FunctionName)

        # A fresh runspace has only the built-in commands — no sibling module functions — so
        # dot-sourcing here proves the file has no load-order dependency at definition time.
        $ps = [powershell]::Create()
        try {
            $null = $ps.AddScript(@"
. '$($Path -replace "'", "''")'
if ('$FunctionName') {
    if (-not (Get-Command -Name '$FunctionName' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "dot-sourcing did not define function [$FunctionName]"
    }
}
"@)
            $null = $ps.Invoke()

            $errorText = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
            $errorText | Should -BeNullOrEmpty
            $ps.HadErrors | Should -BeFalse
        }
        finally {
            $ps.Dispose()
        }
    }
}
