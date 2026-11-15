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
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04@sha256:62300a213a9293916333df2b014cd3a8f22fb0b0b65f2bb446aaf436bcf8c868

# DSC v3 release to install. Left empty, the install script uses the defaultVersion recorded in
# scripts/dsc-checksums.json, which is the version whose archive hashes were reviewed. Pass a
# tag (--build-arg DSC_VERSION=v3.3.0) to choose another; the download is verified either way.
ARG DSC_VERSION=

# tar is used by the bootstrap script to unpack the DSC archive.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tar ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install the DSC v3 engine into a stable location and expose it on PATH.
COPY scripts/Install-DscV3.ps1 scripts/dsc-checksums.json /opt/dsc-pipelinerunner/scripts/
RUN pwsh -NoLogo -NoProfile -File /opt/dsc-pipelinerunner/scripts/Install-DscV3.ps1 \
        ${DSC_VERSION:+-Version "$DSC_VERSION"} -InstallDirectory /usr/local/dsc -Verbose
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

# Run as an unprivileged user. Everything above that needs root (packages, the dsc install, the
# AllUsers modules) is done by now, and the executables stay world-readable and executable, so
# nothing the agent does at run time needs more than this user has.
RUN useradd --create-home --uid 10001 --shell /usr/bin/pwsh runner \
    && mkdir -p /workspace \
    && chown runner:runner /workspace
USER runner

WORKDIR /workspace
CMD ["pwsh"]
