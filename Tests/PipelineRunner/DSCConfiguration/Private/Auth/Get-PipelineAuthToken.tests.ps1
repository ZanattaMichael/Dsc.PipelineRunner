Describe "Get-PipelineAuthToken Function Tests" -Tag Unit, Auth {

    BeforeAll {
        # Unprotect-SecureString is loaded so the tests can assert on the resolved plaintext.
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
        . (Get-FunctionPath 'Get-PipelineAuthToken.ps1').FullName
    }

    Context "Explicit token input" {

        It "Returns a supplied SecureString unchanged" {
            $secure = ConvertTo-SecureString -String 'abc' -AsPlainText -Force

            $result = Get-PipelineAuthToken -Token $secure

            $result | Should -BeOfType ([securestring])
            $result | Should -Be $secure
        }

        It "Wraps a plain string into a SecureString" {
            $result = Get-PipelineAuthToken -Token 'plain-token'

            $result | Should -BeOfType ([securestring])
            Unprotect-SecureString -SecureString $result | Should -Be 'plain-token'
        }
    }

    Context "Environment fallback" {

        AfterEach {
            Remove-Item -Path Env:PR_TEST_TOKEN -ErrorAction SilentlyContinue
        }

        It "Reads the fallback environment variable when no token is supplied" {
            $env:PR_TEST_TOKEN = 'env-token'

            $result = Get-PipelineAuthToken -FallbackEnvName 'PR_TEST_TOKEN'

            Unprotect-SecureString -SecureString $result | Should -Be 'env-token'
        }

        It "Prefers an explicit token over the environment fallback" {
            $env:PR_TEST_TOKEN = 'env-token'

            $result = Get-PipelineAuthToken -Token 'explicit' -FallbackEnvName 'PR_TEST_TOKEN'

            Unprotect-SecureString -SecureString $result | Should -Be 'explicit'
        }

        It "Returns null when neither a token nor the environment variable is present" {
            Get-PipelineAuthToken -FallbackEnvName 'PR_TEST_TOKEN' | Should -BeNullOrEmpty
        }

        It "Ignores a whitespace-only token and falls back to the environment" {
            $env:PR_TEST_TOKEN = 'env-token'

            $result = Get-PipelineAuthToken -Token '   ' -FallbackEnvName 'PR_TEST_TOKEN'

            Unprotect-SecureString -SecureString $result | Should -Be 'env-token'
        }
    }
}
