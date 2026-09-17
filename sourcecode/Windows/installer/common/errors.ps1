# ============================================================
# 错误码表 —— 全安装器唯一的错误定义处
# 约定：ID 格式 E-组件-序号；Level 三级：
#   Fatal  致命，终止整个安装
#   Retry  同一方案内退避重试
#   Switch 立即切换下一套方案/镜像
# 用户报错时只需提供错误 ID。
# ============================================================

$Script:InstallErrors = @{
    'E-SYS-001'  = @{ Level = 'Fatal';   Summary = 'Windows 版本过低';                      Advice = '本安装器需要 Windows 10（64 位）或更高版本，无法继续。' }
    'E-SYS-002'  = @{ Level = 'Fatal';   Summary = '磁盘空间不足';                          Advice = '安装至少需要 2GB 可用空间，请清理 C 盘后重新双击安装器。' }
    'E-SYS-003'  = @{ Level = 'Fatal';   Summary = '系统架构不支持';                        Advice = '本安装器仅支持 64 位 Windows 系统。' }
    'E-SYS-004'  = @{ Level = 'Fatal';   Summary = '安装器组件缺失或加载失败';              Advice = '安装包不完整或被杀毒软件删除了部分文件。请重新解压原 zip（或先把本文件夹加入杀毒软件白名单）后重试；仍失败请把窗口截图发给技术支持。' }
    'E-NET-001'  = @{ Level = 'Fatal';   Summary = '无法连接任何国内镜像站';                Advice = '请检查网络连接、代理或防火墙设置，恢复网络后重新双击安装器（会自动续装）。' }
    'E-DL-001'   = @{ Level = 'Switch';  Summary = '文件下载失败';                          Advice = '即将自动切换备用镜像或安装方案。' }
    'E-DL-002'   = @{ Level = 'Switch';  Summary = '下载文件校验失败（文件损坏）';          Advice = '已删除损坏文件，即将换镜像重新下载。' }
    'E-DL-003'   = @{ Level = 'Switch';  Summary = '下载内容不完整';                        Advice = '即将自动重试或切换镜像。' }
    'E-DL-004'   = @{ Level = 'Fatal';   Summary = '下载地址配置非法';                      Advice = '安装器内部错误，请把「安装报告.txt」发给技术支持（这是安装程序缺陷，不是您的操作问题）。' }
    'E-AV-001'   = @{ Level = 'Retry';   Summary = '文件疑似被杀毒软件删除或锁定';          Advice = '请打开杀毒软件（如 360/火绒/Windows Defender），将本安装器目录和 C:\Users\你的用户名\AppData\Local\Programs 加入信任区/白名单，安装器会自动重试。' }
    'E-NODE-001' = @{ Level = 'Switch';  Summary = 'Node.js 压缩包解压失败';                Advice = '即将自动更换镜像重新下载并解压。' }
    'E-NODE-002' = @{ Level = 'Switch';  Summary = 'Node.js 安装后无法运行';                Advice = '即将自动更换安装方案重试。' }
    'E-GIT-001'  = @{ Level = 'Switch';  Summary = 'Git 解压失败';                          Advice = '即将自动更换镜像重新下载。' }
    'E-GIT-002'  = @{ Level = 'Switch';  Summary = 'Git 初始化失败（post-install 异常）';   Advice = '即将自动更换安装方案重试。' }
    'E-GIT-003'  = @{ Level = 'Switch';  Summary = 'Git 安装后无法运行';                    Advice = '即将自动更换安装方案重试。' }
    'E-PY-001'   = @{ Level = 'Switch';  Summary = 'Python 静默安装失败';                   Advice = '即将自动更换镜像重新下载安装。' }
    'E-PY-002'   = @{ Level = 'Switch';  Summary = 'Python 安装后无法运行';                 Advice = '即将自动更换安装方案重试。' }
    'E-NPM-001'  = @{ Level = 'Switch';  Summary = 'npm 配置或执行失败';                    Advice = '即将自动更换 npm 镜像源重试。' }
    'E-CC-001'   = @{ Level = 'Switch';  Summary = 'npm 安装 Claude Code 失败';             Advice = '即将自动切换 npm 镜像源或改用手动安装方案。' }
    'E-CC-002'   = @{ Level = 'Switch';  Summary = 'Claude Code 安装后无法运行';            Advice = '即将自动更换安装方案重试。' }
    'E-CC-003'   = @{ Level = 'Switch';  Summary = '获取 Claude Code 安装包信息失败';       Advice = '即将自动更换镜像重试。' }
    'E-VSC-001'  = @{ Level = 'Switch';  Summary = 'VS Code 静默安装失败';                  Advice = '即将自动换 zip 免安装方案重试。' }
    'E-VSC-002'  = @{ Level = 'Switch';  Summary = 'VS Code 解压失败';                      Advice = '即将自动更换方案重试。' }
    'E-VSC-003'  = @{ Level = 'Switch';  Summary = 'VS Code 安装后无法运行';                Advice = '即将自动更换方案重试。' }
    'E-CFG-001'  = @{ Level = 'Retry';   Summary = 'Claude Code 配置文件写入失败';          Advice = '请确认 C 盘可写、未被杀毒软件拦截；安装器已生成「重新配置APIKEY.bat」，可稍后单独运行完成配置。' }
    'E-CFG-002'  = @{ Level = 'Retry';   Summary = '恢复官方默认时配置文件处理失败';        Advice = '原配置已自动备份（settings.json.bak / .claude.json.bak）；请重试，仍失败请把 logs 目录日志发给技术支持。' }
    'E-UNK-000'  = @{ Level = 'Retry';   Summary = '未知错误';                              Advice = '请将 logs 目录中的日志发给技术支持。' }
}

# 根据错误 ID 取定义；未知 ID 返回兜底项
# 返回值：hashtable（Level/Summary/Advice）
function Get-ErrorSpec {
    param([string]$Id)
    if ($Script:InstallErrors.ContainsKey($Id)) {
        return $Script:InstallErrors[$Id]
    }
    return $Script:InstallErrors['E-UNK-000']
}

# 从异常消息中解析错误 ID（协议：消息内含 [E-XXX-NNN]）
# 返回值：错误 ID 字符串，解析不到返回 'E-UNK-000'
function Resolve-ErrorId {
    param($Exception)
    $message = ''
    if ($Exception) { $message = $Exception.ToString() }
    if ($message -match '\[(E-[A-Z]+-\d+)\]') { return $Matches[1] }
    return 'E-UNK-000'
}

# 抛出带错误 ID 的安装异常（供各步骤主动调用）
function Throw-InstallError {
    param([string]$Id, [string]$Detail)
    $message = "[$Id] $Detail"
    throw $message
}

# 控制台醒目输出错误块（用户记 ID 即可报障）
function Show-ErrorBlock {
    param([string]$Id, [string]$Detail)
    $spec = Get-ErrorSpec -Id $Id
    $line = '=' * 54
    Write-Host ''
    Write-Host $line -ForegroundColor Red
    Write-Host ("  [错误 {0}]  {1}" -f $Id, $spec.Summary) -ForegroundColor Red
    Write-Host $line -ForegroundColor Red
    if ($Detail) {
        Write-Host ("  详情：{0}" -f $Detail) -ForegroundColor DarkGray
    }
    Write-Host ("  建议：{0}" -f $spec.Advice) -ForegroundColor Yellow
    Write-Host $line -ForegroundColor Red
    Write-Host ''
}
