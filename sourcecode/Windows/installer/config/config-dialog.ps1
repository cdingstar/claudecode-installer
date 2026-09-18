# ============================================================
# 模型配置界面 —— WinForms 弹窗（全中文）
# 字段：供应商下拉（联动模型与获取 Key 提示）/ API Key / 模型 / 自定义端点
# 按钮：测试连接（发 1 token 真实请求）/ 测试当前模型（#024，供应商选择框下方，直测已保存配置）/
#      保存并完成 / 直接保存 / 暂时跳过 / 恢复官方默认（#024，清除第三方配置回官方）
# 降级链：WinForms 打开失败 → 自动退回控制台问答
# 返回值：hashtable（Skipped/Provider/ApiKey/Model/BaseUrl）
# ============================================================

# ============================================================
# 已有配置自动验证（#017）：settings.json 里已有 Key 时静默测试；
# 可用时不再静默跳过（#026）——交由 Confirm-KeepExistingConfig 让用户
# 选择「保留现有」或「重新配置」；不可用才直接弹窗让用户重新输入
# 返回值：$true = 已有配置验证通过；$false = 需要弹窗
# ============================================================
function Test-ExistingConfig {
    $settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path -LiteralPath $settingsFile)) { return $false }
    try {
        $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $env2 = $settings.env
        if (-not $env2) { return $false }
        $token = [string]$env2.ANTHROPIC_AUTH_TOKEN
        $base = [string]$env2.ANTHROPIC_BASE_URL
        $model = [string]$env2.ANTHROPIC_MODEL
        if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($base) -or [string]::IsNullOrWhiteSpace($model)) {
            return $false
        }
        Write-Info ("检测到已有模型配置（{0}，模型 {1}），正在自动验证……" -f $base, $model)
        $result = Test-ProviderConnection -BaseUrl $base -ApiKey $token -Model $model
        if ($result.Ok) {
            Write-Ok ("已有配置验证通过（{0}）" -f $result.Detail)
            return $true
        }
        Write-WarnMsg ("已有配置验证失败：{0}，将弹出配置窗口重新输入" -f $result.Detail)
        return $false
    } catch {
        Write-Log -Message ("读取已有配置异常（按需弹窗处理）：{0}" -f $_.Exception.Message) -Level 'WARN'
        return $false
    }
}

# ============================================================
# 有效配置确认（#026）：已有配置验证通过后不再静默跳过，
# 提示用户选择「保留现有」还是「重新配置」
# 返回值：$true = 保留现有配置（跳过本步骤）；$false = 打开配置窗口
# 图形界面打开失败时降级为控制台问答
# ============================================================
function Confirm-KeepExistingConfig {
    $saved = Get-SavedConfigSnapshot
    $summary = ''
    if ($saved) {
        $summary = ("`r`n`r`n接口地址：{0}`r`n模型：{1}" -f $saved.BaseUrl, $saved.Model)
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $msg = "检测到已保存的模型配置，且连接实测通过。$summary" + "`r`n`r`n" +
            '是否保留现有配置？' + "`r`n`r`n" +
            '· 选「是」：保留现有配置，跳过本步骤' + "`r`n" +
            '· 选「否」：打开配置窗口，可更换供应商 / API Key / 模型'
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, '已存在有效的 API Key 配置',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Ok '保留现有配置，跳过配置步骤'
            return $true
        }
        Write-Info '即将打开配置窗口（可更换供应商 / API Key / 模型）'
        return $false
    } catch {
        Write-Log -Message ("有效配置确认弹窗打开失败，降级为控制台问答：{0}" -f $_.Exception.Message) -Level 'WARN'
        Write-Host ''
        Write-Host '========== 检测到已保存的模型配置（连接实测通过） ==========' -ForegroundColor Cyan
        if ($summary) { Write-Host $summary.Trim() -ForegroundColor Gray }
        while ($true) {
            $choice = Read-Host '保留现有配置输入 y，重新配置输入 n（直接回车 = 保留）'
            if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match '^(?i)y(es)?$') { return $true }
            if ($choice -match '^(?i)n(o)?$') { return $false }
            Write-Host '输入无效：请输入 y 或 n' -ForegroundColor Yellow
        }
    }
}

# 读取当前已保存配置：用于重配时自动回填，减少重复输入
function Get-SavedConfigSnapshot {
    $settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path -LiteralPath $settingsFile)) { return $null }
    try {
        $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $env2 = $settings.env
        if (-not $env2) { return $null }

        $token = [string]$env2.ANTHROPIC_AUTH_TOKEN
        $base = [string]$env2.ANTHROPIC_BASE_URL
        $model = [string]$env2.ANTHROPIC_MODEL
        if ([string]::IsNullOrWhiteSpace($token) -and [string]::IsNullOrWhiteSpace($base) -and [string]::IsNullOrWhiteSpace($model)) {
            return $null
        }

        $providerName = '自定义（其他兼容服务）'
        foreach ($name in Get-ProviderNames) {
            $prov = Get-Provider -Name $name
            if ($prov -and $prov.BaseUrl -and $prov.BaseUrl -eq $base) {
                $providerName = $name
                break
            }
        }

        return @{
            Provider = $providerName
            ApiKey   = $token
            BaseUrl  = $base
            Model    = $model
        }
    } catch {
        Write-Log -Message ("读取已保存配置失败（仅影响回填，不影响继续配置）：{0}" -f $_.Exception.Message) -Level 'WARN'
        return $null
    }
}

# 配置入口：优先弹窗，异常降级控制台
function Invoke-ConfigDialog {
    try {
        return Show-ConfigForm
    } catch {
        Write-Log -Message ("图形界面打开失败，降级为控制台问答：{0}" -f $_.Exception.Message) -Level 'WARN'
        Write-WarnMsg '图形界面打开失败，自动切换为控制台问答模式'
        return Read-ConfigFromConsole
    }
}

# WinForms 配置窗体
function Show-ConfigForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $saved = Get-SavedConfigSnapshot
    $state = @{ Result = $null }
    $fontUi = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $fontSection = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $borderColor = [System.Drawing.Color]::FromArgb(224, 231, 255)
    $brandColor = [System.Drawing.Color]::FromArgb(37, 99, 235)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Claude Code API Key / 模型配置'
    $form.Size = New-Object System.Drawing.Size(780, 760)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White
    $form.Font = $fontUi

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = '重新配置 API Key 与模型'
    $lblTitle.Font = $fontTitle
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 18)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblSubtitle = New-Object System.Windows.Forms.Label
    $lblSubtitle.Text = '适用于安装后未完成配置、Key 失效、换供应商，或想改模型的情况。供应商和模型都可以重新选。'
    $lblSubtitle.Location = New-Object System.Drawing.Point(22, 50)
    $lblSubtitle.Size = New-Object System.Drawing.Size(720, 20)
    $lblSubtitle.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblSubtitle)

    $grpProvider = New-Object System.Windows.Forms.GroupBox
    $grpProvider.Text = '1. 选择供应商'
    $grpProvider.Font = $fontSection
    $grpProvider.Location = New-Object System.Drawing.Point(20, 82)
    $grpProvider.Size = New-Object System.Drawing.Size(235, 250)
    $grpProvider.ForeColor = $brandColor
    $form.Controls.Add($grpProvider)

    $lstProvider = New-Object System.Windows.Forms.ListBox
    $lstProvider.Location = New-Object System.Drawing.Point(14, 30)
    $lstProvider.Size = New-Object System.Drawing.Size(205, 148)
    $lstProvider.BorderStyle = 'FixedSingle'
    Get-ProviderNames | ForEach-Object { [void]$lstProvider.Items.Add($_) }
    $grpProvider.Controls.Add($lstProvider)

    # 测试当前模型（#024）：置于供应商选择框正下方，直测 settings.json 已保存配置
    $btnTestSaved = New-Object System.Windows.Forms.Button
    $btnTestSaved.Text = '测试当前模型'
    $btnTestSaved.Location = New-Object System.Drawing.Point(14, 186)
    $btnTestSaved.Size = New-Object System.Drawing.Size(205, 30)
    $grpProvider.Controls.Add($btnTestSaved)

    $lblProviderTip = New-Object System.Windows.Forms.Label
    $lblProviderTip.Text = '点左侧供应商后，右边会同步刷新获取 Key 指南和可选模型。'
    $lblProviderTip.Location = New-Object System.Drawing.Point(14, 222)
    $lblProviderTip.Size = New-Object System.Drawing.Size(205, 26)
    $lblProviderTip.ForeColor = [System.Drawing.Color]::DimGray
    $grpProvider.Controls.Add($lblProviderTip)

    $grpGuide = New-Object System.Windows.Forms.GroupBox
    $grpGuide.Text = '2. 获取 API Key 指南'
    $grpGuide.Font = $fontSection
    $grpGuide.Location = New-Object System.Drawing.Point(275, 82)
    $grpGuide.Size = New-Object System.Drawing.Size(470, 250)
    $grpGuide.ForeColor = $brandColor
    $form.Controls.Add($grpGuide)

    $txtGuide = New-Object System.Windows.Forms.TextBox
    $txtGuide.Multiline = $true
    $txtGuide.ReadOnly = $true
    $txtGuide.ScrollBars = 'Vertical'
    $txtGuide.Location = New-Object System.Drawing.Point(16, 30)
    $txtGuide.Size = New-Object System.Drawing.Size(438, 196)
    $txtGuide.BackColor = [System.Drawing.Color]::WhiteSmoke
    $txtGuide.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtGuide.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.8)
    $txtGuide.TabStop = $false
    $grpGuide.Controls.Add($txtGuide)

    $grpAccess = New-Object System.Windows.Forms.GroupBox
    $grpAccess.Text = '3. 填写 API Key 与接口地址'
    $grpAccess.Font = $fontSection
    $grpAccess.Location = New-Object System.Drawing.Point(20, 350)
    $grpAccess.Size = New-Object System.Drawing.Size(725, 145)
    $grpAccess.ForeColor = $brandColor
    $form.Controls.Add($grpAccess)

    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = 'API Key：'
    $lblKey.Location = New-Object System.Drawing.Point(18, 34)
    $lblKey.AutoSize = $true
    $grpAccess.Controls.Add($lblKey)

    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = New-Object System.Drawing.Point(110, 30)
    $txtKey.Size = New-Object System.Drawing.Size(490, 24)
    $txtKey.UseSystemPasswordChar = $true
    if ($saved -and $saved.ApiKey) { $txtKey.Text = $saved.ApiKey }
    $grpAccess.Controls.Add($txtKey)

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = '显示 Key'
    $chkShow.Location = New-Object System.Drawing.Point(615, 32)
    $chkShow.AutoSize = $true
    $grpAccess.Controls.Add($chkShow)
    $chkShow.Add_CheckedChanged({
        $txtKey.UseSystemPasswordChar = -not $chkShow.Checked
    })

    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = '接口地址：'
    $lblUrl.Location = New-Object System.Drawing.Point(18, 76)
    $lblUrl.AutoSize = $true
    $grpAccess.Controls.Add($lblUrl)

    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point(110, 72)
    $txtUrl.Size = New-Object System.Drawing.Size(590, 24)
    if ($saved -and $saved.BaseUrl) { $txtUrl.Text = $saved.BaseUrl }
    $grpAccess.Controls.Add($txtUrl)

    $lblUrlHint = New-Object System.Windows.Forms.Label
    $lblUrlHint.Text = '官方供应商会自动带出地址；只有选「自定义」时才需要手动修改。'
    $lblUrlHint.Location = New-Object System.Drawing.Point(110, 104)
    $lblUrlHint.Size = New-Object System.Drawing.Size(560, 20)
    $lblUrlHint.ForeColor = [System.Drawing.Color]::DimGray
    $grpAccess.Controls.Add($lblUrlHint)

    $grpModel = New-Object System.Windows.Forms.GroupBox
    $grpModel.Text = '4. 选择模型（这里会直接影响使用效果）'
    $grpModel.Font = $fontSection
    $grpModel.Location = New-Object System.Drawing.Point(20, 512)
    $grpModel.Size = New-Object System.Drawing.Size(725, 130)
    $grpModel.ForeColor = $brandColor
    $form.Controls.Add($grpModel)

    $lblModelTip = New-Object System.Windows.Forms.Label
    $lblModelTip.Text = '推荐模型会直接显示在下方，点一下就能选中；也可以手动输入其他模型名。'
    $lblModelTip.Location = New-Object System.Drawing.Point(18, 28)
    $lblModelTip.Size = New-Object System.Drawing.Size(680, 18)
    $lblModelTip.ForeColor = [System.Drawing.Color]::DimGray
    $grpModel.Controls.Add($lblModelTip)

    $pnlModelChoices = New-Object System.Windows.Forms.Panel
    $pnlModelChoices.Location = New-Object System.Drawing.Point(18, 52)
    $pnlModelChoices.Size = New-Object System.Drawing.Size(685, 34)
    $pnlModelChoices.BorderStyle = 'FixedSingle'
    $pnlModelChoices.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $grpModel.Controls.Add($pnlModelChoices)

    $lblModel = New-Object System.Windows.Forms.Label
    $lblModel.Text = '当前模型名：'
    $lblModel.Location = New-Object System.Drawing.Point(18, 97)
    $lblModel.AutoSize = $true
    $grpModel.Controls.Add($lblModel)

    $txtModel = New-Object System.Windows.Forms.TextBox
    $txtModel.Location = New-Object System.Drawing.Point(110, 93)
    $txtModel.Size = New-Object System.Drawing.Size(300, 24)
    if ($saved -and $saved.Model) { $txtModel.Text = $saved.Model }
    $grpModel.Controls.Add($txtModel)

    $lblModelHint = New-Object System.Windows.Forms.Label
    $lblModelHint.Text = '如果推荐项里没有你想要的模型，可以直接在这里改。'
    $lblModelHint.Location = New-Object System.Drawing.Point(425, 97)
    $lblModelHint.Size = New-Object System.Drawing.Size(260, 20)
    $lblModelHint.ForeColor = [System.Drawing.Color]::DimGray
    $grpModel.Controls.Add($lblModelHint)

    $lblTest = New-Object System.Windows.Forms.Label
    $lblTest.Location = New-Object System.Drawing.Point(20, 652)
    $lblTest.Size = New-Object System.Drawing.Size(725, 36)
    $lblTest.ForeColor = [System.Drawing.Color]::Gray
    $lblTest.Text = '填好后建议先测试。保存按钮会自动再测一次，通过后再写入。'
    $form.Controls.Add($lblTest)

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = '恢复官方默认'
    $btnReset.Location = New-Object System.Drawing.Point(20, 693)
    $btnReset.Size = New-Object System.Drawing.Size(125, 34)
    $form.Controls.Add($btnReset)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = '暂时跳过'
    $btnSkip.Location = New-Object System.Drawing.Point(155, 693)
    $btnSkip.Size = New-Object System.Drawing.Size(90, 34)
    $form.Controls.Add($btnSkip)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '测试连接'
    $btnTest.Location = New-Object System.Drawing.Point(255, 693)
    $btnTest.Size = New-Object System.Drawing.Size(90, 34)
    $form.Controls.Add($btnTest)

    $btnForce = New-Object System.Windows.Forms.Button
    $btnForce.Text = '直接保存'
    $btnForce.Location = New-Object System.Drawing.Point(355, 693)
    $btnForce.Size = New-Object System.Drawing.Size(90, 34)
    $form.Controls.Add($btnForce)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存并完成'
    $btnSave.Location = New-Object System.Drawing.Point(580, 693)
    $btnSave.Size = New-Object System.Drawing.Size(160, 34)
    $btnSave.BackColor = $brandColor
    $btnSave.UseVisualStyleBackColor = $false
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'
    $btnSave.FlatAppearance.BorderColor = $brandColor
    $form.Controls.Add($btnSave)
    $form.AcceptButton = $btnSave
    $form.CancelButton = $btnSkip

    $renderModels = {
        param($Provider, $PreferredModel)

        $pnlModelChoices.Controls.Clear()
        if (-not $Provider -or -not $Provider.Models -or $Provider.Models.Count -eq 0) {
            $lblEmpty = New-Object System.Windows.Forms.Label
            $lblEmpty.Text = '当前供应商没有内置推荐模型，请在下方手动输入模型名。'
            $lblEmpty.Location = New-Object System.Drawing.Point(10, 8)
            $lblEmpty.Size = New-Object System.Drawing.Size(620, 20)
            $lblEmpty.ForeColor = [System.Drawing.Color]::DimGray
            $pnlModelChoices.Controls.Add($lblEmpty)
            if (-not $PreferredModel) { $txtModel.Text = '' }
            return
        }

        $x = 12
        $selected = $false
        foreach ($m in $Provider.Models) {
            $modelName = [string]$m
            $rb = New-Object System.Windows.Forms.RadioButton
            $rb.Text = $modelName
            $rb.Tag = $modelName
            $rb.AutoSize = $true
            $rb.Location = New-Object System.Drawing.Point($x, 8)
            $rb.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
            $rb.Add_CheckedChanged({
                if ($this.Checked) {
                    $txtModel.Text = [string]$this.Tag
                }
            })
            $pnlModelChoices.Controls.Add($rb)
            $x += [Math]::Max($rb.PreferredSize.Width + 22, 140)
            if ($PreferredModel -and $PreferredModel -eq $modelName) {
                $rb.Checked = $true
                $selected = $true
            }
        }
        if (-not $selected -and $pnlModelChoices.Controls.Count -gt 0) {
            ([System.Windows.Forms.RadioButton]$pnlModelChoices.Controls[0]).Checked = $true
        } elseif ($PreferredModel) {
            $txtModel.Text = $PreferredModel
        }
    }

    $syncProvider = {
        $providerName = [string]$lstProvider.SelectedItem
        $prov = Get-Provider -Name $providerName
        if (-not $prov) { return }

        $txtGuide.Text = Get-ProviderGuide -Name $providerName

        $isCustom = ($providerName -like '自定义*')
        if ($isCustom) {
            $txtUrl.ReadOnly = $false
            $txtUrl.BackColor = [System.Drawing.Color]::White
            if (-not $txtUrl.Text.Trim()) { $txtUrl.Text = '' }
        } else {
            $txtUrl.ReadOnly = $true
            $txtUrl.BackColor = [System.Drawing.Color]::WhiteSmoke
            $txtUrl.Text = $prov.BaseUrl
        }

        $preferredModel = ''
        if ($saved -and $saved.Provider -eq $providerName -and $saved.Model) {
            $preferredModel = $saved.Model
        } elseif ($txtModel.Text.Trim()) {
            $preferredModel = $txtModel.Text.Trim()
        } elseif ($prov.Models.Count -gt 0) {
            $preferredModel = [string]$prov.Models[0]
        }
        & $renderModels $prov $preferredModel
    }
    $lstProvider.Add_SelectedIndexChanged($syncProvider)

    # ---- 测试连接 ----
    $btnTest.Add_Click({
        $lblTest.ForeColor = [System.Drawing.Color]::Gray
        $lblTest.Text = '正在测试连接，请稍候（最长 20 秒）……'
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Refresh()
        $prov = Get-Provider -Name ([string]$lstProvider.SelectedItem)
        $baseUrl = $txtUrl.Text.Trim()
        if (-not $baseUrl -and $prov) { $baseUrl = $prov.BaseUrl }
        $key = $txtKey.Text.Trim()
        $model = $txtModel.Text.Trim()
        if (-not $baseUrl -or -not $key -or -not $model) {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = '请先填写完整：API Key、模型（自定义还需接口地址）'
            return
        }
        $testResult = Test-ProviderConnection -BaseUrl $baseUrl -ApiKey $key -Model $model
        if ($testResult.Ok) {
            $lblTest.ForeColor = [System.Drawing.Color]::Green
            $lblTest.Text = ('连接成功！模型可用（{0}）' -f $testResult.Detail)
        } else {
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = ('连接失败：{0}' -f $testResult.Detail)
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ---- 测试当前模型（#024）：不填表单，直接实测 settings.json 当前生效配置 ----
    $btnTestSaved.Add_Click({
        $savedNow = Get-SavedConfigSnapshot
        if (-not $savedNow) {
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = '当前没有已保存的模型配置：请先在上面填写并保存，或填写后点「测试连接」'
            return
        }
        $lblTest.ForeColor = [System.Drawing.Color]::Gray
        $lblTest.Text = ('正在测试当前模型（已保存配置 {0}，模型 {1}），最长 20 秒……' -f $savedNow.BaseUrl, $savedNow.Model)
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Refresh()
        $r = Test-ProviderConnection -BaseUrl $savedNow.BaseUrl -ApiKey $savedNow.ApiKey -Model $savedNow.Model
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($r.Ok) {
            $lblTest.ForeColor = [System.Drawing.Color]::Green
            $lblTest.Text = ('当前模型连接成功！已保存配置可用（{0}）' -f $r.Detail)
        } else {
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = ('当前模型连接失败：{0}' -f $r.Detail)
        }
    })

    # ---- 恢复官方默认（#024）：清除第三方配置，回到 Claude Code 官方模型/登录 ----
    $btnReset.Add_Click({
        $msg = '将清除第三方供应商配置（API Key / 接口地址 / 模型映射），恢复为 Claude Code 官方默认。' + "`r`n" +
            '恢复后运行 claude 需按提示登录官方账号。' + "`r`n`r`n" +
            '现有 settings.json 会先自动备份。确定继续？'
        $answer = [System.Windows.Forms.MessageBox]::Show($form, $msg, '恢复官方默认',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $state.Result = @{ Skipped = $false; Reset = $true }
            $form.Close()
        }
    })

    # ---- 保存（自动测试，通过才保存；#017）----
    $doSave = {
        $providerName = [string]$lstProvider.SelectedItem
        $prov = Get-Provider -Name $providerName
        $baseUrl = $txtUrl.Text.Trim()
        if (-not $baseUrl -and $prov) { $baseUrl = $prov.BaseUrl }
        $model = $txtModel.Text.Trim()
        if (-not $model -and $prov) { $model = $prov.Models | Select-Object -First 1 }
        $state.Result = @{
            Skipped  = $false
            Provider = $providerName
            ApiKey   = $txtKey.Text.Trim()
            Model    = $model
            BaseUrl  = $baseUrl
        }
        $form.Close()
    }
    $btnSave.Add_Click({
        $key = $txtKey.Text.Trim()
        if (-not $key) {
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = '请填写 API Key（还没有可点「暂时跳过」）'
            return
        }
        $prov = Get-Provider -Name ([string]$lstProvider.SelectedItem)
        $baseUrl = $txtUrl.Text.Trim()
        if (-not $baseUrl -and $prov) { $baseUrl = $prov.BaseUrl }
        $model = $txtModel.Text.Trim()
        if (-not $model) { $model = $prov.Models | Select-Object -First 1 }
        # 保存前自动测试（#017）：通过才保存关闭，失败显示原因让用户修改
        $lblTest.ForeColor = [System.Drawing.Color]::Gray
        $lblTest.Text = '正在自动测试连接（最长 20 秒）……'
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Refresh()
        $r = Test-ProviderConnection -BaseUrl $baseUrl -ApiKey $key -Model $model
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($r.Ok) {
            $lblTest.ForeColor = [System.Drawing.Color]::Green
            $lblTest.Text = ("连接成功，正在保存（{0}）" -f $r.Detail)
            $form.Refresh()
            Start-Sleep -Milliseconds 600
            & $doSave
        } else {
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = ("未保存。{0}；可修改后重试，或点「直接保存」跳过测试" -f $r.Detail)
        }
    })
    # ---- 直接保存（跳过测试的逃生门）----
    $btnForce.Add_Click({
        $key = $txtKey.Text.Trim()
        if (-not $key) {
            $lblTest.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTest.Text = '请填写 API Key（还没有可点「暂时跳过」）'
            return
        }
        & $doSave
    })

    # ---- 跳过 ----
    $btnSkip.Add_Click({
        $state.Result = @{ Skipped = $true }
        $form.Close()
    })
    $form.Add_FormClosing({
        if (-not $state.Result) { $state.Result = @{ Skipped = $true } }
    })

    if ($saved -and $saved.Provider -and $lstProvider.Items.Contains($saved.Provider)) {
        $lstProvider.SelectedItem = $saved.Provider
    } else {
        $lstProvider.SelectedIndex = 0
    }

    [void]$form.ShowDialog()
    return $state.Result
}

# ============================================================
# 错误中文化层 —— 把 HTTP/网络异常翻译成「原始错误 ID + 中文 + 英文」
# 错误 ID 优先级：[GLM 服务端错误码] > [HTTP 状态码] > [网络]
# 匹配顺序（从具体到兜底）：
#   1. GLM 官方业务错误码表（body 的 error.code，来自 docs.bigmodel.cn/cn/faq/api-code）
#   2. 服务端英文消息词典（Insufficient Balance → 余额不足 等，DeepSeek 官方文档口径）
#   3. HTTP 状态码表（400~504，中英对照）
#   4. 网络层异常分类（超时 / 断网 / DNS / SSL）
#   5. 原始消息兜底
# 展示格式：[HTTP 402 · Payment Required] 中文提示（原文：Insufficient Balance）
# 兼容 PS5.1（WebException + GetResponseStream）与 PS7（ErrorDetails）
# 返回值：@{ Chinese = '中文主提示'; English = '英文短语'; Raw = '原始信息'; Detail = '最终展示行' }
# ============================================================
function Get-FriendlyApiError {
    param($ErrorRecord)

    $ex = $ErrorRecord.Exception
    $raw = [string]$ex.Message
    $statusCode = 0
    $bodyText = ''

    # ---- 提取状态码 ----
    if ($ex.Response) {
        try { $statusCode = [int]$ex.Response.StatusCode } catch { $statusCode = 0 }
    }

    # ---- 提取响应体（PS7 在 ErrorDetails；PS5.1 在 Response 流）----
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $bodyText = [string]$ErrorRecord.ErrorDetails.Message
    } elseif ($ex.Response -and $ex.Response.GetType().GetMethod('GetResponseStream')) {
        try {
            $reader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
            $bodyText = $reader.ReadToEnd()
            $reader.Close()
        } catch { }
    }

    # ---- 解析服务端 error.message 与 error.code ----
    $serverMsg = ''
    $serverCode = ''
    if ($bodyText) {
        try {
            $json = $bodyText | ConvertFrom-Json
            if ($json.error) {
                if ($json.error.message) { $serverMsg = [string]$json.error.message }
                if ($json.error.code) { $serverCode = [string]$json.error.code }
            } elseif ($json.message) {
                $serverMsg = [string]$json.message
                if ($json.code) { $serverCode = [string]$json.code }
            }
        } catch {
            $serverMsg = $bodyText.Trim()
        }
    }

    # ---- 1) GLM 官方业务错误码表（docs.bigmodel.cn/cn/faq/api-code）----
    $glmCodeMap = @{
        '1000' = 'API Key 认证失败：请检查 Key 是否正确，或在平台重新生成'
        '1001' = '请求头缺少认证参数：请确认安装器版本为最新'
        '1003' = 'API Key（Token）已过期：请到智谱平台重新生成 Key'
        '1005' = '账户已开启二次认证保护：请到智谱平台完成二次认证'
        '1113' = '账户已欠费：请到智谱平台充值后重试'
        '1210' = '调用参数有误：请检查模型名'
        '1211' = '模型不存在：请检查弹窗里的模型名拼写，或换一个模型'
        '1212' = '当前模型不支持此调用方式'
        '1220' = '无权访问该接口：该 Key 未开通此服务'
        '1221' = '该 API 已下线：请更换模型'
        '1222' = '该 API 不存在：请检查接口地址'
        '1261' = '对话内容（Prompt）超长：请缩短后重试'
        '1301' = '内容安全拦截：输入或生成内容含敏感信息，请调整后重试'
        '1302' = '已达速率限制：请降低请求频率'
        '1305' = '该模型当前访问量过大：请稍后再试'
        '1308' = '已达使用上限：限额将在提示的时间点自动重置'
        '1309' = 'GLM Coding Plan 套餐已到期：请到智谱平台续费'
        '1310' = '已达每周/每月使用上限：限额将在提示的时间点自动重置'
        '1311' = '当前订阅套餐未开放此模型权限：请升级套餐或换模型'
        '1313' = '触发公平使用策略：请降低使用强度或稍后再试'
        '1314' = '企业套餐已失效：请联系企业管理员'
        '1315' = '该 Key 仅限企业编程套餐场景使用'
        '1200' = '服务端调用失败：请稍后重试'
        '1230' = '服务端调用流程出错：请稍后重试'
        '1234' = '服务端网络错误：请联系智谱客服并提供错误 ID'
    }
    if ($serverCode -and $glmCodeMap.ContainsKey($serverCode)) {
        return (New-FriendlyResult -Chinese $glmCodeMap[$serverCode] -English "GLM error $serverCode" -ServerMsg $serverMsg -Raw $raw -Code $statusCode -ServerCode $serverCode)
    }

    # ---- 2) 服务端英文消息词典（DeepSeek 官方口径）----
    $msgDict = [ordered]@{
        'insufficient balance'        = '账户余额不足：请到对应平台充值后，回来再点「测试连接」'
        'insufficient_quota'          = '额度不足：请到对应平台充值或续费套餐'
        'exceeded your current quota' = '额度已用尽：请到对应平台充值'
        'arrears'                     = '账户已欠费：请到对应平台充值'
        'authentication fails'        = 'API Key 无效（认证失败）：请检查 Key 是否正确、复制是否完整'
        'invalid api key'             = 'API Key 无效：请检查 Key 是否正确、复制是否完整'
        'invalid_x_api_key'           = 'API Key 无效：请检查 Key 是否正确、复制是否完整'
        'invalid token'               = 'API Key 无效（令牌错误）：请检查 Key 是否正确、复制是否完整'
        '令牌无效'                     = 'API Key 无效（令牌无效）：请在平台重新生成 Key'
        '令牌过期'                     = 'API Key 已过期：请在平台重新生成 Key'
        'model not exist'             = '模型不存在：请检查弹窗里的模型名拼写，或换一个模型'
        'model not found'             = '模型不存在：请检查弹窗里的模型名拼写，或换一个模型'
        'rate limit'                  = '请求过于频繁：请稍等几秒再点「测试连接」'
        'permission denied'           = '无权限：该 Key 未开通此模型/套餐，或账号被禁用'
        'unauthorized'                = 'API Key 认证失败：请检查 Key 是否正确、复制是否完整，或在平台重新生成'
        'authentication_error'        = 'API Key 认证失败：请检查 Key 是否正确、复制是否完整，或在平台重新生成'
    }
    $searchText = ("{0} {1}" -f $serverMsg, $raw).ToLowerInvariant()
    foreach ($key in $msgDict.Keys) {
        if ($searchText.Contains($key)) {
            return (New-FriendlyResult -Chinese $msgDict[$key] -English $key -ServerMsg $serverMsg -Raw $raw -Code $statusCode)
        }
    }

    # ---- 3) HTTP 状态码表（中英对照，DeepSeek 官方文档口径）----
    $codeMap = @{
        400 = @{ Cn = '请求格式/参数错误：请检查模型名是否正确';                En = 'Bad Request' }
        401 = @{ Cn = 'API Key 无效（认证失败）：请检查 Key 或重新生成';        En = 'Unauthorized' }
        402 = @{ Cn = '账户余额不足：请到对应平台充值后重试';                   En = 'Payment Required' }
        403 = @{ Cn = '无权限：该 Key 未开通此模型/套餐，或账号被禁用';         En = 'Forbidden' }
        404 = @{ Cn = '接口地址或模型不存在：请检查供应商与模型选择';           En = 'Not Found' }
        405 = @{ Cn = '请求方式不被支持：接口地址可能有误';                     En = 'Method Not Allowed' }
        408 = @{ Cn = '请求超时：请检查网络后重试';                             En = 'Request Timeout' }
        413 = @{ Cn = '请求内容过大';                                           En = 'Payload Too Large' }
        415 = @{ Cn = '请求格式不支持：接口地址可能有误';                       En = 'Unsupported Media Type' }
        422 = @{ Cn = '请求参数无法处理：请检查模型名';                         En = 'Unprocessable Entity' }
        429 = @{ Cn = '请求频率/用量达到上限：请稍等几秒再点「测试连接」';      En = 'Too Many Requests' }
        500 = @{ Cn = '服务端内部故障：请稍后重试';                             En = 'Internal Server Error' }
        502 = @{ Cn = '服务端网关错误：请稍后重试';                             En = 'Bad Gateway' }
        503 = @{ Cn = '服务端负载过高（繁忙）：请稍后重试';                     En = 'Service Unavailable' }
        504 = @{ Cn = '服务端网关超时：请稍后重试';                             En = 'Gateway Timeout' }
    }
    if ($statusCode -gt 0 -and $codeMap.ContainsKey($statusCode)) {
        return (New-FriendlyResult -Chinese $codeMap[$statusCode].Cn -English $codeMap[$statusCode].En -ServerMsg $serverMsg -Raw $raw -Code $statusCode)
    }

    # ---- 4) 网络层异常分类（ID 前缀 [网络]）----
    if ($ex -is [System.Net.WebException]) {
        switch ($ex.Status.ToString()) {
            'Timeout'              { return (New-FriendlyResult -Chinese '请求超时：请检查网络后重试' -English 'Network Timeout' -ServerMsg $serverMsg -Raw $raw) }
            'NameResolutionFailure'{ return (New-FriendlyResult -Chinese '域名解析失败：电脑可能断网或 DNS 异常，请检查网络连接' -English 'DNS Resolution Failure' -ServerMsg $serverMsg -Raw $raw) }
            'ConnectFailure'       { return (New-FriendlyResult -Chinese '无法连接服务器：请检查网络、防火墙或代理设置' -English 'Connection Failed' -ServerMsg $serverMsg -Raw $raw) }
            'SecureChannelFailure' { return (New-FriendlyResult -Chinese '安全连接（SSL）失败：可能是网络劫持/代理拦截，或系统缺少 TLS 1.2 支持（可更新 Windows 补丁后重试）' -English 'SSL/TLS Failure' -ServerMsg $serverMsg -Raw $raw) }
            'TrustFailure'         { return (New-FriendlyResult -Chinese 'SSL 证书校验失败：网络可能被劫持，请检查代理设置' -English 'SSL Trust Failure' -ServerMsg $serverMsg -Raw $raw) }
        }
    }
    # 关键词兜底（PS7 的异常消息形态；注意顺序：DNS → 超时 → 连接 → SSL，避免误判）
    $lowerRaw = $raw.ToLowerInvariant()
    if ($lowerRaw -match 'no such host|name resolution|getaddrinfo|host not found') { return (New-FriendlyResult -Chinese '域名解析失败：电脑可能断网或 DNS 异常' -English 'DNS Resolution Failure' -ServerMsg $serverMsg -Raw $raw) }
    if ($lowerRaw -match 'timed? out') { return (New-FriendlyResult -Chinese '请求超时：请检查网络后重试' -English 'Network Timeout' -ServerMsg $serverMsg -Raw $raw) }
    if ($lowerRaw -match 'connection refused|unable to connect|actively refused|unexpected eof|0 bytes from the transport') { return (New-FriendlyResult -Chinese '无法连接服务器：请检查网络、防火墙或代理设置' -English 'Connection Failed' -ServerMsg $serverMsg -Raw $raw) }
    if ($lowerRaw -match 'ssl|secure channel|handshake|certificate') { return (New-FriendlyResult -Chinese '安全连接（SSL）失败：系统可能缺少 TLS 1.2 支持' -English 'SSL/TLS Failure' -ServerMsg $serverMsg -Raw $raw) }

    # ---- 5) 兜底 ----
    return (New-FriendlyResult -Chinese '未知错误：详见括号内原文，报障时请一并提供' -English 'Unknown Error' -ServerMsg $serverMsg -Raw $raw -Code $statusCode)
}

# 组装最终展示行：[错误 ID] 中文提示（English：短语）（原文：服务端消息）
# 规则：服务端原文本身是英文时不重复附 English 短语；本身是中文时仅附英文短语
function New-FriendlyResult {
    param([string]$Chinese, [string]$English, [string]$ServerMsg, [string]$Raw, [int]$Code = 0, [string]$ServerCode = '')

    # 错误 ID 前缀
    $idPart = ''
    if ($ServerCode) {
        $idPart = ("GLM {0}" -f $ServerCode)
        if ($Code -gt 0) { $idPart = ("HTTP {0} · GLM {1}" -f $Code, $ServerCode) }
    } elseif ($Code -gt 0) {
        $idPart = ("HTTP {0}" -f $Code)
    } else {
        $idPart = '网络'
    }
    if ($English -and $Code -gt 0 -and -not $ServerCode) {
        $idPart = ("HTTP {0} · {1}" -f $Code, $English)
    }

    # 中文 + 英文短语 + 服务端原文
    $detail = $Chinese
    $hasChineseServerMsg = ($ServerMsg -match '[一-龥]')
    if ($English -and ($Code -le 0)) { $detail = "{0}（{1}）" -f $Chinese, $English }
    if ($ServerMsg -and -not $hasChineseServerMsg) {
        $detail = "{0}（原文：{1}）" -f $detail, $ServerMsg
    }
    $detail = "[{0}] {1}" -f $idPart, $detail
    return @{
        Chinese = $Chinese
        English = $English
        Raw     = $Raw
        Detail  = $detail
    }
}

# 真实连接测试：POST {Base}/v1/messages（1 token 请求验证 Key 与模型）
# 返回值：@{ Ok = bool; Detail = '原因' }
function Test-ProviderConnection {
    param([string]$BaseUrl, [string]$ApiKey, [string]$Model)

    $url = $BaseUrl.TrimEnd('/') + '/v1/messages'
    # [1m] 等后缀是 Claude Code 客户端的上下文标记，API 端点不识别，测试前需剥掉
    $testModel = $Model -replace '\[1m\]$', ''
    $body = @{
        model      = $testModel
        max_tokens = 1
        messages   = @(@{ role = 'user'; content = 'hi' })
    } | ConvertTo-Json -Depth 5
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 20 -ContentType 'application/json' -Headers @{
            'x-api-key'         = $ApiKey
            'Authorization'     = ("Bearer {0}" -f $ApiKey)
            'anthropic-version' = '2023-06-01'
        }
        $modelUsed = $resp.model
        if ($modelUsed) {
            return @{ Ok = $true; Detail = ("服务端模型：{0}" -f $modelUsed) }
        }
        return @{ Ok = $true; Detail = '服务端已响应' }
    } catch {
        $friendly = Get-FriendlyApiError -ErrorRecord $_
        return @{ Ok = $false; Detail = $friendly.Detail }
    }
}

# 降级方案：控制台问答配置
function Read-ConfigFromConsole {
    Write-Host ''
    Write-Host '========== 模型配置（控制台模式） ==========' -ForegroundColor Cyan
    $names = Get-ProviderNames
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $names[$i])
    }
    $choice = Read-Host '请选择供应商编号（直接回车跳过配置）'
    if ([string]::IsNullOrWhiteSpace($choice)) { return @{ Skipped = $true } }

    $idx = 0
    if (-not ([int]::TryParse($choice, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $names.Count) {
        Write-Host '编号无效，已取消配置（稍后可运行「重新配置APIKEY.bat」）' -ForegroundColor Yellow
        return @{ Skipped = $true }
    }
    $providerName = $names[$idx - 1]
    $prov = Get-Provider -Name $providerName

    # 获取 Key 指南（#021：官网 + 注册/支付/取 Key 流程）
    Write-Host ''
    Write-Host '---------- 获取 API Key 指南 ----------' -ForegroundColor Cyan
    Get-ProviderGuide -Name $providerName | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    Write-Host '----------------------------------------' -ForegroundColor Cyan
    Write-Host '请先到官网完成注册与支付、拿到 API Key 后再继续。' -ForegroundColor Yellow

    Write-Host ('获取 Key：{0}' -f $prov.KeyHint) -ForegroundColor Gray
    $key = Read-Host '请粘贴 API Key（直接回车跳过）'
    if ([string]::IsNullOrWhiteSpace($key)) { return @{ Skipped = $true } }

    $model = ''
    if ($prov.Models.Count -gt 0) {
        Write-Host ("可选模型：{0}" -f ($prov.Models -join '、'))
        $model = Read-Host ("请输入模型名（直接回车用默认 {0}）" -f $prov.Models[0])
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $prov.Models[0] }
    } else {
        $model = Read-Host '请输入模型名'
    }

    $baseUrl = $prov.BaseUrl
    if (-not $baseUrl) {
        $baseUrl = Read-Host '请输入接口地址（Base URL，如 https://xxx/anthropic）'
    }

    return @{
        Skipped  = $false
        Provider = $providerName
        ApiKey   = $key.Trim()
        Model    = $model.Trim()
        BaseUrl  = $baseUrl.Trim()
    }
}
