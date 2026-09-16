# Credential/SecretManagement.ps1's header records that it is "only unit-tested with Get-Secret
# mocked ... this environment has no live vault to validate a real secret lookup against". This
# suite is that validation: it installs Microsoft.PowerShell.SecretManagement plus the
# cross-platform Microsoft.PowerShell.SecretStore extension, registers a throwaway vault, stores
# real secrets in it, and drives the real action against them.
#
# Whether it can run is decided by Get-LiveVaultSkipReason (Tests/TestHelpers), which checks that
# both modules are installed and that PIPELINERUNNER_ALLOW_SECRETSTORE_RESET opts in to the
# destructive SecretStore reconfiguration. It is called TWICE, deliberately: Pester evaluates an
# It's -Skip: argument during DISCOVERY and runs BeforeAll during EXECUTION, and those are
# separate scopes - a variable assigned here at file scope is $null by the time BeforeAll runs.
# The probe therefore lives in the test-helper module so both phases can call it.

$script:SecretsSkipReason = Get-LiveVaultSkipReason
$script:SecretsAvailable  = [string]::IsNullOrEmpty($script:SecretsSkipReason)

if (-not $script:SecretsAvailable) {
    Write-Warning "[SecretManagementCredential.Integration] Skipping the live-vault tests: $($script:SecretsSkipReason)"
}

Describe "Credential/SecretManagement against a live SecretManagement vault" -Tag Integration, HostedIntegration {

    BeforeAll {
        $script:SecretManagementPath = (Get-FunctionPath 'SecretManagement.ps1').FullName
        $script:VaultName            = 'PipelineRunnerIntegration'

        # Re-probed here for the execution scope (see the file header): the discovery-phase value
        # above drove the -Skip: decisions but is not visible from inside BeforeAll.
        $script:SecretsAvailable = [string]::IsNullOrEmpty((Get-LiveVaultSkipReason))

        if ($script:SecretsAvailable) {
            Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
            Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop

            # Unattended configuration: no password prompt, no interactive unlock. Reset-SecretStore
            # is what actually applies this to a store that may already exist, which is why the
            # opt-in gate above exists.
            Reset-SecretStore -Authentication None -Interaction None -Scope CurrentUser -Force -ErrorAction Stop

            # Registered by an explicit name and always addressed by -Vault, so the suite never
            # depends on (or changes) whichever vault the host considers its default.
            if (Get-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue) {
                Unregister-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue
            }
            Register-SecretVault -Name $script:VaultName -ModuleName Microsoft.PowerShell.SecretStore -ErrorAction Stop

            # Two secret shapes the action is contracted to handle, plus one it must reject.
            $script:CredentialSecretName = 'pr-credential-secret'
            $script:SecureStringSecretName = 'pr-securestring-secret'
            $script:UnsupportedSecretName = 'pr-unsupported-secret'

            $script:ExpectedUserName = 'CONTOSO\svc-pipelinerunner'
            $script:ExpectedPassword = 'S3cret-' + [guid]::NewGuid().ToString('N')

            $securePassword = ConvertTo-SecureString -String $script:ExpectedPassword -AsPlainText -Force

            Set-Secret -Name $script:CredentialSecretName -Vault $script:VaultName -ErrorAction Stop `
                -Secret ([System.Management.Automation.PSCredential]::new($script:ExpectedUserName, $securePassword))

            Set-Secret -Name $script:SecureStringSecretName -Vault $script:VaultName -Secret $securePassword -ErrorAction Stop

            # A byte-array secret, deliberately NOT a plain string: SecretManagement hands a String
            # secret back as a SecureString unless -AsPlainText is passed, so a string would take
            # the SecureString branch instead of the rejection this test is here to cover. A
            # byte[] round-trips as a byte[] and is exactly what the action refuses.
            Set-Secret -Name $script:UnsupportedSecretName -Vault $script:VaultName -Secret ([byte[]]@(1, 2, 3)) -ErrorAction Stop
        }

        # Reads a PSCredential's password back as plain text so a test can assert the exact value
        # survived the round trip through the vault.
        function Get-PlainTextPassword {
            param([System.Management.Automation.PSCredential]$Credential)
            return $Credential.GetNetworkCredential().Password
        }
    }

    AfterAll {
        if ($script:SecretsAvailable) {
            foreach ($name in @($script:CredentialSecretName, $script:SecureStringSecretName, $script:UnsupportedSecretName)) {
                Remove-Secret -Name $name -Vault $script:VaultName -ErrorAction SilentlyContinue
            }
            Unregister-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue
        }
    }

    It "resolves a PSCredential secret out of the vault unchanged" -Skip:(-not $script:SecretsAvailable) {

        $credential = & $script:SecretManagementPath -Context @{
            Name  = $script:CredentialSecretName
            Vault = $script:VaultName
        }

        $credential | Should -BeOfType [System.Management.Automation.PSCredential]
        $credential.UserName | Should -Be $script:ExpectedUserName
        (Get-PlainTextPassword -Credential $credential) | Should -Be $script:ExpectedPassword
    }

    It "wraps a bare SecureString secret in a PSCredential named after the secret" -Skip:(-not $script:SecretsAvailable) {

        # No UserName in the context, so the action's documented default applies: the secret's
        # own name becomes the credential's username.
        $credential = & $script:SecretManagementPath -Context @{
            Name  = $script:SecureStringSecretName
            Vault = $script:VaultName
        }

        $credential | Should -BeOfType [System.Management.Automation.PSCredential]
        $credential.UserName | Should -Be $script:SecureStringSecretName
        (Get-PlainTextPassword -Credential $credential) | Should -Be $script:ExpectedPassword
    }

    It "uses a supplied UserName for a bare SecureString secret" -Skip:(-not $script:SecretsAvailable) {

        $credential = & $script:SecretManagementPath -Context @{
            Name     = $script:SecureStringSecretName
            Vault    = $script:VaultName
            UserName = 'CONTOSO\explicit-user'
        }

        $credential.UserName | Should -Be 'CONTOSO\explicit-user'
        (Get-PlainTextPassword -Credential $credential) | Should -Be $script:ExpectedPassword
    }

    It "resolves a secret without an explicit Vault when the vault is the default" -Skip:(-not $script:SecretsAvailable) {

        # Exercises the branch that omits Get-Secret's -Vault parameter entirely. The vault is
        # promoted to default only for the duration of this test and demoted again afterwards,
        # so the other tests keep addressing it explicitly.
        Set-SecretVaultDefault -Name $script:VaultName -ErrorAction Stop
        try {
            $credential = & $script:SecretManagementPath -Context @{ Name = $script:CredentialSecretName }

            $credential.UserName | Should -Be $script:ExpectedUserName
            (Get-PlainTextPassword -Credential $credential) | Should -Be $script:ExpectedPassword
        }
        finally {
            Set-SecretVaultDefault -ClearDefault -ErrorAction SilentlyContinue
        }
    }

    It "throws for a secret that is neither a PSCredential nor a SecureString" -Skip:(-not $script:SecretsAvailable) {

        # The action's last guard: anything that is not a PSCredential or a SecureString cannot
        # become a credential, and must say so rather than returning something unusable.
        { & $script:SecretManagementPath -Context @{ Name = $script:UnsupportedSecretName; Vault = $script:VaultName } } |
            Should -Throw "*cannot resolve it to a credential*"
    }

    It "throws a 'not found' error for a secret the vault does not hold" -Skip:(-not $script:SecretsAvailable) {

        # Get-Secret is called with -ErrorAction Stop, so a missing secret surfaces as a throw.
        # Either the action's own "not found" message or SecretManagement's own error is a
        # correct outcome; what must not happen is a silent $null credential reaching the runner.
        { & $script:SecretManagementPath -Context @{ Name = 'pr-no-such-secret'; Vault = $script:VaultName } } |
            Should -Throw
    }

    It "still rejects a missing secret Name before touching a vault" {
        # Not skipped with the rest: the guard fires before the module check, so it holds on any
        # host and keeps the suite from reporting "all skipped" where no vault is configured.
        { & $script:SecretManagementPath -Context @{} } | Should -Throw "*Name*"
    }
}
