# ============================================================
# 步骤 5：最终自检 + 生成《安装报告.txt》（v1.1 增强版）
# 报告板块：
#   环境信息（系统/用户/版本/耗时/日志文件）
#   组件状态（版本 + 实际调用路径 + 期望安装路径）
#   安装明细（每步状态 + 方案 + 耗时；失败项含错误 ID/建议/详情）
#   下载明细（文件/来源镜像/大小/耗时/重试次数）
#   PATH 检查（User 级顺序 + 存在性 + 终端实际解析结果）
# 目标：不回传 logs 也能从报告直接定位绝大多数问题
# ============================================================

# 依次探测多个候选命令路径，返回第一个成功取到的版本号（避免 -or 返回布尔的陷阱）
function Get-FirstVersion {
    param([string[]]$Candidates, [string[]]$Arguments)
    foreach ($cmd in $Candidates) {
        if (-not $cmd) { continue }
        try {
            $v = Get-CommandVersion -Command $cmd -Arguments $Arguments
            if ($v) { return $v }
        } catch { }
    }
    return $null
}

# 取第一个能成功运行的候选命令的完整路径（Get-Command 的 Source）
function Get-FirstCommandPath {
    param([string[]]$Candidates)
    foreach ($cmd in $Candidates) {
        if (-not $cmd) { continue }
        try {
            $v = Get-CommandVersion -Command $cmd
            if ($v) { return $cmd }
        } catch { }
    }
    return $null
}

# 安全取组件安装目录（目录函数异常时返回空串，报告不崩）
function Get-SafeDir {
    param([scriptblock]$Getter)
    try { return ([string](& $Getter)) } catch { return '' }
}

# 探测各组件：版本 + 实际调用路径 + 期望安装路径（独立于步骤状态，直接实测）
# 路径全部用字符串拼接（目录为空时只得到无效路径，不抛异常——报告是最后防线）
function Get-ComponentVersions {
    $result = [ordered]@{}
    $nodeDir = Get-SafeDir { Get-NodeInstallDir }
    $gitDir = Get-SafeDir { Get-GitInstallDir }
    $pyDir = Get-SafeDir { Get-PythonInstallDir }
    $npmGlobal = Get-SafeDir { Get-NpmGlobalDir }

    $nodeExe = "$nodeDir\node.exe"
    $gitExe = "$gitDir\cmd\git.exe"
    $pyExe = "$pyDir\python.exe"
    $claudeShim = "$npmGlobal\claude.cmd"

    $result.Node    = Get-FirstVersion -Candidates @($nodeExe, 'node') -Arguments @('-v')
    $result.NodePath    = Get-FirstCommandPath -Candidates @($nodeExe, 'node')
    $result.NodeExpect  = $nodeExe

    $result.Git     = Get-FirstVersion -Candidates @($gitExe, 'git') -Arguments @('--version')
    $result.GitPath    = Get-FirstCommandPath -Candidates @($gitExe, 'git')
    $result.GitExpect  = $gitExe

    $result.Python  = Get-FirstVersion -Candidates @($pyExe, 'python') -Arguments @('--version')
    $result.PythonPath = Get-FirstCommandPath -Candidates @($pyExe, 'python')
    $result.PythonExpect = $pyExe

    $result.Claude    = Get-FirstVersion -Candidates @($claudeShim, 'claude') -Arguments @('--version')
    $result.ClaudePath   = Get-FirstCommandPath -Candidates @($claudeShim, 'claude')
    $result.ClaudeExpect = $claudeShim

    $vscodeDir = Get-SafeDir { Get-VscodeInstallDir }
    $codeExe = "$vscodeDir\Code.exe"
    $result.Vscode    = Get-FirstVersion -Candidates @($codeExe, 'code') -Arguments @('--version')
    $result.VscodePath   = Get-FirstCommandPath -Candidates @($codeExe, 'code')
    $result.VscodeExpect = $codeExe
    return $result
}

# 步骤入口：自检 + 写报告
# 返回值：$true 全部就绪；$false 有失败项（不抛异常，失败信息进报告）
function Invoke-StepVerify {
    param([string]$AppRoot)

    Write-Info '开始自检（实测各组件版本）……'
    $versions = Get-ComponentVersions

    $allOk = $true
    foreach ($name in @('Node', 'Git', 'Python', 'Claude', 'Vscode')) {
        $label = @{ Node = 'Node.js'; Git = 'Git'; Python = 'Python'; Claude = 'Claude Code'; Vscode = 'VS Code' }[$name]
        if ($versions[$name]) {
            Write-Ok ("{0}：{1}" -f $label, $versions[$name])
        } else {
            Write-Fail ("{0}：不可用" -f $label)
            $allOk = $false
        }
    }

    # 模型连接实测（#020）：有配置时真发一条请求，结果进报告
    $versions.ConnectionTest = (Get-ModelConnectionTestResult)

    New-InstallReport -AppRoot $AppRoot -Versions $versions
    return $allOk
}

# 读取已有配置并实测模型连接（无配置返回「未配置」描述）
function Get-ModelConnectionTestResult {
    try {
        $settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
        if (-not (Test-Path -LiteralPath $settingsFile)) { return '未配置（双击「重新配置APIKEY.bat」可补配）' }
        $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $env2 = $settings.env
        if (-not $env2 -or -not $env2.ANTHROPIC_AUTH_TOKEN -or -not $env2.ANTHROPIC_BASE_URL) {
            return '未配置（双击「重新配置APIKEY.bat」可补配）'
        }
        Write-Info '正在实测模型连接（发送 1 条测试请求）……'
        $r = Test-ProviderConnection -BaseUrl ([string]$env2.ANTHROPIC_BASE_URL) -ApiKey ([string]$env2.ANTHROPIC_AUTH_TOKEN) -Model ([string]$env2.ANTHROPIC_MODEL)
        if ($r.Ok) { return ("通过（{0}）" -f $r.Detail) }
        return ("失败：{0}" -f $r.Detail)
    } catch {
        return ("测试异常：{0}" -f $_.Exception.Message)
    }
}

# 生成《安装报告.txt》（UTF-8 BOM，记事本直接打开不乱码）
function New-InstallReport {
    param([string]$AppRoot, [hashtable]$Versions)

    $reportPath = Join-Path $AppRoot '安装报告.txt'
    $lines = New-Object System.Collections.ArrayList
    $versionTag = 'v1.1'
    if ($Script:InstallerVersionFull) { $versionTag = $Script:InstallerVersionFull }
    elseif ($Script:InstallerVersion) { $versionTag = ("v{0}" -f $Script:InstallerVersion) }

    # ---- 头部 ----
    [void]$lines.Add('==============================================')
    [void]$lines.Add(("        Claude Code 安装报告（{0}）" -f $versionTag))
    [void]$lines.Add(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$lines.Add('==============================================')
    [void]$lines.Add('')
    [void]$lines.Add('【遇到问题？把本文件和 logs 文件夹发给开发者】')
    [void]$lines.Add('  邮箱：cdingstar@outlook.com    微信：cdingstar')
    [void]$lines.Add('  （更简单：把安装器目录里的「问题反馈-安装日志-*.zip」发过去即可）')

    # ---- 环境信息 ----
    [void]$lines.Add('')
    [void]$lines.Add('【环境信息】')
    [void]$lines.Add(("  系统：{0}（64 位：{1}）" -f [Environment]::OSVersion.VersionString, [Environment]::Is64BitOperatingProcess))
    [void]$lines.Add(("  用户：{0}" -f $env:USERNAME))
    [void]$lines.Add(("  安装器目录：{0}" -f $AppRoot))
    if ($Script:InstallState.StartTime) {
        $elapsed = (Get-Date) - $Script:InstallState.StartTime
        [void]$lines.Add(("  本次开始：{0}  总耗时：{1} 分 {2} 秒" -f $Script:InstallState.StartTime.ToString('HH:mm:ss'), [int]$elapsed.TotalMinutes, [int]$elapsed.Seconds))
    }
    if ($Script:LogFile) {
        [void]$lines.Add(("  本次日志：{0}" -f $Script:LogFile))
    }

    # ---- 组件状态（版本 + 实际位置 + 期望位置）----
    [void]$lines.Add('')
    [void]$lines.Add('【组件状态】')
    $statusMap = @(
        @{ Key = 'Node';    Label = 'Node.js' },
        @{ Key = 'Git';     Label = 'Git' },
        @{ Key = 'Python';  Label = 'Python' },
        @{ Key = 'Claude';  Label = 'Claude Code' },
        @{ Key = 'Vscode';  Label = 'VS Code' }
    )
    foreach ($item in $statusMap) {
        $key = $item.Key
        if ($Versions[$key]) {
            [void]$lines.Add(("  [成功] {0}  {1}" -f $item.Label, $Versions[$key]))
            [void]$lines.Add(("         实际调用：{0}" -f $Versions[($key + 'Path')]))
        } else {
            $expectPath = [string]$Versions[($key + 'Expect')]
            $expectState = '信息缺失'
            if ($expectPath) {
                $expectState = $(if (Test-Path -LiteralPath $expectPath) { '文件存在但无法运行' } else { '文件不存在' })
            }
            [void]$lines.Add(("  [失败] {0}  不可用" -f $item.Label))
            [void]$lines.Add(("         期望位置：{0}（{1}）" -f $expectPath, $expectState))
        }
    }

    # ---- 安装明细（状态 + 方案 + 耗时 + 失败详情）----
    [void]$lines.Add('')
    [void]$lines.Add('【安装明细】')
    foreach ($r in $Script:InstallState.Results) {
        $statusText = switch ($r.Status) {
            'Success' { '成功' }
            'Skipped' { '跳过（已安装）' }
            'Blocked' { '未执行（前置失败）' }
            default   { '失败' }
        }
        $durationText = ''
        if ($r.Duration -ne '' -and $r.Duration -ne $null) { $durationText = ("  耗时 {0} 秒" -f $r.Duration) }
        [void]$lines.Add(("  [{0}] [{1}] 方案：{2}{3}" -f $r.Name, $statusText, $r.Plan, $durationText))
        if ($r.Status -eq 'Failed' -and $r.ErrorIds.Count -gt 0) {
            foreach ($errId in ($r.ErrorIds | Select-Object -Unique)) {
                $spec = Get-ErrorSpec -Id $errId
                [void]$lines.Add(("      - 错误 {0}：{1}" -f $errId, $spec.Summary))
                [void]$lines.Add(("        建议：{0}" -f $spec.Advice))
            }
            if ($r.LastError) {
                $clip = $r.LastError
                if ($clip.Length -gt 500) { $clip = $clip.Substring(0, 500) + '……' }
                [void]$lines.Add(("      - 失败详情（各方案）：{0}" -f $clip))
            }
        }
    }

    # ---- 下载明细 ----
    [void]$lines.Add('')
    if ($Script:DownloadRecords -and $Script:DownloadRecords.Count -gt 0) {
        [void]$lines.Add('【下载明细】')
        foreach ($d in $Script:DownloadRecords) {
            [void]$lines.Add(("  {0}" -f $d.File))
            [void]$lines.Add(("      来源：{0}  大小：{1}  耗时：{2} 秒  重试：{3} 次" -f $d.Source, $d.Size, $d.Seconds, $d.Retries))
        }
    } else {
        [void]$lines.Add('【下载明细】本次运行未下载任何文件（全部命中缓存/离线包/已安装跳过）')
    }

    # ---- PATH 检查 ----
    [void]$lines.Add('')
    [void]$lines.Add('【PATH 检查（User 级，按优先顺序）】')
    $userPathItems = @(Get-UserPathArray)
    if ($userPathItems.Count -eq 0) {
        [void]$lines.Add('  （User PATH 为空）')
    }
    $idx = 0
    foreach ($p in $userPathItems) {
        $idx++
        $mark = $(if (Test-Path -LiteralPath $p) { '[存在]' } else { '[不存在]' })
        $tag = ''
        if ($p -like '*\Programs\nodejs*') { $tag = ' ← Node.js' }
        elseif ($p -like '*\Programs\Git*') { $tag = ' ← Git' }
        elseif ($p -like '*\Python*') { $tag = ' ← Python' }
        elseif ($p -like '*\Roaming\npm') { $tag = ' ← Claude Code 命令' }
        [void]$lines.Add(("  {0}. {1} {2}{3}" -f $idx, $mark, $p, $tag))
    }
    # 终端实际解析到的 node（能发现旧版遮蔽问题）
    $nodeCmd = Get-Command -Name 'node' -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nodeV = Get-CommandVersion -Command $nodeCmd.Source -Arguments @('-v')
        [void]$lines.Add(("  终端实际解析 node → {0}（{1}）" -f $nodeCmd.Source, $nodeV))
    } else {
        [void]$lines.Add('  终端实际解析 node → 未找到（新开终端后才会生效，属正常）')
    }

    # ---- 特别注意（条件触发）----
    $pathNode = Get-CommandVersion -Command 'node' -Arguments @('-v')
    if ($pathNode -and ($pathNode -match 'v?(\d+)') -and ([int]$Matches[1] -lt 18)) {
        [void]$lines.Add('')
        [void]$lines.Add('【特别注意】')
        [void]$lines.Add(("  终端 PATH 里的 Node 是 {0}，低于 Claude Code 要求的 18。" -f $pathNode))
        [void]$lines.Add('  本安装器已把新版 Node 装到用户目录并尽量置于 PATH 优先位置；')
        [void]$lines.Add('  若新开终端 node -v 仍是旧版本，说明系统另有旧版 Node（常见于')
        [void]$lines.Add('  Program Files 或 nvm 目录），建议在「设置 → 应用」卸载旧版后重开终端，')
        [void]$lines.Add('  或手动把 %LOCALAPPDATA%\Programs\nodejs 提到环境变量 Path 最前面。')
    }

    # ---- 模型连接与扩展（#020）----
    [void]$lines.Add('')
    [void]$lines.Add('【模型连接实测】')
    [void]$lines.Add(("  {0}" -f $Versions.ConnectionTest))
    if ($Script:VscodeExtension) {
        [void]$lines.Add('【VS Code 扩展】')
        [void]$lines.Add(("  Claude Code 扩展：{0}" -f $Script:VscodeExtension))
    }

    # ---- 下一步 ----
    [void]$lines.Add('')
    $failedCount = @($Script:InstallState.Results | Where-Object { $_.Status -eq 'Failed' }).Count
    if ($failedCount -gt 0) {
        [void]$lines.Add('【下一步】')
        [void]$lines.Add('  1. 按上面每条错误 ID 的建议处理后，重新双击「双击安装ClaudeCode.bat」')
        [void]$lines.Add('     （已装好的组件会自动跳过，只补装失败的部分）')
        [void]$lines.Add('  2. 仍有问题请把「安装报告.txt」+ logs 文件夹整个发给技术支持，')
        [void]$lines.Add('     并注明出现的错误 ID（报告已含定位所需的路径与下载明细）')
    } else {
        [void]$lines.Add('【下一步】')
        [void]$lines.Add('  全部组件就绪！打开「开始菜单 → Windows PowerShell」（或 cmd），输入：')
        [void]$lines.Add('      claude')
        [void]$lines.Add('  即可开始使用（首次如未配置模型，请双击「重新配置APIKEY.bat」）')
    }
    [void]$lines.Add('')

    # UTF-8 with BOM 写入
    [System.IO.File]::WriteAllLines($reportPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Write-Ok ("安装报告已生成：{0}" -f $reportPath)

    # 一键反馈包（#022）：报告 + 全部日志打成一个 zip，小白直接发这一个文件即可
    New-FeedbackPackage -AppRoot $AppRoot
}

# 生成「问题反馈」zip（安装报告 + logs 全部日志），返回 zip 路径
function New-FeedbackPackage {
    param([string]$AppRoot)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zipName = ("问题反馈-安装日志-{0}.zip" -f $stamp)
    $zipPath = Join-Path $AppRoot $zipName
    try {
        $sources = @()
        $report = Join-Path $AppRoot '安装报告.txt'
        if (Test-Path -LiteralPath $report) { $sources += $report }
        $logDir = Join-Path $AppRoot 'logs'
        if (Test-Path -LiteralPath $logDir) { $sources += (Get-ChildItem -LiteralPath $logDir -Filter '*.log' | Select-Object -ExpandProperty FullName) }
        if ($sources.Count -eq 0) { return $null }
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path $sources -DestinationPath $zipPath -CompressionLevel Optimal
        Write-Ok ("已生成问题反馈包（遇到问题把它发给开发者即可）：{0}" -f $zipName)
        return $zipPath
    } catch {
        Write-Log -Message ("反馈包生成失败（不影响安装）：{0}" -f $_.Exception.Message) -Level 'WARN'
        return $null
    }
}

# 失败场景的帮助：弹出文件夹并选中反馈 zip + 预开邮件草稿（小白只需发一个文件）
function Show-FeedbackHelp {
    param([string]$AppRoot)

    $zip = Get-ChildItem -LiteralPath $AppRoot -Filter '问题反馈-安装日志-*.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $line = '=' * 54
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host '  遇到问题？把反馈包发给开发者：' -ForegroundColor White
    Write-Host '    邮箱：cdingstar@outlook.com' -ForegroundColor Yellow
    Write-Host '    微信：cdingstar' -ForegroundColor Yellow
    if ($zip) {
        Write-Host ("    反馈文件：{0}（已在安装器文件夹选中）" -f $zip.Name) -ForegroundColor Yellow
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList (@('/select,', $zip.FullName) -join '') } catch { }
    } else {
        Write-Host '    反馈文件：请把「安装报告.txt」和 logs 文件夹一起发送' -ForegroundColor Yellow
    }
    Write-Host $line -ForegroundColor Cyan
    # 预开邮件草稿（主题已带版本；正文需粘贴 zip 内容，用户也可直接发微信）
    try {
        $subject = [Uri]::EscapeDataString(("Claude Code 安装器问题反馈（{0}）" -f $Script:InstallerVersionFull))
        Start-Process ("mailto:cdingstar@outlook.com?subject={0}" -f $subject)
    } catch { }
}
