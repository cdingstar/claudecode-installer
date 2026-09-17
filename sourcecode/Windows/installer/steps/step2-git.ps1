# ============================================================
# 步骤 2：安装 Git for Windows（Claude Code 在 Windows 上依赖其 Bash 环境）
# 方案链：A 华为云 PortableGit 自解压 → B npmmirror PortableGit
#        → C 完整安装器静默安装（/CURRENTUSER 免管理员）
# 安装位置：%LOCALAPPDATA%\Programs\Git
# 幂等：git --version 可用则跳过
# ============================================================

# Git 版本（已验证镜像文件存在）与下载 URL
# 注意：数组内每个 -f 表达式必须加圆括号（问题备案 #012，同 step3 的 URI 陷阱）
$Script:GitTag = 'v2.55.0.windows.5'
$Script:GitVersion = '2.55.0.5'
$Script:GitPortableUrls = @(
    ("https://mirrors.huaweicloud.com/git-for-windows/{0}/PortableGit-{1}-64-bit.7z.exe" -f $Script:GitTag, $Script:GitVersion),
    ("https://registry.npmmirror.com/-/binary/git-for-windows/{0}/PortableGit-{1}-64-bit.7z.exe" -f $Script:GitTag, $Script:GitVersion)
)
$Script:GitInstallerUrl = "https://mirrors.huaweicloud.com/git-for-windows/{0}/Git-{1}-64-bit.exe" -f $Script:GitTag, $Script:GitVersion

# 本步骤 Git 安装目录
function Get-GitInstallDir {
    return (Join-Path $env:LOCALAPPDATA 'Programs\Git')
}

# 步骤入口：由 main.ps1 调用
function Invoke-StepGit {
    param([string]$AppRoot)

    $gitDir = Get-GitInstallDir
    # 把两路 PortableGit 镜像各自成方案（方案内下载失败也会自动换镜像），完整安装器兜底
    $plans = @(
        @{ Name = '华为云 PortableGit 解压版'
           Action = { Install-GitPortable -AppRoot $AppRoot -GitDir $gitDir -Urls @($Script:GitPortableUrls[0], $Script:GitPortableUrls[1]) } },
        @{ Name = 'npmmirror PortableGit 解压版'
           Action = { Install-GitPortable -AppRoot $AppRoot -GitDir $gitDir -Urls @($Script:GitPortableUrls[1], $Script:GitPortableUrls[0]) } },
        @{ Name = '完整安装器静默安装'
           Action = { Install-GitSilent -AppRoot $AppRoot -GitDir $gitDir } }
    )

    return (Invoke-InstallStep -Id 'git' -Name 'Git for Windows' -Precheck { Test-GitReady } -Plans $plans)
}

# 幂等预检：git 命令可用
function Test-GitReady {
    if (Test-CommandAvailable -Name 'git') {
        $v = Get-CommandVersion -Command 'git' -Arguments @('--version')
        if ($v) { return $true }
    }
    $gitExe = Join-Path (Get-GitInstallDir) 'cmd\git.exe'
    if ((Test-Path -LiteralPath $gitExe) -and (Get-CommandVersion -Command $gitExe -Arguments @('--version'))) { return $true }
    return $false
}

# 方案 A/B：PortableGit 自解压 + post-install 初始化
function Install-GitPortable {
    param([string]$AppRoot, [string]$GitDir, [string[]]$Urls)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $sfxFile = Join-Path $cacheDir ("PortableGit-{0}-64-bit.7z.exe" -f $Script:GitVersion)
    Invoke-DownloadFile -DisplayName 'Git Portable' -Urls $Urls -OutFile $sfxFile -PayloadDir (Join-Path $AppRoot 'payload')

    # 7z 自解压：-y 全自动确认，-o 指定输出目录
    try {
        if (Test-Path -LiteralPath $GitDir) { Remove-Item -LiteralPath $GitDir -Recurse -Force }
        New-Item -ItemType Directory -Path $GitDir -Force | Out-Null
        $p = Start-Process -FilePath $sfxFile -ArgumentList @('-y', ("-o{0}" -f $GitDir)) -WindowStyle Hidden -PassThru
        if (-not (Wait-ProcessWithSpinner -Process $p -Activity '正在解压 Git（PortableGit，约 1-2 分钟）' -TimeoutSec 300)) {
            Throw-InstallError -Id 'E-GIT-001' -Detail 'PortableGit 自解压超时（5 分钟）'
        }
        if ($p.ExitCode -ne 0) {
            Throw-InstallError -Id 'E-GIT-001' -Detail ("自解压退出码 {0}" -f $p.ExitCode)
        }
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("解压文件被占用（疑被杀毒软件拦截）：{0}" -f $_.Exception.Message)
    }

    # post-install.bat 生成 bash 环境必需的链接（必须在 Git 目录下执行）
    $postInstall = Join-Path $GitDir 'post-install.bat'
    if (Test-Path -LiteralPath $postInstall) {
        try {
            $p2 = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'post-install.bat') -WorkingDirectory $GitDir -WindowStyle Hidden -PassThru
            [void](Wait-ProcessWithSpinner -Process $p2 -Activity '正在初始化 Git 环境（post-install，约 1 分钟）' -TimeoutSec 180)
        } catch {
            Write-Log -Message ("post-install 执行异常（忽略继续）：{0}" -f $_.Exception.Message) -Level 'WARN'
        }
    }

    Complete-GitInstall -GitDir $GitDir
}

# 方案 C：完整安装器静默安装到用户目录（/CURRENTUSER 免 UAC）
function Install-GitSilent {
    param([string]$AppRoot, [string]$GitDir)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $installer = Join-Path $cacheDir ("Git-{0}-64-bit.exe" -f $Script:GitVersion)
    Invoke-DownloadFile -DisplayName 'Git 安装器' -Urls @($Script:GitInstallerUrl) -OutFile $installer -PayloadDir (Join-Path $AppRoot 'payload')

    try {
        $p = Start-Process -FilePath $installer `
            -ArgumentList @('/VERYSILENT', '/NORESTART', '/CURRENTUSER', '/SUPPRESSMSGBOXES', ("/DIR=`"{0}`"" -f $GitDir)) `
            -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit(600000)) {
            try { $p.Kill() } catch { }
            Throw-InstallError -Id 'E-GIT-001' -Detail 'Git 静默安装超时（10 分钟）'
        }
        if ($p.ExitCode -ne 0) {
            Throw-InstallError -Id 'E-GIT-001' -Detail ("安装器退出码 {0}" -f $p.ExitCode)
        }
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("安装器被占用（疑被杀毒软件拦截）：{0}" -f $_.Exception.Message)
    }

    Complete-GitInstall -GitDir $GitDir
}

# 安装收尾：验证 + PATH
function Complete-GitInstall {
    param([string]$GitDir)

    $gitExe = Join-Path $GitDir 'cmd\git.exe'
    $version = $null
    if (Test-Path -LiteralPath $gitExe) {
        try { $version = Get-CommandVersion -Command $gitExe -Arguments @('--version') } catch { }
    }
    if (-not $version) {
        Throw-InstallError -Id 'E-GIT-003' -Detail 'git.exe 不存在或无法运行'
    }
    Write-Info ("Git 版本：{0}" -f $version)

    Add-UserPath -Dirs @((Join-Path $GitDir 'cmd'), (Join-Path $GitDir 'bin'))
    Update-SessionPath
}
