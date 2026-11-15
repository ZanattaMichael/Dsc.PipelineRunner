<#
Security regression suite: a rejected -PATToken is never echoed back.

PowerShell's default ValidatePattern failure quotes the rejected argument, so a token that is
only slightly malformed (a stray quote, an underscore, a trailing newline from a pipeline
variable) is printed into the pipeline log in full. The parameter's own ErrorMessage must
replace that text, and the pattern must anchor with \A..\z because '$' also matches before a
trailing newline. These tests build a function from the real parameter attribute, so they pin
the shipped declaration, not a copy of it. Dummy values only.
#>
Describe "Security: -PATToken validation does not echo the token" -Tag Unit, Security {

    BeforeAll {
        $path = (Get-FunctionPath 'Invoke-DscPipelineRunner.ps1').FullName
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $parameter = $ast.Find({
            $args[0] -is [System.Management.Automation.Language.ParameterAst] -and $args[0].Name.VariablePath.UserPath -eq 'PATToken'
        }, $true)
        $script:attributeText = ($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidatePattern' }).Extent.Text
        $script:binder = [scriptblock]::Create("param($($script:attributeText)[string]`$PATToken) 'accepted'")
    }

    It "declares a ValidatePattern with a custom ErrorMessage" {
        $script:attributeText | Should -Match 'ErrorMessage'
        $script:attributeText | Should -Not -Match '\{0\}'
    }

    It "accepts a well-formed token" {
        (& $script:binder -PATToken ('A1' * 15)) | Should -Be 'accepted'
    }

    It "rejects <Label> without printing it" -ForEach @(
        @{ Label = 'a token containing a hyphen and underscore'; Token = 'dummy-TOKEN-0123456789_x' }
        @{ Label = 'a token with a trailing newline';             Token = ('A1' * 15) + "`n" }
        @{ Label = 'a token that is too short';                   Token = 'dummyshort12' }
        @{ Label = 'a token containing a quote';                  Token = 'dummyTOKEN0123456789"x' }
    ) {
        $thrown = $null
        try { $null = & $script:binder -PATToken $Token } catch { $thrown = $_.Exception.Message }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -Match 'not in the expected format'
        $thrown | Should -Not -Match 'dummy'
        if ($Token.Length -gt 20) { $thrown | Should -Not -Match ([regex]::Escape($Token.Trim())) }
    }
}
