# ============================================================
# Claude Code 卸载工具 ——「卸载ClaudeCode.bat」调起
# 语义（v1.15 起收窄）：只卸载 Claude Code 本体——npm 全局包
#       @anthropic-ai/claude-code（含平台包 / claude 命令）；
#       另尽力卸载 VS Code 里的 Claude Code 扩展（不动 VS Code 本体）
# 安全边界：Node.js / Git / Python / VS Code 等其他组件一律保留；
#       用户级 PATH 与 ~/.npmrc 不动（npm 全局目录仍在用）
# 个人数据（~/.claude 配置、聊天记录、API Key）默认保留，
#       确认后输入 D 才删除
# 异常处理：
#   · 中断：随时 Ctrl+C / 关窗口；每步操作前先写日志，中断后重新双击
#          本工具可续跑（幂等）；中断也会生成标注「被中断」的卸载报告
#   · 重试：删除失败自动重试 3 次（重试前重杀 claude 进程）；
#          权限类错误不重试，直接给出处理办法
#   · 权限：UnauthorizedAccessException → 提示右键「以管理员身份运行」
#   · 兜底：全局 try/catch/finally（Ctrl+C 也会进 finally），
#          任何异常/中断都写日志 + 报告；日志目录不可写时退回 %TEMP%
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Script:AppRoot = Split-Path -Parent $PSScriptRoot

# ---- 版本号（v1.15 起与安装器统一：包内 VERSION → 上级 VERSION → 兜底）----
$Script:UninstallerVersion = '1.15'   # 纯数字，兜底值
$Script:UninstallerVersionFull = $null
$_verFile = Join-Path $Script:AppRoot 'VERSION'
if (-not (Test-Path -LiteralPath $_verFile)) { $_verFile = Join-Path $Script:AppRoot '..\VERSION' }
if (Test-Path -LiteralPath $_verFile) {
    try {
        $_rawVer = (Get-Content -LiteralPath $_verFile -TotalCount 1).Trim()
        if ($_rawVer) {
            $Script:UninstallerVersion = ($_rawVer -replace '^v', '' -replace '\(.*$', '')
            if ($_rawVer -match '\(') { $Script:UninstallerVersionFull = $_rawVer }
        }
    } catch { }
}
if (-not $Script:UninstallerVersionFull) { $Script:UninstallerVersionFull = 'v' + $Script:UninstallerVersion }

# ---- 日志初始化（安装器目录不可写时退回 %TEMP%，保证任何环境都有日志）----
function Initialize-UninstallLog {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $header = [char]0xFEFF + ("==== Claude Code 卸载日志 开始 {0} ====`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $preferred = Join-Path $Script:AppRoot 'logs'
    try {
        New-Item -ItemType Directory -Path $preferred -Force | Out-Null
        $f = Join-Path $preferred ("uninstall-{0}.log" -f $stamp)
        [System.IO.File]::WriteAllText($f, $header)
        return $f
    } catch { }
    try {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-uninstall-{0}.log" -f $stamp)
        [System.IO.File]::WriteAllText($f, $header)
        Write-Host ("  [注意] 安装器目录无写权限，日志改存：{0}" -f $f) -ForegroundColor Yellow
        return $f
    } catch { return $null }
}
$Script:LogFile = Initialize-UninstallLog

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Script:LogFile) {
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        [System.IO.File]::AppendAllText($Script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}
function Write-Banner {
    param([string]$Text)
    $line = '=' * 56
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Text) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Log -Message $Text -Level 'BANNER'
}
function Write-StepHeader {
    param([int]$Index, [int]$Total, [string]$Name)
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $Index, $Total, $Name) -ForegroundColor White
    Write-Log -Message ("步骤 {0}/{1}：{2}" -f $Index, $Total, $Name) -Level 'STEP'
}
function Write-Info {
    param([string]$Message)
    Write-Host ("  {0}" -f $Message) -ForegroundColor Gray
    Write-Log -Message $Message -Level 'INFO'
}
function Write-Ok {
    param([string]$Message)
    Write-Host ("  [OK] {0}" -f $Message) -ForegroundColor Green
    Write-Log -Message $Message -Level 'OK'
}
function Write-WarnMsg {
    param([string]$Message)
    Write-Host ("  [注意] {0}" -f $Message) -ForegroundColor Yellow
    Write-Log -Message $Message -Level 'WARN'
}
function Write-Fail {
    param([string]$Message)
    Write-Host ("  [失败] {0}" -f $Message) -ForegroundColor Red
    Write-Log -Message $Message -Level 'FAIL'
}

# 复用 env-utils：v1.15 起卸载不再改写 PATH / .npmrc，无需加载（保留变量供日志定位）

# ---- 目标位置（v1.15 起只针对 Claude Code 本体）----
$NodeDir    = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'   # 仅用于调 npm 卸载，目录本身不动
$NpmGlobal  = Join-Path $env:APPDATA 'npm'
$VscodeDir  = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'   # 仅用于卸载 Claude 扩展，本体不动
$ClaudeCfg  = Join-Path $env:USERPROFILE '.claude'
$ClaudeJson = Join-Path $env:USERPROFILE '.claude.json'

# ---- 运行状态（供日志 / 报告 / 中断兜底使用）----
$Script:Results = @()
$Script:FailedCount = 0
$Script:RunStatus = '未开始'      # 未开始 → 进行中 → 完成 / 已取消 / 异常 / 被中断
$Script:ElapsedSec = 0

function Add-Result {
    param([string]$Name, [string]$Status)
    $Script:Results += @{ Name = $Name; Status = $Status }
    if ($Status -like '失败*') { $Script:FailedCount++ }
    Write-Log -Message ("结果：{0} → {1}" -f $Name, $Status) -Level 'RESULT'
}

function Get-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 探测 Claude Code 是否装过（shim 或包目录任一存在即算）
function Test-ClaudeInstalled {
    if (Test-Path -LiteralPath (Join-Path $NpmGlobal 'claude.cmd')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $NpmGlobal 'node_modules\@anthropic-ai\claude-code')) { return $true }
    return $false
}

# 强制结束 claude 进程（已提前提示用户保存并关闭；v1.15 起只杀 claude，
# VS Code / node 等其他程序的进程一律不动）
# 每次删除重试前也会调用：占用进程可能被系统重新拉起
function Stop-RelatedProcesses {
    Write-Info '正在结束 claude 相关进程……'
    $killed = 0
    try {
        $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $killed += $procs.Count
            Write-Log -Message ("已结束进程：claude × {0}" -f $procs.Count) -Level 'INFO'
        }
    } catch {
        Write-Log -Message ("进程清理异常（忽略）：{0}" -f $_.Exception.Message) -Level 'WARN'
    }
    if ($killed -eq 0) { Write-Info '没有发现占用中的相关进程' }
}

# 删除目录/文件（带重试：最多 3 次，指数退避，重试前重杀进程；
# 权限类错误不重试，直接给出针对性处理办法）
function Remove-TreeSafely {
    param([string]$Path, [string]$Name, [int]$MaxAttempts = 3)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Write-Log -Message ("开始删除：{0}" -f $Path) -Level 'INFO'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) {
                Write-Ok ("已删除：{0}" -f $Path)
                return $true
            }
            throw '删除命令已返回但路径仍存在（可能被杀毒软件占用或拦截）'
        } catch {
            $exType = $_.Exception.GetType().Name
            $exMsg = $_.Exception.Message
            Write-Log -Message ("删除失败（第 {0}/{1} 次，异常 {2}）：{3} —— {4}" -f $attempt, $MaxAttempts, $exType, $Path, $exMsg) -Level 'WARN'
            if ($exType -eq 'UnauthorizedAccessException') {
                # 权限不足：重试没有意义，直接给出处理办法
                Write-Fail ("{0} 权限不足，无法删除：{1}" -f $Name, $Path)
                if (-not (Get-IsAdmin)) {
                    Write-WarnMsg '处理办法：右键「卸载ClaudeCode.bat」→「以管理员身份运行」，再跑一次'
                } else {
                    Write-WarnMsg '处理办法：已是管理员仍被拒，多为杀毒软件拦截——把该目录加入白名单后重跑'
                }
                return $false
            }
            if ($attempt -lt $MaxAttempts) {
                Write-Info ("  文件可能被占用，{0} 秒后自动重试（还可重试 {1} 次）……" -f ($attempt * 2), ($MaxAttempts - $attempt))
                Start-Sleep -Seconds ($attempt * 2)
                Stop-RelatedProcesses   # 占用进程可能被重新拉起，删前再杀一遍
            }
        }
    }
    Write-Fail ("{0} 自动重试 {1} 次后仍删除失败：{2}" -f $Name, $MaxAttempts, $Path)
    Write-WarnMsg '处理办法：关闭所有相关程序（或重启电脑）后重新双击「卸载ClaudeCode.bat」；也可手动删除该文件夹'
    return $false
}

# 清理 ~/.npmrc 里本安装器写入的行 —— v1.15 起不再清理：
# Node.js 与 npm 均保留，安装器写入的镜像源 / prefix / cache 配置继续有效。
# 仅清理历史版本（v1.14 及之前）卸载中断残留的临时文件
function Remove-InstallerNpmrcLines {
    $tmpFile = Join-Path $env:USERPROFILE '.npmrc.uninstall-tmp'
    if (Test-Path -LiteralPath $tmpFile) {
        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Log -Message ('已清理上次中断残留的临时文件：{0}' -f $tmpFile) -Level 'INFO'
    }
}

# 生成卸载报告（正常完成 / 被中断 / 异常都会调用，报告里标注运行状态）
function Write-UninstallReport {
    $report = Join-Path $Script:AppRoot '卸载报告.txt'
    $lines = @(
        '==============================================',
        ("        Claude Code 卸载报告（Windows 版 {0}）" -f $Script:UninstallerVersionFull),
        ("生成时间：{0}（耗时 {1} 秒）" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Script:ElapsedSec),
        '==============================================',
        '',
        ("【运行状态】{0}" -f $Script:RunStatus)
    )
    if ($Script:RunStatus -eq '被中断' -or $Script:RunStatus -eq '异常') {
        $lines += '  本次未完成：重新双击「卸载ClaudeCode.bat」会继续剩余部分（已完成的不会重来）'
        $lines += '  中断位置见日志中的最后一条「开始删除/步骤」记录'
    }
    $lines += ''
    $lines += '【卸载明细】'
    if ($Script:Results.Count -eq 0) { $lines += '  （尚未执行到删除步骤）' }
    foreach ($r in $Script:Results) { $lines += ("  {0}: {1}" -f $r.Name, $r.Status) }
    $lines += ''
    $lines += '【日志】'
    $lines += ("  {0}" -f $Script:LogFile)
    $lines += ''
    $lines += '【安全边界】只卸载了 Claude Code 本体；'
    $lines += '          Node.js / Git / Python / VS Code 等其他组件、用户 PATH 与 npm 配置均未改动。'
    $lines += ''
    $lines += '【重新安装】随时重新双击「双击安装ClaudeCode.bat」即可重装。'
    $lines += '【遇到问题】把「卸载报告.txt」和 logs 文件夹发给开发者：'
    $lines += '          邮箱 cdingstar@outlook.com / 微信 cdingstar'
    try {
        [System.IO.File]::WriteAllText($report, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Ok ("卸载报告：{0}" -f $report)
    } catch {
        Write-WarnMsg ("卸载报告写入失败（目录无写权限？）：{0}" -f $_.Exception.Message)
    }
}

# ---- 主流程（早退路径用 return；全局兜底在后面的 try/catch/finally）----
function Invoke-UninstallMain {
    Write-Banner ("Claude Code 卸载工具 {0}（只卸载 Claude Code 本体，其他组件不动）" -f $Script:UninstallerVersionFull)
    if ($Script:LogFile) { Write-Info ("日志文件：{0}" -f $Script:LogFile) }
    Write-Info '卸载过程中随时可按 Ctrl+C 中断；中断后重新双击本工具会继续完成剩余部分'

    # ---- 1. 扫描 ----
    Write-StepHeader -Index 1 -Total 3 -Name '检查已安装组件'
    $foundClaude = Test-ClaudeInstalled
    $foundVscode = Test-Path -LiteralPath (Join-Path $VscodeDir 'bin\code.cmd')
    $foundData   = (Test-Path -LiteralPath $ClaudeCfg) -or (Test-Path -LiteralPath $ClaudeJson)
    Write-Log -Message ("扫描结果：Claude={0} VSCode(仅扩展卸载用)={1} 个人数据={2}" -f `
        [int]$foundClaude, [int]$foundVscode, [int]$foundData) -Level 'INFO'

    function Show-Found {
        param([bool]$Found, [string]$Label)
        if ($Found) { Write-Host ("  [发现] {0}" -f $Label) -ForegroundColor Green; Write-Log -Message ("[发现] " + $Label) }
        else { Write-Host ("  [未安装] {0}" -f $Label) -ForegroundColor DarkGray; Write-Log -Message ("[未安装] " + $Label) }
    }
    Show-Found -Found $foundClaude -Label ('Claude Code：{0}' -f $NpmGlobal)
    if ($foundVscode) {
        Write-Host '  [发现] VS Code 已安装（将只卸载其中的 Claude Code 扩展，VS Code 本体保留）' -ForegroundColor Green
        Write-Log -Message '[发现] VS Code 已安装（仅卸载 Claude 扩展）'
    }
    if ($foundData) { Write-Host ("  [发现] 个人数据：{0}（默认保留）" -f $ClaudeCfg) -ForegroundColor Green; Write-Log -Message ("[发现] 个人数据：" + $ClaudeCfg) }
    Write-Info '本工具只卸载 Claude Code 本体；Node.js / Git / Python / VS Code 等其他组件不会被卸载'

    if (-not $foundClaude -and -not $foundData) {
        Write-Ok '未发现 Claude Code 或其数据，无需卸载'
        return 0
    }

    # ---- 2. 确认 ----
    Write-StepHeader -Index 2 -Total 3 -Name '确认卸载'
    if ($foundClaude) {
        Write-WarnMsg '请先保存并关闭：正在运行的 claude 会话和其他终端窗口'
        Read-Host '  关闭后按回车继续（想取消请直接关掉本窗口）'
        Write-Log -Message '用户已确认程序关闭，继续' -Level 'INFO'

        function Write-PlanLine {
            param([string]$Message)
            Write-Host ("    {0}" -f $Message) -ForegroundColor Yellow
            Write-Log -Message ("[将删除] " + $Message) -Level 'INFO'
        }
        Write-Host ''
        Write-Host '  即将删除以下内容（个人数据除外）：' -ForegroundColor Yellow
        if ($foundClaude) { Write-PlanLine ("Claude Code 本体：{0}（npm 包 + claude 命令）" -f $NpmGlobal) }
        if ($foundVscode) { Write-PlanLine 'VS Code 里的 Claude Code 扩展（尽力而为，VS Code 本体与设置不动）' }
        Write-Host '  不会卸载 / 不会改动：Node.js、Git、Python、VS Code 本体、用户环境变量 Path、~/.npmrc' -ForegroundColor Gray
        Write-Info '执行过程中随时可按 Ctrl+C 中断；已删除的部分不会恢复，中断后重跑本工具会继续'
        $confirm = Read-Host '  确认卸载请输入 Y（回车或其他任意键取消）'
        if ($confirm -notmatch '^[Yy]') {
            $Script:RunStatus = '已取消'
            Write-Info '已取消，未做任何改动'
            return 0
        }
        Write-Log -Message '用户输入 Y，确认卸载' -Level 'INFO'
    }

    $wipeData = ''
    if ($foundData) {
        Write-Host ''
        Write-Host '  个人数据包括：' -ForegroundColor Gray
        Write-Host ("    {0}（配置、聊天记录、全局指令、API Key）" -f $ClaudeCfg) -ForegroundColor Gray
        Write-Host ("    {0}" -f $ClaudeJson) -ForegroundColor Gray
        $wipeData = Read-Host '  要彻底清空请输入 D，回车保留（推荐：重装后免重新配置）'
        Write-Log -Message ("个人数据处理选择：{0}" -f $(if ($wipeData -match '^[Dd]') { 'D（删除）' } else { '保留' })) -Level 'INFO'
    }

    # ---- 3. 执行 ----
    Write-StepHeader -Index 3 -Total 3 -Name '执行卸载'
    $Script:RunStatus = '进行中'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-RelatedProcesses

    # VS Code 的 Claude Code 扩展（尽力而为，失败不影响；不退出 VS Code、不动其本体）
    if ($foundVscode) {
        $codeCmd = Join-Path $VscodeDir 'bin\code.cmd'
        if (Test-Path -LiteralPath $codeCmd) {
            Write-Info '正在卸载 VS Code 的 Claude Code 扩展（尽力而为）……'
            try {
                $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                & $codeCmd --uninstall-extension anthropic.claude-code 2>&1 | Out-Null
                $ErrorActionPreference = $prevEap
                Write-Log -Message 'VS Code 扩展卸载命令已执行' -Level 'INFO'
            } catch {
                Write-Log -Message ("VS Code 扩展卸载命令异常（忽略）：{0}" -f $_.Exception.Message) -Level 'WARN'
            }
        }
    }

    # Claude Code：优先 npm 正规卸载（Node.js 保留未动，npm 一直可用），再手动兜底删残留
    if ($foundClaude) {
        $npmCmd = Join-Path $NodeDir 'npm.cmd'
        if (Test-Path -LiteralPath $npmCmd) {
            Write-Info '正在通过 npm 卸载 Claude Code……'
            try {
                $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                & $npmCmd uninstall -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
                $ErrorActionPreference = $prevEap
                Write-Log -Message 'npm uninstall 命令已执行' -Level 'INFO'
            } catch {
                Write-Log -Message ("npm uninstall 异常（改用直接删除）：{0}" -f $_.Exception.Message) -Level 'WARN'
            }
        }
        $ok = $true
        foreach ($sub in @('node_modules\@anthropic-ai\claude-code', 'node_modules\@anthropic-ai\claude-code-win32-x64')) {
            $p = Join-Path $NpmGlobal $sub
            if (Test-Path -LiteralPath $p) { $ok = (Remove-TreeSafely -Path $p -Name 'Claude Code') -and $ok }
        }
        foreach ($shim in @('claude.cmd', 'claude', 'claude.ps1')) {
            $shimPath = Join-Path $NpmGlobal $shim
            if (Test-Path -LiteralPath $shimPath) { $ok = (Remove-TreeSafely -Path $shimPath -Name 'claude 命令') -and $ok }
        }
        # 空壳清理：@anthropic-ai 下已无内容时一并删除（避免留下空目录）
        $anthropicDir = Join-Path $NpmGlobal 'node_modules\@anthropic-ai'
        if (Test-Path -LiteralPath $anthropicDir) {
            $leftover = @(Get-ChildItem -LiteralPath $anthropicDir -Force -ErrorAction SilentlyContinue)
            if ($leftover.Count -eq 0) { $ok = (Remove-TreeSafely -Path $anthropicDir -Name '@anthropic-ai 空目录') -and $ok }
        }
        Add-Result -Name 'Claude Code' -Status ($(if ($ok) { '成功' } else { '失败（见日志）' }))
    }

    # 历史版本中断残留临时文件清理（v1.15 起不再改写 PATH / .npmrc，二者保持不动）
    Remove-InstallerNpmrcLines
    Write-Ok '用户环境变量 Path 与 npm 配置未做改动（npm 全局目录仍在用）'

    # 个人数据（仅在用户输入 D 时删除；仅 Claude 自身数据）
    if ($foundData) {
        if ($wipeData -match '^[Dd]') {
            $dOk = $true
            if (Test-Path -LiteralPath $ClaudeCfg) { $dOk = (Remove-TreeSafely -Path $ClaudeCfg -Name 'Claude 配置') -and $dOk }
            $dOk = (Remove-TreeSafely -Path $ClaudeJson -Name '.claude.json') -and $dOk
            Add-Result -Name '个人数据' -Status ($(if ($dOk) { '成功（已彻底删除）' } else { '失败（见日志）' }))
        } else {
            Add-Result -Name '个人数据' -Status '已保留（含配置 / 聊天记录 / API Key）'
        }
    }

    $sw.Stop()
    $Script:ElapsedSec = [int]$sw.Elapsed.TotalSeconds
    $Script:RunStatus = '完成'
    Write-Log -Message ("执行阶段完成，耗时 {0} 秒" -f $Script:ElapsedSec) -Level 'DONE'
    return $(if ($Script:FailedCount -eq 0) { 0 } else { 1 })
}

# ---- 全局兜底：任何异常 / Ctrl+C（finally 必然执行）都写日志与报告 ----
$exitCode = 0
try {
    $exitCode = Invoke-UninstallMain
} catch {
    Write-Fail ("发生未预期错误，卸载中断：{0}" -f $_.Exception.Message)
    if ($_.Exception.GetType().Name -eq 'UnauthorizedAccessException') {
        Write-WarnMsg '疑似权限不足：右键「卸载ClaudeCode.bat」→「以管理员身份运行」后重试'
    } else {
        Write-WarnMsg '请关闭相关程序后重新双击「卸载ClaudeCode.bat」重试（已完成的步骤不用重来）'
    }
    Write-Log -Message ("全局异常：{0}" -f $_.Exception.ToString()) -Level 'FATAL'
    $Script:RunStatus = '异常'
    $exitCode = 2
} finally {
    # Ctrl+C 也会进入这里：状态仍为「进行中」即视为被中断
    if ($Script:RunStatus -eq '进行中') { $Script:RunStatus = '被中断' }
    if ($Script:RunStatus -ne '未开始' -and $Script:RunStatus -ne '已取消') {
        try { Write-UninstallReport } catch { }
    }
    if ($Script:LogFile) {
        Write-Log -Message ("==== Claude Code 卸载日志 结束（运行状态：{0}，退出码 {1}）====" -f $Script:RunStatus, $exitCode) -Level 'DONE'
    }
}
exit $exitCode
