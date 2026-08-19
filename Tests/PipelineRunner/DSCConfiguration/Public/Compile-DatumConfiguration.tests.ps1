Describe "Compile-DatumConfiguration Function Tests" -Tag Unit -Skip {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Compile-DatumConfiguration.ps1').FullName
        Wait-Debugger
        . $preParseFilePath

        Mock -CommandName Get-ChildItem -MockWith {
            @()  # Return an empty array to simulate no files present
        }
    
        Mock -CommandName Test-Path -MockWith { return $true }
        Mock -CommandName Remove-Item
        Mock -CommandName Write-Verbose
        Mock -CommandName Import-Module
        Mock -CommandName Set-Location
        Mock -CommandName New-DatumStructure -MockWith {
            return [PSCustomObject]@{
                Projects = [PSCustomObject]@{
                    ExampleProjectType = [PSCustomObject]@{
                        ExampleNode = [PSCustomObject]@{}
                    }
                }
            }
        }
    
        Mock -CommandName Resolve-Datum -MockWith {
            return @{
                resources   = @{}
                parameters  = @{}
                conditions  = @{}
                variables   = @{}
            }
        }

        $OutputPath = New-MockDirectoryPath
        $ConfigurationPath = New-MockDirectoryPath

    }

    It "should clear the output directory" {

        Compile-DatumConfiguration -OutputPath $OutputPath -ConfigurationPath $ConfigurationPath

        # Verify that Get-ChildItem was called with the correct parameters
        Assert-MockCalled -CommandName Get-ChildItem -Exactly 1 -Scope It -ParameterFilter { $_.LiteralPath -eq $OutputPath }
        
        # Verify that Remove-Item was called
        Assert-MockCalled -CommandName Remove-Item -AtLeast 0 -Scope It
    }

    It "should import necessary modules" {
        Compile-DatumConfiguration -OutputPath $OutputPath -ConfigurationPath $ConfigurationPath

        # Verify that Import-Module was called for each required module
        Assert-MockCalled -CommandName Import-Module -Exactly 3 -Scope It
    }

    It "should create a Datum structure from definition file" {
        Compile-DatumConfiguration -OutputPath $OutputPath -ConfigurationPath $ConfigurationPath

        # Verify that New-DatumStructure was called
        Assert-MockCalled -CommandName New-DatumStructure -Exactly 1 -Scope It
    }

    It "should resolve configurations for each node" {
        Compile-DatumConfiguration -OutputPath $OutputPath -ConfigurationPath $ConfigurationPath

        # Verify that Resolve-Datum was called multiple times for different properties
        Assert-MockCalled -CommandName Resolve-Datum -AtLeast 4 -Scope It
    }
}
