# Dsc.PipelineRunner hosted-agent base image.
#
# A ready-to-run agent for evaluating configurations through the DSC v3 engine on Linux:
#   * PowerShell (from the official Microsoft image)
#   * the DSC v3 command-line engine (dsc), installed via the repo's bootstrap script
#   * the runner's required PowerShell modules
#
# It is deliberately a *runtime base*: it does not bake in a specific build of
# Dsc.PipelineRunner. Install the module on top (from the PowerShell Gallery once
# published, or by mounting a locally built copy onto the module path) and call
# Invoke-DscRunner. See containers/dsc-agent/README.md.

# The base image is pinned by digest, so a build gets exactly the image that was reviewed and a
# moved or replaced tag cannot change what runs. The tag is kept for readers (and for
# Dependabot, which updates tag and digest together). To move to another image, change both.
# The digest is what the registry serves for that tag, resolved on a GitHub runner by the
# 'Update DSC checksums' workflow, not copied from anywhere else.
FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04@sha256:042240d57ec9e47e511033b92625a8d95875ee5860af3015992c248b58a8be81

# DSC v3 release to install. Left empty, the install script uses the defaultVersion recorded in
# scripts/dsc-checksums.json, which is the version whose archive hashes were reviewed. Pass a
# tag (--build-arg DSC_VERSION=v3.3.0) to choose another; the download is verified either way.
ARG DSC_VERSION=

# tar is used by the bootstrap script to unpack the DSC archive.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tar ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install the DSC v3 engine into a stable location and expose it on PATH.
COPY scripts/Install-DscV3.ps1 scripts/Install-PinnedModule.ps1 scripts/dsc-checksums.json scripts/module-versions.json /opt/dsc-pipelinerunner/scripts/
#
# The installer asks the GitHub API which release asset to download, and anonymous API calls from
# a shared build host are rate limited (a build can fail with "API rate limit exceeded"). To
# authenticate, pass a token as a BuildKit secret:
#     docker build --secret id=github_token,env=GITHUB_TOKEN ...
# The secret is mounted for this one RUN step only and read into the installer's environment, so
# it is never written to a layer, the image history or the build cache. It is optional: without
# it the build runs unauthenticated, exactly as before. The token needs no scopes (a read-only
# GITHUB_TOKEN is enough) because only public release metadata is read.
RUN --mount=type=secret,id=github_token \
    if [ -s /run/secrets/github_token ]; then GITHUB_TOKEN="$(cat /run/secrets/github_token)"; export GITHUB_TOKEN; fi; \
    pwsh -NoLogo -NoProfile -File /opt/dsc-pipelinerunner/scripts/Install-DscV3.ps1 \
        ${DSC_VERSION:+-Version "$DSC_VERSION"} -InstallDirectory /usr/local/dsc -Verbose
ENV PATH="/usr/local/dsc:${PATH}"

# Install the runner's required PowerShell modules for all users, at the exact versions pinned in
# scripts/module-versions.json (a failed download is retried).
RUN pwsh -NoLogo -NoProfile -File /opt/dsc-pipelinerunner/scripts/Install-PinnedModule.ps1 \
        -Name Datum, Datum.InvokeCommand, powershell-yaml, PSDesiredStateConfiguration -Scope AllUsers

# Keep the smoke test available for image validation / debugging.
COPY scripts/Test-DscV3Smoke.ps1 /opt/dsc-pipelinerunner/scripts/Test-DscV3Smoke.ps1

# Sanity-check the executable is present and runnable at build time.
RUN dsc --version

# Run as an unprivileged user. Everything above that needs root (packages, the dsc install, the
# AllUsers modules) is done by now, and the executables stay world-readable and executable, so
# nothing the agent does at run time needs more than this user has.
RUN useradd --create-home --uid 10001 --shell /usr/bin/pwsh runner \
    && mkdir -p /workspace \
    && chown runner:runner /workspace
USER runner

WORKDIR /workspace
CMD ["pwsh"]
