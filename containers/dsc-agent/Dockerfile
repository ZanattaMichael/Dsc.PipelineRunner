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

ARG POWERSHELL_TAG=7.4-ubuntu-22.04
FROM mcr.microsoft.com/powershell:${POWERSHELL_TAG}

# DSC v3 release to install. 'latest' resolves the newest stable release at build time;
# pin to a tag (e.g. v3.0.0) for reproducible images.
ARG DSC_VERSION=latest

# tar is used by the bootstrap script to unpack the DSC archive.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tar ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install the DSC v3 engine into a stable location and expose it on PATH.
COPY scripts/Install-DscV3.ps1 /opt/dsc-pipelinerunner/scripts/Install-DscV3.ps1
RUN pwsh -NoLogo -NoProfile -File /opt/dsc-pipelinerunner/scripts/Install-DscV3.ps1 \
        -Version "${DSC_VERSION}" -InstallDirectory /usr/local/dsc -Verbose
ENV PATH="/usr/local/dsc:${PATH}"

# Install the runner's required PowerShell modules for all users.
RUN pwsh -NoLogo -NoProfile -Command " \
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
        Install-Module -Name Datum, Datum.InvokeCommand, powershell-yaml, PSDesiredStateConfiguration \
            -Scope AllUsers -Force -ErrorAction Stop"

# Keep the smoke test available for image validation / debugging.
COPY scripts/Test-DscV3Smoke.ps1 /opt/dsc-pipelinerunner/scripts/Test-DscV3Smoke.ps1

# Sanity-check the executable is present and runnable at build time.
RUN dsc --version

WORKDIR /workspace
CMD ["pwsh"]
