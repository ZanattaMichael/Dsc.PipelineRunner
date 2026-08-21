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
# $Context is intentionally ignored: every Connect action shares one signature so the
# runner can invoke them uniformly. This action establishes no session.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Context',
    Justification = 'Present so every Connect action shares the same signature; the no-auth action ignores it by design.')]
param(
    [hashtable]$Context = @{}
)

Write-Verbose "[Actions/Connect/None] No authentication provider required."
return $null
