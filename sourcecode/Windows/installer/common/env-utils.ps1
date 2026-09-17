# ============================================================
# 环境变量工具 —— User 级 PATH 幂等写入 + 当前会话刷新 + 命令探测
# 要点：
#   1. 只操作 User 级 PATH，不碰 Machine 级（免管理员）
#   2. 写入后同步刷新当前会话 $env:Path，立即生效
# ============================================================

# 读取 User 级 PATH 并按分号拆分为数组（自动去空）
# 返回值：string[]
function Get-UserPathArray {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) { return @() }
    return $userPath.Split(';') | Where-Object { $_ -and $_.Trim() }
}

# 将目录加入 User 级 PATH（幂等 + 前插优先）
# 要点：
#   1. 新目录插到 User PATH 最前面：本安装器装的 Node 22 要优先于
#      系统里可能存在的旧版 Node（问题备案 #009，否则终端里 node -v 仍是旧版）
#   2. 已存在的条目先移除再前插，保证去重且优先级最高
function Add-UserPath {
    param([string[]]$Dirs)
    $existing = @(Get-UserPathArray | ForEach-Object { $_.TrimEnd('\') })
    $changed = $false
    $toPrepend = @()
    foreach ($dir in $Dirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $normalized = $dir.TrimEnd('\')
        $already = @($existing | Where-Object { $_.ToLowerInvariant() -eq $normalized.ToLowerInvariant() })
        if ($already.Count -gt 0) {
            # 已存在：移除旧位置，稍后前插
            $existing = @($existing | Where-Object { $_.ToLowerInvariant() -ne $normalized.ToLowerInvariant() })
        }
        $toPrepend += $normalized
        $changed = $true
        Write-Log -Message ("PATH 前插（User 级）：{0}" -f $normalized) -Level 'INFO'
    }
    if ($changed) {
        $newPath = (@($toPrepend) + @($existing)) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
}

# 用注册表中的最新值刷新当前会话 PATH（Machine + User），让刚装的命令立即可用
function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($machinePath, $userPath) | Where-Object { $_ }
    $env:Path = ($parts -join ';')
}

# 将目录从 User 级 PATH 移除（卸载/修复时用；忽略大小写前缀匹配）
function Remove-UserPath {
    param([string[]]$Dirs)
    $existing = @(Get-UserPathArray | ForEach-Object { $_.TrimEnd('\') })
    $changed = $false
    foreach ($dir in $Dirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $normalized = $dir.TrimEnd('\')
        $before = $existing.Count
        $existing = @($existing | Where-Object { $_.ToLowerInvariant() -ne $normalized.ToLowerInvariant() })
        if ($existing.Count -ne $before) {
            $changed = $true
            Write-Log -Message ("PATH 移除（User 级）：{0}" -f $normalized) -Level 'INFO'
        }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($existing -join ';'), 'User')
    }
}

# 探测命令是否可用（Get-Command 静默探测）
# 返回值：bool
function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

# 探测命令版本（如 node -v），成功返回版本字符串，失败返回 $null
# 注意：PS5.1 在 ErrorActionPreference=Stop 下，native 命令写 stderr 也会触发异常，
#       必须临时降为 Continue 再执行（否则命令探测会被误判失败）
function Get-CommandVersion {
    param([string]$Command, [string[]]$Arguments = @('--version'))
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Command @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            return ([string]($output | Select-Object -First 1))
        }
    } catch {
        Write-Log -Message ("版本探测异常（{0}）：{1}" -f $Command, $_.Exception.Message) -Level 'DEBUG'
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return $null
}
