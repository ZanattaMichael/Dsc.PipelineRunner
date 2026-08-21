Describe "Resolve-CacheDirectory Function Tests" -Tag Unit, Configuration {

    BeforeAll {
        . (Get-FunctionPath 'Resolve-CacheDirectory.ps1').FullName
    }

    AfterEach {
        # Keep the environment clean so cases don't leak into one another.
        Remove-Item Env:PIPELINERUNNER_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        Remove-Item Env:PR_TEST_CACHE -ErrorAction SilentlyContinue
    }

    Context "Explicit value" {

        It "Returns an explicit -CacheDirectory unchanged and ignores the environment" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = 'from-env'

            Resolve-CacheDirectory -CacheDirectory 'explicit-dir' | Should -Be 'explicit-dir'
        }

        It "Treats a whitespace-only -CacheDirectory as unset" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = 'from-env'

            Resolve-CacheDirectory -CacheDirectory '   ' | Should -Be 'from-env'
        }
    }

    Context "Environment resolution" {

        It "Reads the generic PIPELINERUNNER_CACHE_DIRECTORY variable" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = 'generic-dir'

            Resolve-CacheDirectory | Should -Be 'generic-dir'
        }

        It "Falls back to the legacy AZDODSC_CACHE_DIRECTORY alias" {
            $env:AZDODSC_CACHE_DIRECTORY = 'legacy-dir'

            Resolve-CacheDirectory | Should -Be 'legacy-dir'
        }

        It "Prefers the generic name over the legacy alias" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = 'generic-dir'
            $env:AZDODSC_CACHE_DIRECTORY = 'legacy-dir'

            Resolve-CacheDirectory | Should -Be 'generic-dir'
        }

        It "Honours a custom ordered list of environment variable names" {
            $env:PR_TEST_CACHE = 'custom-dir'

            Resolve-CacheDirectory -EnvironmentVariableName @('PR_TEST_CACHE') | Should -Be 'custom-dir'
        }
    }

    Context "Nothing set" {

        It "Returns null when neither the parameter nor any variable is set" {
            Resolve-CacheDirectory | Should -BeNullOrEmpty
        }
    }
}
