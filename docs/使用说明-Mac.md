# Claude Code 一键安装器（Mac 版）使用说明

## 这是什么

在 macOS（Apple Silicon 或 Intel）上**双击一下**，自动完成：

- 安装 Node.js 22（华为云镜像，装到用户目录，不需要 sudo）
- 检测系统自带的 Git / Python（macOS 一般自带，缺了会给出提示，不影响使用）
- 安装 Claude Code 本体（npmmirror 源，失败自动切手动安装方案）
- 弹出中文配置窗口，选择大模型（GLM / DeepSeek / 通义 / 自定义）并填入 API Key
- 安装 VS Code（微软官方中国下载通道，装到 ~/Applications）
- 全程国内镜像，不需要管理员权限

## 使用步骤

1. 把整个安装器文件夹解压/放到任意位置（如「应用程序」或桌面）
2. 双击 **「安装ClaudeCode.command」**
   - 首次双击若提示「无法打开」：右键点该文件 →「打开」→ 再点「打开」
   （macOS 对网上下载的脚本默认拦截，右键打开即放行）
   - 终端窗口第一行会显示**版本号**（如 `v1.12(20260917)`），反馈问题时请一并告知
3. 按终端窗口提示等待（约 3-10 分钟，视网速）
4. 装完弹出配置窗口：选供应商 → 粘贴 API Key → 确定
5. **新开一个「终端」窗口**，输入 `claude` 回车开始使用

## API Key 获取

| 供应商 | 地址 |
|--------|------|
| GLM（智谱） | https://open.bigmodel.cn |
| DeepSeek | https://platform.deepseek.com（预付费，需充值） |
| 通义千问 | https://bailian.console.aliyun.com |


## 遇到问题如何反馈（重要）

安装结束后，安装器文件夹里会自动生成一个 **「问题反馈-安装日志-日期.zip」**（内含安装报告 + 全部日志）。

把它发给我们即可：
- 邮箱：**cdingstar@outlook.com**
- 微信：**cdingstar**

> 安装失败时，安装器会自动弹出文件夹定位这个 zip，并预开邮件草稿——把它作为附件发送就行。
> 也可以直接把「安装报告.txt」的内容复制粘贴过来（报告里有错误 ID，能快速定位）。

## 常见问题

### 安装到一半断网/关了窗口？
重新双击「安装ClaudeCode.command」。已装好的组件自动跳过，只补缺的部分。

### 想换模型 / 换 Key？
双击 **「重新配置APIKEY.command」**。

### 想测试当前配置的模型能不能用？
双击 **「重新配置APIKEY.command」**，在供应商列表选 **「—— 测试当前已保存配置」**——不用重新填写任何内容，立即实测当前生效的 Key / 接口 / 模型，结果显示在弹窗里，看完回到列表可继续配置。

### 想恢复成 Claude Code 官方默认？
双击 **「重新配置APIKEY.command」**，在供应商列表选 **「—— 恢复官方默认」** 并确认——自动清除第三方供应商配置（原配置会先备份为 `settings.json.bak`），恢复后运行 `claude` 按提示登录官方账号即可。

### 某个组件装坏了？
删除对应目录后重跑安装器（等于卸载重装）：
- Node：`~/.claude-installer/nodejs`
- Claude Code：`~/.claude-installer/npm-global`
- VS Code：`~/Applications/Visual Studio Code.app`

### 装在哪些位置？怎么完全卸载？
全部在用户目录（不碰系统）：
```
~/.claude-installer/          # Node 与 Claude Code
~/Applications/Visual Studio Code.app
~/.claude/                    # 配置（settings.json / CLAUDE.md）
```
卸载：双击 **「卸载ClaudeCode.command」**，确认后自动删除上述组件并清理终端配置；
个人数据（配置、聊天记录、API Key）默认保留，想彻底清空按提示输入 D 即可。
卸载中可随时按 Ctrl+C 停止；文件被占用时工具会自动重试，仍失败（或提示权限不足）时
按窗口里给出的命令操作，再重跑一次卸载工具即可接着删完（已删的不会重来）。
（也可手动删除上述目录，并删除 `~/.zprofile` / `~/.bash_profile` 里带 `claude-code-installer` 标记的行。）

### 提示「无法验证开发者」或「没有权限」？
右键点击 .command 文件 →「打开」→「打开」。或终端执行：
```
xattr -d com.apple.quarantine 安装ClaudeCode.command
chmod +x 安装ClaudeCode.command 配置模型.command 重新配置APIKEY.command
```

## 环境检测策略（与 Windows 版一致）

- 已装且版本达标（Node ≥18、Claude Code ≥2）→ 直接用，不下载
- 不达标才安装；本地 `cache/` 已有安装包则不重复下载
- 修复重装 = 删目录 + 重跑安装器

## 目录结构

```
ClaudeCode安装器/
├── 安装ClaudeCode.command   # 安装入口（双击）
├── 卸载ClaudeCode.command    # 一键卸载（个人数据默认保留）
├── 重新配置APIKEY.command    # 换供应商/Key/模型用
├── 配置模型.command          # 同上（别名入口）
├── 使用说明-Mac.md           # 本文件
├── VERSION                   # 版本号（勿删，启动横幅与报告会显示）
├── installer-mac.sh          # 安装逻辑（勿改）
├── uninstall-mac.sh          # 卸载逻辑（勿改）
├── 安装报告.txt              # 每次安装的结果报告（安装时自动生成）
├── cache/                   # 下载缓存（自动生成，可删）
└── logs/                    # 运行日志（排障发这个）
```
