<#
.SYNOPSIS
A self-contained, class-based DSC v2 resource used only by the self-hosted DSC v2
integration tests.

.DESCRIPTION
Invoke-DscResource (the DSC v2 engine path) needs a real, discoverable DSC resource to
drive. AzureDevOpsDscNative cannot be installed on CI (it needs a live Azure DevOps org), so
these tests stand up their own dependency-free resource instead: a "marker file" resource
whose presence on disk stands in for a real cloud object existing.

The resource is deterministic and has no external dependencies, so a self-hosted Windows
runner with PowerShell 7 + PSDesiredStateConfiguration can genuinely exercise the runner's
DscV2 engine end-to-end (real Test/Set/Get through Invoke-DscResource) without any mock:

  * Test -> the marker file exists (Present) or does not (Absent), inverted for Ensure = Absent.
  * Set  -> creates the marker file (Present) or deletes it (Absent).
  * Get  -> reports the current Ensure by inspecting the file system.

Modeled to mirror the Example Configuration's build/teardown shape: a "Project"-like marker
is created on build (Ensure = Present) and removed on teardown (Ensure = Absent).
#>

enum Ensure
{
    Absent
    Present
}

[DscResource()]
class PipelineRunnerFile
{
    # The instance name; also the marker file's base name. Key so each resource instance is
    # a distinct marker.
    [DscProperty(Key)]
    [string] $Name

    # The directory the marker file lives in. Mandatory so the test controls exactly where
    # state is written (a per-run temp directory), keeping runs isolated and observable.
    [DscProperty(Mandatory)]
    [string] $Path

    # Whether the marker should exist. Present creates it; Absent removes it.
    [DscProperty()]
    [Ensure] $Ensure = [Ensure]::Present

    # Resolves the marker file path for this instance.
    hidden [string] MarkerPath()
    {
        return (Join-Path -Path $this.Path -ChildPath ('{0}.marker' -f $this.Name))
    }

    [bool] Test()
    {
        $exists = Test-Path -LiteralPath $this.MarkerPath()
        if ($this.Ensure -eq [Ensure]::Present)
        {
            return $exists
        }
        return (-not $exists)
    }

    [void] Set()
    {
        $marker = $this.MarkerPath()
        if ($this.Ensure -eq [Ensure]::Present)
        {
            if (-not (Test-Path -LiteralPath $this.Path))
            {
                New-Item -ItemType Directory -Path $this.Path -Force | Out-Null
            }
            Set-Content -LiteralPath $marker -Value $this.Name
        }
        else
        {
            if (Test-Path -LiteralPath $marker)
            {
                Remove-Item -LiteralPath $marker -Force
            }
        }
    }

    [PipelineRunnerFile] Get()
    {
        $current = [PipelineRunnerFile]::new()
        $current.Name = $this.Name
        $current.Path = $this.Path
        if (Test-Path -LiteralPath $this.MarkerPath())
        {
            $current.Ensure = [Ensure]::Present
        }
        else
        {
            $current.Ensure = [Ensure]::Absent
        }
        return $current
    }
}
