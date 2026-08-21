Describe "Merge-DscRunnerResult Function Tests" -Tag Unit, Runner {

    BeforeAll {
        . (Get-FunctionPath 'Merge-DscRunnerResult.ps1').FullName

        # Keep the information stream and disk writes out of the test run.
        Mock -CommandName Write-Information
        Mock -CommandName Set-Content

        # Builds a per-configuration result shaped like Start-DscRunner's return value.
        function New-RunnerResult {
            param(
                [string]$File = 'node.yml',
                [string]$Status = 'Completed',
                [int]$Total = 1,
                [int]$Pass = 1,
                [int]$Fail = 0,
                [int]$Skip = 0,
                [double]$Duration = 0.5,
                [object[]]$Failed = @()
            )
            [pscustomobject]@{
                ConfigurationFile = $File
                Status            = $Status
                TotalResources    = $Total
                PassCount         = $Pass
                FailCount         = $Fail
                SkipCount         = $Skip
                DurationSeconds   = $Duration
                FailedResources   = $Failed
                Results           = @()
            }
        }
    }

    Context "aggregation" {

        It "returns a Completed summary with zero counts for an empty run" {
            $summary = Merge-DscRunnerResult -Result @()

            $summary.Status | Should -Be 'Completed'
            $summary.TotalConfigurations | Should -Be 0
            $summary.TotalResources | Should -Be 0
            $summary.PassCount | Should -Be 0
        }

        It "tolerates a null result collection" {
            $summary = Merge-DscRunnerResult -Result $null
            $summary.Status | Should -Be 'Completed'
            $summary.TotalConfigurations | Should -Be 0
        }

        It "sums counts across every configuration" {
            $results = @(
                (New-RunnerResult -File 'a.yml' -Total 3 -Pass 3)
                (New-RunnerResult -File 'b.yml' -Total 2 -Pass 2 -Duration 1.25)
            )

            $summary = Merge-DscRunnerResult -Result $results

            $summary.Status | Should -Be 'Completed'
            $summary.TotalConfigurations | Should -Be 2
            $summary.TotalResources | Should -Be 5
            $summary.PassCount | Should -Be 5
            $summary.DurationSeconds | Should -Be 1.75
        }

        It "reports Failed and collects the failed resources when any configuration fails" {
            $results = @(
                (New-RunnerResult -File 'a.yml' -Pass 1)
                (New-RunnerResult -File 'b.yml' -Pass 0 -Fail 1 -Failed @([pscustomobject]@{ InstanceName = 'R1' }))
            )

            $summary = Merge-DscRunnerResult -Result $results

            $summary.Status | Should -Be 'Failed'
            $summary.FailCount | Should -Be 1
            $summary.FailedResources.Count | Should -Be 1
            $summary.FailedResources[0].InstanceName | Should -Be 'R1'
        }

        It "reports Aborted when any configuration was aborted by an exception" {
            $results = @(
                (New-RunnerResult -File 'a.yml' -Pass 1)
                (New-RunnerResult -File 'b.yml' -Status 'AbortedByException' -Pass 0)
            )

            $summary = Merge-DscRunnerResult -Result $results
            $summary.Status | Should -Be 'Aborted'
        }

        It "reports PartialSuccess when a configuration stopped early with no failures" {
            $results = @(
                (New-RunnerResult -File 'a.yml' -Pass 1)
                (New-RunnerResult -File 'b.yml' -Status 'StoppedByRequest' -Pass 0 -Skip 1)
            )

            $summary = Merge-DscRunnerResult -Result $results
            $summary.Status | Should -Be 'PartialSuccess'
        }
    }

    Context "report output" {

        It "writes an aggregate report.json when a ReportPath is supplied" {
            Merge-DscRunnerResult -Result @((New-RunnerResult)) -ReportPath 'C:\Reports' | Out-Null
            Assert-MockCalled -CommandName Set-Content -Exactly 1 -Scope It -ParameterFilter {
                $LiteralPath -like '*report.json'
            }
        }

        It "does not write a report when no ReportPath is supplied" {
            Merge-DscRunnerResult -Result @((New-RunnerResult)) | Out-Null
            Assert-MockCalled -CommandName Set-Content -Exactly 0 -Scope It
        }
    }

    Context "exit contract (#19)" {

        It "sets the process exit code to 1 with -FailOnError on a failed run" {
            $previousExitCode = [System.Environment]::ExitCode
            try {
                [System.Environment]::ExitCode = 0
                Merge-DscRunnerResult -Result @((New-RunnerResult -Fail 1 -Pass 0)) -FailOnError | Out-Null
                [System.Environment]::ExitCode | Should -Be 1
            }
            finally {
                [System.Environment]::ExitCode = $previousExitCode
            }
        }

        It "leaves the exit code unchanged on failure without -FailOnError" {
            $previousExitCode = [System.Environment]::ExitCode
            try {
                [System.Environment]::ExitCode = 0
                Merge-DscRunnerResult -Result @((New-RunnerResult -Fail 1 -Pass 0)) | Out-Null
                [System.Environment]::ExitCode | Should -Be 0
            }
            finally {
                [System.Environment]::ExitCode = $previousExitCode
            }
        }

        It "does not fail the process for a PartialSuccess even with -FailOnError" {
            $previousExitCode = [System.Environment]::ExitCode
            try {
                [System.Environment]::ExitCode = 0
                Merge-DscRunnerResult -Result @((New-RunnerResult -Status 'StoppedByRequest' -Pass 0 -Skip 1)) -FailOnError | Out-Null
                [System.Environment]::ExitCode | Should -Be 0
            }
            finally {
                [System.Environment]::ExitCode = $previousExitCode
            }
        }
    }

}
