<#
Mocked by design: this suite mocks Get-Module/Get-Secret so it can assert dispatch and
result-shape handling without SecretManagement installed. The live vault lookup is covered
separately by ../Integration/SecretManagementCredential.Integration.tests.ps1, which registers a
real Microsoft.PowerShell.SecretStore vault.
#>
Describe "Actions/Credential/SecretManagement Tests" -Tag Unit, Credential {

    BeforeAll {
        $script:SecretManagementPath = (Get-FunctionPath 'SecretManagement.ps1').FullName

        # Get-Secret comes from Microsoft.PowerShell.SecretManagement, which is not installed in
        # this sandbox. Define a stub so it resolves for Get-Command / Mock to attach to; the real
        # module's soft-dependency check (Get-Module -ListAvailable) is exercised separately below
        # and is itself mocked, so this stub is never invoked for real secret storage.
        function Get-Secret {
            param([string]$Name, [string]$Vault)
        }
    }

    It "Throws when Name is not supplied" {
        Mock -CommandName Get-Module -MockWith { return $true }
        { & $script:SecretManagementPath -Context @{} } | Should -Throw "*Name*"
    }

    It "Throws an actionable error when the SecretManagement module is not available" {
        Mock -CommandName Get-Module -ParameterFilter { $ListAvailable } -MockWith { return $null }
        { & $script:SecretManagementPath -Context @{ Name = 'MySecret' } } | Should -Throw "*Microsoft.PowerShell.SecretManagement*"
    }

    Context "with the SecretManagement module available" {

        BeforeAll {
            Mock -CommandName Get-Module -ParameterFilter { $ListAvailable } -MockWith { return $true }
            Mock -CommandName Import-Module
        }

        It "Throws when the secret is not found" {
            Mock -CommandName Get-Secret -MockWith { return $null }
            { & $script:SecretManagementPath -Context @{ Name = 'MySecret' } } | Should -Throw "*not found*"
        }

        It "Returns a PSCredential secret unchanged" {
            $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            Mock -CommandName Get-Secret -MockWith { return $cred }

            $result = & $script:SecretManagementPath -Context @{ Name = 'MySecret' }

            $result | Should -Be $cred
        }

        It "Wraps a bare SecureString secret into a PSCredential, defaulting UserName to the secret Name" {
            $secure = ConvertTo-SecureString 'super-secret' -AsPlainText -Force
            Mock -CommandName Get-Secret -MockWith { return $secure }

            $result = & $script:SecretManagementPath -Context @{ Name = 'MySecret' }

            $result | Should -BeOfType ([System.Management.Automation.PSCredential])
            $result.UserName | Should -Be 'MySecret'
            $result.GetNetworkCredential().Password | Should -Be 'super-secret'
        }

        It "Uses an explicit UserName over the secret Name for a bare SecureString" {
            $secure = ConvertTo-SecureString 'super-secret' -AsPlainText -Force
            Mock -CommandName Get-Secret -MockWith { return $secure }

            $result = & $script:SecretManagementPath -Context @{ Name = 'MySecret'; UserName = 'explicit-user' }

            $result.UserName | Should -Be 'explicit-user'
        }

        It "Throws when the secret is neither a PSCredential nor a SecureString" {
            Mock -CommandName Get-Secret -MockWith { return 'plain-string-secret' }
            { & $script:SecretManagementPath -Context @{ Name = 'MySecret' } } | Should -Throw "*not a PSCredential or SecureString*"
        }

        It "Passes -Vault through to Get-Secret when supplied" {
            Mock -CommandName Get-Secret -MockWith { return $null }
            { & $script:SecretManagementPath -Context @{ Name = 'MySecret'; Vault = 'MyVault' } } | Should -Throw
            Assert-MockCalled -CommandName Get-Secret -ParameterFilter { $Vault -eq 'MyVault' } -Exactly 1 -Scope It
        }
    }
}
