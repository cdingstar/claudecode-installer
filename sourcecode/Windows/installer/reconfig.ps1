# ============================================================
# 单独重新配置模型 —— 「重新配置APIKEY.bat」调起（兼容旧入口「配置模型.bat」）
# 用途：安装时跳过了配置、或日后想换供应商/Key/模型
# 逻辑：加载公共模块 → 弹配置界面 → 写入配置
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:AppRoot = Split-Path -Parent $PSScriptRoot
$installerDir = Join-Path $script:AppRoot 'installer'

# 加载所需模块（顺序：日志 → 错误 → 配置三件套）
. (Join-Path $installerDir 'common\logger.ps1')
. (Join-Path $installerDir 'common\errors.ps1')
. (Join-Path $installerDir 'config\providers.ps1')
. (Join-Path $installerDir 'config\config-dialog.ps1')
. (Join-Path $installerDir 'config\apply-config.ps1')

Initialize-Logger -LogDir (Join-Path $script:AppRoot 'logs') | Out-Null
Write-Banner 'Claude Code 模型配置'

$config = Invoke-ConfigDialog
if ($config -and -not $config.Skipped) {
    if ($config.Reset) {
        # 「恢复官方默认」（#024）：清除第三方配置，回到官方模型/登录
        Invoke-ResetConfig
    } else {
        Invoke-ApplyConfig -Config $config -AppRoot $script:AppRoot
    }
} else {
    Write-Info '已跳过配置（配置未改动）'
}
