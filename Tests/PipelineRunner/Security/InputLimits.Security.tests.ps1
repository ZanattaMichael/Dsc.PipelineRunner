<#
Security regression suite: values that become a file name, a process argument or a resource count
are bounded.

  * a compiled node file name cannot leave the output directory,
  * a composite expansion cannot describe an unbounded number of resources (nesting depth alone
    does not bound the output: 10 composites listing 10 members of the next give 10^10),
  * an SSH host name cannot be read by ssh as an option.

Dummy values only.
#>
Describe "Security: node file names, composite fan-out and SSH host names are bounded" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName
        $script:SSHPath = (Get-FunctionPath 'SSH.ps1').FullName

        function ConvertTo-Yaml {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true, ValueFromPipeline = $true)] $InputObject)
            return "---`nkey: value"
        }

        Mock -CommandName Write-Host
        Mock -CommandName Write-Verbose
        Mock -CommandName Write-Information
        Mock -CommandName Resolve-Datum -MockWith { return @{} }
        Mock -CommandName Test-InvokeCommandFilter -MockWith { return $false }
        Mock -CommandName Invoke-InvokeCommandAction -MockWith { return $_ }
        Mock -CommandName ConvertTo-Yaml -MockWith { return "---`nkey: value" }
        Mock -CommandName Out-File
        Mock -CommandName New-PSSession -MockWith {
            param($HostName, $UserName, $KeyFilePath)
            return [pscustomobject]@{ Marker = 'ssh'; HostName = $HostName }
        }

        # Each level lists five members of the next, so three levels expand to 5 * 5 * 5 = 125 leaves.
        function New-FanOutDefinitions {
            $leaf = { 1..5 | ForEach-Object { [ordered]@{ name = "Leaf$_"; type = 'Stub/Leaf'; properties = @{ n = $_ } } } }
            $level = { param($childType) 1..5 | ForEach-Object { [ordered]@{ name = "Child$_"; type = "Composite/$childType" } } }
            return @{
                L1 = [ordered]@{ resources = @(& $level 'L2') }
                L2 = [ordered]@{ resources = @(& $level 'L3') }
                L3 = [ordered]@{ resources = @(& $leaf) }
            }
        }
    }

    Context "compiled node file name" {

        It "refuses the node name <Name> and writes nothing" -ForEach @(
            @{ Name = '..\..\outside' }
            @{ Name = '../outside' }
            @{ Name = 'sub/dir' }
            @{ Name = 'C:evil' }
            @{ Name = '.hidden' }
            @{ Name = 'a..b' }
            @{ Name = 'wild*card' }
            @{ Name = 'pipe|name' }
            @{ Name = ' leading-space' }
            @{ Name = '' }
        ) {
            { Resolve-DscDatumProject -NodeName @{ Name = $Name } -AllNodes @{} } | Should -Throw '*not a valid file name*'

            Should -Invoke -CommandName Out-File -Exactly 0 -Scope It
        }

        It "still accepts the ordinary node name <Name>" -ForEach @(
            @{ Name = 'Node1' }
            @{ Name = 'Magenta' }
            @{ Name = 'web-01.contoso.com' }
            @{ Name = 'node_2' }
            @{ Name = 'node[1]' }
        ) {
            { Resolve-DscDatumProject -NodeName @{ Name = $Name } -AllNodes @{} } | Should -Not -Throw

            Should -Invoke -CommandName Out-File -Exactly 1 -Scope It
        }
    }

    Context "composite fan-out" {

        It "expands a fan-out that is within the limit" {
            $resources = @([ordered]@{ name = 'root'; type = 'Composite/L1' })

            $result = @(Expand-CompositeResource -Resources $resources -Definitions (New-FanOutDefinitions) -MaxResources 200)

            $result.Count | Should -Be 125
        }

        It "stops, with a clear error, when the expansion would exceed -MaxResources" {
            $resources = @([ordered]@{ name = 'root'; type = 'Composite/L1' })

            { Expand-CompositeResource -Resources $resources -Definitions (New-FanOutDefinitions) -MaxResources 100 } |
                Should -Throw '*more than 100 resources*'
        }

        It "applies a default limit, so an unbounded expansion cannot be asked for by accident" {
            (Get-Command Expand-CompositeResource).Parameters['MaxResources'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] } |
                ForEach-Object { $_.MaxRange } | Should -Be 1000000
            $resources = @([ordered]@{ name = 'root'; type = 'Composite/L1' })
            @(Expand-CompositeResource -Resources $resources -Definitions (New-FanOutDefinitions)).Count | Should -Be 125
        }
    }

    Context "SSH host name" {

        It "refuses the option-shaped host name <HostName>" -ForEach @(
            @{ HostName = '-oProxyCommand=touch /tmp/pwned' }
            @{ HostName = '-oProxyCommand=evil' }
            @{ HostName = '--version' }
            @{ HostName = 'host name with spaces' }
            @{ HostName = 'host;rm -rf /' }
        ) {
            { & $script:SSHPath -Context @{ ComputerName = $HostName; Engine = 'DscV3' } } | Should -Throw '*not a valid host name*'

            Should -Invoke -CommandName New-PSSession -Exactly 0 -Scope It
        }

        It "still accepts the host name <HostName>" -ForEach @(
            @{ HostName = 'node01' }
            @{ HostName = 'node01.contoso.com' }
            @{ HostName = 'deploy@node01' }
            @{ HostName = '10.0.0.5' }
            @{ HostName = '[::1]' }
        ) {
            { & $script:SSHPath -Context @{ ComputerName = $HostName; Engine = 'DscV3' } } | Should -Not -Throw

            Should -Invoke -CommandName New-PSSession -Exactly 1 -Scope It
        }
    }
}
