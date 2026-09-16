Describe "String and collection function-language accessors" -Tag Unit, Runner, Configuration {

    # concat / empty / coalesce / toLower / toUpper / startsWith / contains are covered together
    # because what they are for is a single job - letting a preCondition, which has no string
    # interpolation available to it, express the checks a property expression would write with
    # $( ) and a method call. Their shared rules (a $null operand degrades rather than throws;
    # comparison is case-insensitive unless asked otherwise) are only visible side by side.

    BeforeAll {
        . (Get-FunctionPath 'Expand-ConditionArgumentList.ps1').FullName
        . (Get-FunctionPath 'concat.ps1').FullName
        . (Get-FunctionPath 'empty.ps1').FullName
        . (Get-FunctionPath 'coalesce.ps1').FullName
        . (Get-FunctionPath 'toLower.ps1').FullName
        . (Get-FunctionPath 'toUpper.ps1').FullName
        . (Get-FunctionPath 'startsWith.ps1').FullName
        . (Get-FunctionPath 'contains.ps1').FullName
    }

    Context "concat" {

        It "joins its operands with no separator" {
            concat 'a' 'b' 'c' | Should -Be 'abc'
        }

        It "treats a `$null operand as an empty string rather than the text 'null'" {
            concat 'a' $null 'c' | Should -Be 'ac'
        }

        It "converts non-string operands to their string form" {
            concat 'v' 1 '.' 2 | Should -Be 'v1.2'
        }

        It "returns an empty string when given no operands" {
            concat | Should -Be ''
        }

        It "flattens an array operand and joins its elements" {
            # PowerShell unrolls an array into a variadic parameter, so `concat (variables 'X')`
            # and `concat 'a' 'b'` arrive identically - there is deliberately no array-merging
            # mode, because it could not be told apart from this one.
            concat @('x', 'y') | Should -Be 'xy'
        }
    }

    Context "empty" {

        It "reports `$null as empty" {
            empty $null | Should -BeTrue
        }

        It "reports an empty string as empty and a whitespace string as not empty" {
            empty ''  | Should -BeTrue
            empty ' ' | Should -BeFalse
        }

        It "reports an empty collection as empty" {
            empty @()    | Should -BeTrue
            empty @(1)   | Should -BeFalse
        }

        It "reports an empty dictionary as empty" {
            empty @{}         | Should -BeTrue
            empty @{ a = 1 }  | Should -BeFalse
        }

        It "asks whether a value is present, not whether it is truthy" {
            # The distinction that makes it usable as a guard: 0 and $false are values.
            empty 0      | Should -BeFalse
            empty $false | Should -BeFalse
        }
    }

    Context "coalesce" {

        It "returns the first operand that is not `$null" {
            coalesce $null $null 'x' | Should -Be 'x'
        }

        It "returns the first operand when it has a value" {
            coalesce 'a' 'b' | Should -Be 'a'
        }

        It "treats an empty string as a value, not as absent" {
            # ARM's rule, and the one that makes a deliberately blanked layer win. Pair it with
            # empty() when a blank should fall through.
            coalesce '' 'b' | Should -Be ''
        }

        It "returns `$null when every operand is null" {
            coalesce $null $null | Should -BeNullOrEmpty
        }
    }

    Context "toLower and toUpper" {

        It "changes case" {
            toLower 'PrOd' | Should -Be 'prod'
            toUpper 'prod' | Should -Be 'PROD'
        }

        It "returns an empty string for `$null rather than throwing" {
            toLower $null | Should -Be ''
            toUpper $null | Should -Be ''
        }
    }

    Context "startsWith" {

        It "is case-insensitive by default" {
            startsWith 'Internal-Billing' 'internal-' | Should -BeTrue
        }

        It "is ordinal when asked" {
            startsWith 'Internal-Billing' 'internal-' -CaseSensitive | Should -BeFalse
        }

        It "treats an empty prefix as matching, so an unset filter means no filter" {
            startsWith 'abc' '' | Should -BeTrue
        }

        It "treats a `$null value as an empty string" {
            startsWith $null 'a' | Should -BeFalse
        }
    }

    Context "contains" {

        It "tests a substring when the container is a string" {
            contains 'Encrypt=True;Timeout=30' 'encrypt=true' | Should -BeTrue
            contains 'Encrypt=True;Timeout=30' 'encrypt=true' -CaseSensitive | Should -BeFalse
        }

        It "tests membership when the container is an array" {
            contains @('Boards', 'Repos') 'boards'     | Should -BeTrue
            contains @('Boards', 'Repos') 'Pipelines'  | Should -BeFalse
        }

        It "compares non-string array elements with their own equality" {
            contains @(1, 2, 3) 2 | Should -BeTrue
        }

        It "tests the KEYS, not the values, when the container is a dictionary" {
            # The distinction that catches people: a `variables` block of key/value pairs is a
            # dictionary, so contains() asks whether the key is declared.
            contains @{ Boards = 'enabled' } 'boards'   | Should -BeTrue
            contains @{ Boards = 'enabled' } 'enabled'  | Should -BeFalse
        }

        It "reports `$false for a `$null container rather than throwing" {
            contains $null 'a' | Should -BeFalse
        }
    }

    Context "Expand-ConditionArgumentList" {

        It "flattens nested arrays" {
            (Expand-ConditionArgumentList -Value @(@(1, 2), 3)) -join ',' | Should -Be '1,2,3'
        }

        It "does not enumerate a string into characters" {
            @(Expand-ConditionArgumentList -Value @('ab')).Count | Should -Be 1
        }

        It "does not enumerate a dictionary into its entries" {
            @(Expand-ConditionArgumentList -Value @(@{ a = 1; b = 2 })).Count | Should -Be 1
        }

        It "preserves `$null operands so coalesce can see them" {
            @(Expand-ConditionArgumentList -Value @($null, 'x')).Count | Should -Be 2
        }
    }
}
