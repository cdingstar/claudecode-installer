# ============================================================
# 步骤 1：安装 Node.js 22（zip 免安装版，解压到用户目录，无 UAC）
# 方案链：A 阿里云 zip → B npmmirror zip → C 华为云 zip
# 安装位置：%LOCALAPPDATA%\Programs\nodejs
# 幂等：node.exe 存在且可运行则跳过
# ============================================================

# Node.js 版本与三镜像 URL（npmmirror 为 302 跳转 CDN，HttpWebRequest 自动跟随）
$Script:NodeVersion = '22.23.2'
$Script:NodeUrls = @(
    @{ Name = '阿里云镜像'; Url = "https://mirrors.aliyun.com/nodejs-release/v{0}/node-v{0}-win-x64.zip" -f $Script:NodeVersion },
    @{ Name = 'npmmirror 镜像'; Url = "https://registry.npmmirror.com/-/binary/node/v{0}/node-v{0}-win-x64.zip" -f $Script:NodeVersion },
    @{ Name = '华为云镜像'; Url = "https://mirrors.huaweicloud.com/nodejs/v{0}/node-v{0}-win-x64.zip" -f $Script:NodeVersion }
)

# 本步骤使用的 Node 安装目录
function Get-NodeInstallDir {
    return (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
}

# 步骤入口：由 main.ps1 调用
function Invoke-StepNode {
    param([string]$AppRoot)

    $nodeDir = Get-NodeInstallDir

    # 每个方案 = 从指定镜像下载 zip + 解压安装；组装方案链
    $plans = @()
    foreach ($entry in $Script:NodeUrls) {
        $url = $entry.Url
        $mirrorName = $entry.Name
        $plans += @{
            Name   = ("{0} zip 免安装" -f $mirrorName)
            Action = { Install-NodeFromZip -Url $url -AppRoot $AppRoot -NodeDir $nodeDir }
        }
    }

    return (Invoke-InstallStep -Id 'node' -Name 'Node.js' -Precheck { Test-NodeReady } -Plans $plans)
}

# 幂等预检：node 可用且版本 ≥ 18（Claude Code 2.x 硬性要求）
# 教训（问题备案 #009）：曾只查「能运行」不查版本，导致旧 Node 16 被跳过、
# Claude Code 装上后无法运行
function Test-NodeReady {
    $nodeDir = Get-NodeInstallDir
    $nodeExe = Join-Path $nodeDir 'node.exe'
    if ((Test-Path -LiteralPath $nodeExe) -and (Test-NodeVersionAtLeast -NodePath $nodeExe -Major 18)) {
        return $true
    }
    # 系统其他位置的 node 也要求 ≥ 18，否则视为需要安装新版本
    $cmd = Get-Command -Name 'node' -ErrorAction SilentlyContinue
    if ($cmd -and (Test-NodeVersionAtLeast -NodePath $cmd.Source -Major 18)) {
        return $true
    }
    return $false
}

# 检查指定 node.exe 的主版本是否达到下限（"v22.23.2" → 22 ≥ 18）
function Test-NodeVersionAtLeast {
    param([string]$NodePath, [int]$Major)
    $version = Get-CommandVersion -Command $NodePath -Arguments @('-v')
    if (-not $version) { return $false }
    if ($version -match 'v?(\d+)') {
        $found = [int]$Matches[1]
        if ($found -lt $Major) {
            Write-Log -Message ("Node 版本过低：{0}（要求 ≥ {1}），将安装新版" -f $version, $Major) -Level 'WARN'
            return $false
        }
        return $true
    }
    return $false
}

# 单方案动作：下载 → 解压 → 验证 → 配 PATH
function Install-NodeFromZip {
    param([string]$Url, [string]$AppRoot, [string]$NodeDir)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $zipFile = Join-Path $cacheDir ("node-v{0}-win-x64.zip" -f $Script:NodeVersion)

    Invoke-DownloadFile -DisplayName 'Node.js 22' -Urls @($Url) -OutFile $zipFile -PayloadDir (Join-Path $AppRoot 'payload')

    # 解压到临时目录（zip 内含顶层目录 node-vXX-win-x64）
    $extractDir = Join-Path $cacheDir 'node-extract'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    Write-Info '正在解压 Node.js（约 30MB，请稍候）……'
    try {
        Expand-Archive -LiteralPath $zipFile -DestinationPath $extractDir -Force
    } catch {
        Throw-InstallError -Id 'E-NODE-001' -Detail ("解压失败：{0}" -f $_.Exception.Message)
    }
    $inner = Get-ChildItem -LiteralPath $extractDir -Directory | Where-Object { $_.Name -like 'node-v*-win-*' } | Select-Object -First 1
    if (-not $inner) {
        Throw-InstallError -Id 'E-NODE-001' -Detail '压缩包内容结构异常（未找到 node-v*-win-* 目录）'
    }

    # 移动内容到最终目录（-Force 确保包含隐藏文件；被杀软占用会抛 IO 异常 → E-AV-001）
    try {
        if (Test-Path -LiteralPath $NodeDir) { Remove-Item -LiteralPath $NodeDir -Recurse -Force }
        New-Item -ItemType Directory -Path $NodeDir -Force | Out-Null
        Get-ChildItem -LiteralPath $inner.FullName -Force | Move-Item -Destination $NodeDir -Force
    } catch {
        Throw-InstallError -Id 'E-AV-001' -Detail ("文件移动失败（可能被杀毒软件占用）：{0}" -f $_.Exception.Message)
    }
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    # 安装后验证
    $nodeExe = Join-Path $NodeDir 'node.exe'
    $version = $null
    try { $version = Get-CommandVersion -Command $nodeExe -Arguments @('-v') } catch { }
    if (-not $version) {
        # exe 可能刚落地就被杀软隔离
        if (-not (Test-Path -LiteralPath $nodeExe)) {
            Throw-InstallError -Id 'E-AV-001' -Detail 'node.exe 解压后消失，疑似被杀毒软件删除'
        }
        Throw-InstallError -Id 'E-NODE-002' -Detail 'node.exe 存在但无法运行'
    }
    Write-Info ("Node.js 版本：{0}" -f $version)

    # User 级 PATH + 当前会话立即可用
    Add-UserPath -Dirs @($NodeDir)
    Update-SessionPath
}
