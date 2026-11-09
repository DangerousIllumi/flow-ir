# PadConfig.psm1 — 运行时集中配置：读取并逐字段校验
#
# 只做三件事：读 JSON、校验必需项/路径/类型、返回强类型对象。
# 刻意不做多份配置合并、环境变量兜底或默认值回退：缺项直接硬失败，
# 避免「看起来跑起来了，实际用的是旧路径或硬编码默认值」。

# 抛出带错误码的异常：调用方与测试只看 Data['code']，不解析中文文案
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

    # 超时必须是正整数；JSON 里写成字符串或小数一律按类型错误处理
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
