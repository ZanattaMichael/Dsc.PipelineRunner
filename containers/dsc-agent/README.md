# Dsc.PipelineRunner hosted-agent image

A runtime base image for evaluating configurations through the **DSC v3** engine on Linux:

- PowerShell (official `mcr.microsoft.com/powershell` base)
- the DSC v3 command-line engine (`dsc`), installed via
  [`scripts/Install-DscV3.ps1`](../../scripts/Install-DscV3.ps1)
- the runner's required PowerShell modules (`Datum`, `Datum.InvokeCommand`,
  `powershell-yaml`, `PSDesiredStateConfiguration`)

It is intentionally a **base**: it does not bake in a specific build of
`Dsc.PipelineRunner`, so the image stays reusable across module versions. Add the module
on top.

## Build

Build from the repository root (the build context must include `scripts/`):

```bash
# Latest stable dsc.
docker build -f containers/dsc-agent/Dockerfile -t dsc-pipelinerunner-agent .

# Pin the dsc release and/or the PowerShell base tag.
docker build -f containers/dsc-agent/Dockerfile \
  --build-arg DSC_VERSION=v3.0.0 \
  --build-arg POWERSHELL_TAG=7.4-ubuntu-22.04 \
  -t dsc-pipelinerunner-agent:3.0.0 .
```

## Use

Provide the module (once published, install from the PowerShell Gallery; until then, mount
a locally built copy onto the module path) and call `Invoke-DscRunner`:

```bash
docker run --rm -it \
  -v "$PWD/output/Dsc.PipelineRunner:/usr/local/share/powershell/Modules/Dsc.PipelineRunner:ro" \
  -v "$PWD/config:/workspace/config:ro" \
  dsc-pipelinerunner-agent \
  pwsh -c "Import-Module Dsc.PipelineRunner; Invoke-DscRunner -ConfigurationSourcePath /workspace/config -Mode Test -Engine DscV3"
```

`dsc` is already on `PATH`, so `-Engine DscV3` (or `-Engine Auto`) works out of the box.
For private configuration repositories, pass a token via the source context or expose the
job's short-lived token as `SYSTEM_ACCESSTOKEN` — see
[docs/hosted-agent-dsc-v3.md](../../docs/hosted-agent-dsc-v3.md).

## Validate

The smoke test is included at `/opt/dsc-pipelinerunner/scripts/Test-DscV3Smoke.ps1`, but it
needs the repository's `source/` tree to dot-source the engine internals. Run it from a
checkout (see the `DSC v3 Hosted Agent` workflow), or just confirm the engine is present:

```bash
docker run --rm dsc-pipelinerunner-agent dsc --version
```
