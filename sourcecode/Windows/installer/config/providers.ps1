# ============================================================
# 模型供应商数据表 —— 内置 DeepSeek / GLM + 自定义（v1.14 起移除通义千问）
# 端点均为官方 Anthropic 兼容 API（已核对官方文档）
# 每家提供：Base URL、模型列表（含 1M 上下文变体）、附加 env
# ============================================================

# 供应商表（显示名 → 完整配置；键顺序 = 弹窗/控制台显示顺序）
# 字段说明：
#   Key            控制台/获取 Key 的入口（显示给用户）
#   Guide          获取 Key 的完整流程说明（官网/注册/支付/取 Key，弹窗展示）
#   BaseUrl        ANTHROPIC_BASE_URL
#   Models         可选模型列表（默认第一个）
#   DefaultModel   haiku/子代理 映射模型（快、便宜）
#   ExtraEnv       供应商专属附加环境变量
$Script:Providers = [ordered]@{
    'DeepSeek' = @{
        KeyHint      = 'https://platform.deepseek.com → API Keys'
        Guide        = @(
            '【官网】https://platform.deepseek.com（DeepSeek 开放平台）',
            '【步骤】① 邮箱/手机号注册并登录',
            '　　　　② 点左侧「充值」完成付款 —— 注意：DeepSeek 为预付费，',
            '　　　　　新账户无免费额度，不充值无法调用（报 402 余额不足即此因）',
            '　　　　③ 进入「API Keys」页面 → 创建 API Key → 复制粘贴到本窗口',
            '【计费】按量计费（用多少扣多少，余额用尽会 402）'
        )
        BaseUrl      = 'https://api.deepseek.com/anthropic'
        Models       = @('deepseek-v4-pro[1m]', 'deepseek-v4-flash')
        FastModel    = 'deepseek-v4-flash'
        ExtraEnv     = @{}
    }
    'GLM（智谱）' = @{
        KeyHint      = 'https://open.bigmodel.cn → 右上角控制台 → API Keys'
        Guide        = @(
            '【官网】https://open.bigmodel.cn（智谱 AI 开放平台）',
            '【步骤】① 手机号注册并登录',
            '　　　　② 到控制台「财务中心」完成充值（预付费）；推荐了解',
            '　　　　　「GLM Coding Plan」包月套餐（专为编程工具设计，更划算）',
            '　　　　③ 进入「API Keys」页面 → 创建 API Key → 复制粘贴到本窗口',
            '【计费】Coding Plan 包月，或 API 按量付费（新用户通常有赠送额度）'
        )
        BaseUrl      = 'https://open.bigmodel.cn/api/anthropic'
        Models       = @('glm-4.7', 'glm-5.2[1m]')
        FastModel    = 'glm-4.7'
        ExtraEnv     = @{
            'API_TIMEOUT_MS'                          = '3000000'
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' = '1'
        }
    }
    '自定义（其他兼容服务）' = @{
        KeyHint      = '向您的服务商获取 Anthropic 兼容端点与 Key'
        Guide        = @(
            '【说明】请向您的模型服务商获取以下两项信息：',
            '　　　　① Anthropic 兼容接口地址（Base URL）',
            '　　　　② API Key 与可用模型名',
            '【提示】常见支持 Anthropic 兼容协议的服务均可填入'
        )
        BaseUrl      = ''
        Models       = @()
        FastModel    = ''
        ExtraEnv     = @{}
    }
}

# 取供应商的指南文本（多行拼接）
function Get-ProviderGuide {
    param([string]$Name)
    $prov = Get-Provider -Name $Name
    if ($prov -and $prov.Guide) { return ($prov.Guide -join "`r`n") }
    return ''
}

# 取供应商显示名列表
function Get-ProviderNames {
    return @($Script:Providers.Keys)
}

# 按名称取供应商配置 hashtable
function Get-Provider {
    param([string]$Name)
    if ($Script:Providers.Contains($Name)) { return $Script:Providers[$Name] }
    return $null
}
