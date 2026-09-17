# ============================================================
# 进度动画模块（#020）—— 避免「长时间无输出被用户当成死机」
# 1. Wait-ProcessWithSpinner：等待进程退出期间显示 marquee 滚动条
#    （Write-Progress 不带 PercentComplete 时 PS5.1 自动显示滚动动画）
# 2. Invoke-ToolWithSpinner：运行外部工具（.cmd/.exe）+ 动画 + 超时 + 输出收集
#    —— 经 cmd /s /c 标准形式调用（引号一次写对，教训见 #013 的引号剥离）
# ============================================================

# 等待进程退出 + marquee 动画；超时杀进程返回 $false
function Wait-ProcessWithSpinner {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Activity,
        [int]$TimeoutSec = 600
    )
    $frames = @('|', '/', '-', '\')
    $i = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Process.WaitForExit(400)) {
        $frame = $frames[$i % $frames.Count]; $i++
        Write-Progress -Activity $Activity -Status ("{0}  已进行 {1} 秒，请稍候……" -f $frame, [int]$sw.Elapsed.TotalSeconds)
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            try { $Process.Kill() } catch { }
            Write-Progress -Activity $Activity -Completed -ErrorAction SilentlyContinue
            return $false
        }
    }
    Write-Progress -Activity $Activity -Completed -ErrorAction SilentlyContinue
    return $true
}

# 运行外部工具（支持 .cmd/.bat）：动画等待 + 异步收集输出 + 超时保护
# 返回值：@{ Ok = bool; ExitCode = int; Output = '合并输出' }
function Invoke-ToolWithSpinner {
    param(
        [string]$FilePath,          # 工具路径（.cmd/.exe 均可）
        [string[]]$Arguments,       # 参数数组（自动逐个加引号）
        [string]$Activity,          # 动画显示的中文说明
        [int]$TimeoutSec = 600
    )
    $quoted = @($Arguments | ForEach-Object { '"{0}"' -f $_ })
    # cmd /s /c "整条命令" —— /s 保留引号原样，是 cmd 的标准可靠形式
    $argLine = '/s /c "' + ('"{0}"' -f $FilePath) + ' ' + ($quoted -join ' ') + '"'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $outBuilder = New-Object System.Text.StringBuilder
    $errBuilder = New-Object System.Text.StringBuilder
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    # 异步读输出（防管道缓冲满导致子进程卡死）
    $outHandler = { if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
    $sub1 = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $outHandler -MessageData $outBuilder
    $sub2 = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action $outHandler -MessageData $errBuilder
    try {
        try {
            [void]$p.Start()
        } catch {
            return @{ Ok = $false; TimedOut = $false; ExitCode = -1; Output = ("进程启动失败：{0}" -f $_.Exception.Message) }
        }
        $p.BeginOutputReadLine()
        $p.BeginErrorReadLine()
        $notTimeout = Wait-ProcessWithSpinner -Process $p -Activity $Activity -TimeoutSec $TimeoutSec
        $p.WaitForExit()
        $output = ("{0}{1}" -f $outBuilder.ToString(), $errBuilder.ToString()).Trim()
        return @{
            Ok       = ($notTimeout -and $p.ExitCode -eq 0)
            TimedOut = (-not $notTimeout)
            ExitCode = $p.ExitCode
            Output   = $output
        }
    } finally {
        foreach ($s in @($sub1, $sub2)) {
            if ($s) { Unregister-Event -SourceIdentifier $s.Name -ErrorAction SilentlyContinue }
        }
    }
}
