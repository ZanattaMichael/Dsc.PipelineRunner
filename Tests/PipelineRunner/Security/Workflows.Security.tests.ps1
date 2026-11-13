<#
Security regression suite: GitHub Actions workflow policy.

The 2026-10 audit found three workflows that ran pull requests from forks on a self-hosted
runner holding a managed identity into a live Azure DevOps organization, and six workflows with
no token permissions declared. These tests parse every workflow under .github/workflows and
fail the unit gate if any of those conditions comes back, or if a workflow starts interpolating
attacker-controlled event data into a shell step.
#>
Describe "Security: GitHub Actions workflow policy" -Tag Unit, Security {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop

        $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
        $script:workflowFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github/workflows') -Filter '*.yml' -File)

        # YAML 1.1 parsers may read the bare key `on` as boolean true; accept either spelling.
        function Get-WorkflowTriggers {
            param($Workflow)
            foreach ($key in $Workflow.Keys) {
                if (($key -is [bool] -and $key) -or ([string]$key -eq 'on')) { return $Workflow[$key] }
            }
            return $null
        }

        function Test-SelfHostedJob {
            param($Job)
            $runsOn = $Job['runs-on']
            if ($null -eq $runsOn) { return $false }
            foreach ($label in @($runsOn)) {
                if ($label -is [System.Collections.IDictionary]) {
                    foreach ($v in $label.Values) { if ("$v" -match 'self-hosted') { return $true } }
                }
                elseif ("$label" -match 'self-hosted') { return $true }
            }
            return $false
        }

        $script:workflows = foreach ($file in $script:workflowFiles) {
            [pscustomobject]@{
                Name     = $file.Name
                Raw      = (Get-Content -LiteralPath $file.FullName -Raw)
                Document = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Yaml)
            }
        }
        $script:workflowCases = @($script:workflows | ForEach-Object { @{ Name = $_.Name; Workflow = $_ } })
    }

    It "finds the workflows it is supposed to guard" {
        $script:workflowFiles.Count | Should -BeGreaterThan 5
    }

    It "<Name>: declares token permissions at workflow level or on every job" -TestCases $script:workflowCases {
        param($Name, $Workflow)
        $doc = $Workflow.Document
        if ($doc.Contains('permissions')) {
            $doc['permissions'] | Should -Not -BeNullOrEmpty
        }
        else {
            foreach ($jobName in $doc['jobs'].Keys) {
                $job = $doc['jobs'][$jobName]
                # A job that only calls a reusable workflow inherits the caller's cap; everything
                # else must say what it needs.
                if ($job.Contains('uses')) { continue }
                $job.Contains('permissions') | Should -BeTrue -Because "job '$jobName' in $Name runs without an explicit permissions block"
            }
        }
    }

    It "<Name>: never uses the privileged pull_request_target trigger" -TestCases $script:workflowCases {
        param($Name, $Workflow)
        $triggers = Get-WorkflowTriggers -Workflow $Workflow.Document
        $triggers | Should -Not -BeNullOrEmpty
        if ($triggers -is [System.Collections.IDictionary]) {
            $triggers.Contains('pull_request_target') | Should -BeFalse
        }
        else {
            @($triggers) | Should -Not -Contain 'pull_request_target'
        }
        $Workflow.Raw | Should -Not -Match 'pull_request_target'
    }

    It "<Name>: every self-hosted job that can run on pull_request is guarded against forks" -TestCases $script:workflowCases {
        param($Name, $Workflow)
        $doc = $Workflow.Document
        $triggers = Get-WorkflowTriggers -Workflow $doc
        $runsOnPullRequest = ($triggers -is [System.Collections.IDictionary] -and $triggers.Contains('pull_request')) -or
                             ($triggers -isnot [System.Collections.IDictionary] -and (@($triggers) -contains 'pull_request'))

        foreach ($jobName in $doc['jobs'].Keys) {
            $job = $doc['jobs'][$jobName]
            if (-not (Test-SelfHostedJob -Job $job)) { continue }
            if (-not $runsOnPullRequest -and -not $job.Contains('uses')) { continue }

            $job.Contains('if') | Should -BeTrue -Because "self-hosted job '$jobName' in $Name has no fork guard"
            [string]$job['if'] | Should -Match 'github\.event\.pull_request\.head\.repo\.full_name\s*==\s*github\.repository' `
                -Because "self-hosted job '$jobName' in $Name must skip pull requests from forks"
        }
    }

    It "<Name>: never interpolates attacker-controlled event data into a run step" -TestCases $script:workflowCases {
        param($Name, $Workflow)
        $doc = $Workflow.Document
        $dangerous = '\$\{\{\s*(github\.event\.(issue|comment|review|pull_request\.(title|body|head\.(ref|label)))|github\.head_ref|inputs\.)'
        foreach ($jobName in $doc['jobs'].Keys) {
            foreach ($step in @($doc['jobs'][$jobName]['steps'])) {
                if ($null -eq $step -or -not $step.Contains('run')) { continue }
                [string]$step['run'] | Should -Not -Match $dangerous -Because "a run step in job '$jobName' of $Name interpolates untrusted context; pass it through env: instead"
            }
        }
    }

    It "<Name>: pins every third-party action to a version, never a moving branch" -TestCases $script:workflowCases {
        param($Name, $Workflow)
        $doc = $Workflow.Document
        foreach ($jobName in $doc['jobs'].Keys) {
            foreach ($step in @($doc['jobs'][$jobName]['steps'])) {
                if ($null -eq $step -or -not $step.Contains('uses')) { continue }
                $uses = [string]$step['uses']
                if ($uses.StartsWith('./')) { continue }
                $uses | Should -Match '@(v\d+|[0-9a-f]{40})' -Because "'$uses' in job '$jobName' of $Name is not pinned to a version tag or a commit SHA"
                $uses | Should -Not -Match '@(main|master|latest)$'
            }
        }
    }
}
