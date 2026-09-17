# ============================================================
# 系统预检 —— 安装前的硬性条件检查 + 断网等待恢复
# 检查项：Win10+ 64 位 / 磁盘 ≥2GB / 镜像站连通（断网最多等 10 分钟）
# Fatal 级别（E-SYS-xxx / E-NET-001）会直接终止安装。
# ============================================================

# 系统硬性要求检查（版本、架构、磁盘），不满足抛 Fatal 错误
function Test-SystemRequirements {
    # 1) 64 位
    if (-not [Environment]::Is64BitOperatingSystem) {
        Throw-InstallError -Id 'E-SYS-003' -Detail '当前系统不是 64 位 Windows'
    }
    Write-Ok '系统架构：64 位'

    # 2) Windows 10（内核 10.0）及以上
    $version = [Environment]::OSVersion.Version
    Write-Info ("Windows 内核版本：{0}" -f $version)
    if ($version.Major -lt 10) {
        Throw-InstallError -Id 'E-SYS-001' -Detail ("当前为 Windows 内核 {0}" -f $version)
    }
    Write-Ok '系统版本：Windows 10 或更高'

    # 3) 磁盘空间（安装目标全在系统盘的用户目录，检查系统盘即可）
    $systemDrive = $env:SystemDrive
    if (-not $systemDrive) { $systemDrive = 'C:' }
    $drive = Get-PSDrive -Name ($systemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($drive) {
        $freeBytes = [long]$drive.Free
        Write-Info ("系统盘剩余空间：{0}" -f (Format-Size $freeBytes))
        if ($freeBytes -lt 2GB) {
            Throw-InstallError -Id 'E-SYS-002' -Detail ("系统盘仅剩 {0}" -f (Format-Size $freeBytes))
        }
        Write-Ok '磁盘空间：充足（≥ 2GB）'
    }

    # 4) PowerShell TLS 1.2（老系统 Win10 早期版本默认未启用）
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-WarnMsg '无法显式启用 TLS 1.2，若下载失败请升级 Windows 补丁'
    }
    Write-Ok 'TLS 1.2：已启用'
}

# 测试某个主机 443 端口能否建立 TCP 连接（3 秒超时）
# 返回值：bool
function Test-HostReachable {
    param([string]$HostName)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, 443)
        if ($task.Wait(3000) -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# 网络等待：任一国内镜像可达即通过；断网时每 30 秒中文提示重检，最长 10 分钟
# 全部超时抛 E-NET-001（Fatal）
function Wait-ForNetwork {
    param([int]$MaxWaitMinutes = 10)
    $mirrors = @('registry.npmmirror.com', 'mirrors.aliyun.com', 'mirrors.huaweicloud.com')

    for ($round = 1; $round -le ($MaxWaitMinutes * 2); $round++) {
        foreach ($hostName in $mirrors) {
            if (Test-HostReachable -HostName $hostName) {
                Write-Ok ("网络正常（可达镜像：{0}）" -f $hostName)
                return
            }
        }
        if ($round -eq 1) {
            Write-WarnMsg '当前无法连接任何国内镜像站（可能断网或防火墙拦截）'
        }
        Write-Info ("第 {0}/{1} 轮探测失败，30 秒后自动重试……" -f $round, ($MaxWaitMinutes * 2))
        Start-Sleep -Seconds 30
    }
    Throw-InstallError -Id 'E-NET-001' -Detail ("连续 {0} 分钟无法连接镜像站（已探测：{1}）" -f $MaxWaitMinutes, ($mirrors -join '、'))
}

# 当前是否以管理员身份运行（用于提示；本安装器不需要管理员）
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
# 启动自检 —— 防「加载顺序 / 未定义引用」类问题（见 问题备案.md #001）
# 背景：曾有 main.ps1 在模块加载前引用 $Script:InstallState 导致裸崩。
# 本函数在全部模块加载完成后校验关键函数与状态变量确实就位，
# 任何缺失立即抛 E-SYS-004（Fatal），让此类问题第一时间以错误 ID 暴露。
# ============================================================
function Start-PreflightCheck {
    $requiredFunctions = @(
        'Initialize-Logger', 'Write-Log', 'Show-ErrorBlock', 'Get-ErrorSpec', 'Throw-InstallError', 'Resolve-ErrorId',
        'Invoke-InstallStep', 'Register-SkippedDependency', 'Get-StepStatus',
        'Invoke-DownloadFile', 'Add-UserPath', 'Update-SessionPath', 'Test-CommandAvailable', 'Get-CommandVersion',
        'Wait-ProcessWithSpinner', 'Invoke-ToolWithSpinner',
        'Test-SystemRequirements', 'Wait-ForNetwork', 'Test-IsAdministrator',
        'Invoke-StepNode', 'Invoke-StepGit', 'Invoke-StepPython', 'Invoke-StepClaudeCode', 'Invoke-StepVscode', 'Invoke-StepVerify',
        'Get-Provider', 'Get-ProviderNames', 'Invoke-ConfigDialog', 'Invoke-ApplyConfig', 'Invoke-ResetConfig'
    )
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $requiredFunctions) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            [void]$missing.Add("函数 $name")
        }
    }
    # 状态变量（dot-source 后应落在当前 script 作用域）
    $requiredVars = @('InstallState', 'InstallErrors', 'Providers', 'LogFile')
    foreach ($name in $requiredVars) {
        if (-not (Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)) {
            [void]$missing.Add("变量 `$$name")
        }
    }
    if ($missing.Count -gt 0) {
        Throw-InstallError -Id 'E-SYS-004' -Detail ("启动自检发现缺失组件：{0}" -f ($missing -join '、'))
    }
}

# 检测安装器是否被放在微信/QQ 的文件接收目录内（文件易被占用，只提醒不阻塞）
function Test-ImFolderHint {
    param([string]$AppRoot)
    $markers = @('xwechat_files', 'WeChat Files', 'Tencent Files', 'QQ\Users')
    foreach ($m in $markers) {
        if ($AppRoot -like ("*{0}*" -f $m)) {
            Write-WarnMsg '当前文件夹位于微信/QQ 的接收目录内，文件可能被聊天程序占用导致安装失败'
            Write-WarnMsg '强烈建议：把整个「ClaudeCode 安装器」文件夹复制到 D:\ 或桌面后再运行'
            return
        }
    }
}
