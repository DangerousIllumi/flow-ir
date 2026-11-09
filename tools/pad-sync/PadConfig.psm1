# PadConfig.psm1 — centralized runtime configuration: read it, then validate field by field
#
# It does exactly three things: read the JSON, validate required keys/paths/types, and return a strongly typed object.
# It deliberately does not merge multiple configs, fall back to environment variables, or apply defaults: a missing field
# fails hard, so we never end up with "it looks like it ran, but it actually used an old path or a hard-coded default".

# Throw an exception that carries an error code: callers and tests read only Data['code'] and never parse the message text
function Throw-ConfigError {
    param([string]$Code, [string]$Message)
    $ex = New-Object System.Exception ($Code + ': ' + $Message)
    $ex.Data['code'] = $Code
    throw $ex
}

function Get-PadRuntimeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Throw-ConfigError 'CONFIG_PATH_NOT_FOUND' "config file not found: $ConfigPath"
    }
    try {
        $raw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
        $cfg = $raw | ConvertFrom-Json
    } catch {
        Throw-ConfigError 'CONFIG_INVALID_VALUE' "config is not valid JSON: $ConfigPath"
    }

    $required = @('PadSyncPath', 'PythonExe', 'CalendarPath', 'WorkdayScript', 'RunTimeoutSec', 'PadRoot')
    foreach ($name in $required) {
        if (-not ($cfg.PSObject.Properties.Name -contains $name) -or
            [string]::IsNullOrWhiteSpace([string]$cfg.$name)) {
            Throw-ConfigError 'CONFIG_MISSING' "missing required field: $name"
        }
    }

    foreach ($name in @('PadSyncPath', 'PythonExe', 'CalendarPath', 'WorkdayScript', 'PadRoot')) {
        if (-not (Test-Path -LiteralPath ([string]$cfg.$name))) {
            Throw-ConfigError 'CONFIG_PATH_NOT_FOUND' "path does not exist: $name=$($cfg.$name)"
        }
    }

    # The timeout must be a positive integer; a string or a decimal in the JSON is treated as a type error
    $sec = $cfg.RunTimeoutSec
    if (-not ($sec -is [int] -or $sec -is [long])) {
        Throw-ConfigError 'CONFIG_INVALID_VALUE' "RunTimeoutSec must be a positive integer: $sec"
    }
    if ([int64]$sec -le 0) {
        Throw-ConfigError 'CONFIG_INVALID_VALUE' "RunTimeoutSec must be greater than 0: $sec"
    }

    return [pscustomobject]@{
        PadSyncPath   = [string]$cfg.PadSyncPath
        PythonExe     = [string]$cfg.PythonExe
        CalendarPath  = [string]$cfg.CalendarPath
        WorkdayScript = [string]$cfg.WorkdayScript
        RunTimeoutSec = [int64]$sec
        PadRoot       = [string]$cfg.PadRoot
    }
}

Export-ModuleMember -Function Get-PadRuntimeConfig
