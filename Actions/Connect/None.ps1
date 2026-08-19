<#
.SYNOPSIS
Connect action: no authentication (default).

.DESCRIPTION
The default Connect action. It establishes no session and returns $null, so the
core runner can evaluate DSC resources that need no ambient provider (for example
local, cross-platform DSC v3 resources) with zero coupling to any cloud service.

.PARAMETER Context
Ignored. Present so every action shares the same signature.

.OUTPUTS
$null
#>
param(
    [hashtable]$Context = @{}
)

Write-Verbose "[Actions/Connect/None] No authentication provider required."
return $null
