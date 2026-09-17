# ============================================================
# 步骤 4：安装 Claude Code 本体
# 方案链：A npmmirror registry npm 安装 → B 腾讯镜像 npm 安装
#        → C 手动 tgz（主包 + win32-x64 平台包，npm 坏了也能装）
# 前置：Node.js 安装成功
# 全局位置：%APPDATA%\npm（prefix），命令 claude.cmd
# 幂等：claude --version 可用则跳过
# ============================================================

# npm 全局目录（本步骤统一使用）
function Get-NpmGlobalDir {
    return (Join-Path $env:APPDATA 'npm')
}

# 步骤入口：由 main.ps1 调用（前置已确认 node 可用）
function Invoke-StepClaudeCode {
    param([string]$AppRoot)

    $plans = @(
        @{ Name = 'npmmirror 源 npm 安装'
           Action = { Install-ClaudeViaNpm -AppRoot $AppRoot -Registry 'https://registry.npmmirror.com' } },
        @{ Name = '腾讯源 npm 安装'
           Action = { Install-ClaudeViaNpm -AppRoot $AppRoot -Registry 'https://mirrors.cloud.tencent.com/npm/' } },
        @{ Name = '手动安装包（tgz）'
           Action = { Install-ClaudeFromTgz -AppRoot $AppRoot } }
    )

    return (Invoke-InstallStep -Id 'claude' -Name 'Claude Code' -Precheck { Test-ClaudeReady } -Plans $plans)
}

# 幂等预检：claude 实测 --version 能运行且主版本 ≥ 2 才算已装
# 教训（问题备案 #009）：曾只查 PATH 里「claude 命令存在」，旧残留 shim 存在但
# 跑不起来，导致误判已装而跳过安装，最终自检失败
# v1.7（#016）：1.x 老版本能跑但兼容性差，也视为需要重装升级
function Test-ClaudeReady {
    $shim = Join-Path (Get-NpmGlobalDir) 'claude.cmd'
    if ((Test-Path -LiteralPath $shim) -and (Test-ClaudeVersionAtLeast -CommandPath $shim -Major 2)) {
        Write-Log -Message '预检：Claude Code 可用（版本达标）' -Level 'INFO'
        return $true
    }
    $cmd = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
    if ($cmd -and (Test-ClaudeVersionAtLeast -CommandPath $cmd.Source -Major 2)) {
        Write-Log -Message ("预检：PATH 中的 Claude Code 可用（{0}）" -f $cmd.Source) -Level 'INFO'
        return $true
    }
    return $false
}

# 校验 claude 主版本是否达到下限（"2.1.245 (Claude Code)" → 2 ≥ 2）
function Test-ClaudeVersionAtLeast {
    param([string]$CommandPath, [int]$Major)
    $version = Get-CommandVersion -Command $CommandPath
    if (-not $version) { return $false }
    if ($version -match 'v?(\d+)\.') {
        $found = [int]$Matches[1]
        if ($found -lt $Major) {
            Write-Log -Message ("Claude Code 版本过旧：{0}（要求 ≥ {1}），将重装升级" -f ($version -split '\s+' | Select-Object -First 1), $Major) -Level 'WARN'
            return $false
        }
        return $true
    }
    return $false
}

# 取 npm.cmd 的绝对路径（不依赖 PATH 是否已刷新）
function Get-NpmCommand {
    $nodeDir = Get-NodeInstallDir
    $npmCmd = Join-Path $nodeDir 'npm.cmd'
    if (Test-Path -LiteralPath $npmCmd) { return $npmCmd }
    # node 目录里没有（老版 zip 结构差异），退回 PATH 查找
    $found = Get-Command -Name 'npm.cmd' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    Throw-InstallError -Id 'E-NPM-001' -Detail '找不到 npm.cmd（Node.js 安装不完整）'
}

# 方案 A/B：通过指定 npm 镜像源全局安装（含 npm 预配置）
function Install-ClaudeViaNpm {
    param([string]$AppRoot, [string]$Registry)

    $npmCmd = Get-NpmCommand
    $npmGlobal = Get-NpmGlobalDir

    # 先清理损坏的旧安装（问题备案 #011）：
    # claude.exe 损坏（PE 头坏 → Windows 误报"16 位不兼容"）时，
    # npm install -g 会因"已是最新版本"跳过替换，损坏文件永远留着
    Clear-BrokenClaudeInstall -NpmGlobal $npmGlobal

    # npm 基础配置：镜像源 + 用户级全局目录 + 缓存位置（全部免管理员）
    $configActions = @(
        @('config', 'set', 'registry', $Registry),
        @('config', 'set', 'prefix', $npmGlobal),
        @('config', 'set', 'cache', (Join-Path $env:LOCALAPPDATA 'npm-cache'))
    )
    foreach ($action in $configActions) {
        Invoke-NpmWait -NpmCmd $npmCmd -Arguments $action -TimeoutSec 60 | Out-Null
    }

    # 安装（10 分钟超时，防网络慢导致假死）
    New-Item -ItemType Directory -Path $npmGlobal -Force | Out-Null
    Invoke-NpmWait -NpmCmd $npmCmd -Arguments @('install', '-g', '@anthropic-ai/claude-code', '--no-fund', '--no-audit', '--loglevel', 'error') -TimeoutSec 600 | Out-Null

    # PATH 收尾 + 验证
    Add-UserPath -Dirs @($npmGlobal)
    Update-SessionPath
    $shim = Join-Path $npmGlobal 'claude.cmd'
    if (-not (Test-Path -LiteralPath $shim)) {
        Throw-InstallError -Id 'E-CC-002' -Detail ('npm 安装完成但未生成 claude.cmd（检查 %APPDATA%\npm 目录）')
    }
    $version = $null
    try { $version = Get-CommandVersion -Command $shim } catch { }
    if (-not $version) {
        # 装完仍跑不起来：附体检诊断（exe 是否被删/截断 + 杀软名单），直接进报告
        $diag = Get-ClaudeFailureDiagnosis -NpmGlobal $npmGlobal
        Throw-InstallError -Id 'E-CC-002' -Detail ("claude.cmd 已生成但无法执行。诊断：{0}" -f $diag)
    }
    Write-Info ("Claude Code 版本：{0}" -f $version)
}

# 清理损坏的旧 Claude Code 安装（exe 无法运行时整包删除，强制 npm 重下）
# 判据：包目录存在，但 bin\claude.exe 缺失或实测 --version 失败
function Clear-BrokenClaudeInstall {
    param([string]$NpmGlobal)

    $pkgDir = Join-Path $NpmGlobal 'node_modules\@anthropic-ai\claude-code'
    if (-not (Test-Path -LiteralPath $pkgDir)) { return }

    $exePath = Join-Path $pkgDir 'bin\claude.exe'
    $broken = $true
    if (Test-Path -LiteralPath $exePath) {
        $exeSize = (Get-Item -LiteralPath $exePath).Length
        if ($exeSize -lt 1MB) {
            # 小于 1MB = postinstall 没跑成的占位 stub（500 字节），必然无法运行
            Write-Log -Message ("bin\claude.exe 仅 {0} 字节（占位 stub 未被替换）" -f $exeSize) -Level 'INFO'
        } else {
            try {
                $v = Get-CommandVersion -Command $exePath
                if ($v) { $broken = $false }
            } catch { }
        }
    }
    if (-not $broken) { return }

    Write-Info '检测到旧版 Claude Code 损坏（claude.exe 为占位 stub 或无法运行），清理后强制重装'
    Write-Log -Message ("清理损坏安装：{0}" -f $pkgDir) -Level 'INFO'
    try {
        Remove-Item -LiteralPath $pkgDir -Recurse -Force
        # 平台包与命令 shim 一并清理，避免半新半旧
        $platDir = Join-Path $NpmGlobal 'node_modules\@anthropic-ai\claude-code-win32-x64'
        if (Test-Path -LiteralPath $platDir) { Remove-Item -LiteralPath $platDir -Recurse -Force }
        foreach ($shimName in @('claude.cmd', 'claude', 'claude.ps1')) {
            $shimPath = Join-Path $NpmGlobal $shimName
            if (Test-Path -LiteralPath $shimPath) { Remove-Item -LiteralPath $shimPath -Force }
        }
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("删除损坏文件失败（可能被杀毒软件/其他程序占用）：{0}" -f $_.Exception.Message)
    }
}

# 检测正在运行的常见杀毒软件（返回名称数组；Windows 上 Windows Defender 始终存在）
function Get-AntiVirusNames {
    $found = New-Object System.Collections.ArrayList
    try {
        $procNames = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        # 360/火绒/QQ/金山/百度/2345/瑞星 等常见进程名特征
        foreach ($p in $procNames) {
            if ($p -match '^(360|Hips|wsctrl|usysdiag|QQPCRTP|QMDL|kxetray|kwsprotect|baidusd|2345|rav|wscntfy|huorong|sysdiag|SecMind)') {
                [void]$found.Add($p)
            }
        }
    } catch { }
    # Windows Defender（Win10/11 内置，多数「文件被静默删除」的元凶）
    try {
        if (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
            if ($mp -and ($mp.RealTimeProtectionEnabled -or $mp.AMRunningEnabled)) {
                [void]$found.Add('Windows Defender(实时防护)')
            }
        }
    } catch { }
    return @($found | Select-Object -Unique)
}

# claude 运行失败时的体检诊断（输出可执行的定位信息，进错误详情与报告）
function Get-ClaudeFailureDiagnosis {
    param([string]$NpmGlobal)

    $pkgDir = Join-Path $NpmGlobal 'node_modules\@anthropic-ai\claude-code'
    $platDir = Join-Path $NpmGlobal 'node_modules\@anthropic-ai\claude-code-win32-x64'
    $exePath = Join-Path $pkgDir 'bin\claude.exe'
    $parts = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $exePath)) {
        [void]$parts.Add('bin\claude.exe 文件已消失（刚下载解压就不存在——极大概率被杀毒软件删除/隔离）')
    } else {
        $size = (Get-Item -LiteralPath $exePath).Length
        if ($size -lt 1MB) {
            [void]$parts.Add(("bin\claude.exe 仅 {0:N0} 字节——是未完成安装的占位 stub（真实主程序约 380MB，Windows 报「16 位不兼容」正是此物）" -f $size))
        } else {
            [void]$parts.Add(("bin\claude.exe 存在，大小 {0:N0} 字节" -f $size))
        }
    }
    if (Test-Path -LiteralPath $platDir) {
        $platFiles = @(Get-ChildItem -LiteralPath $platDir -Recurse -File -ErrorAction SilentlyContinue)
        $platSize = ($platFiles | Measure-Object -Property Length -Sum).Sum
        [void]$parts.Add(("平台包已解压（{0} 个文件，共 {1:N0} 字节）" -f $platFiles.Count, $platSize))
        if ($platFiles.Count -gt 0 -and $platSize -lt 10MB) {
            [void]$parts.Add('平台包体积异常偏小（疑似被杀毒软件截断/篡改——Windows 报「16 位不兼容」的典型原因就是 exe 文件损坏）')
        }
    } else {
        [void]$parts.Add('平台包目录缺失（claude.exe 找不到真实程序，无法运行）')
    }
    $av = Get-AntiVirusNames
    if ($av.Count -gt 0) {
        [void]$parts.Add(("检测到杀毒软件：{0}。请把以下两个目录加入其信任区/白名单后重跑安装器：{1}；{2}" -f ($av -join '、'), $pkgDir, $platDir))
    }
    return ($parts -join '；')
}

# 方案 C：手动 tgz 安装（主包 + Windows 平台包 + 手写 shim，不依赖 npm install）
function Install-ClaudeFromTgz {
    param([string]$AppRoot)

    $npmGlobal = Get-NpmGlobalDir
    $cacheDir = Get-PackageCacheDir -AppRoot $AppRoot
    $registry = 'https://registry.npmmirror.com'
    $payloadDir = Join-Path $AppRoot 'payload'

    # 1) 从镜像查询版本与 tarball 地址（失败抛 E-CC-003 切换方案）
    $meta = $null
    try {
        $meta = Invoke-RestMethod -Uri "$registry/@anthropic-ai/claude-code/latest" -TimeoutSec 30
    } catch {
        Throw-InstallError -Id 'E-CC-003' -Detail ("读取包信息失败：{0}" -f $_.Exception.Message)
    }
    $version = $meta.version
    if (-not $version) {
        Throw-InstallError -Id 'E-CC-003' -Detail '包信息中缺少 version 字段'
    }
    Write-Info ("目标版本：{0}" -f $version)

    # 2) 下载主包与 win32-x64 平台包（2.1.x 起真正的可执行文件在平台包内）
    $mainTgz = Join-Path $cacheDir ("claude-code-{0}.tgz" -f $version)
    $platTgz = Join-Path $cacheDir ("claude-code-win32-x64-{0}.tgz" -f $version)
    Invoke-DownloadFile -DisplayName 'Claude Code 主包' -Urls @("$registry/@anthropic-ai/claude-code/-/claude-code-$version.tgz") -OutFile $mainTgz -PayloadDir $payloadDir
    Invoke-DownloadFile -DisplayName 'Claude Code 平台包(win32-x64)' -Urls @("$registry/@anthropic-ai/claude-code-win32-x64/-/claude-code-win32-x64-$version.tgz") -OutFile $platTgz -PayloadDir $payloadDir

    # 3) 解压并归位：node_modules\@anthropic-ai\claude-code(-win32-x64)
    $scopeDir = Join-Path $npmGlobal 'node_modules\@anthropic-ai'
    New-Item -ItemType Directory -Path $scopeDir -Force | Out-Null
    $mainDir = Join-Path $scopeDir 'claude-code'
    $platDir = Join-Path $scopeDir 'claude-code-win32-x64'
    try {
        if (Test-Path -LiteralPath $mainDir) { Remove-Item -LiteralPath $mainDir -Recurse -Force }
        if (Test-Path -LiteralPath $platDir) { Remove-Item -LiteralPath $platDir -Recurse -Force }
        # tar 为 Windows 10 1803+ 自带（bsdtar，支持 tgz）
        $tmpMain = Join-Path $cacheDir 'tgz-main'
        $tmpPlat = Join-Path $cacheDir 'tgz-plat'
        foreach ($tmp in @($tmpMain, $tmpPlat)) {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        }
        $tar = 'tar.exe'
        & $tar -xzf $mainTgz -C $tmpMain
        if ($LASTEXITCODE -ne 0) { Throw-InstallError -Id 'E-CC-001' -Detail ('主包解压失败（tar 退出码 {0}）' -f $LASTEXITCODE) }
        & $tar -xzf $platTgz -C $tmpPlat
        if ($LASTEXITCODE -ne 0) { Throw-InstallError -Id 'E-CC-001' -Detail ('平台包解压失败（tar 退出码 {0}）' -f $LASTEXITCODE) }
        Move-Item -LiteralPath (Join-Path $tmpMain 'package') -Destination $mainDir -Force
        Move-Item -LiteralPath (Join-Path $tmpPlat 'package') -Destination $platDir -Force
        Remove-Item -LiteralPath $tmpMain -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpPlat -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Throw-InstallError -Id 'E-CC-001' -Detail ("tgz 安装失败：{0}" -f $_.Exception.Message)
    }

    # 4) 复制平台包的真实程序覆盖主包 stub（问题备案 #013 的关键步骤）
    #    主包 bin\claude.exe 只是 500 字节占位；npm 正常安装靠 postinstall(install.cjs)
    #    把平台包的 366MB claude.exe 复制过来——手动安装必须自己补这一步，
    #    否则 claude.exe 无法运行（Windows 报「16 位不兼容」的 stub 残留即此因）
    $binExe = Join-Path $mainDir 'bin\claude.exe'
    $realExe = Join-Path $platDir 'claude.exe'
    if (-not (Test-Path -LiteralPath $realExe)) {
        Throw-InstallError -Id 'E-CC-002' -Detail ('平台包中缺少 claude.exe（版本 {0} 结构变化）' -f $version)
    }
    $realSize = (Get-Item -LiteralPath $realExe).Length
    if ($realSize -lt 50MB) {
        Throw-InstallError -Id 'E-CC-002' -Detail ("平台包 claude.exe 体积异常（{0:N0} 字节，正常约 380MB）" -f $realSize)
    }
    try {
        Write-Info ("正在复制主程序（{0:N0} MB，约需几秒到十几秒，请稍候）……" -f ($realSize / 1MB))
        Copy-Item -LiteralPath $realExe -Destination $binExe -Force
    } catch [System.IO.IOException] {
        Throw-InstallError -Id 'E-AV-001' -Detail ("复制主程序失败（疑被杀毒软件占用/拦截）：{0}" -f $_.Exception.Message)
    }
    Write-Info ("已就位真实主程序：{0:N0} 字节" -f (Get-Item -LiteralPath $binExe).Length)
    $shim = Join-Path $npmGlobal 'claude.cmd'
    $shimContent = "@`"%~dp0node_modules\@anthropic-ai\claude-code\bin\claude.exe`" %*`r`n"
    [System.IO.File]::WriteAllText($shim, $shimContent, (New-Object System.Text.UTF8Encoding($false)))

    Add-UserPath -Dirs @($npmGlobal)
    Update-SessionPath

    $version2 = $null
    try { $version2 = Get-CommandVersion -Command $shim } catch { }
    if (-not $version2) {
        $diag = Get-ClaudeFailureDiagnosis -NpmGlobal $npmGlobal
        Throw-InstallError -Id 'E-CC-002' -Detail ("手动安装完成但 claude.cmd 无法执行。诊断：{0}" -f $diag)
    }
    Write-Info ("Claude Code 版本：{0}" -f $version2)
}

# 执行 npm 命令（带 marquee 动画 + 超时保护 + 输出收集，#020）
# 经 Invoke-ToolWithSpinner（cmd /s /c 标准形式，引号一次写对——#013 教训），
# 不再用同步 & 调用（等待期间无任何输出，用户会以为死机）
function Invoke-NpmWait {
    param([string]$NpmCmd, [string[]]$Arguments, [int]$TimeoutSec = 600)

    $result = Invoke-ToolWithSpinner -FilePath $NpmCmd -Arguments $Arguments `
        -Activity ("npm {0}（正在下载安装，可能需要几分钟）" -f (($Arguments | Where-Object { $_ -notmatch '^(--|https?://)' } | Select-Object -Last 2) -join ' ')) `
        -TimeoutSec $TimeoutSec
    if ($result.Output) { Write-Log -Message ("npm 输出：{0}" -f $result.Output) -Level 'DEBUG' }
    if ($result.TimedOut) {
        Throw-InstallError -Id 'E-NPM-001' -Detail ("npm 命令超时（{0} 秒）" -f $TimeoutSec)
    }
    if (-not $result.Ok) {
        $tail = ($result.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' / '
        Throw-InstallError -Id 'E-CC-001' -Detail ("npm {0} 退出码 {1}：{2}" -f ($Arguments -join ' '), $result.ExitCode, $tail)
    }
    return $result.Output
}
