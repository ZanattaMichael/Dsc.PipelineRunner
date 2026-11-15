
<#
.SYNOPSIS
    Sets variables from a source hashtable to a target hashtable and creates corresponding environment variables.

.DESCRIPTION
    The SetVariables function takes two hashtable parameters: $Source and $Target. It iterates through each key in the $Source hashtable, adds the key-value pair to the $Target hashtable, and creates a new variable in the script scope with the key name (dots replaced by underscores). Additionally, it creates an environment variable with the same name.

.PARAMETER Source
    The source hashtable containing the variables to be set.

.PARAMETER Target
    The target hashtable where the variables from the source hashtable will be added.

.EXAMPLE
    $source = @{ "key1" = "value1"; "key2" = "value2" }
    $target = @{}
    SetVariables -Source $source -Target $target

    This example sets the variables from the $source hashtable to the $target hashtable and creates corresponding script scope and environment variables.
#>
function Set-Variables {
    [CmdletBinding()]
    [Alias('SetVariables')]
    param (
        [hashtable] $Source,
        [hashtable] $Target
    )

    # Names a configuration must not claim as a script variable. Each one is runner state
    # (a configuration that sets StopTaskProcessing could switch its own enforcement off),
    # a preference variable (VerbosePreference would change what the whole session logs) or a
    # PowerShell automatic variable. They were previously overwritten silently; now they fail
    # loudly, naming the offending key, before anything is written.
    $reservedName = '^(references|variables|parameters|StopTaskProcessing|notifyDeclarations|resourceOutputs|pendingNotifyRefresh|currentResourceKey|currentResourceResult|currentNodeName|currentConfigurationFile|RunnerTemporaryDirectoryRegistry|RunnerExportedEnv|ModuleConfigurationData|.*Preference|PSDefaultParameterValues|null|true|false|_|PSItem|args|input|this|Error|Matches|LASTEXITCODE|ExecutionContext|Host|HOME|PID|PWD|PSScriptRoot|PSCommandPath|MyInvocation|PSBoundParameters|PSCmdlet|OFS|PSVersionTable|ShellId|StackTrace)$'

    # Environment names that change how a child process (git, dsc, ssh, a DSC resource) loads
    # code or authenticates. A configuration value is data, so it must never be able to
    # redirect those, whether or not the variable already exists in the agent's environment.
    $blockedEnvName = '^(PATH|PATHEXT|PSModulePath|HOME|USERPROFILE|TEMP|TMP|TMPDIR|COMSPEC|SHELL|IFS|ENV|BASH_ENV|SSH_ASKPASS|SSH_AUTH_SOCK|SYSTEM_ACCESSTOKEN|GIT_.*|LD_.*|DYLD_.*|DSC_.*|PIPELINERUNNER_.*|AZDODSC_.*|NODE_OPTIONS|PYTHONPATH|PERL5LIB|RUBYLIB|CLASSPATH|JAVA_TOOL_OPTIONS|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE)$'

    if (-not $script:RunnerExportedEnv) {
        $script:RunnerExportedEnv = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    # Validate every name first, so a rejected configuration leaves no partial state behind.
    foreach ($key in $Source.Keys) {
        $candidate = ([string]$key).Replace('.', '_')
        if ($candidate -match $reservedName) {
            throw "[Set-Variables] The variable name '$key' is reserved by the runner or PowerShell and cannot be used in a configuration. Rename it."
        }
    }

    foreach ($key in $Source.Keys) {
        $Target.Add($key, $Source[$key])

        $varName = ([string]$key).Replace(".", "_")

        # Only a valid identifier can be read back as $Name. Anything else (a hyphen, a space,
        # an empty key) is still reachable through the variables() accessor, which reads the
        # table above, so it stays in the table but gets no script or environment variable.
        if ($varName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Write-Verbose "[Set-Variables] '$key' is not a valid variable name; available through variables() only."
            continue
        }

        New-Variable -Name $varName -Value $Source[$key] -Scope Script -Force | Out-Null

        # Export to the process environment for resources that read $env:NAME, but never over
        # a name that controls how child processes run, and never over a variable the agent
        # already had: a configuration value must not replace the agent's own environment.
        if ($varName -match $blockedEnvName) {
            Write-Warning "[Set-Variables] Not exporting '$varName' to the environment: that name controls how child processes load code or authenticate."
        }
        elseif ($null -ne [System.Environment]::GetEnvironmentVariable($varName) -and -not $script:RunnerExportedEnv.Contains($varName)) {
            Write-Warning "[Set-Variables] Not exporting '$varName' to the environment: a variable of that name already exists."
        }
        else {
            # Use the interpolated variable name (env:$varName), not the literal string
            # "varName", and Set-Item so an existing runner-exported variable is updated.
            Set-Item -Path "env:$varName" -Value $Source[$key] -ErrorAction SilentlyContinue | Out-Null
            $null = $script:RunnerExportedEnv.Add($varName)
        }
    }
}
