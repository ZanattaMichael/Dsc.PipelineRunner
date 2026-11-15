<#
Security regression suite: the release tag is computed by a script that refuses anything
ambiguous, and the workflow that creates it is locked down.

A tag is what deploys a release, and a published release cannot be taken back. So:

  * Get-NextReleaseTag.ps1 only ever produces vX.Y.Z or vX.Y.Z-<letters><digits>, never goes
    backwards, never goes to a version that was already released, and refuses a preview counter that would sort out of order,
  * the "Create release tag" workflow runs from main only, needs a green main, takes its inputs
    through environment variables, and asks for no more token permission than it uses.

Dummy tag names only; nothing here touches git.
#>
Describe "Security: release tags are computed safely and created only from a green main" -Tag Unit, Security {

    BeforeAll {
        $script:root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
        $script:script = Join-Path $script:root 'scripts/Get-NextReleaseTag.ps1'
        $script:workflowPath = Join-Path $script:root '.github/workflows/Create-ReleaseTag.yml'

        $script:tags = @('v1.0.0', 'v1.0.0-preview1', 'v1.1.0-preview1', 'v1.1.0-preview2', 'v1.1.0', 'v1.1.1-preview1', 'not-a-release', 'latest')
    }

    Context "the next version" {

        It "bumps the latest stable release: <Bump> -> <Expected>" -ForEach @(
            @{ Bump = 'patch'; Expected = 'v1.1.1' }
            @{ Bump = 'minor'; Expected = 'v1.2.0' }
            @{ Bump = 'major'; Expected = 'v2.0.0' }
        ) {
            & $script:script -Tag $script:tags -Bump $Bump | Should -Be $Expected
        }

        It "counts up from the previews that already exist for that version" {
            & $script:script -Tag $script:tags -Bump patch -Prerelease | Should -Be 'v1.1.1-preview2'
        }

        It "starts a new version's previews at a zero-padded 0001" {
            & $script:script -Tag $script:tags -Bump minor -Prerelease | Should -Be 'v1.2.0-preview0001'
        }

        It "takes an explicit version instead of a bump" {
            & $script:script -Tag $script:tags -Version '3.0.0' | Should -Be 'v3.0.0'
            & $script:script -Tag $script:tags -Version '3.0.0' -Prerelease | Should -Be 'v3.0.0-preview0001'
        }

        It "ignores names that are not release tags" {
            & $script:script -Tag @('latest', 'v1', 'release-1.0', 'v1.0.0') -Bump patch | Should -Be 'v1.0.1'
        }

        It "keeps the number width the version already uses, so labels keep sorting in order" {
            & $script:script -Tag @('v1.0.0', 'v2.0.0-preview0007') -Version '2.0.0' -Prerelease | Should -Be 'v2.0.0-preview0008'
        }
    }

    Context "what it refuses" {

        It "refuses to bump when no stable release exists to bump from" {
            { & $script:script -Tag @('v1.0.0-preview1') -Bump patch } | Should -Throw '*No stable release*'
        }

        It "refuses a version that is not above the latest stable release: <Version>" -ForEach @(
            @{ Version = '1.1.0' }
            @{ Version = '1.0.9' }
            @{ Version = '0.9.0' }
        ) {
            { & $script:script -Tag $script:tags -Version $Version } | Should -Throw '*not above the latest stable*'
        }

        It "refuses a malformed version: <Version>" -ForEach @(
            @{ Version = '1.2' }
            @{ Version = 'v1.2.3' }
            @{ Version = '1.2.3-rc1' }
            @{ Version = '1.2.3; rm -rf /' }
            @{ Version = '1.2.3 ' }
            @{ Version = '1.2.x' }
        ) {
            { & $script:script -Tag $script:tags -Version $Version } | Should -Throw '*is not valid*'
        }

        It "refuses a preview label the PowerShell Gallery would reject: <Label>" -ForEach @(
            @{ Label = 'rc.1' }
            @{ Label = 'pre-release' }
            @{ Label = 'preview1' }
            @{ Label = '' }
            @{ Label = 'a b' }
        ) {
            { & $script:script -Tag $script:tags -Bump patch -Prerelease -PreviewLabel $Label } | Should -Throw '*label*'
        }

        It "refuses a preview number that no longer fits its width" {
            { & $script:script -Tag @('v1.0.0', 'v2.0.0-preview9') -Version '2.0.0' -Prerelease } | Should -Throw '*no longer fits*'
        }

        It "only ever returns a tag of the expected shape" {
            $result = & $script:script -Tag $script:tags -Bump patch -Prerelease
            $result | Should -Match '\Av\d+\.\d+\.\d+(-[A-Za-z]+\d+)?\z'
        }
    }

    Context "the workflow that creates the tag" {

        BeforeAll { $script:text = Get-Content -LiteralPath $script:workflowPath -Raw }

        It "exists and can only be started by hand" {
            $script:text | Should -Match '(?m)^on:\s*\r?\n\s+workflow_dispatch:'
            $script:text | Should -Not -Match '(?m)^\s+(push|pull_request|pull_request_target|schedule|workflow_run):'
        }

        It "runs from main only" {
            $script:text | Should -Match "if:\s*github\.ref == 'refs/heads/main'"
        }

        It "asks for no more token permission than it uses" {
            $script:text | Should -Match '(?m)^permissions:\s*\r?\n\s+contents:\s*write\s*\r?\n\s+actions:\s*write\s*\r?\n\s+checks:\s*read'
            $script:text | Should -Not -Match '(?m)^\s+(id-token|packages|pull-requests|security-events|attestations):\s*write'
        }

        It "refuses to tag a main whose checks are not all passing" {
            $script:text | Should -Match 'Require main to be green'
            $script:text | Should -Match 'check-runs'
        }

        It "never puts an input straight into a script" {
            $runBlocks = [regex]::Matches($script:text, '(?ms)^\s+run:\s*[|>]?-?\s*\r?\n(.*?)(?=^\s+- name:|\z)') | ForEach-Object { $_.Groups[1].Value }
            foreach ($block in $runBlocks) { $block | Should -Not -Match '\$\{\{\s*inputs\.' }
        }

        It "starts the release through the tag, not by storing a personal access token" {
            $script:text | Should -Match 'gh workflow run Release\.yml --ref'
            $script:text | Should -Not -Match '(?i)secrets\.(?!GITHUB_TOKEN)\w*(PAT|TOKEN)'
        }

        It "creates an annotated tag, so the release records who and when" {
            $script:text | Should -Match 'git tag -a'
        }

        It "supports a dry run that creates nothing" {
            $script:text | Should -Match 'dry_run'
            $script:text | Should -Match "if:\s*\$\{\{\s*!inputs\.dry_run\s*\}\}"
        }
    }
}
