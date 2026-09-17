# ============================================================
# 配置写入 —— 把用户在弹窗里选的供应商/Key/模型写入 Claude Code
# 写入目标（全部合并不覆盖，保留用户已有配置）：
#   1. ~\.claude\settings.json  的 env 段（第三方端点 + 模型映射）
#   2. ~\.claude.json           的 hasCompletedOnboarding（跳过官方登录）
#   3. ~\.claude\CLAUDE.md      「始终使用中文回复」全局指令（中文版核心）
#   4. 安装器目录下生成重配入口（支持「重新配置APIKEY.bat」单独启动）
# ============================================================

# 应用配置总入口；Config 来自 Invoke-ConfigDialog 的返回值
function Invoke-ApplyConfig {
    param([hashtable]$Config, [string]$AppRoot)

    $home2 = $env:USERPROFILE
    $claudeDir = Join-Path $home2 '.claude'

    try {
        New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null

        $prov = Get-Provider -Name $Config.Provider
        $model = $Config.Model
        $fastModel = $model
        if ($prov -and $prov.FastModel) { $fastModel = $prov.FastModel }

        # ---- 1. settings.json 的 env 段 ----
        $envMap = [ordered]@{
            'ANTHROPIC_AUTH_TOKEN'             = $Config.ApiKey
            'ANTHROPIC_BASE_URL'               = $Config.BaseUrl
            'ANTHROPIC_MODEL'                  = $model
            'ANTHROPIC_DEFAULT_OPUS_MODEL'     = $model
            'ANTHROPIC_DEFAULT_SONNET_MODEL'   = $model
            'ANTHROPIC_DEFAULT_HAIKU_MODEL'    = $fastModel
            'CLAUDE_CODE_SUBAGENT_MODEL'       = $fastModel
        }
        # 供应商附加项（如 GLM 的超时/流量开关）
        if ($prov) {
            foreach ($k in $prov.ExtraEnv.Keys) { $envMap[$k] = $prov.ExtraEnv[$k] }
        }
        # 1M 上下文模型的自动压缩窗口（注意：不能用 -like '*[1m]'，方括号是通配符字符集语法）
        if ($model -and $model.Contains('[1m]')) {
            $envMap['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] = '1000000'
        }

        Write-ClaudeSettings -ClaudeDir $claudeDir -EnvMap $envMap

        # ---- 2. 跳过官方登录 ----
        Write-OnboardingFlag -HomeDir $home2

        # ---- 3. 中文指令 ----
        Write-ChineseInstruction -ClaudeDir $claudeDir

        Write-Ok ("已配置模型供应商：{0}（模型：{1}）" -f $Config.Provider, $model)
    } catch {
        Show-ErrorBlock -Id 'E-CFG-001' -Detail $_.Exception.Message
    }

    # ---- 4. 生成重配入口（无论成功失败都生成，供日后重配） ----
    New-ReconfigBat -AppRoot $AppRoot
}

# ============================================================
# 恢复官方默认（#024）—— 配置弹窗「恢复官方默认」按钮调起
# 作用：清除第三方供应商配置，回到 Claude Code 官方模型与官方登录
#   1. settings.json 备份为 .bak 后，从 env 段删除第三方相关变量
#      （固定 8 个映射键 + 各供应商 ExtraEnv 键，动态收集防遗漏）
#   2. ~/.claude.json 删除 hasCompletedOnboarding，让官方登录引导重新出现
# ============================================================
function Invoke-ResetConfig {
    $home2 = $env:USERPROFILE
    try {
        # 待清除键集合：固定的模型映射 8 键 + 所有供应商的附加键
        # （CLAUDE_CODE_MAX_CONTEXT_TOKENS 原为通义千问附加键，v1.14 移除该供应商后
        #   改入固定清单——已配通义的老用户执行恢复官方时仍能被清除）
        $resetKeys = @(
            'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_MODEL',
            'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
            'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW',
            'CLAUDE_CODE_MAX_CONTEXT_TOKENS'
        )
        foreach ($name in Get-ProviderNames) {
            $prov = Get-Provider -Name $name
            if ($prov -and $prov.ExtraEnv) { $resetKeys += @($prov.ExtraEnv.Keys) }
        }

        # ---- 1. settings.json：备份后删除第三方 env 变量 ----
        $settingsFile = Join-Path $home2 '.claude\settings.json'
        if (Test-Path -LiteralPath $settingsFile) {
            $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings -and $settings.PSObject.Properties['env']) {
                Copy-Item -LiteralPath $settingsFile -Destination "$settingsFile.bak" -Force
                foreach ($k in $resetKeys) {
                    if ($settings.env.PSObject.Properties[$k]) {
                        $settings.env.PSObject.Properties.Remove($k)
                    }
                }
                if (@($settings.env.PSObject.Properties).Count -eq 0) {
                    $settings.PSObject.Properties.Remove('env')
                }
                $json = $settings | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($settingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
                Write-Log -Message '已清除第三方配置（备份：settings.json.bak）' -Level 'INFO'
            } else {
                Write-Log -Message 'settings.json 无第三方 env 配置，无需清除' -Level 'INFO'
            }
        } else {
            Write-Log -Message 'settings.json 不存在，无需清除' -Level 'INFO'
        }

        # ---- 2. 恢复官方登录引导（删除 hasCompletedOnboarding）----
        $onboardFile = Join-Path $home2 '.claude.json'
        if (Test-Path -LiteralPath $onboardFile) {
            $obj = $null
            try { $obj = Get-Content -LiteralPath $onboardFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $obj = $null }
            if ($obj -and $obj.PSObject.Properties['hasCompletedOnboarding']) {
                Copy-Item -LiteralPath $onboardFile -Destination "$onboardFile.bak" -Force
                $obj.PSObject.Properties.Remove('hasCompletedOnboarding')
                $json = $obj | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($onboardFile, $json, (New-Object System.Text.UTF8Encoding($false)))
                Write-Log -Message '已恢复官方登录引导（hasCompletedOnboarding 已删除）' -Level 'INFO'
            }
        }

        Write-Ok '已恢复官方默认模型（Claude 官方）。运行 claude 后按提示登录官方账号即可'
    } catch {
        Show-ErrorBlock -Id 'E-CFG-002' -Detail $_.Exception.Message
    }
}


# 合并写入 settings.json（保留用户已有字段）
function Write-ClaudeSettings {
    param([string]$ClaudeDir, [hashtable]$EnvMap)

    $settingsFile = Join-Path $ClaudeDir 'settings.json'
    $settings = $null
    if (Test-Path -LiteralPath $settingsFile) {
        try {
            $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-WarnMsg '现有 settings.json 解析失败，将备份后重建'
            Copy-Item -LiteralPath $settingsFile -Destination "$settingsFile.bak" -Force
            $settings = $null
        }
    }
    if (-not $settings) { $settings = New-Object PSObject }

    # 确保 env 存在并合并（旧值被新供应商覆盖，其余保留）
    if (-not $settings.PSObject.Properties['env']) {
        $settings | Add-Member -MemberType NoteProperty -Name 'env' -Value (New-Object PSObject)
    }
    foreach ($k in $EnvMap.Keys) {
        $value = [string]$EnvMap[$k]
        if ($settings.env.PSObject.Properties[$k]) {
            $settings.env.$k = $value
        } else {
            $settings.env | Add-Member -MemberType NoteProperty -Name $k -Value $value
        }
    }

    # PS5.1 的 ConvertTo-Json 深度默认 2，这里显式给足
    $json = $settings | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($settingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log -Message ("settings.json 已写入（{0} 个环境变量）" -f $EnvMap.Count) -Level 'INFO'
}

# 合并写入 ~/.claude.json 的 hasCompletedOnboarding
# 注意：参数不可命名为 $Home（PowerShell 只读保留变量，赋值即报错）
function Write-OnboardingFlag {
    param([string]$HomeDir)
    $file = Join-Path $HomeDir '.claude.json'
    $obj = $null
    if (Test-Path -LiteralPath $file) {
        try { $obj = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $obj = $null }
    }
    if (-not $obj) { $obj = New-Object PSObject }
    if ($obj.PSObject.Properties['hasCompletedOnboarding']) {
        $obj.hasCompletedOnboarding = $true
    } else {
        $obj | Add-Member -MemberType NoteProperty -Name 'hasCompletedOnboarding' -Value $true
    }
    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# 写全局中文指令（已有则不覆盖）
function Write-ChineseInstruction {
    param([string]$ClaudeDir)
    $file = Join-Path $ClaudeDir 'CLAUDE.md'
    if (Test-Path -LiteralPath $file) {
        Write-Log -Message '全局 CLAUDE.md 已存在，保留用户内容' -Level 'INFO'
        return
    }
    $content = "# 全局配置`r`n`r`n## 语言`r`n`r`n- 始终使用中文回复，包括代码注释和 commit message`r`n"
    [System.IO.File]::WriteAllText($file, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok '已启用中文回复（全局指令）'
}

# 生成重配入口：日后想换供应商/Key 时双击它单独重配
# 兼容保留旧名「配置模型.bat」，同时新增更直白的新入口「重新配置APIKEY.bat」
function New-ReconfigBat {
    param([string]$AppRoot)
    $content = @(
        '@echo off',
        'title Claude Code API Key Config',
        'cd /d "%~dp0"',
        'powershell -NoProfile -ExecutionPolicy Bypass -File "installer\reconfig.ps1"',
        'pause'
    ) -join "`r`n"
    $launcherFiles = @(
        (Join-Path $AppRoot '重新配置APIKEY.bat'),
        (Join-Path $AppRoot '配置模型.bat')
    )
    foreach ($batPath in $launcherFiles) {
        [System.IO.File]::WriteAllText($batPath, $content, (New-Object System.Text.ASCIIEncoding))
    }
    Write-Ok '已生成「重新配置APIKEY.bat」和兼容入口「配置模型.bat」'
}
