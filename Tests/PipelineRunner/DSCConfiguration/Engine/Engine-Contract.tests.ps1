# Shared contract every execution engine (Actions/Engine/<Name>.ps1) must satisfy:
# given a Test/Set/Get context, it returns an object that normalizes cleanly into a
# [DscMethodResult] exposing InDesiredState:[bool], RebootRequired:[bool],
# Message:[string] and Raw. DscV2 and DscV3 both run through this suite with their
# backends mocked, so a new engine is "done" only once it is green here too.
Describe "Execution engine contract" -Tag Unit, Engine {

    BeforeAll {
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName

        $script:DscV2Path = (Get-FunctionPath 'DscV2.ps1').FullName
        $script:DscV3Path = (Get-FunctionPath 'DscV3.ps1').FullName

        # DscV2 backend: Invoke-DscResource returns a per-method shape.
        Mock -CommandName Invoke-DscResource -MockWith {
            param($Name, $ModuleName, $Method, $Property)
            switch ($Method) {
                'Test'  { return [pscustomobject]@{ InDesiredState = $true; Message = 'tested' } }
                'Set'   { return [pscustomobject]@{ RebootRequired = $false } }
                default { return [pscustomobject]@{ Prop = 'current' } }
            }
        }

        # DscV3 backend: dsc.exe returns method-appropriate JSON with a zero exit code.
        Mock -CommandName Invoke-DscExecutable -MockWith {
            param($Arguments, $Executable)
            $verb = $Arguments[1]
            $json = switch ($verb) {
                'test'  { '{"inDesiredState":true,"differingProperties":[]}' }
                'set'   { '{"changedProperties":["Ensure"]}' }
                default { '{"actualState":{"Prop":"current"}}' }
            }
            return @{ ExitCode = 0; Output = $json }
        }
    }

    It "<Name> returns a contract-valid result for every method" -ForEach @(
        @{ Name = 'DscV2' }
        @{ Name = 'DscV3' }
    ) {
        $enginePath = if ($Name -eq 'DscV2') { $script:DscV2Path } else { $script:DscV3Path }

        foreach ($method in 'Test', 'Set', 'Get') {
            $context = @{ Method = $method; ModuleName = 'Mod'; Name = 'Res'; Property = @{ Ensure = 'Present' } }
            $raw = & $enginePath -Context $context
            $normalized = ConvertTo-DscMethodResult -InputObject $raw -Method $method

            $normalized | Should -BeOfType ([DscMethodResult])
            $normalized.InDesiredState | Should -BeOfType ([bool])
            $normalized.RebootRequired | Should -BeOfType ([bool])
        }
    }
}
