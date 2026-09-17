# ============================================================
# 方案链执行器 —— 所有安装步骤的统一容错内核
# 职责：
#   1. 幂等预检：已装组件直接跳过
#   2. 方案链执行：A 失败自动切 B、C；单方案内 3 次指数退避重试
#   3. 错误分级：Fatal 终止全局 / Retry 退避重试 / Switch 换方案
#   4. 结果登记：供 step5 生成安装报告
# ============================================================

# 全局安装状态（步骤结果登记表）
$Script:InstallState = @{
    Results   = New-Object System.Collections.ArrayList
    StartTime = Get-Date
    Root      = ''
}

# 执行一个安装步骤
# 参数：
#   Id        步骤 ID（如 node/git/python/claude）
#   Name      中文名（报告显示用）
#   Precheck  幂等预检脚本块，返回 $true 表示已安装 → 跳过
#   Plans     方案数组，每项 @{ Name='方案名'; Action={...} }
# 返回值：$true 成功或跳过；$false 全部方案失败
function Invoke-InstallStep {
    param(
        [string]$Id,
        [string]$Name,
        [scriptblock]$Precheck,
        [hashtable[]]$Plans
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # ---- 幂等预检 ----
    if ($Precheck) {
        try {
            if (& $Precheck) {
                Write-Ok ("检测到 {0} 已安装，跳过" -f $Name)
                [void]$Script:InstallState.Results.Add((New-StepResult -Id $Id -Name $Name -Status 'Skipped' -Plan '已存在' -ErrorIds @()))
                return $true
            }
        } catch {
            Write-Log -Message ("预检异常（视为未安装继续）：{0}" -f $_.Exception.Message) -Level 'WARN'
        }
    }

    # ---- 方案链 ----
    $triedErrors = New-Object System.Collections.ArrayList
    $lastErrorDetail = ''
    foreach ($plan in $Plans) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if ($attempt -eq 1) {
                    Write-Info ("执行方案：{0}" -f $plan.Name)
                } else {
                    Write-Info ("执行方案：{0}（第 {1} 次尝试）" -f $plan.Name, $attempt)
                }
                # 方案内部输出一律吞掉，保证本函数只返回布尔结果
                & $plan.Action | Out-Null
                Write-Ok ("{0} 安装成功（方案：{1}）" -f $Name, $plan.Name)
                $sw.Stop()
                [void]$Script:InstallState.Results.Add((New-StepResult -Id $Id -Name $Name -Status 'Success' -Plan $plan.Name -ErrorIds @($triedErrors) -LastError $lastErrorDetail -Duration ([math]::Round($sw.Elapsed.TotalSeconds, 1))))
                return $true
            } catch {
                $errId = Resolve-ErrorId -Exception $_.Exception
                $detail = $_.Exception.Message
                # 收集所有方案/所有尝试的错误（报告用，不只留最后一个）
                if ($lastErrorDetail) { $lastErrorDetail += ' | ' }
                $lastErrorDetail += ("[{0}/{1}] {2}" -f $plan.Name, $errId, $detail)
                [void]$triedErrors.Add($errId)
                $spec = Get-ErrorSpec -Id $errId
                Write-Log -Message ("步骤 {0} 方案 {1} 第 {2} 次失败 [{3}]：{4}" -f $Id, $plan.Name, $attempt, $errId, $detail) -Level 'WARN'

                if ($spec.Level -eq 'Fatal') {
                    Show-ErrorBlock -Id $errId -Detail $detail
                    $sw.Stop()
                    [void]$Script:InstallState.Results.Add((New-StepResult -Id $Id -Name $Name -Status 'Failed' -Plan $plan.Name -ErrorIds @($triedErrors) -LastError $lastErrorDetail -Duration ([math]::Round($sw.Elapsed.TotalSeconds, 1))))
                    Throw-InstallError -Id $errId -Detail ("步骤「{0}」发生致命错误，安装终止" -f $Name)
                }
                if ($spec.Level -eq 'Switch' -or $attempt -ge 3) {
                    # 立即换方案（或重试次数用尽自动换）
                    Show-ErrorBlock -Id $errId -Detail $detail
                    break
                }
                # Retry 级：退避后同方案重试
                Show-ErrorBlock -Id $errId -Detail $detail
                $waitSec = [math]::Pow(2, $attempt)
                Write-Info ("{0} 秒后重试本方案……" -f $waitSec)
                Start-Sleep -Seconds $waitSec
            }
        }
        Write-Log -Message ("方案 {0} 放弃，切换下一方案" -f $plan.Name) -Level 'WARN'
    }

    # ---- 全部方案失败：登记但继续后续步骤 ----
    $failId = 'E-UNK-000'
    if ($triedErrors.Count -gt 0) { $failId = $triedErrors[$triedErrors.Count - 1] }
    Write-Fail ("{0} 所有方案均失败（最后错误：{1}）" -f $Name, $failId)
    $sw.Stop()
    [void]$Script:InstallState.Results.Add((New-StepResult -Id $Id -Name $Name -Status 'Failed' -Plan '全部失败' -ErrorIds @($triedErrors) -LastError $lastErrorDetail -Duration ([math]::Round($sw.Elapsed.TotalSeconds, 1))))
    return $false
}

# 构造单条步骤结果记录
function New-StepResult {
    param([string]$Id, [string]$Name, [string]$Status, [string]$Plan, [string[]]$ErrorIds, [string]$LastError = '')
    return @{
        Id         = $Id
        Name       = $Name
        Status     = $Status
        Plan       = $Plan
        ErrorIds   = @($ErrorIds | Select-Object -Unique)
        LastError  = $LastError
        Duration   = ''
    }
}

# 标记某步骤「因前置失败而跳过」（如 Node 没装上则不尝试 Claude Code）
function Register-SkippedDependency {
    param([string]$Id, [string]$Name, [string]$Reason)
    Write-WarnMsg ("跳过 {0}：{1}" -f $Name, $Reason)
    [void]$Script:InstallState.Results.Add((New-StepResult -Id $Id -Name $Name -Status 'Blocked' -Plan $Reason -ErrorIds @()))
    return $false
}

# 查询某步骤的最终状态（Success/Skipped/Blocked/Failed/不存在 $null）
function Get-StepStatus {
    param([string]$Id)
    $hit = $Script:InstallState.Results | Where-Object { $_.Id -eq $Id } | Select-Object -Last 1
    if ($hit) { return $hit.Status }
    return $null
}
