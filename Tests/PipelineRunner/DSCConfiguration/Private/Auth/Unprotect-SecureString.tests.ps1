Describe "Unprotect-SecureString Function Tests" -Tag Unit, Auth {

    BeforeAll {
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
    }

    It "Round-trips a SecureString back to its plaintext" {
        $secret = 'p@ss-w0rd-123'
        $secure = ConvertTo-SecureString -String $secret -AsPlainText -Force

        Unprotect-SecureString -SecureString $secure | Should -Be $secret
    }

    It "Returns an empty string for an empty SecureString" {
        $secure = ConvertTo-SecureString -String '' -AsPlainText -Force

        Unprotect-SecureString -SecureString $secure | Should -Be ''
    }
}
