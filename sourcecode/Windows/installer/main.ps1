# ============================================================
# Claude Code 一键安装器 —— 主流程编排
# 阶段：自举 → 模块加载（带保护）→ 启动自检 → 预检 →
#      Node → Git → Python → Claude Code → 配置弹窗 → 自检报告
# 特性：全程国内镜像 / 免管理员 / 每步幂等可续装 /
#      方案链容错（A/B/C 自动切换）+ 错误 ID 体系
# 入口：双击安装ClaudeCode.bat → powershell -File 本文件
# 高级：powershell -File main.ps1 -CheckOnly  仅做模块自检后退出
#       （不执行任何安装动作，用于快速验证安装包完整性）
# ============================================================

param(
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
# 注意：不能设置 $ProgressPreference='SilentlyContinue'，否则下载进度条不显示
# （下载走自实现 HttpWebRequest 流式读取，不受该偏好拖慢）

# ---- 0. 自举：编码、TLS、路径 ----
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$Script:AppRoot = Split-Path -Parent $PSScriptRoot   # 安装器根目录（bat 所在目录）

# ---- 安装器版本号 ----
# 版本规则：每次修改发布，小版本 +1（如 1.11 → 1.12），统一维护在 sourcecode/VERSION；
# 打包时 build.sh 生成包内 VERSION 文件（完整格式 v1.12(20260917)，日期=打包日）。
# 读取顺序：包内 VERSION → 源码目录上级 VERSION（仅数字，开发态）→ 内置兜底。
$Script:InstallerVersion = '1.15'   # 纯数字版本（PATH 标记等内部用途），兜底值
$Script:InstallerVersionFull = $null
$_verFile = Join-Path $Script:AppRoot 'VERSION'
if (-not (Test-Path -LiteralPath $_verFile)) { $_verFile = Join-Path $Script:AppRoot '..\VERSION' }
if (Test-Path -LiteralPath $_verFile) {
    try {
        $_rawVer = (Get-Content -LiteralPath $_verFile -TotalCount 1).Trim()
        if ($_rawVer) {
            $Script:InstallerVersion = ($_rawVer -replace '^v', '' -replace '\(.*$', '')
            if ($_rawVer -match '\(') { $Script:InstallerVersionFull = $_rawVer }
        }
    } catch { }
}
if (-not $Script:InstallerVersionFull) { $Script:InstallerVersionFull = 'v' + $Script:InstallerVersion }

# ---- 1. 模块加载（全部纳入保护：任何文件加载失败立即给出中文定位，不裸崩）----
# 顺序敏感：logger 最先（后续模块的函数体依赖它），errors 次之
$commonDir = Join-Path $PSScriptRoot 'common'
$stepsDir = Join-Path $PSScriptRoot 'steps'
$configDir = Join-Path $PSScriptRoot 'config'
$moduleFiles = @(
    (Join-Path $commonDir 'logger.ps1'),
    (Join-Path $commonDir 'errors.ps1'),
    (Join-Path $commonDir 'runner.ps1'),
    (Join-Path $commonDir 'downloader.ps1'),
    (Join-Path $commonDir 'spinner.ps1'),
    (Join-Path $commonDir 'env-utils.ps1'),
    (Join-Path $commonDir 'sys-check.ps1'),
    (Join-Path $stepsDir 'step1-node.ps1'),
    (Join-Path $stepsDir 'step2-git.ps1'),
    (Join-Path $stepsDir 'step3-python.ps1'),
    (Join-Path $stepsDir 'step4-claude.ps1'),
    (Join-Path $stepsDir 'step6-vscode.ps1'),
    (Join-Path $stepsDir 'step5-verify.ps1'),
    (Join-Path $configDir 'providers.ps1'),
    (Join-Path $configDir 'config-dialog.ps1'),
    (Join-Path $configDir 'apply-config.ps1')
)
foreach ($module in $moduleFiles) {
    if (-not (Test-Path -LiteralPath $module)) {
        Write-Host ''
        Write-Host ('======================================================') -ForegroundColor Red
        Write-Host ('  [致命 E-SYS-004] 安装器文件缺失') -ForegroundColor Red
        Write-Host ('======================================================') -ForegroundColor Red
        Write-Host ('  缺少文件：{0}' -f $module) -ForegroundColor Yellow
        Write-Host ('  安装包不完整或被杀毒软件删除了部分文件。') -ForegroundColor Yellow
        Write-Host ('  请重新解压原 zip（或把本文件夹加入杀毒软件白名单后重试）。') -ForegroundColor Yellow
        exit 2
    }
    try {
        . $module
    } catch {
        Write-Host ''
        Write-Host ('======================================================') -ForegroundColor Red
        Write-Host ('  [致命 E-SYS-004] 安装器组件加载失败') -ForegroundColor Red
        Write-Host ('======================================================') -ForegroundColor Red
        Write-Host ('  文件：{0}' -f $module) -ForegroundColor Yellow
        Write-Host ('  原因：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('  请重新解压原 zip 后重试；仍失败请把本窗口截图发给技术支持。') -ForegroundColor Yellow
        exit 2
    }
}

$exitCode = 0
try {
    # 日志先行（E-SYS-004 等启动期错误也要进日志文件）
    Initialize-Logger -LogDir (Join-Path $Script:AppRoot 'logs') | Out-Null

    # ---- 2. 启动自检（防「加载顺序/未定义引用」类问题，见 问题备案.md）----
    # 校验所有关键函数与状态变量确实就位，任何缺失立即以错误 ID 暴露
    Start-PreflightCheck

    # ---- 3. -CheckOnly 干跑模式：验证安装包完整性后退出 ----
    if ($CheckOnly) {
        Write-Banner '安装器自检（-CheckOnly 模式，不执行安装）'
        Write-Ok '全部 16 个模块加载成功，关键函数与状态变量就位'
        Write-Ok ('安装器目录：{0}' -f $Script:AppRoot)
        Write-Info '自检通过。正式安装请双击「双击安装ClaudeCode.bat」'
        exit 0
    }

    # ---- 4. 开场 ----
    Write-Banner ("Claude Code 一键安装器 {0}（全程国内镜像 · 免管理员）" -f $Script:InstallerVersionFull)
    Write-Info ("安装器目录：{0}" -f $Script:AppRoot)
    Write-Info ("日志文件：{0}" -f $Script:LogFile)
    Write-Info '中途断网或失败都没关系：重新双击安装器会自动续装'

    # 微信/QQ 接收目录内直接运行容易文件被占用，提醒但不阻塞
    Test-ImFolderHint -AppRoot $Script:AppRoot

    if (Test-IsAdministrator) {
        Write-WarnMsg '当前以管理员身份运行（非必需）。若遇到权限异常，可用普通账户直接双击运行'
    }

    # ---- 5. 系统预检（Fatal 直接终止） ----
    Write-StepHeader -Index 1 -Total 8 -Name '系统环境检查'
    Test-SystemRequirements
    Wait-ForNetwork -MaxWaitMinutes 10

    # ---- 6. 安装四个组件（方案链 + 幂等） ----
    Write-StepHeader -Index 2 -Total 8 -Name '安装 Node.js 22（运行环境）'
    $nodeOk = Invoke-StepNode -AppRoot $Script:AppRoot

    Write-StepHeader -Index 3 -Total 8 -Name '安装 Git for Windows（依赖的 Bash 环境）'
    $gitOk = Invoke-StepGit -AppRoot $Script:AppRoot

    Write-StepHeader -Index 4 -Total 8 -Name '安装 Python 3.12（含 pip 国内源）'
    $pyOk = Invoke-StepPython -AppRoot $Script:AppRoot

    Write-StepHeader -Index 5 -Total 8 -Name '安装 Claude Code 本体'
    if ($nodeOk) {
        $claudeOk = Invoke-StepClaudeCode -AppRoot $Script:AppRoot
    } else {
        $claudeOk = Register-SkippedDependency -Id 'claude' -Name 'Claude Code' -Reason 'Node.js 未安装成功（修复 Node 后重跑安装器即可）'
    }

    # ---- 7. 模型配置弹窗 ----
    Write-StepHeader -Index 6 -Total 8 -Name '配置大模型（API Key）'
    if ($claudeOk -or ((Get-StepStatus -Id 'claude') -eq 'Skipped')) {
        # 先验证已有配置（#017）：Key 已存在且可用时不再静默跳过（#026），
        # 而是提示用户选择「保留现有」或「重新配置」
        $keepExisting = $false
        if (Test-ExistingConfig) {
            $keepExisting = Confirm-KeepExistingConfig
            if ($keepExisting) { $configStepNote = '跳过（已有配置验证通过，用户选择保留）' }
        }
        if (-not $keepExisting) {
            Write-Info '即将弹出配置窗口：选择供应商 → 粘贴 API Key → 保存（保存时自动测试）'
            Write-Info '（还没有 Key 可点「暂时跳过」，日后双击「重新配置APIKEY.bat」再配）'
            $config = Invoke-ConfigDialog
            if ($config -and -not $config.Skipped) {
                if ($config.Reset) {
                    # 「恢复官方默认」（#024）：清除第三方配置，回到官方模型/登录
                    Invoke-ResetConfig
                    $configStepNote = '成功（已恢复官方默认）'
                } else {
                    Invoke-ApplyConfig -Config $config -AppRoot $Script:AppRoot
                    $configStepNote = '成功（新配置）'
                }
            } else {
                Write-Info '已跳过模型配置；已生成「重新配置APIKEY.bat」，需要时双击它'
                New-ReconfigBat -AppRoot $Script:AppRoot
                $configStepNote = '跳过（用户选择）'
            }
        }
    } else {
        Register-SkippedDependency -Id 'config' -Name '模型配置' -Reason 'Claude Code 未安装成功'
    }

    # ---- 8. 安装 VS Code（配置完 Key 之后，作为编辑器配套） ----
    Write-StepHeader -Index 7 -Total 8 -Name '安装 VS Code（代码编辑器）'
    $vscodeOk = Invoke-StepVscode -AppRoot $Script:AppRoot

    # ---- 9. 自检 + 报告 ----
    Write-StepHeader -Index 8 -Total 8 -Name '自检并生成安装报告'
    $verifyOk = Invoke-StepVerify -AppRoot $Script:AppRoot

    # ---- 9. 收尾提示 ----
    $failed = @($Script:InstallState.Results | Where-Object { $_.Status -eq 'Failed' })
    Write-Banner '安装结束'
    if ($failed.Count -eq 0 -and $verifyOk) {
        Write-Ok '全部组件就绪，安装完成！'
        Write-Host ''
        Write-Host '  如何开始使用：' -ForegroundColor White
        Write-Host '  1. 打开「开始菜单」→ 输入 powershell → 回车' -ForegroundColor Gray
        Write-Host '  2. 输入 claude 回车，即可开始对话' -ForegroundColor Gray
        Write-Host '  3. Claude 会用中文回复（已自动配置）' -ForegroundColor Gray
        Write-Host '  4. 已装好 VS Code 编辑器：开始菜单搜 VS Code 打开' -ForegroundColor Gray
        Write-Host ''
        Write-Info '首次使用建议：在想要开发的项目文件夹里按住 Shift + 右键 →「在此处打开 PowerShell」再运行 claude'
        Write-Host ''
        Write-Host '  以后遇到任何问题：把安装器文件夹里的「问题反馈-安装日志-*.zip」' -ForegroundColor DarkGray
        Write-Host '  发给开发者即可 —— 邮箱 cdingstar@outlook.com / 微信 cdingstar' -ForegroundColor DarkGray
    } else {
        Write-WarnMsg ("有 {0} 个组件未完成，详见「安装报告.txt」" -f $failed.Count)
        Write-Host ''
        Write-Host '  按错误 ID 的建议处理后，重新双击「双击安装ClaudeCode.bat」即可续装' -ForegroundColor Yellow
        Write-Host '  （已装好的组件会自动跳过，不会重复安装）' -ForegroundColor Gray
        # 一键反馈帮助（醒目联系方式 + 定位反馈包 + 预开邮件草稿）
        Show-FeedbackHelp -AppRoot $Script:AppRoot
        $exitCode = 1
    }
} catch {
    # 全局兜底：Fatal 错误或未预期异常
    $errId = Resolve-ErrorId -Exception $_.Exception
    Show-ErrorBlock -Id $errId -Detail $_.Exception.Message
    Write-Fail '安装已终止。修复上述问题后重新双击「双击安装ClaudeCode.bat」续装'
    Write-Log -Message ("全局异常：{0}" -f $_.Exception.ToString()) -Level 'FATAL'
    # 已完成的步骤也要出报告（仅当 verify 已可用，即模块加载完成后的异常）
    if (Get-Command Invoke-StepVerify -ErrorAction SilentlyContinue) {
        try { Invoke-StepVerify -AppRoot $Script:AppRoot | Out-Null } catch { }
        try { Show-FeedbackHelp -AppRoot $Script:AppRoot } catch { }
    }
    $exitCode = 2
} finally {
    if ($Script:LogFile) {
        Write-Log -Message ("安装结束，退出码 {0}" -f $exitCode) -Level 'DONE'
    }
}
exit $exitCode
