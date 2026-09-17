# ============================================================
# 步骤 6：安装 VS Code（用户级，免管理员）
# 时机：模型配置弹窗之后（用户要求：配完 API Key 再装 VSCode）
# 镜像策略（v1.6 调研结论，见 问题备案 #015）：
#   A 主：微软官方中国下载通道（vscode.download.prss.microsoft.com/dbazure）
#        —— 官方 CDN、版本最新；版本/commit/SHA256 由官方更新 API 动态获取
#          （API 仅取 KB 级元数据，安装包下载发生在微软中国通道）
#   B 备：华为云 UserSetup 静默（静态版本，官方通道不可用时兜底）
#   C 备：华为云 zip 免安装解压
# 安装位置：%LOCALAPPDATA%\Programs\Microsoft VS Code（UserSetup 默认）
# 幂等：code --version 可用或已装其他 VSCode 则跳过；下载包缓存/离线包直接复用
# ============================================================

# 华为云镜像静态版本（已验证 HTTP 200；注意华为云同步滞后，仅在官方通道失败时使用）
$Script:VscodeVersion = '1.105.0'

# 生成华为云下载 URL（平铺结构：<版本>/文件名）
function Get-VscodeUrls {
    param([string]$Version, [string]$Kind)
    if ($Kind -eq 'zip') {
        return @(
            ("https://mirrors.huaweicloud.com/VSCode/{0}/VSCode-win32-x64-{0}.zip" -f $Version)
        )
    }
    return @(
        ("https://mirrors.huaweicloud.com/VSCode/{0}/VSCodeUserSetup-x64-{0}.exe" -f $Version)
    )
}

# 从官方更新 API 取最新版元数据（版本/直链/SHA256）
# 返回：@{ Version; Url; Sha256 } 或 $null（API 不可达时走华为云备份）
function Get-VscodeOfficialMeta {
    try {
        $meta = Invoke-RestMethod -Uri 'https://update.code.visualstudio.com/api/update/win32-x64-user/stable/latest' -TimeoutSec 15
        if ($meta.url -and $meta.url -match '^https://' -and $meta.sha256hash) {
            return @{
                Version = [string]$meta.productVersion
                Url     = [string]$meta.url
                Sha256  = [string]$meta.sha256hash
            }
        }
    } catch {
        Write-Log -Message ("官方更新 API 不可达（切华为云备份）：{0}" -f $_.Exception.Message) -Level 'WARN'
    }
    return $null
}

# 本步骤 VS Code 安装目录
function Get-VscodeInstallDir {
    return (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code')
}

# 步骤入口：由 main.ps1 调用
function Invoke-StepVscode {
    param([string]$AppRoot)

    $plans = @(
        @{ Name = '微软官方中国通道（最新版）'
           Action = { Install-VscodeOfficial -AppRoot $AppRoot } },
        @{ Name = ("华为云备份 UserSetup {0}" -f $Script:VscodeVersion)
           Action = { Install-VscodeSilent -AppRoot $AppRoot -Version $Script:VscodeVersion } },
        @{ Name = ("华为云备份 zip 免安装 {0}" -f $Script:VscodeVersion)
           Action = { Install-VscodeFromZip -AppRoot $AppRoot -Version $Script:VscodeVersion } }
    )

    return (Invoke-InstallStep -Id 'vscode' -Name 'VS Code' -Precheck { Test-VscodeReady } -Plans $plans)
}

# 方案 A：官方元数据 → 官方中国通道直链（含 SHA256 校验）→ 静默安装
function Install-VscodeOfficial {
    param([string]$AppRoot)

    $meta = Get-VscodeOfficialMeta
    if (-not $meta) {
        Throw-InstallError -Id 'E-VSC-001' -Detail '无法获取官方版本信息（网络原因），切换华为云备份方案'
    }
    Write-Info ("官方最新版：{0}（下载通道：{1}）" -f $meta.Version, ([Uri]$meta.Url).Host)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $installer = Join-Path $cacheDir ("VSCodeUserSetup-x64-{0}.exe" -f $meta.Version)
    Invoke-DownloadFile -DisplayName ("VS Code {0}（官方）" -f $meta.Version) -Urls @($meta.Url) -OutFile $installer -Sha256 $meta.Sha256 -PayloadDir (Join-Path $AppRoot 'payload')

    # 复用静默安装逻辑（已下载的安装器路径直接传入）
    Invoke-VscodeSetupExe -Installer $installer
    Complete-VscodeInstall -ExpectedDir (Get-VscodeInstallDir)
}

# 幂等预检：code 命令可用，或常见安装位置可运行（含系统级安装）
function Test-VscodeReady {
    if (Test-CommandAvailable -Name 'code') {
        $v = Get-CommandVersion -Command 'code'
        if ($v) { return $true }
    }
    foreach ($dir in @((Get-VscodeInstallDir), (Join-Path $env:ProgramFiles 'Microsoft VS Code'))) {
        $exe = Join-Path $dir 'Code.exe'
        if ((Test-Path -LiteralPath $exe) -and (Get-CommandVersion -Command $exe -Arguments @('--version'))) { return $true }
    }
    return $false
}

# 执行 VSCode UserSetup 安装器（静默，Inno Setup 参数，per-user 免管理员）
function Invoke-VscodeSetupExe {
    param([string]$Installer)

    try {
        # /MERGETASKS=!runcode：装完不自动启动 VS Code
        $p = Start-Process -FilePath $Installer `
            -ArgumentList @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/MERGETASKS=!runcode') `
            -WindowStyle Hidden -PassThru
        if (-not (Wait-ProcessWithSpinner -Process $p -Activity '正在安装 VS Code（解压约 1-3 分钟）' -TimeoutSec 600)) {
            Throw-InstallError -Id 'E-VSC-001' -Detail 'VS Code 静默安装超时（10 分钟）'
        }
        if ($p.ExitCode -ne 0) {
            Throw-InstallError -Id 'E-VSC-001' -Detail ("VS Code 安装器退出码 {0}" -f $p.ExitCode)
        }
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("安装器被占用（疑被杀毒软件拦截）：{0}" -f $_.Exception.Message)
    }
}

# 方案 B：华为云 UserSetup 静默安装（备份路径）
function Install-VscodeSilent {
    param([string]$AppRoot, [string]$Version)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $installer = Join-Path $cacheDir ("VSCodeUserSetup-x64-{0}.exe" -f $Version)
    Invoke-DownloadFile -DisplayName "VS Code $Version" -Urls (Get-VscodeUrls -Version $Version -Kind 'exe') -OutFile $installer -PayloadDir (Join-Path $AppRoot 'payload')

    Invoke-VscodeSetupExe -Installer $installer
    Complete-VscodeInstall -ExpectedDir (Get-VscodeInstallDir)
}

# 方案 C：华为云 zip 免安装解压（无右键菜单/文件关联，但功能完整，最稳）
function Install-VscodeFromZip {
    param([string]$AppRoot, [string]$Version)

    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $zipFile = Join-Path $cacheDir ("VSCode-win32-x64-{0}.zip" -f $Version)
    Invoke-DownloadFile -DisplayName "VS Code $Version (zip)" -Urls (Get-VscodeUrls -Version $Version -Kind 'zip') -OutFile $zipFile -PayloadDir (Join-Path $AppRoot 'payload')

    $vsDir = Get-VscodeInstallDir
    try {
        if (Test-Path -LiteralPath $vsDir) { Remove-Item -LiteralPath $vsDir -Recurse -Force }
        New-Item -ItemType Directory -Path $vsDir -Force | Out-Null
        # tar.exe（Win10 1803+ 自带 bsdtar）解压大 zip 远快于 Expand-Archive
        & tar.exe -xf $zipFile -C $vsDir
        if ($LASTEXITCODE -ne 0) {
            # 兜底：标准解压
            $tmpDir = Join-Path $cacheDir 'vscode-extract'
            if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
            Expand-Archive -LiteralPath $zipFile -DestinationPath $tmpDir -Force
            Get-ChildItem -LiteralPath $tmpDir -Force | Move-Item -Destination $vsDir -Force
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("解压文件被占用（疑被杀毒软件拦截）：{0}" -f $_.Exception.Message)
    } catch {
        Throw-InstallError -Id 'E-VSC-002' -Detail ("VS Code 解压失败：{0}" -f $_.Exception.Message)
    }

    Complete-VscodeInstall -ExpectedDir $vsDir
}

# 安装收尾：验证 + PATH（bin\code.cmd 提供 code 命令）+ 自动装 Claude Code 扩展（#020）
function Complete-VscodeInstall {
    param([string]$ExpectedDir)

    $codeExe = Join-Path $ExpectedDir 'Code.exe'
    $version = $null
    if (Test-Path -LiteralPath $codeExe) {
        try { $version = Get-CommandVersion -Command $codeExe -Arguments @('--version') } catch { }
    }
    if (-not $version) {
        Throw-InstallError -Id 'E-VSC-003' -Detail 'Code.exe 不存在或无法运行'
    }
    Write-Info ("VS Code 版本：{0}" -f ($version -split "`r?`n" | Select-Object -First 1))

    Add-UserPath -Dirs @((Join-Path $ExpectedDir 'bin'))
    Update-SessionPath

    # 尽力而为：安装 Claude Code 官方扩展（走 VS Code 官方市场，微软 CDN 国内一般可达；
    # 失败仅警告，不影响安装结果——市场无国内镜像，此步不属于"国内镜像"承诺范围）
    Install-ClaudeVscodeExtension -ExpectedDir $ExpectedDir
}

# 安装 Claude Code 的 VS Code 扩展（失败静默跳过）
function Install-ClaudeVscodeExtension {
    param([string]$ExpectedDir)
    $codeCmd = Join-Path $ExpectedDir 'bin\code.cmd'
    if (-not (Test-Path -LiteralPath $codeCmd)) { return }

    Write-Info '正在安装 Claude Code 的 VS Code 扩展（官方市场，失败不影响使用）……'
    $result = Invoke-ToolWithSpinner -FilePath $codeCmd `
        -Arguments @('--install-extension', 'anthropic.claude-code') `
        -Activity '正在安装 VS Code 扩展（anthropic.claude-code）' -TimeoutSec 240
    if ($result.Ok -and ($result.Output -match 'successfully installed|已成功安装|Installing extensions')) {
        Write-Ok 'Claude Code 扩展安装成功（VS Code 内即可使用）'
        $Script:VscodeExtension = '成功'
    } elseif ($result.Output -match 'already installed|已安装') {
        Write-Info '扩展此前已安装'
        $Script:VscodeExtension = '已存在'
    } else {
        $clip = $result.Output
        if ($clip.Length -gt 160) { $clip = $clip.Substring(0, 160) }
        Write-WarnMsg ("扩展安装未成功（不影响其他功能，可稍后在 VS Code 扩展面板手动安装）：{0}" -f $clip)
        Write-Log -Message ("扩展安装输出：{0}" -f $result.Output) -Level 'WARN'
        $Script:VscodeExtension = '失败（可手动装）'
    }
}
