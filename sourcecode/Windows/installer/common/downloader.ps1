# ============================================================
# 下载器 —— 多镜像 fallback + 断点续传 + SHA256 校验 + 离线包优先
# 入口：Invoke-DownloadFile
#   1. 先查本地 payload/ 离线包（存在且校验通过直接用，全程不联网）
#   2. 逐镜像尝试：单镜像 3 次指数退避（2s/4s/8s）
#   3. 大文件 .part 断点续传（HTTP Range）
#   4. 下载后校验大小与 SHA256（提供时）
#   5. 全部失败 → 抛 E-DL-001（Switch 级，由 runner 切换下一方案）
# ============================================================

# 下载临时目录（统一的安装包缓存位置）
function Get-PackageCacheDir {
    param([string]$AppRoot)
    $dir = Join-Path $AppRoot 'cache'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# 检查 payload 离线包：存在且校验通过则复制到目标位置并返回 $true
function Test-PayloadPackage {
    param([string]$PayloadDir, [string]$FileName, [string]$Sha256, [string]$OutFile)
    if (-not $PayloadDir) { return $false }
    $candidate = Join-Path $PayloadDir $FileName
    if (-not (Test-Path -LiteralPath $candidate)) { return $false }
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            Write-Log -Message ("离线包 {0} 校验失败，忽略并改为在线下载" -f $FileName) -Level 'WARN'
            return $false
        }
    }
    Copy-Item -LiteralPath $candidate -Destination $OutFile -Force
    return $true
}

# 单次流式下载（含断点续传逻辑），失败抛普通异常由外层处理
function Invoke-StreamDownload {
    param([string]$Url, [string]$OutFile, [string]$DisplayName)
    $partFile = "$OutFile.part"

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'Mozilla/5.0 (compatible; ClaudeCodeInstaller/1.0)'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 60000

    # 断点续传：存在 .part 则从其末尾继续
    $offset = [long]0
    if (Test-Path -LiteralPath $partFile) {
        $offset = (Get-Item -LiteralPath $partFile).Length
        if ($offset -gt 0) {
            [void]$request.AddRange($offset)
            Write-Log -Message ("检测到未完成分片 {0}KB，尝试续传" -f [math]::Round($offset / 1KB)) -Level 'INFO'
        }
    }

    try {
        $response = $request.GetResponse()
    } catch {
        # 服务器不支持 Range 或连接失败：若是续传请求被拒，删除分片从头再试一次
        if ($offset -gt 0 -and (Test-Path -LiteralPath $partFile)) {
            Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue
        }
        throw ("连接失败：{0}" -f $_.Exception.Message)
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -ne 200 -and $statusCode -ne 206) {
        $response.Close()
        throw ("HTTP {0}" -f $statusCode)
    }
    if ($statusCode -eq 200 -and $offset -gt 0) {
        # 服务器返回完整文件（不支持续传），从头写
        $offset = [long]0
    }

    $totalBytes = [long]$response.ContentLength + $offset
    $fileMode = [System.IO.FileMode]::Create
    if ($offset -gt 0) { $fileMode = [System.IO.FileMode]::Append }

    $fileStream = $null
    try {
        $netStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($partFile, $fileMode, [System.IO.FileAccess]::Write)
        $buffer = New-Object byte[] 65536
        $downloaded = $offset
        $lastTick = [System.Diagnostics.Stopwatch]::StartNew()
        $lastBytes = [long]$offset
        $speed = 0.0
        while (($read = $netStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($lastTick.ElapsedMilliseconds -ge 500) {
                $speed = ($downloaded - $lastBytes) / $lastTick.Elapsed.TotalSeconds
                $lastBytes = $downloaded
                $lastTick.Restart()
                if ($totalBytes -gt 0) {
                    $pct = [math]::Round($downloaded * 100 / $totalBytes)
                    Write-Progress -Activity ("正在下载 {0}" -f $DisplayName) -Status ("{0} / {1}（{2:N1} MB/s）" -f (Format-Size $downloaded), (Format-Size $totalBytes), ($speed / 1MB)) -PercentComplete $pct
                } else {
                    Write-Progress -Activity ("正在下载 {0}" -f $DisplayName) -Status (Format-Size $downloaded)
                }
            }
        }
        $fileStream.Close()
        $fileStream = $null
        if ($totalBytes -gt 0 -and $downloaded -ne $totalBytes) {
            Throw-InstallError -Id 'E-DL-003' -Detail ("下载不完整：{0}/{1} 字节（{2}）" -f $downloaded, $totalBytes, $Url)
        }
        Move-Item -LiteralPath $partFile -Destination $OutFile -Force
    } finally {
        if ($fileStream) { $fileStream.Close() }
        if ($response) { $response.Close() }
        Write-Progress -Activity ("正在下载 {0}" -f $DisplayName) -Completed -ErrorAction SilentlyContinue
    }
}

# 字节数格式化为人类可读（KB/MB/GB）
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

# 下载明细登记表（供安装报告输出：文件/来源/大小/耗时/重试次数）
$Script:DownloadRecords = New-Object System.Collections.ArrayList

# 登记一次下载结果（内部函数）
function Add-DownloadRecord {
    param([string]$File, [string]$Source, [string]$Size, [double]$Seconds, [int]$Retries)
    [void]$Script:DownloadRecords.Add((@{
        File    = $File
        Source  = $Source
        Size    = $Size
        Seconds = $Seconds
        Retries = $Retries
    }))
}

# 统一下载入口（所有安装步骤都用这个）
# 参数：
#   DisplayName 显示名（进度条用）
#   Urls        镜像 URL 数组（按优先级排序）
#   OutFile     保存的完整路径
#   Sha256      可选的期望哈希
#   PayloadDir  可选的离线包目录
function Invoke-DownloadFile {
    param(
        [string]$DisplayName,
        [string[]]$Urls,
        [string]$OutFile,
        [string]$Sha256 = '',
        [string]$PayloadDir = ''
    )
    $fileName = [System.IO.Path]::GetFileName($OutFile)
    $outDir = Split-Path -Parent $OutFile
    if ($outDir) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    # 入口防御（问题备案 #012）：过滤非法 URL（空/不以 http 开头——曾被数组
    # -f 陷阱变成单字符 'h'/'t'），并在日志留痕，全无效则直接报配置错误
    $validUrls = @($Urls | Where-Object { $_ -and ($_ -match '^https?://') })
    foreach ($bad in ($Urls | Where-Object { -not ($_ -and ($_ -match '^https?://')) })) {
        Write-Log -Message ("忽略非法 URL：[{0}]（长度 {1}）" -f $bad, ([string]$bad).Length) -Level 'WARN'
    }
    if ($validUrls.Count -eq 0) {
        Throw-InstallError -Id 'E-DL-004' -Detail ("所有下载地址均非法（传入 {0} 个），安装器配置有误" -f $Urls.Count)
    }
    $Urls = $validUrls

    # 1) 离线包优先（不联网）
    if ($PayloadDir -and (Test-PayloadPackage -PayloadDir $PayloadDir -FileName $fileName -Sha256 $Sha256 -OutFile $OutFile)) {
        Write-Ok ("使用本地离线包：{0}" -f $fileName)
        Add-DownloadRecord -File $fileName -Source '本地离线包 payload' -Size (Format-Size (Get-Item -LiteralPath $OutFile).Length) -Seconds 0 -Retries 0
        return $OutFile
    }

    # 2) 已存在且校验通过（上次运行下载成功过），直接复用
    if ((Test-Path -LiteralPath $OutFile) -and (Test-FileValid -File $OutFile -Sha256 $Sha256)) {
        Write-Info ("已有缓存文件，跳过下载：{0}" -f $fileName)
        Add-DownloadRecord -File $fileName -Source '缓存复用（上次已下载）' -Size (Format-Size (Get-Item -LiteralPath $OutFile).Length) -Seconds 0 -Retries 0
        return $OutFile
    }
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue

    # 3) 逐镜像 + 退避重试
    $lastError = ''
    $totalRetries = 0
    foreach ($url in $Urls) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Info ("下载：{0}（第 {1} 次尝试）" -f $url, $attempt)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Invoke-StreamDownload -Url $url -OutFile $OutFile -DisplayName $DisplayName
                if (-not (Test-FileValid -File $OutFile -Sha256 $Sha256)) {
                    Throw-InstallError -Id 'E-DL-002' -Detail ("文件校验失败：{0}" -f $fileName)
                }
                $sw.Stop()
                Write-Ok ("下载完成：{0}（{1}）" -f $fileName, (Format-Size (Get-Item -LiteralPath $OutFile).Length))
                Add-DownloadRecord -File $fileName -Source ("在线：{0}" -f $url) -Size (Format-Size (Get-Item -LiteralPath $OutFile).Length) -Seconds ([math]::Round($sw.Elapsed.TotalSeconds, 1)) -Retries $totalRetries
                return $OutFile
            } catch {
                $errId = Resolve-ErrorId -Exception $_.Exception
                $totalRetries++
                $lastError = ("{0} | {1}" -f $errId, $_.Exception.Message)
                Write-Log -Message ("下载失败 [{0}] 第 {1} 次：{2} → {3}" -f $errId, $attempt, $url, $_.Exception.Message) -Level 'WARN'
                if ($errId -eq 'E-DL-002') {
                    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath "$OutFile.part" -Force -ErrorAction SilentlyContinue
                }
                if ($attempt -lt 3) {
                    $waitSec = [math]::Pow(2, $attempt)
                    Write-Info ("{0} 秒后重试……" -f $waitSec)
                    Start-Sleep -Seconds $waitSec
                }
            }
        }
        Write-Log -Message ("镜像 {0} 连续 3 次失败，切换下一镜像" -f $url) -Level 'WARN'
    }
    Throw-InstallError -Id 'E-DL-001' -Detail ("所有镜像均下载失败：{0}（尝试镜像 {1} 个，共重试 {2} 次；最后错误：{3}）" -f $DisplayName, $Urls.Count, $totalRetries, $lastError)
}

# 校验文件：存在、非空、（可选）SHA256 匹配
function Test-FileValid {
    param([string]$File, [string]$Sha256 = '')
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $item = Get-Item -LiteralPath $File
    if ($item.Length -le 0) { return $false }
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpperInvariant()) { return $false }
    }
    return $true
}
