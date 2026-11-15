<#
Security regression suite: the security policy stays complete and in step with the tests.

SECURITY.md is the document a reporter reads before deciding how to disclose, and an operator
reads to learn what the module guarantees. Two things make it rot: a section gets dropped in an
edit, and a new security test is added without the document learning about it (so a guarantee
exists that nobody can find). These tests fail in both cases.
#>
Describe "Security: the security policy is complete and lists every security test" -Tag Unit, Security {

    BeforeAll {
        # Paths come from this file's own location, not from a global the helper module sets
        # lazily: this file sits in <repo>/Tests/PipelineRunner/Security.
        $script:root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
        $script:policyPath = Join-Path $script:root 'SECURITY.md'
        $script:policy = Get-Content -LiteralPath $script:policyPath -Raw
        $script:runbookPath = Join-Path $script:root 'docs/security-response-process.md'
        $script:securityTests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Security.tests.ps1')
    }

    It "has the section <Heading>" -ForEach @(
        @{ Heading = 'Supported versions' }
        @{ Heading = 'Reporting a vulnerability' }
        @{ Heading = 'What to expect' }
        @{ Heading = 'Severity' }
        @{ Heading = 'Scope' }
        @{ Heading = 'Disclosure and safe harbor' }
        @{ Heading = 'How the module ensures security' }
        @{ Heading = 'Trust model' }
        @{ Heading = 'Regression tests for these guarantees' }
    ) {
        $script:policy | Should -Match "(?m)^#{2,3} $([regex]::Escape($Heading))\s*$"
    }

    It "tells reporters to use a private channel and not to open a public issue" {
        $script:policy | Should -Match 'security/advisories/new'
        $script:policy | Should -Match '(?i)do \*\*not\*\* open a public\s+issue'
    }

    It "states response targets for acknowledgement, triage, updates and fixes" {
        $script:policy | Should -Match '(?i)Acknowledge the report'
        $script:policy | Should -Match '(?i)initial severity'
        $script:policy | Should -Match '(?i)Status update'
        $script:policy | Should -Match '(?i)Fix released'
        $script:policy | Should -Match '(?i)Public disclosure'
    }

    It "defines all four severities" -ForEach @(
        @{ Severity = 'Critical' }, @{ Severity = 'High' }, @{ Severity = 'Medium' }, @{ Severity = 'Low' }
    ) {
        $script:policy | Should -Match "\*\*$Severity\*\*"
    }

    It "links the maintainers' response process, and that document exists with its steps" {
        $script:policy | Should -Match 'docs/security-response-process\.md'
        Test-Path -LiteralPath $script:runbookPath | Should -BeTrue
        $runbook = Get-Content -LiteralPath $script:runbookPath -Raw
        foreach ($step in 'Receive', 'Triage', 'Fix', 'Release and disclose', 'After') {
            $runbook | Should -Match "(?m)^## \d\. $([regex]::Escape($step))"
        }
    }

    It "lists the security test file <Name>" -ForEach @(
        # Evaluated at discovery time, so it uses only $PSScriptRoot (this file's directory).
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Security.tests.ps1' |
            ForEach-Object { @{ Name = $_.Name } }
    ) {
        $script:policy | Should -Match ([regex]::Escape($Name))
    }

    It "finds the security test files it is checking" {
        $script:securityTests.Count | Should -BeGreaterThan 5
    }
}
