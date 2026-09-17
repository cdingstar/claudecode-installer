# ============================================================
# 步骤 3：安装 Python 3.12（用户级静默，免管理员）+ pip 阿里镜像
# 方案链：A 华为云 exe 静默 → B npmmirror exe 静默 → C 备用版本 3.12.9 华为云
# 安装位置：%LOCALAPPDATA%\Programs\Python\Python312
# 幂等：python --version 可用则跳过
# ============================================================

# Python 主版本与备用版本（华为云已验证存在）
$Script:PythonVersion = '3.12.10'
$Script:PythonFallbackVersion = '3.12.9'

# 生成某版本的下载 URL（华为云 + npmmirror 双镜像）
# 注意：数组内每个 -f 表达式必须加圆括号！（问题备案 #012）
# PS 的 -f 右操作数会吞掉逗号列表，裸写会把两个 URL 合并成 1 个字符串，
# 导致 $urls[0]/[1] 取到单个字符，下载时报「无效的 URI」
function Get-PythonUrls {
    param([string]$Version)
    return @(
        ("https://mirrors.huaweicloud.com/python/{0}/python-{0}-amd64.exe" -f $Version),
        ("https://registry.npmmirror.com/-/binary/python/{0}/python-{0}-amd64.exe" -f $Version)
    )
}

# 本步骤 Python 安装目录
function Get-PythonInstallDir {
    return (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312')
}

# 步骤入口：由 main.ps1 调用
function Invoke-StepPython {
    param([string]$AppRoot)

    $pyDir = Get-PythonInstallDir
    $mainUrls = Get-PythonUrls -Version $Script:PythonVersion
    $fallbackUrls = Get-PythonUrls -Version $Script:PythonFallbackVersion

    $plans = @(
        @{ Name = ("华为云 Python {0} 静默" -f $Script:PythonVersion)
           Action = { Install-PythonSilent -AppRoot $AppRoot -PyDir $pyDir -Version $Script:PythonVersion -Urls @($mainUrls[0], $mainUrls[1]) } },
        @{ Name = ("npmmirror Python {0} 静默" -f $Script:PythonVersion)
           Action = { Install-PythonSilent -AppRoot $AppRoot -PyDir $pyDir -Version $Script:PythonVersion -Urls @($mainUrls[1], $mainUrls[0]) } },
        @{ Name = ("备用版本 {0}" -f $Script:PythonFallbackVersion)
           Action = { Install-PythonSilent -AppRoot $AppRoot -PyDir $pyDir -Version $Script:PythonFallbackVersion -Urls @($fallbackUrls[0], $fallbackUrls[1]) } }
    )

    return (Invoke-InstallStep -Id 'python' -Name 'Python 3.12' -Precheck { Test-PythonReady } -Plans $plans)
}

# 幂等预检：机器上已有可用的 Python 就跳过（问题备案 #012 增强）
# 四路探测，覆盖 Windows 上 Python 的各种存在形态：
#   1. python 命令（注意：WindowsApps 里的商店 stub 无版本输出，天然被排除）
#   2. py 启动器（机器装过 Python 的标准形态，如本例 PATH 里只有 Python\Launcher）
#   3. 用户目录 Python3* 安装目录扫描（任意 3.x 均认可）
#   4. 本安装器的安装位置
function Test-PythonReady {
    if (Test-CommandAvailable -Name 'python') {
        $v = Get-CommandVersion -Command 'python' -Arguments @('--version')
        if ($v) {
            Write-Log -Message ("预检：PATH 中 python 可用（{0}）" -f $v) -Level 'INFO'
            return $true
        }
    }
    if (Test-CommandAvailable -Name 'py') {
        $v = Get-CommandVersion -Command 'py' -Arguments @('-3', '--version')
        if ($v) {
            Write-Log -Message ("预检：py 启动器可用（{0}）" -f $v) -Level 'INFO'
            return $true
        }
    }
    $pythonRoot = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $pythonRoot) {
        $dirs = @(Get-ChildItem -LiteralPath $pythonRoot -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            $exe = Join-Path $d.FullName 'python.exe'
            if ((Test-Path -LiteralPath $exe) -and (Get-CommandVersion -Command $exe -Arguments @('--version'))) {
                Write-Log -Message ("预检：发现已装 Python（{0}）" -f $d.Name) -Level 'INFO'
                return $true
            }
        }
    }
    $pyExe = Join-Path (Get-PythonInstallDir) 'python.exe'
    if ((Test-Path -LiteralPath $pyExe) -and (Get-CommandVersion -Command $pyExe -Arguments @('--version'))) { return $true }
    return $false
}

# 单方案动作：下载 exe → 官方安装器静默安装（用户级）→ pip 换国内源 → 验证
function Install-PythonSilent {
    param([string]$AppRoot, [string]$PyDir, [string]$Version, [string[]]$Urls)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $installer = Join-Path $cacheDir ("python-{0}-amd64.exe" -f $Version)
    Invoke-DownloadFile -DisplayName "Python $Version" -Urls $Urls -OutFile $installer -PayloadDir (Join-Path $AppRoot 'payload')

    # 官方安装器静默参数：用户级安装、加 PATH、含 pip、精简组件（全自动无弹窗）
    try {
        $arguments = @(
            '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=1',
            'Include_test=0', 'Include_doc=0', 'Include_launcher=1', 'InstallLauncherAllUsers=0',
            ("TargetDir=`"{0}`"" -f $PyDir)
        )
        $p = Start-Process -FilePath $installer -ArgumentList $arguments -WindowStyle Hidden -PassThru
        if (-not (Wait-ProcessWithSpinner -Process $p -Activity '正在静默安装 Python 3.12（约 1-3 分钟）' -TimeoutSec 900)) {
            Throw-InstallError -Id 'E-PY-001' -Detail 'Python 静默安装超时（15 分钟）'
        }
        if ($p.ExitCode -ne 0) {
            Throw-InstallError -Id 'E-PY-001' -Detail ("Python 安装器退出码 {0}（常见原因：杀毒软件拦截或磁盘空间不足）" -f $p.ExitCode)
        }
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("安装器被占用（疑被杀毒软件拦截）：{0}" -f $_.Exception.Message)
    }

    # 安装器写的 PATH 在注册表里，刷新当前会话后验证
    Update-SessionPath
    $pyExe = Join-Path $PyDir 'python.exe'
    $versionOut = $null
    if (Test-Path -LiteralPath $pyExe) {
        try { $versionOut = Get-CommandVersion -Command $pyExe -Arguments @('--version') } catch { }
    }
    if (-not $versionOut) {
        Throw-InstallError -Id 'E-PY-002' -Detail 'python.exe 不存在或无法运行'
    }
    Write-Info ("Python 版本：{0}" -f $versionOut)

    # PATH 收尾（安装器已写注册表，这里确保幂等 + 当前会话生效）
    Add-UserPath -Dirs @($PyDir, (Join-Path $PyDir 'Scripts\'))
    Update-SessionPath

    # pip 换阿里云镜像（失败仅警告，不影响安装结果）
    try {
        $pipProc = Start-Process -FilePath $pyExe `
            -ArgumentList @('-m', 'pip', 'config', 'set', 'global.index-url', 'https://mirrors.aliyun.com/pypi/simple/') `
            -WindowStyle Hidden -PassThru -Wait
        Write-Ok 'pip 已配置阿里云镜像源'
    } catch {
        Write-WarnMsg 'pip 镜像配置失败（不影响使用，可稍后手动配置）'
    }
}
