# ============================================================
# 修复重装工具 ——「修复重装工具.bat」调起（问题备案 #016）
# 场景：极端情况下某个工具装坏了/版本混乱，卸载本安装器装的副本后自动重装
# 语义：只卸载「本安装器安装的用户级副本」，不动系统级安装（安全边界）
# 卸载完成后自动重新调起 main.ps1（其余组件会自动跳过，只重装被卸载的）
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Script:AppRoot = Split-Path -Parent $PSScriptRoot
$installerDir = Join-Path $Script:AppRoot 'installer'

# 加载公共模块（logger 先行）
. (Join-Path $installerDir 'common\logger.ps1')
. (Join-Path $installerDir 'common\errors.ps1')
. (Join-Path $installerDir 'common\env-utils.ps1')
. (Join-Path $installerDir 'common\downloader.ps1')

Initialize-Logger -LogDir (Join-Path $Script:AppRoot 'logs') | Out-Null
Write-Banner 'Claude Code 修复重装工具'

$menu = @(
    @{ Key = 'node';   Label = 'Node.js（运行环境）' },
    @{ Key = 'git';    Label = 'Git for Windows' },
    @{ Key = 'python'; Label = 'Python 3.12' },
    @{ Key = 'claude'; Label = 'Claude Code' },
    @{ Key = 'vscode'; Label = 'VS Code' }
)

Write-Host ''
Write-Host '本工具会卸载指定组件（仅限本安装器安装的用户级副本，' -ForegroundColor Gray
Write-Host '不影响系统里其他方式安装的版本），然后自动重新安装。' -ForegroundColor Gray
Write-Host ''
for ($i = 0; $i -lt $menu.Count; $i++) {
    Write-Host ("  {0}. {1}" -f ($i + 1), $menu[$i].Label)
}
Write-Host ''
$choice = Read-Host '请输入要修复重装的组件编号（回车退出）'
if ([string]::IsNullOrWhiteSpace($choice)) { Write-Info '已退出（未做任何改动）'; exit 0 }

$idx = 0
if (-not ([int]::TryParse($choice, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $menu.Count) {
    Write-Host '编号无效，已退出' -ForegroundColor Yellow
    exit 1
}
$target = $menu[$idx - 1]
Write-Host ''
Write-WarnMsg ("即将卸载并重装：{0}" -f $target.Label)
$confirm = Read-Host '确认请输入 Y（其他任意键退出）'
if ($confirm -notmatch '^[Yy]') { Write-Info '已取消'; exit 0 }

# ---- 卸载 ----
Write-StepHeader -Index 1 -Total 2 -Name ("卸载 {0}" -f $target.Label)
try {
    switch ($target.Key) {
        'node' {
            $dir = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            Remove-UserPath -Dirs @($dir)
        }
        'git' {
            $dir = Join-Path $env:LOCALAPPDATA 'Programs\Git'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            Remove-UserPath -Dirs @((Join-Path $dir 'cmd'), (Join-Path $dir 'bin'))
        }
        'python' {
            # 仅卸载本安装器的 Python312（不动 Launcher 与用户其他版本）
            $dir = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            Remove-UserPath -Dirs @($dir, (Join-Path $dir 'Scripts\'))
        }
        'claude' {
            # npm 卸载（用本安装器装的 npm；失败则直接删目录）
            $npmCmd = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\npm.cmd'
            if (Test-Path -LiteralPath $npmCmd) {
                try {
                    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    & $npmCmd uninstall -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
                    $ErrorActionPreference = $prevEap
                } catch { }
            }
            $npmGlobal = Join-Path $env:APPDATA 'npm'
            foreach ($sub in @('node_modules\@anthropic-ai\claude-code', 'node_modules\@anthropic-ai\claude-code-win32-x64')) {
                $p = Join-Path $npmGlobal $sub
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
            }
            foreach ($shim in @('claude.cmd', 'claude', 'claude.ps1')) {
                $p = Join-Path $npmGlobal $shim
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
        }
        'vscode' {
            $dir = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
            # 优先用官方卸载器（保留系统干净），失败则直接删目录
            $unins = Join-Path $dir 'unins000.exe'
            if (Test-Path -LiteralPath $unins) {
                try {
                    $p = Start-Process -FilePath $unins -ArgumentList @('/VERYSILENT', '/NORESTART') -WindowStyle Hidden -PassThru
                    [void]$p.WaitForExit(180000)
                } catch { }
            }
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            Remove-UserPath -Dirs @((Join-Path $dir 'bin'))
        }
    }
    Update-SessionPath
    Write-Ok '卸载完成'
} catch {
    Show-ErrorBlock -Id 'E-AV-001' -Detail ("卸载失败（文件可能被占用，请关闭相关程序后重试）：{0}" -f $_.Exception.Message)
    exit 2
}

# ---- 自动重装（调起主流程；其余组件已装会自动跳过） ----
Write-StepHeader -Index 2 -Total 2 -Name '自动重新安装'
Write-Info '即将重新运行安装器（已装好的组件会自动跳过，只重装刚卸载的组件）……'
Start-Sleep -Seconds 2
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installerDir 'main.ps1')
exit $LASTEXITCODE
