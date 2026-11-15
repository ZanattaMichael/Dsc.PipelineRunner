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
# The dsc release recorded in scripts/dsc-checksums.json (the one whose hashes were reviewed).
docker build -f containers/dsc-agent/Dockerfile -t dsc-pipelinerunner-agent .

# Choose another dsc release. The download is still verified: against the lock file if the
# release is pinned there, otherwise against the digest GitHub publishes for the asset.
docker build -f containers/dsc-agent/Dockerfile \
  --build-arg DSC_VERSION=v3.3.0 \
  -t dsc-pipelinerunner-agent:3.3.0 .
```

The build asks the GitHub API for the dsc release asset, and anonymous calls from a shared host
can be rate limited (`API rate limit exceeded`). To authenticate, pass a token as a BuildKit
secret. It is mounted for the install step only and never lands in a layer or the image history
(do not use `--build-arg` for it, which would). No scopes are needed; a read-only token is enough.
The secret is optional.

```bash
export GITHUB_TOKEN=<token>
docker build --secret id=github_token,env=GITHUB_TOKEN \
  -f containers/dsc-agent/Dockerfile -t dsc-pipelinerunner-agent .
```

The base image is pinned by digest on the `FROM` line (Dependabot keeps it current). To use a
different PowerShell image, edit that line. The container runs as the unprivileged user
`runner`, so mount anything it must write to a path that user can write.

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
