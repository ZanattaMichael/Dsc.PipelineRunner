Describe "Arithmetic function-language accessors" -Tag Unit, Runner, Configuration {

    # The nine arithmetic accessors share one coercion (ConvertTo-ConditionNumber) and one
    # behavioural contract, so they are covered together rather than in nine near-identical
    # files: what is actually under test is the contract, and splitting it up would hide which
    # accessors are meant to agree with each other.
    #
    # The contract, in one sentence: an operand's OWN type decides the result's type, a string
    # operand is parsed with the invariant culture, and anything that is not a number throws
    # rather than resolving to 0.

    BeforeAll {
        . (Get-FunctionPath 'ConvertTo-ConditionNumber.ps1').FullName
        . (Get-FunctionPath 'Expand-ConditionArgumentList.ps1').FullName
        . (Get-FunctionPath 'add.ps1').FullName
        . (Get-FunctionPath 'sub.ps1').FullName
        . (Get-FunctionPath 'mul.ps1').FullName
        . (Get-FunctionPath 'div.ps1').FullName
        . (Get-FunctionPath 'mod.ps1').FullName
        . (Get-FunctionPath 'min.ps1').FullName
        . (Get-FunctionPath 'max.ps1').FullName
        . (Get-FunctionPath 'int.ps1').FullName
        . (Get-FunctionPath 'float.ps1').FullName
    }

    Context "add, sub and mul" {

        It "adds two whole numbers and returns a whole number" {
            $result = add 1 2
            $result | Should -Be 3
            $result | Should -BeOfType [long]
        }

        It "adds operands that arrived from a configuration file as strings" {
            # The case that makes the coercion load-bearing: every scalar in a YAML/JSON
            # configuration can reach an accessor as a string, and '7' + '3' in PowerShell is
            # the string '73'.
            add '7' '3' | Should -Be 10
        }

        It "keeps a real operand real" {
            add 1.5 2 | Should -Be 3.5
        }

        It "subtracts in the written order" {
            sub 10 3 | Should -Be 7
        }

        It "multiplies" {
            mul 3 4 | Should -Be 12
        }
    }

    Context "div" {

        It "divides two whole numbers as whole-number division" {
            # This is the one deliberate difference from PowerShell's own '/', which would
            # return 3.5 here.
            $result = div 7 2
            $result | Should -Be 3
            $result | Should -BeOfType [long]
        }

        It "truncates toward zero rather than flooring" {
            div -7 2 | Should -Be -3
        }

        It "divides for real when either operand is real" {
            div 7.5 2 | Should -Be 3.75
        }

        It "divides for real when float() was used to say so" {
            # float() would be pointless if the coercion collapsed a whole-valued double back
            # to [long] - this is the test that pins that down.
            div (float 7) 2 | Should -Be 3.5
        }

        It "throws on a zero divisor rather than returning infinity" {
            { div 1 0 } | Should -Throw '*Division by zero*'
        }
    }

    Context "mod" {

        It "returns the remainder" {
            mod 7 3 | Should -Be 1
        }

        It "takes the sign of the dividend" {
            mod -7 3 | Should -Be -1
        }

        It "throws on a zero divisor" {
            { mod 1 0 } | Should -Throw '*Division by zero*'
        }
    }

    Context "min and max" {

        It "selects from operands written out" {
            min 3 1 2 | Should -Be 1
            max 3 1 2 | Should -Be 3
        }

        It "selects from a single array operand" {
            min @(9, 10, 4) | Should -Be 4
            max @(9, 10, 4) | Should -Be 10
        }

        It "compares string operands numerically rather than lexically" {
            # Lexically '10' sorts before '9'; numerically it does not.
            min '9' '10' | Should -Be 9
            max '9' '10' | Should -Be 10
        }

        It "returns a whole number for whole-number operands" {
            # Measure-Object would return a [double] here, which would then propagate into a
            # resource property as '4' vs '4' but into div() as real division.
            (min 3 1 2) | Should -BeOfType [long]
            (max 3 1 2) | Should -BeOfType [long]
        }

        It "throws when given no operands" {
            { min } | Should -Throw '*at least one number*'
            { max } | Should -Throw '*at least one number*'
        }
    }

    Context "int and float" {

        It "truncates toward zero rather than rounding" {
            int 2.9  | Should -Be 2
            int -2.9 | Should -Be -2
        }

        It "converts a string to a number" {
            $result = int '8080'
            $result | Should -Be 8080
            $result | Should -BeOfType [long]
        }

        It "converts a whole number to a real one" {
            float 7 | Should -BeOfType [double]
        }
    }

    Context "rejecting operands that are not numbers" {

        It "throws on text rather than treating it as zero" {
            { add 'abc' 1 } | Should -Throw '*not numeric*'
        }

        It "throws on `$null rather than treating it as zero" {
            # variables() returns $null for an undefined variable, so this is the shape of a
            # typo in a configuration - it must fail the resource, not compute on nothing.
            { add $null 1 } | Should -Throw '*received $null*'
        }

        It "throws on a boolean" {
            { mul $true 2 } | Should -Throw '*received a boolean*'
        }

        It "names the calling accessor in the message" {
            { sub 'x' 1 } | Should -Throw '*[sub]*'
        }
    }

    Context "ConvertTo-ConditionNumber" {

        It "parses with the invariant culture" {
            # A machine whose locale uses ',' as the decimal separator must read the same
            # configuration the same way.
            ConvertTo-ConditionNumber -Value '2.5' -Accessor 'test' | Should -Be 2.5
        }

        It "keeps a real value real even when its value is whole" {
            ConvertTo-ConditionNumber -Value 7.0 -Accessor 'test' | Should -BeOfType [double]
        }

        It "returns a whole number for an integer-valued string" {
            ConvertTo-ConditionNumber -Value '7' -Accessor 'test' | Should -BeOfType [long]
        }
    }
}
