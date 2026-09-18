#!/bin/zsh
# ============================================================
# Claude Code 一键安装器（Mac 版）—— 版本号见同目录 VERSION 文件（v1.12 起）
# 策略与 Windows 版一致（问题备案 #001-#016 的经验全部继承）：
#   全程国内镜像 / 每步幂等（已装且版本达标直接用）/ 方案切换容错 /
#   错误中文提示 / 本地缓存包复用 / 安装报告
# 流程：环境检测 → Node(≥18) → Git/Python(检测) → Claude Code(≥2)
#      → 配置弹窗(osascript) → VS Code → 报告
# 入口：双击「安装ClaudeCode.command」
# 高级：zsh installer-mac.sh --skip-dialog   # 跳过配置弹窗（测试用）
# ============================================================

setopt KSH_ARRAYS  # zsh 数组下标从 0（兼容 bash 写法；另：macOS bash 3.2 有多字节变量插值丢字节 bug，故整体用 zsh，见问题备案 #018）
APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---- 版本号（与 Windows 统一维护在 sourcecode/VERSION，每次修改发布小版本 +1）----
# 打包时 build.sh 在包内写入完整格式 VERSION 文件（如 v1.12(20260917)，日期=打包日）。
# 读取顺序：包内 VERSION → 源码目录上级 VERSION（仅数字，开发态）→ 内置兜底。
VERSION="1.15"   # 纯数字版本（PATH 标记等内部用途，保持幂等），兜底值
_rawver=""
[ -f "$APP_ROOT/VERSION" ] && _rawver=$(head -1 "$APP_ROOT/VERSION" | tr -d '[:space:]')
[ -z "$_rawver" ] && [ -f "$APP_ROOT/../VERSION" ] && _rawver=$(head -1 "$APP_ROOT/../VERSION" | tr -d '[:space:]')
case "$_rawver" in
  v*\(*) VERSION="${_rawver#v}"; VERSION="${VERSION%%\(*}"; VERSION_SHOW="$_rawver" ;;
  v*)    VERSION="${_rawver#v}"; VERSION_SHOW="$_rawver" ;;
  ?*)    VERSION="$_rawver"; VERSION_SHOW="v$_rawver" ;;
esac
[ -n "$VERSION_SHOW" ] || VERSION_SHOW="v$VERSION"

LOG_DIR="$APP_ROOT/logs"; CACHE_DIR="$APP_ROOT/cache"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
NODE_VERSION="22.23.2"
NPM_MIRRORS=("https://registry.npmmirror.com" "https://mirrors.cloud.tencent.com/npm/")
INSTALL_BASE="$HOME/.claude-installer"
NODE_DIR="$INSTALL_BASE/nodejs"; NPM_GLOBAL="$INSTALL_BASE/npm-global"
PATH_MARK="# claude-code-installer (v$VERSION)"
mkdir -p "$LOG_DIR" "$CACHE_DIR" "$INSTALL_BASE"
exec 3>&1  # 保存 stdout 供 tee 之外的交互输出

log()  { echo "  $*" | tee -a "$LOG_FILE"; }
ok()   { echo "  [OK] $*" | tee -a "$LOG_FILE"; }
warn() { echo "  [注意] $*" | tee -a "$LOG_FILE"; }
fail() { echo "  [失败] $*" | tee -a "$LOG_FILE"; }
step() { echo "" | tee -a "$LOG_FILE"; echo "[ $* ]" | tee -a "$LOG_FILE"; }

# ---------- 进度动画（#020）：后台转圈，避免「以为死机」 ----------
SPINNER_PID=""
spinner_start() {
  [ -t 1 ] || return 0
  local msg="$1"
  zsh -c 'msg="$1"
    while :; do
      for f in "|" "/" "-" "\\"; do
        printf "\r  %s %s（%d 秒，请稍候）" "$f" "$msg" "$SECONDS"
        sleep 0.4
      done
    done' _ "$msg" &
  SPINNER_PID=$!
}
spinner_stop() {
  [ -n "$SPINNER_PID" ] && kill "$SPINNER_PID" 2>/dev/null
  SPINNER_PID=""
  printf "\r\033[K"
}

# ---------- 工具函数 ----------
major_of() { echo "$1" | sed -E 's/^v?([0-9]+).*/\1/'; }

download() {  # download <显示名> <输出文件> <url...>
  local name="$1" out="$2"; shift 2
  for url in "$@"; do
    for i in 1 2 3; do
      log "下载：$url（第 $i 次）"
      spinner_start "正在下载 $(basename "$out")"
      if curl -fsL --retry 2 -C - --connect-timeout 20 -o "$out.part" "$url" 2>>"$LOG_FILE"; then
        spinner_stop
        mv "$out.part" "$out"
        local size; size=$(du -h "$out" | cut -f1)
        ok "下载完成：$(basename "$out")（$size）"
        return 0
      else
        spinner_stop
      fi
      sleep $((i * 2))
    done
  done
  fail "[E-MAC-DL001] $name 所有镜像下载失败（详见 $LOG_FILE）"
  return 1
}

add_path_block() {  # 幂等追加 PATH 标记块到 zprofile/bash_profile
  local line="export PATH=\"$1:\$PATH\" $PATH_MARK"
  for f in "$HOME/.zprofile" "$HOME/.bash_profile"; do
    [ -f "$f" ] || touch "$f"
    grep -qF "$PATH_MARK" "$f" 2>/dev/null || echo "$line" >> "$f"
  done
  export PATH="$1:$PATH"
}

node_ok() {  # 环境中存在 ≥18 的 node
  local v=""
  command -v node >/dev/null 2>&1 && v="$(node -v 2>/dev/null)"
  [ -n "$v" ] && [ "$(major_of "$v")" -ge 18 ] && { log "检测到可用 Node $v（版本达标，跳过安装）"; return 0; }
  [ -x "$NODE_DIR/bin/node" ] && v="$("$NODE_DIR/bin/node" -v 2>/dev/null)" && [ "$(major_of "$v")" -ge 18 ] && return 0
  return 1
}

claude_ok() {  # 环境中存在 ≥2.0 的 claude
  local p=""; command -v claude >/dev/null 2>&1 && p="claude"
  [ -z "$p" ] && [ -x "$NPM_GLOBAL/bin/claude" ] && p="$NPM_GLOBAL/bin/claude"
  [ -z "$p" ] && return 1
  local v; v="$("$p" --version 2>/dev/null | head -1)"
  [ -n "$v" ] && [ "$(major_of "$v")" -ge 2 ] && { log "检测到可用 Claude Code（$v，跳过安装）"; return 0; }
  return 1
}

# ---------- 步骤 ----------
step1_env() {
  step "1/6 系统环境检查"
  [ "$(uname)" = "Darwin" ] || { fail "[E-MAC-SYS001] 本安装器仅支持 macOS"; exit 2; }
  MAC_ARCH="$(uname -m)"; DARWIN_PKG="darwin-arm64"
  [ "$MAC_ARCH" = "x86_64" ] && DARWIN_PKG="darwin-x64"
  ok "系统：macOS（$MAC_ARCH）"
  local free_gb; free_gb=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  if [ "${free_gb:-0}" -lt 2 ]; then fail "[E-MAC-SYS002] 磁盘空间不足（剩余 ${free_gb}GB，需 ≥2GB）"; exit 2; fi
  ok "磁盘：剩余 ${free_gb}GB"
  if curl -sI --max-time 8 "https://registry.npmmirror.com" -o /dev/null; then ok "网络：镜像可达"
  else fail "[E-MAC-NET001] 无法连接国内镜像，请检查网络后重跑"; exit 2; fi
}

step2_node() {
  step "2/6 安装 Node.js $NODE_VERSION（华为云镜像）"
  node_ok && { RESULT_NODE="跳过（已安装）"; return 0; }
  local tgz="$CACHE_DIR/node-v$NODE_VERSION-$DARWIN_PKG.tar.gz"
  download "Node.js" "$tgz" \
    "https://mirrors.huaweicloud.com/nodejs/v$NODE_VERSION/node-v$NODE_VERSION-$DARWIN_PKG.tar.gz" \
    "https://mirrors.aliyun.com/nodejs-release/v$NODE_VERSION/node-v$NODE_VERSION-$DARWIN_PKG.tar.gz" || return 1
  rm -rf "$NODE_DIR" "$CACHE_DIR/node-extract"; mkdir -p "$NODE_DIR" "$CACHE_DIR/node-extract"
  spinner_start "正在解压 Node.js（约 40MB）"
  tar -xzf "$tgz" -C "$CACHE_DIR/node-extract"; local tar_rc=$?
  spinner_stop
  [ $tar_rc -ne 0 ] && { fail "[E-MAC-NODE001] 解压失败"; return 1; }
  mv "$CACHE_DIR/node-extract/node-v$NODE_VERSION-$DARWIN_PKG/"* "$NODE_DIR/"
  rm -rf "$CACHE_DIR/node-extract"
  local v; v="$("$NODE_DIR/bin/node" -v 2>/dev/null)" || { fail "[E-MAC-NODE002] node 安装后无法运行"; return 1; }
  ok "Node.js $v 已就位（$NODE_DIR）"
  add_path_block "$NODE_DIR/bin"
  RESULT_NODE="成功（华为云 zip 免安装，$v）"
}

step3_devtools() {
  step "3/6 检查 Git / Python（macOS 通常自带）"
  if command -v git >/dev/null 2>&1; then ok "Git：$(git --version)（跳过）"; RESULT_GIT="跳过（系统自带）"
  else warn "未检测到 Git（可稍后执行：xcode-select --install 安装 Xcode 命令行工具）；不影响 Claude Code 使用"; RESULT_GIT="未安装（已提示）"; fi
  if command -v python3 >/dev/null 2>&1; then ok "Python：$(python3 --version 2>&1)（跳过）"; RESULT_PY="跳过（系统自带）"
  else warn "未检测到 python3（可稍后用 Homebrew 安装）；不影响 Claude Code 使用"; RESULT_PY="未安装（已提示）"; fi
}

step4_claude() {
  step "4/6 安装 Claude Code 本体"
  claude_ok && { RESULT_CLAUDE="跳过（已安装）"; return 0; }
  [ -x "$NODE_DIR/bin/npm" ] || { fail "[E-MAC-CC003] Node 未安装成功，无法继续"; return 1; }
  mkdir -p "$NPM_GLOBAL"

  # 方案 A/B：npm 双镜像
  local npm="$NODE_DIR/bin/npm"
  for reg in "${NPM_MIRRORS[@]}"; do
    log "npm 安装（源：$reg）"
    "$npm" config set registry "$reg" >/dev/null 2>&1
    "$npm" config set prefix "$NPM_GLOBAL" >/dev/null 2>&1
    spinner_start "npm 正在下载安装 Claude Code（可能需几分钟）"
    "$npm" install -g @anthropic-ai/claude-code --no-fund --no-audit --loglevel error >>"$LOG_FILE" 2>&1
    local npm_rc=$?
    spinner_stop
    if [ $npm_rc -eq 0 ]; then
      add_path_block "$NPM_GLOBAL/bin"
      local v; v="$("$NPM_GLOBAL/bin/claude" --version 2>/dev/null | head -1)"
      if [ -n "$v" ]; then ok "Claude Code 安装成功（$v）"; RESULT_CLAUDE="成功（npm，$v）"; return 0; fi
    fi
    warn "npm 源 $reg 失败，切换下一方案"
  done

  # 方案 C：手动 tgz（主包 + 平台包，复制真身；Windows 版 #013 的教训）
  log "切换手动安装方案（tgz）"
  local reg="${NPM_MIRRORS[0]}"
  local ver tball plat
  ver=$(curl -fs --max-time 20 "$reg/@anthropic-ai/claude-code/latest" | sed -E 's/.*"version":"([^"]+)".*/\1/' | head -1)
  [ -n "$ver" ] || { fail "[E-MAC-CC001] 获取版本信息失败"; return 1; }
  tball="$CACHE_DIR/claude-code-$ver.tgz"; plat="$CACHE_DIR/claude-code-$DARWIN_PKG-$ver.tgz"
  download "Claude Code 主包" "$tball" "$reg/@anthropic-ai/claude-code/-/claude-code-$ver.tgz" || return 1
  download "Claude Code 平台包" "$plat" "$reg/@anthropic-ai/claude-code-$DARWIN_PKG/-/claude-code-$DARWIN_PKG-$ver.tgz" || return 1
  local scope="$NPM_GLOBAL/lib/node_modules/@anthropic-ai"
  rm -rf "$scope/claude-code" "$scope/claude-code-$DARWIN_PKG"; mkdir -p "$scope/claude-code" "$scope/claude-code-$DARWIN_PKG" "$NPM_GLOBAL/bin"
  spinner_start "正在解压安装包（平台包约 380MB，请稍候）"
  tar -xzf "$tball" -C "$scope/claude-code" --strip-components=1
  tar -xzf "$plat" -C "$scope/claude-code-$DARWIN_PKG" --strip-components=1
  # 关键（#013）：主包里是占位 stub，必须用平台包的真身覆盖
  cp "$scope/claude-code-$DARWIN_PKG/claude" "$scope/claude-code/bin/claude" 2>/dev/null
  spinner_stop
  ln -sf "$scope/claude-code/bin/claude" "$NPM_GLOBAL/bin/claude"
  chmod +x "$NPM_GLOBAL/bin/claude"
  add_path_block "$NPM_GLOBAL/bin"
  local v; v="$("$NPM_GLOBAL/bin/claude" --version 2>/dev/null | head -1)"
  [ -n "$v" ] && { ok "Claude Code 安装成功（手动方案，$v）"; RESULT_CLAUDE="成功（tgz 手动，$v）"; return 0; }
  fail "[E-MAC-CC002] Claude Code 安装后无法运行"; return 1
}

# API 连接测试（#017 双端一致）：test_connection <base> <key> <model> → 0=可用
# 注意：[1m] 等后缀是 Claude Code 客户端的上下文标记，API 端点不识别，测试前需剥掉
test_connection() {
  local code
  local tmodel="${3%\[1m]}"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
    -X POST "$1/v1/messages" -H "Content-Type: application/json" \
    -H "x-api-key: $2" -H "Authorization: Bearer $2" -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"$tmodel\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null)
  [ "$code" = "200" ]
}


# 供应商获取 Key 指南（#021：官网 + 注册/支付/取 Key 流程）
provider_guide() {
  case "$1" in
    "GLM（智谱）") cat << 'GEOF'
【官网】https://open.bigmodel.cn（智谱 AI 开放平台）
【步骤】① 手机号注册并登录
　　　　② 控制台「财务中心」充值（预付费）；推荐了解「GLM Coding Plan」包月套餐（专为编程工具设计）
　　　　③ 「API Keys」页面创建并复制 Key
【计费】Coding Plan 包月 或 API 按量付费（新用户通常有赠送额度）
GEOF
    ;;
    "DeepSeek") cat << 'GEOF'
【官网】https://platform.deepseek.com（DeepSeek 开放平台）
【步骤】① 邮箱/手机号注册并登录
　　　　② 左侧「充值」完成付款——注意：预付费，新账户无免费额度，不充值无法调用（402 即此因）
　　　　③ 「API Keys」创建并复制 Key
【计费】按量计费（余额用尽会 402）
GEOF
    ;;
    *) echo "【说明】请向您的服务商获取 Anthropic 兼容接口地址（Base URL）、API Key 与模型名" ;;
  esac
}

# ---------- 按钮（#024）：实测当前已保存的模型配置（不重新填写/保存即可测） ----------
test_current_model() {
  local sf="$HOME/.claude/settings.json"
  local tok base model
  if [ -f "$sf" ]; then
    tok=$(python3 -c "import json; e=json.load(open('$sf')).get('env',{}); print(e.get('ANTHROPIC_AUTH_TOKEN',''))" 2>/dev/null)
    base=$(python3 -c "import json; e=json.load(open('$sf')).get('env',{}); print(e.get('ANTHROPIC_BASE_URL',''))" 2>/dev/null)
    model=$(python3 -c "import json; e=json.load(open('$sf')).get('env',{}); print(e.get('ANTHROPIC_MODEL',''))" 2>/dev/null)
  fi
  if [ -z "$tok" ] || [ -z "$base" ] || [ -z "$model" ]; then
    osascript -e 'display dialog "当前没有已保存的完整配置（缺少 Key / 接口地址 / 模型）。请先选择供应商完成一次配置。" buttons {"好"} default button 1 with title "测试当前模型"' >/dev/null 2>&1
    return 0
  fi
  log "实测当前模型配置（$base，模型 $model）……"
  if test_connection "$base" "$tok" "$model"; then
    osascript -e "display dialog \"连接成功！当前模型可用。接口：$base  模型：$model\" buttons {\"好\"} default button 1 with title \"测试当前模型\"" >/dev/null 2>&1
  else
    osascript -e "display dialog \"连接失败（Key 无效 / 余额不足 / 模型名错误等）。接口：$base  模型：$model。可返回重新配置。\" buttons {\"好\"} default button 1 with title \"测试当前模型\"" >/dev/null 2>&1
  fi
}

# ---------- 工具项（#024）：恢复官方默认（清除第三方配置，回官方模型/登录） ----------
reset_to_official() {
  local confirm
  confirm=$(osascript -e 'display dialog "将清除第三方供应商配置（API Key / 接口地址 / 模型映射），恢复为 Claude Code 官方默认。恢复后运行 claude 需按提示登录官方账号。现有配置会先自动备份。" buttons {"取消", "确认恢复"} default button 2 with title "恢复官方默认"' -e 'button returned of result' 2>/dev/null)
  [ "$confirm" = "确认恢复" ] || { warn "已取消恢复官方默认"; return 1; }
  # 与 Windows 端 Invoke-ResetConfig 同口径：固定 8 键 + 各供应商附加键；
  # 解析失败即中止（不清空文件），改动前自动备份 .bak；同时恢复官方登录引导
  python3 <<'PYEOF' >>"$LOG_FILE" 2>&1 || { fail "[E-MAC-CFG002] 恢复官方默认失败"; osascript -e 'display dialog "恢复失败：配置文件处理出错（详见日志）。" buttons {"好"} default button 1 with title "恢复官方默认"' >/dev/null 2>&1; return 1; }
import json, sys, pathlib, shutil
home = pathlib.Path.home()
keys = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "API_TIMEOUT_MS", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
sp = home / ".claude" / "settings.json"
if sp.exists():
    try: s = json.loads(sp.read_text(encoding="utf-8"))
    except Exception as e: print("settings.json 解析失败，中止：", e); sys.exit(1)
    env = s.get("env", {})
    if any(k in env for k in keys): shutil.copy2(sp, str(sp) + ".bak")
    for k in keys: env.pop(k, None)
    if env: s["env"] = env
    else: s.pop("env", None)
    sp.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
cj = home / ".claude.json"
if cj.exists():
    try: d = json.loads(cj.read_text(encoding="utf-8"))
    except Exception as e: print(".claude.json 解析失败，中止：", e); sys.exit(1)
    if "hasCompletedOnboarding" in d:
        shutil.copy2(cj, str(cj) + ".bak")
        d.pop("hasCompletedOnboarding")
        cj.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
print("reset done")
PYEOF
  ok "已恢复官方默认模型（Claude 官方）。运行 claude 后按提示登录官方账号即可"
  osascript -e 'display dialog "已恢复官方默认（Claude 官方）。运行 claude 后按提示登录官方账号即可。" buttons {"好"} default button 1 with title "恢复官方默认"' >/dev/null 2>&1
  RESULT_CFG="成功（已恢复官方默认）"
  return 0
}

step5_config() {
  step "5/6 配置大模型（API Key）"
  if claude_ok; then :; else warn "Claude Code 未安装成功，跳过配置"; RESULT_CFG="未执行"; return 0; fi

  # 已有配置自动验证（#017）：Key 已存在且实测可用 → 弹提示让用户选
  #   「保留现有」或「重新配置」（#026，不再静默跳过）
  # 例外（#023）：「重新配置APIKEY.command」单独调起（SKIP_CONFIG_ONLY=1）时
  #   强制弹窗——用户主动要求重配（换供应商/换 Key/换模型），跳过本验证
  local sf="$HOME/.claude/settings.json"
  if [ "$SKIP_CONFIG_ONLY" = "1" ]; then
    log "单独重配模式：跳过已有配置自动验证，直接弹出配置窗口"
  elif [ -f "$sf" ] && python3 -c "
import json, sys
try:
    e = json.load(open('$sf')).get('env', {})
    sys.exit(0 if e.get('ANTHROPIC_AUTH_TOKEN') and e.get('ANTHROPIC_BASE_URL') and e.get('ANTHROPIC_MODEL') else 1)
except Exception:
    sys.exit(1)" 2>/dev/null; then
    local ex_tok ex_base ex_model
    ex_tok=$(python3 -c "import json; e=json.load(open('$sf'))['env']; print(e['ANTHROPIC_AUTH_TOKEN'])" 2>/dev/null)
    ex_base=$(python3 -c "import json; e=json.load(open('$sf'))['env']; print(e['ANTHROPIC_BASE_URL'])" 2>/dev/null)
    ex_model=$(python3 -c "import json; e=json.load(open('$sf'))['env']; print(e['ANTHROPIC_MODEL'])" 2>/dev/null)
    log "检测到已有模型配置（$ex_base，模型 $ex_model），自动验证……"
    if test_connection "$ex_base" "$ex_tok" "$ex_model"; then
      # 有效配置已存在（#026）：询问保留还是重配（与 Windows 双端一致）
      local keep
      keep=$(osascript -e "display dialog \"检测到已保存的模型配置，且连接实测通过。\\n\\n接口地址：$ex_base\\n模型：$ex_model\\n\\n保留现有配置将跳过本步骤；选「重新配置」可更换供应商 / API Key / 模型。\" buttons {\"重新配置\", \"保留现有\"} default button \"保留现有\" with title \"已存在有效的 API Key 配置\"" -e 'button returned of result' 2>/dev/null)
      if [ "$keep" != "重新配置" ]; then
        ok "保留现有配置，跳过配置步骤"
        RESULT_CFG="跳过（已有配置验证通过，用户选择保留）"; return 0
      fi
      log "用户选择重新配置，继续弹出配置窗口"
    else
      warn "已有配置验证失败（Key 失效/余额不足等），将重新输入"
    fi
  fi

  [ "$SKIP_DIALOG" = "1" ] && { warn "已指定跳过配置弹窗"; RESULT_CFG="跳过（--skip-dialog）"; return 0; }

  # 供应商选择（#024）：下拉选择框 + 下方「测试当前模型」按钮（不再作为列表项）
  # choose from list 不支持自定义按钮，改用 NSAlert + NSPopUpButton 实现；
  # 组件异常时降级回普通列表（仅供应商，无工具按钮）
  local provider choice act idx
  while :; do
    # 返回格式：按钮代码|下拉选中序号（1000=继续 1001=测试当前模型 1002=恢复官方默认 1003=取消）
    # 注意：正文不得出现撇号（AppleScript 的 xxx's 写法）——老版 bash 3.2 解析
    # 「$() 内嵌 heredoc」时撇号会被误当引号导致整脚本语法错误，故全部改用 of/tell 语法
    choice=$(osascript 2>/dev/null <<'EOF'
use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

activate
set theAlert to init() of (alloc() of (NSAlert of current application))
tell theAlert
    its setMessageText:"Claude Code 模型配置"
    its setInformativeText:"请选择大模型供应商；可先点「测试当前模型」检查已保存配置是否可用"
    its addButtonWithTitle:"继续"
    its addButtonWithTitle:"测试当前模型"
    its addButtonWithTitle:"恢复官方默认"
    its addButtonWithTitle:"取消"
end tell
-- Esc 键绑定到「取消」
repeat with theBtn in ((buttons of theAlert) as list)
    if ((title of theBtn) as text) is "取消" then tell theBtn to setKeyEquivalent:(character id 27)
end repeat
set thePopup to init() of (alloc() of (NSPopUpButton of current application))
tell thePopup
    its setFrame:(NSMakeRect(0, 0, 340, 26) of current application)
    its addItemsWithTitles:{"DeepSeek", "GLM（智谱）", "自定义"}
end tell
tell theAlert
    its setAccessoryView:thePopup
end tell
set theResp to (runModal() of theAlert) as integer
set theIdx to (indexOfSelectedItem() of thePopup) as integer
return (theResp as text) & "|" & (theIdx as text)
EOF
)
    if [ -z "$choice" ]; then
      provider=$(osascript 2>/dev/null <<'EOF2'
choose from list {"DeepSeek", "GLM（智谱）", "自定义"} with prompt "请选择大模型供应商" with title "Claude Code 模型配置"
EOF2
) || { warn "已取消配置（可稍后运行「重新配置APIKEY.command」）"; RESULT_CFG="跳过（用户取消）"; return 0; }
      [ "$provider" = "false" ] && { warn "已取消配置"; RESULT_CFG="跳过（用户取消）"; return 0; }
      break
    fi
    act="${choice%%|*}"; idx="${choice##*|}"
    case "$act" in
      1001) test_current_model; continue ;;
      1002) reset_to_official && return 0; continue ;;
      1003) warn "已取消配置（可稍后运行「重新配置APIKEY.command」）"; RESULT_CFG="跳过（用户取消）"; return 0 ;;
    esac
    case "$idx" in
      0) provider="DeepSeek" ;;
      1) provider="GLM（智谱）" ;;
      *) provider="自定义" ;;
    esac
    break
  done

  # 获取 Key 指南（#021）：先展示官网与注册/支付/取 Key 流程，确认后继续
  # 多行文本需转义（引号加反斜杠、换行转 \n）才能安全传入 osascript
  local guide_text guide_esc
  guide_text=$(provider_guide "$provider")
  guide_esc=$(printf "%s" "$guide_text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | sed -e ':a' -e 'N;$!ba' -e 's/\n/\\n/g')
  osascript -e "display dialog \"${guide_esc}请先到官网完成注册与支付，拿到 API Key 后点「继续」。\" with title \"获取 API Key 指南（$provider）\" buttons {\"取消\", \"继续\"} default button 2" >/dev/null 2>&1 \
    || { warn "已取消（未保存）"; RESULT_CFG="跳过（用户取消）"; return 0; }

  local base="" models=() fast="" extra=""
  case "$provider" in
    "DeepSeek")       base="https://api.deepseek.com/anthropic"; models=("deepseek-v4-pro[1m]" "deepseek-v4-flash"); fast="deepseek-v4-flash" ;;
    "GLM（智谱）")    base="https://open.bigmodel.cn/api/anthropic"; models=("glm-4.7" "glm-5.2[1m]"); fast="glm-4.7"; extra="API_TIMEOUT_MS=3000000;CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" ;;
    *) base="CUSTOM" ;;
  esac

  local key
  key=$(osascript -e "display dialog \"请输入 $provider 的 API Key\" default answer \"\" with hidden answer buttons {\"取消\",\"确定\"} default button 2 with title \"Claude Code 模型配置\"" -e "text returned of result" 2>/dev/null) \
    || { warn "已取消"; RESULT_CFG="跳过（用户取消）"; return 0; }
  [ -z "$key" ] && { warn "Key 为空，已取消"; RESULT_CFG="跳过（Key 为空）"; return 0; }

  local model="$base"
  if [ "$base" = "CUSTOM" ]; then
    base=$(osascript -e 'display dialog "请输入自定义接口地址（Base URL）" default answer "" buttons {"取消","确定"} default button 2' -e 'text returned of result' 2>/dev/null) || return 0
    model=$(osascript -e 'display dialog "请输入模型名" default answer "" buttons {"取消","确定"} default button 2' -e 'text returned of result' 2>/dev/null) || return 0
    fast="$model"; [ -z "$model" ] && { warn "模型名为空，已取消"; return 0; }
  else
    model=$(osascript 2>/dev/null <<EOF
choose from list {"$(printf '%s","' "${models[@]}" | sed 's/","$//')"} with prompt "请选择模型（推荐项已列出，默认会优先使用第一项）" with title "Claude Code 模型配置"
EOF
) || { warn "已取消"; RESULT_CFG="跳过（用户取消）"; return 0; }
    [ "$model" = "false" ] && { warn "已取消"; RESULT_CFG="跳过（用户取消）"; return 0; }
    [ -z "$model" ] && model="${models[0]}"
  fi

  # 保存前自动测试（#017）：通过才写入；失败给「直接保存」逃生门
  log "正在自动测试连接（$base / $model）……"
  if ! test_connection "$base" "$key" "$model"; then
    local force
    force=$(osascript -e 'display dialog "连接测试未通过（Key 无效/余额不足/模型名错误等）。是否仍然直接保存？" buttons {"取消","直接保存"} default button 2 with title "Claude Code 模型配置"' -e 'button returned of result' 2>/dev/null)
    if [ "$force" != "直接保存" ]; then warn "已取消（未保存）"; RESULT_CFG="取消（测试未通过）"; return 0; fi
    warn "按用户要求跳过测试，直接保存"
  fi

  # python3 写配置（JSON 合并，保留用户已有内容）
  KEY="$key" BASE="$base" MODEL="$model" FAST="$fast" EXTRA="$extra" python3 <<'PYEOF' >>"$LOG_FILE" 2>&1 || { fail "[E-MAC-CFG001] 配置写入失败"; return 1; }
import json, os, pathlib
home = pathlib.Path.home(); cd = home / ".claude"; cd.mkdir(exist_ok=True)
sp = cd / "settings.json"
settings = {}
if sp.exists():
    try: settings = json.loads(sp.read_text(encoding="utf-8"))
    except Exception: settings = {}
env = settings.get("env", {})
env.update({"ANTHROPIC_AUTH_TOKEN": os.environ["KEY"], "ANTHROPIC_BASE_URL": os.environ["BASE"],
            "ANTHROPIC_MODEL": os.environ["MODEL"], "ANTHROPIC_DEFAULT_OPUS_MODEL": os.environ["MODEL"],
            "ANTHROPIC_DEFAULT_SONNET_MODEL": os.environ["MODEL"], "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ["FAST"],
            "CLAUDE_CODE_SUBAGENT_MODEL": os.environ["FAST"]})
extra = os.environ.get("EXTRA", "")
if "[1m]" in os.environ["MODEL"]: env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = "1000000"
for kv in extra.split(";"):
    if "=" in kv:
        k, v = kv.split("=", 1); env[k.strip()] = v.strip()
settings["env"] = env
sp.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")
cj = home / ".claude.json"
data = {}
if cj.exists():
    try: data = json.loads(cj.read_text(encoding="utf-8"))
    except Exception: data = {}
data["hasCompletedOnboarding"] = True
cj.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
cm = cd / "CLAUDE.md"
if not cm.exists():
    cm.write_text("# 全局配置\n\n## 语言\n\n- 始终使用中文回复，包括代码注释和 commit message\n", encoding="utf-8")
print("config written")
PYEOF
  ok "已配置：$provider（模型：$model）"
  RESULT_CFG="成功（$provider / $model）"
}

step6_vscode() {
  step "6/6 安装 VS Code（官方中国通道）"
  if command -v code >/dev/null 2>&1; then ok "VS Code 已安装（$(code --version 2>/dev/null | head -1)，跳过）"; RESULT_VSCODE="跳过（已安装）"; return 0; fi
  for app in "/Applications/Visual Studio Code.app" "$HOME/Applications/Visual Studio Code.app"; do
    if [ -d "$app" ]; then
      ok "VS Code 已安装（$app，补 PATH）"; add_path_block "$app/Contents/Resources/app/bin"
      local code_bin="$app/Contents/Resources/app/bin/code"
      if [ -x "$code_bin" ]; then
        spinner_start "正在安装 VS Code 扩展"
        "$code_bin" --install-extension anthropic.claude-code >>"$LOG_FILE" 2>&1; local ext_rc=$?
        spinner_stop
        if [ $ext_rc -eq 0 ]; then ok "Claude Code 扩展安装成功"; RESULT_EXT="成功"
        else warn "扩展安装未成功（可手动安装）"; RESULT_EXT="失败（可手动）"; fi
      fi
      RESULT_VSCODE="跳过（已安装）"; return 0
    fi
  done
  local api="https://update.code.visualstudio.com/api/update/$DARWIN_PKG/stable/latest"
  local meta url ver
  meta=$(curl -fs --max-time 20 "$api" 2>>"$LOG_FILE") || { warn "[E-MAC-VSC001] 官方版本信息获取失败，跳过 VS Code"; RESULT_VSCODE="失败（API 不可达）"; return 0; }
  url=$(echo "$meta" | sed -E 's/.*"url":"([^"]+)".*/\1/'); ver=$(echo "$meta" | sed -E 's/.*"productVersion":"([^"]+)".*/\1/')
  case "$url" in https://*) ;; *) warn "[E-MAC-VSC001] 元数据异常，跳过"; RESULT_VSCODE="失败"; return 0 ;; esac
  local zip="$CACHE_DIR/VSCode-$DARWIN_PKG-$ver.zip"
  download "VS Code $ver" "$zip" "$url" || { RESULT_VSCODE="失败（下载）"; return 0; }  # 失败不中断
  rm -rf "$CACHE_DIR/vscode-extract"; mkdir -p "$CACHE_DIR/vscode-extract" "$HOME/Applications"
  spinner_start "正在解压 VS Code（约 230MB）"
  unzip -q "$zip" -d "$CACHE_DIR/vscode-extract"; local uz=$?
  spinner_stop
  [ $uz -ne 0 ] && { warn "[E-MAC-VSC002] 解压失败"; RESULT_VSCODE="失败（解压）"; return 0; }
  rm -rf "$HOME/Applications/Visual Studio Code.app"
  mv "$CACHE_DIR/vscode-extract/Visual Studio Code.app" "$HOME/Applications/" && rm -rf "$CACHE_DIR/vscode-extract"
  add_path_block "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
  ok "VS Code $ver 已安装到 ~/Applications"
  RESULT_VSCODE="成功（官方中国通道，$ver）"

  # 尽力而为：安装 Claude Code 官方扩展（VS Code 官方市场；失败不影响）
  local code_bin="$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  [ -x "$code_bin" ] || code_bin="$(command -v code 2>/dev/null)"
  if [ -n "$code_bin" ] && [ -x "$code_bin" ]; then
    log "正在安装 Claude Code 的 VS Code 扩展（官方市场，失败不影响）……"
    spinner_start "正在安装 VS Code 扩展"
    "$code_bin" --install-extension anthropic.claude-code >>"$LOG_FILE" 2>&1
    local ext_rc=$?
    spinner_stop
    if [ $ext_rc -eq 0 ]; then ok "Claude Code 扩展安装成功"; RESULT_EXT="成功"
    else warn "扩展安装未成功（可稍后在 VS Code 扩展面板手动安装）"; RESULT_EXT="失败（可手动）"; fi
  fi
}

model_connection_test() {  # #020：有配置时实测，结果进报告
  RESULT_CONN="未配置（双击「重新配置APIKEY.command」可补配）"
  local sf="$HOME/.claude/settings.json"
  [ -f "$sf" ] || return 0
  python3 -c "
import json, sys
try:
    e = json.load(open('$sf')).get('env', {})
    sys.exit(0 if e.get('ANTHROPIC_AUTH_TOKEN') and e.get('ANTHROPIC_BASE_URL') else 1)
except Exception: sys.exit(1)" 2>/dev/null || return 0
  local tok base model
  tok=$(python3 -c "import json; print(json.load(open('$sf'))['env']['ANTHROPIC_AUTH_TOKEN'])" 2>/dev/null)
  base=$(python3 -c "import json; print(json.load(open('$sf'))['env']['ANTHROPIC_BASE_URL'])" 2>/dev/null)
  model=$(python3 -c "import json; print(json.load(open('$sf'))['env']['ANTHROPIC_MODEL'])" 2>/dev/null)
  log "正在实测模型连接（发送 1 条测试请求）……"
  if test_connection "$base" "$tok" "$model"; then RESULT_CONN="通过（$base，模型 $model）"
  else RESULT_CONN="失败（$base，模型 $model；请用「重新配置APIKEY.command」重新配置）"; fi
}

write_report() {
  local report="$APP_ROOT/安装报告.txt"
  {
    echo "=============================================="
    echo "        Claude Code 安装报告（Mac 版 $VERSION_SHOW）"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
    echo ""
    echo "【遇到问题？把本文件和 logs 文件夹发给开发者】"
    echo "  邮箱：cdingstar@outlook.com    微信：cdingstar"
    echo "  （更简单：把本文件夹里的「问题反馈-安装日志-*.zip」发过去即可）"
    echo ""
    echo "【环境】macOS（$MAC_ARCH），用户：$(whoami)，日志：$LOG_FILE"
    echo ""
    echo "【安装明细】"
    echo "  Node.js:     ${RESULT_NODE:-未执行}"
    echo "  Git:         ${RESULT_GIT:-未执行}"
    echo "  Python:      ${RESULT_PY:-未执行}"
    echo "  Claude Code: ${RESULT_CLAUDE:-未执行}"
    echo "  模型配置:    ${RESULT_CFG:-未执行}"
    echo "  VS Code:     ${RESULT_VSCODE:-未执行}"
    echo "  VS Code 扩展: ${RESULT_EXT:-未尝试}"
    echo ""
    echo "【模型连接实测】"
    echo "  ${RESULT_CONN:-未测试}"
    echo ""
    echo "【安装位置（卸载时删除这些即可）】"
    echo "  Node: $NODE_DIR"
    echo "  Claude Code: $NPM_GLOBAL"
    echo "  VS Code: ~/Applications/Visual Studio Code.app"
    echo "  配置: ~/.claude/"
    echo ""
    echo "【开始使用】打开「终端」，输入 claude 回车"
  } > "$report"
  ok "安装报告：$report"

  # 一键反馈包（#022）：报告 + 全部日志打成一个 zip
  local fz="问题反馈-安装日志-$(date +%Y%m%d-%H%M%S).zip"
  if zip -j -q "$APP_ROOT/$fz" "$report" "$LOG_DIR"/*.log 2>/dev/null; then
    ok "已生成问题反馈包（遇到问题把它发给开发者即可）：$fz"
  fi
}

# ---------- 主流程 ----------
SKIP_DIALOG=0
case "${1:-}" in
  --skip-dialog) SKIP_DIALOG=1 ;;
  config-only)
    # 单独重新配置模型（「重新配置APIKEY.command」调起）：只跑配置步骤
    echo "==============================================" | tee -a "$LOG_FILE"
    echo "  Claude Code API Key / 模型配置（Mac 版 $VERSION_SHOW）" | tee -a "$LOG_FILE"
    echo "==============================================" | tee -a "$LOG_FILE"
    step5_config
    exit 0
    ;;
esac

echo "==============================================" | tee -a "$LOG_FILE"
echo "  Claude Code 一键安装器 Mac 版 $VERSION_SHOW" | tee -a "$LOG_FILE"
echo "  （全程国内镜像 · 日志：$LOG_FILE）" | tee -a "$LOG_FILE"
echo "==============================================" | tee -a "$LOG_FILE"

step1_env
step2_node  || warn "Node 未完成（修复后重跑本安装器可续装）"
step3_devtools
step4_claude || warn "Claude Code 未完成（修复后重跑可续装）"
step5_config
step6_vscode
model_connection_test
write_report

echo "" | tee -a "$LOG_FILE"
ok "流程结束。打开「终端」输入 claude 开始使用（新终端生效 PATH）"

# 反馈帮助（#022）：有失败步骤时醒目提示 + Finder 定位反馈包 + 预开邮件草稿
if grep -q "失败" 安装报告.txt 2>/dev/null; then
  echo "======================================================" | tee -a "$LOG_FILE"
  warn "遇到问题？把反馈包发给开发者："
  echo "  邮箱：cdingstar@outlook.com    微信：cdingstar" | tee -a "$LOG_FILE"
  fbz=$(ls -t "$APP_ROOT"/问题反馈-安装日志-*.zip 2>/dev/null | head -1)
  if [ -n "$fbz" ]; then
    echo "  反馈文件：$(basename "$fbz")（已在 Finder 中定位）" | tee -a "$LOG_FILE"
    open -R "$fbz" 2>/dev/null
  fi
  echo "======================================================" | tee -a "$LOG_FILE"
  open "mailto:cdingstar@outlook.com?subject=Claude%20Code%20%E5%AE%89%E8%A3%85%E5%99%A8%E9%97%AE%E9%A2%98%E5%8F%8D%E9%A6%88%EF%BC%88Mac%20$VERSION_SHOW%EF%BC%89" 2>/dev/null
else
  echo "  以后遇到任何问题：把本文件夹里的「问题反馈-安装日志-*.zip」发给开发者" | tee -a "$LOG_FILE"
  echo "  —— 邮箱 cdingstar@outlook.com / 微信 cdingstar" | tee -a "$LOG_FILE"
fi
exit 0
