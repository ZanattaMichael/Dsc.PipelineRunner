Describe "nodeName and configurationFile function-language accessors" -Tag Unit, Runner, Configuration {

    # Both read module-script state that Start-DscRunner owns, so the unit-level contract is
    # narrow: they return what was set, and they return $null when nothing is set. That second
    # half is the one worth pinning - it is what stops a value leaking from one configuration
    # file into a condition evaluated for the next. Start-DscRunner's half of the contract (it
    # sets them per file and clears them in its finally block) is covered by
    # FunctionLanguage.Integration.tests.ps1, which runs the real loop.

    BeforeAll {
        . (Get-FunctionPath 'nodeName.ps1').FullName
        . (Get-FunctionPath 'configurationFile.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
    }

    BeforeEach {
        $script:currentNodeName          = $null
        $script:currentConfigurationFile = $null
    }

    It "returns the node name the runner recorded" {
        $script:currentNodeName = 'SRV-APP-01'
        nodeName | Should -Be 'SRV-APP-01'
    }

    It "returns the configuration file path the runner recorded" {
        $script:currentConfigurationFile = '/configs/SRV-APP-01.yml'
        configurationFile | Should -Be '/configs/SRV-APP-01.yml'
    }

    It "returns `$null outside a run" {
        nodeName          | Should -BeNullOrEmpty
        configurationFile | Should -BeNullOrEmpty
    }

    It "is rewritten from its documented zero-argument spelling into one that parses" {
        # `identifier()` is not valid PowerShell, so the documented nodeName() spelling only
        # works because the normalizer rewrites it before the condition is parsed.
        ConvertTo-NormalizedConditionExpression -Expression "startsWith (nodeName()) 'SRV'" |
            Should -Be "startsWith ((nodeName)) 'SRV'"

        ConvertTo-NormalizedConditionExpression -Expression 'configurationFile()' |
            Should -Be '(configurationFile)'
    }

    It "produces a rewritten condition that actually parses" {
        $normalized = ConvertTo-NormalizedConditionExpression -Expression "startsWith (nodeName()) 'SRV'"

        $parseErrors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($normalized, [ref] $tokens, [ref] $parseErrors) | Out-Null

        $parseErrors | Should -BeNullOrEmpty
    }
}
