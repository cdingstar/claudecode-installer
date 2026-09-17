# ============================================================
# 日志模块 —— 控制台中文着色输出 + 日志文件双写
# 文件：logs/install-yyyyMMdd-HHmmss.log
# 控制台只显示人话，完整细节（URL/HTTP码/堆栈）进日志文件。
# ============================================================

$Script:LogFile = $null

# 初始化日志文件（每次运行生成新文件）
function Initialize-Logger {
    param([string]$LogDir)
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:LogFile = Join-Path $LogDir ("install-{0}.log" -f $stamp)
    # 日志文件写入 UTF-8（带 BOM），确保记事本打开中文不乱码
    [System.IO.File]::WriteAllText($Script:LogFile, [char]0xFEFF + "==== Claude Code 安装日志 开始 {0} ====`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    return $Script:LogFile
}

# 底层写日志（同时进文件；控制台输出由各专用函数负责）
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Script:LogFile) {
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        # 追加写并保持 UTF-8 编码
        [System.IO.File]::AppendAllText($Script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

# 顶部大横幅
function Write-Banner {
    param([string]$Text)
    $line = '=' * 56
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Text) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Log -Message $Text -Level 'BANNER'
}

# 步骤标题：[2/6] 安装 Node.js
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

# 纯日志调试信息（控制台不显示，避免刷屏）
function Write-DebugLog {
    param([string]$Message)
    Write-Log -Message $Message -Level 'DEBUG'
}
