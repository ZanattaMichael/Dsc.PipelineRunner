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
        # ConvertTo-SecureString rejects an empty -String, so build the empty
        # SecureString directly to exercise the empty-credential path.
        $secure = [System.Security.SecureString]::new()

        Unprotect-SecureString -SecureString $secure | Should -Be ''
    }
}
