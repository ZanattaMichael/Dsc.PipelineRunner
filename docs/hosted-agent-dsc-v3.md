# Getting started on a hosted Linux agent with DSC v3

`Invoke-DscResource` (DSC **v2**) is Windows- and PowerShell-first. DSC **v3** ships a
standalone, cross-platform command-line engine (`dsc`) that runs on Linux, macOS and
Windows. Running the pipeline runner's **DscV3** engine on a hosted Linux agent is what
makes cloud-hosted, ephemeral agents genuinely useful — no Windows box required.

This page covers three things:

1. Bootstrapping `dsc` on a fresh agent.
2. Running `Invoke-DscRunner` with the DSC v3 engine.
3. Pipeline-native authentication, including **workload-identity federation** (no
   long-lived PATs).

---

## 1. Bootstrap the DSC v3 engine

Use the bundled bootstrap script. It resolves a release from the PowerShell/DSC project,
picks the archive matching the agent's OS and CPU architecture, installs it, and — inside
GitHub Actions — appends `dsc` to the job `PATH` automatically.

```powershell
# Latest stable dsc, default install location, added to PATH for the rest of the job.
./scripts/Install-DscV3.ps1 -Verbose

# Or pin a specific release into a chosen directory.
./scripts/Install-DscV3.ps1 -Version v3.0.0 -InstallDirectory /usr/local/dsc
```

Verify:

```powershell
dsc --version
dsc resource list
```

> The script downloads from GitHub. Pass `-GitHubToken` (or set `$env:GITHUB_TOKEN`) to
> raise the API rate limit; the token is used only for the release lookup and is never
> written to disk or logged.

A ready-made **container image** (PowerShell + `dsc` + the runner's module dependencies)
is provided under [`containers/dsc-agent`](../containers/dsc-agent/README.md) if you would
rather run in a pinned image than bootstrap each job.

---

## 2. Run with the DSC v3 engine

Select the engine explicitly, or let the runner choose:

```powershell
# Explicit — always use the DSC v3 (dsc) engine.
Invoke-DscRunner -ConfigurationSourcePath ./config -Mode Test -Engine DscV3

# Auto — pick DscV3 when dsc is present (or the config's DSCResourceVersion is 3.x),
# otherwise fall back to the well-supported DscV2 engine.
Invoke-DscRunner -ConfigurationSourcePath ./config -Mode Test -Engine Auto
```

When `-Engine` is not passed, the configuration decides: a `PipelineRunnerSettings.Engine`
key names the engine, and failing that the back-compat `DSCResourceVersion` major version
maps through (2.x → DscV2, 3.x → DscV3).

### Cache directory

`Invoke-DscRunner` needs no cache environment variable — it uses a temporary directory by
default. To pin one, pass `-CacheDirectory`, or set the generic
`PIPELINERUNNER_CACHE_DIRECTORY` environment variable (the legacy `AZDODSC_CACHE_DIRECTORY`
is still honoured as a back-compat alias).

```powershell
$env:PIPELINERUNNER_CACHE_DIRECTORY = "$PWD/.cache"
```

---

## 3. Pipeline-native authentication

When the configuration source is a private git repository, the runner needs a credential
to clone it. Three rules hold across every provider (GitHub, GitLab, Bitbucket, Azure
DevOps):

- **Tokens are `[SecureString]` end-to-end.** Pass a `[SecureString]` or a plain string;
  the runner converts and holds it securely.
- **No token appears in any output stream.** The `git` wrapper injects the credential as
  an HTTP `Authorization` header through git's environment-based config
  (`GIT_CONFIG_*`), never on the process command line, and redacts it from error text.
- **The pipeline's own token is auto-detected.** If you supply no explicit token, the
  runner reads `$env:SYSTEM_ACCESSTOKEN` — the token most CI systems already expose to a
  job — so no secret has to be passed by hand.

```powershell
# Explicit token (string or SecureString).
Invoke-DscRunner -Source Git `
                 -SourceContext @{ Url = $repoUrl; Token = $env:MY_PIPELINE_TOKEN } `
                 -Engine DscV3

# No token supplied — $env:SYSTEM_ACCESSTOKEN is used automatically when present.
Invoke-DscRunner -Source Git -SourceContext @{ Url = $repoUrl } -Engine DscV3
```

### Workload-identity federation (recommended — no stored PAT)

A Personal Access Token is a long-lived secret you have to store, rotate and protect.
**Workload-identity federation** replaces it with a short-lived token the platform mints
for the running job from its own trusted identity — nothing long-lived is stored in the
pipeline.

The runner is credential-shaped, not provider-shaped: it consumes whatever token the job
already holds. So the federation happens in the platform, and the runner simply receives
the short-lived token:

- **Azure DevOps** — configure a
  [workload identity federation service connection](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure)
  for the pipeline. The agent exposes the job's OAuth token as `SYSTEM_ACCESSTOKEN`
  (enable *"Allow scripts to access the OAuth token"* on the job). The runner auto-detects
  it — no PAT required:

  ```yaml
  steps:
    - pwsh: |
        Import-Module Dsc.PipelineRunner
        Invoke-DscRunner -Source Git -SourceContext @{ Url = "$(ConfigRepoUrl)" } -Engine DscV3
      env:
        SYSTEM_ACCESSTOKEN: $(System.AccessToken)   # short-lived, job-scoped
  ```

- **GitHub Actions** — the job's `GITHUB_TOKEN` (or an OIDC token exchanged for a
  short-lived credential via `id-token: write`) is the federated credential. Pass it in:

  ```yaml
  permissions:
    contents: read
    id-token: write
  steps:
    - shell: pwsh
      env:
        SYSTEM_ACCESSTOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        Import-Module Dsc.PipelineRunner
        Invoke-DscRunner -Source Git -SourceContext @{ Url = '${{ github.server_url }}/${{ github.repository }}' } -Engine DscV3
  ```

Because these tokens are minted per-job and expire quickly, a leak is far less damaging
than a leaked PAT — and there is no secret to rotate. Prefer federation over a stored PAT
wherever the platform supports it.

---

## Continuous validation

The [`DSC v3 Hosted Agent`](../.github/workflows/DscV3-HostedAgent.yml) workflow runs on
every push and pull request. It bootstraps `dsc` on a clean Ubuntu runner, drives a real
resource through the DscV3 engine, and builds the hosted-agent container image — so the
Linux DSC v3 path stays green as the module evolves.
