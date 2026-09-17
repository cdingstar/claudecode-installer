#!/bin/zsh
# ============================================================
# Claude Code 卸载工具（Mac 版）—— 版本号见同目录 VERSION 文件（v1.12 起）
# 语义（v1.15 起收窄）：只卸载 Claude Code 本体——
#      npm 全局包 @anthropic-ai/claude-code + claude 命令；
#      另尽力卸载 VS Code 里的 Claude Code 扩展（不动 VS Code 本体）
# 安全边界：Node.js / VS Code 等其他组件一律保留；
#      终端 PATH 与 ~/.npmrc 不动（npm 全局目录仍在用）
# 个人数据（~/.claude 配置、聊天记录、API Key）默认保留，
#      确认后输入 D 才删除
# 异常处理：
#   · 中断：随时 Ctrl+C / 关终端；每步操作前先写日志，中断后重新双击
#          本工具可续跑（幂等）；中断也会生成标注「被中断」的卸载报告；
#          中断残留的临时文件在下次启动时自动清理
#   · 重试：删除失败自动重试 3 次（指数退避）；权限类错误不重试，
#          直接打印可复制的 sudo 处理命令
#   · 权限：Permission denied → 给出「sudo rm -rf 路径」具体命令
# 入口：双击「卸载ClaudeCode.command」
# ============================================================

setopt KSH_ARRAYS  # 与 installer-mac.sh 一致：zsh 数组下标从 0
APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---- 版本号（与 installer-mac.sh 同源：包内 VERSION → 上级 VERSION → 兜底）----
VERSION="1.15"
_rawver=""
[ -f "$APP_ROOT/VERSION" ] && _rawver=$(head -1 "$APP_ROOT/VERSION" | tr -d '[:space:]')
[ -z "$_rawver" ] && [ -f "$APP_ROOT/../VERSION" ] && _rawver=$(head -1 "$APP_ROOT/../VERSION" | tr -d '[:space:]')
case "$_rawver" in
  v*\(*) VERSION="${_rawver#v}"; VERSION="${VERSION%%\(*}"; VERSION_SHOW="$_rawver" ;;
  v*)    VERSION="${_rawver#v}"; VERSION_SHOW="$_rawver" ;;
  ?*)    VERSION="$_rawver"; VERSION_SHOW="v$_rawver" ;;
esac
[ -n "$VERSION_SHOW" ] || VERSION_SHOW="v$VERSION"
INSTALL_BASE="$HOME/.claude-installer"
NODE_DIR="$INSTALL_BASE/nodejs"; NPM_GLOBAL="$INSTALL_BASE/npm-global"
CLAUDE_PKG_DIR="$NPM_GLOBAL/lib/node_modules/@anthropic-ai"
VSCODE_APP="$HOME/Applications/Visual Studio Code.app"

# ---- 日志初始化（安装器目录不可写时退回 /tmp，保证任何环境都有日志）----
init_log() {
  LOG_DIR="$APP_ROOT/logs"
  if mkdir -p "$LOG_DIR" 2>/dev/null && [ -w "$LOG_DIR" ]; then
    LOG_FILE="$LOG_DIR/uninstall-$(date +%Y%m%d-%H%M%S).log"
  else
    LOG_FILE="/tmp/claude-uninstall-$(date +%Y%m%d-%H%M%S).log"
    LOG_FILE_FALLBACK_NOTICE=1
  fi
  : > "$LOG_FILE" 2>/dev/null || LOG_FILE=""
  echo "==== Claude Code 卸载日志 开始 $(date '+%Y-%m-%d %H:%M:%S') ====" >> "$LOG_FILE" 2>/dev/null
}
init_log

log()  { echo "  $*" | tee -a "$LOG_FILE" 2>/dev/null; }
ok()   { echo "  [OK] $*" | tee -a "$LOG_FILE" 2>/dev/null; }
warn() { echo "  [注意] $*" | tee -a "$LOG_FILE" 2>/dev/null; }
fail() { echo "  [失败] $*" | tee -a "$LOG_FILE" 2>/dev/null; }
step() { echo "" | tee -a "$LOG_FILE" 2>/dev/null; echo "[ $* ]" | tee -a "$LOG_FILE" 2>/dev/null; }

# ---- 运行状态（供日志 / 报告 / 中断兜底使用）----
RUN_STATUS="未开始"   # 未开始 → 进行中 → 完成 / 已取消 / 异常 / 被中断
FAILED=0
RESULT_LINES=()
START_TS=$(date +%s)

add_result() {  # add_result <组件名> <状态>；失败自动计数并写日志
  RESULT_LINES+=("  $1: $2")
  echo "  [日志] 结果：$1 → $2" >> "$LOG_FILE" 2>/dev/null
  case "$2" in 失败*) FAILED=$((FAILED + 1)) ;; esac
}

# 生成卸载报告（正常完成 / 被中断 / 异常都会调用，报告里标注运行状态）
write_report() {
  local elapsed=$(( $(date +%s) - START_TS ))
  local report="$APP_ROOT/卸载报告.txt"
  local tmp="$report.try"
  if { echo "=============================================="
       echo "        Claude Code 卸载报告（Mac 版 $VERSION_SHOW）"
       echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')（耗时 ${elapsed} 秒）"
       echo "=============================================="
       echo ""
       echo "【运行状态】$RUN_STATUS"
       case "$RUN_STATUS" in
         被中断|异常)
           echo "  本次未完成：重新双击「卸载ClaudeCode.command」会继续剩余部分（已完成的不会重来）"
           echo "  中断位置见日志中的最后一条「开始删除 / 步骤」记录" ;;
       esac
       echo ""
       echo "【卸载明细】"
       if [ ${#RESULT_LINES[@]} -gt 0 ]; then
         for l in "${RESULT_LINES[@]}"; do echo "$l"; done
       else
         echo "  （尚未执行到删除步骤）"
       fi
       echo ""
       echo "【日志】"
       echo "  ${LOG_FILE:-（日志创建失败）}"
       echo ""
       echo "【安全边界】只卸载了 Claude Code 本体；"
       echo "          Node.js / VS Code 等其他组件、终端 PATH 与 npm 配置均未改动。"
       echo ""
       echo "【重新安装】随时重新双击「安装ClaudeCode.command」即可重装。"
       echo "【遇到问题】把「卸载报告.txt」和 logs 文件夹发给开发者："
       echo "          邮箱 cdingstar@outlook.com / 微信 cdingstar"
     } > "$tmp" 2>>"$LOG_FILE"; then
    mv -f "$tmp" "$report" && ok "卸载报告：$report"
  else
    rm -f "$tmp" 2>/dev/null
    warn "卸载报告写入失败（目录无写权限？）：$report"
  fi
}

# ---- 中断处理：Ctrl+C / 关终端 / 系统信号 ----
# zsh 会在当前前台命令结束后执行 trap：写日志、出报告、清理临时文件再退出
# （v1.15 起不再改写 profile / .npmrc，此处仅清历史版本中断残留的临时文件）
cleanup_tmp_files() {
  rm -f "$HOME/.npmrc.uninstall-tmp" \
        "$HOME/.zprofile.uninstall-tmp" "$HOME/.bash_profile.uninstall-tmp" \
        "$APP_ROOT/卸载报告.txt.try" 2>/dev/null
}
on_interrupt() {
  echo "" | tee -a "$LOG_FILE" 2>/dev/null
  warn "已中断。已删除的部分不会恢复；重新双击「卸载ClaudeCode.command」会继续完成剩余部分"
  [ "$RUN_STATUS" = "进行中" ] && RUN_STATUS="被中断"
  [ "$RUN_STATUS" = "未开始" ] && RUN_STATUS="已取消（开始前中断）"
  write_report
  echo "  进程结束（收到中断信号，运行状态：$RUN_STATUS）" >> "$LOG_FILE" 2>/dev/null
  cleanup_tmp_files
  exit 130
}
trap on_interrupt INT TERM HUP

# ---- 删除（带重试与异常分类）----
# remove_safely <路径> <显示名>：
#   · 最多尝试 3 次，每次间隔递增（2/4 秒）
#   · Permission denied → 不重试，打印可复制的 sudo 命令
#   · 其他失败（文件被占用等）→ 重试，最终失败给出处理建议
remove_safely() {
  [ -e "$1" ] || return 0
  local attempt rc err
  echo "  [日志] 开始删除：$1" >> "$LOG_FILE" 2>/dev/null
  for attempt in 1 2 3; do
    err=$(rm -rf "$1" 2>&1); rc=$?
    if [ $rc -eq 0 ] && [ ! -e "$1" ]; then ok "已删除：$1"; return 0; fi
    echo "  [日志] 删除失败（第 $attempt/3 次，退出码 $rc）：$1 —— $err" >> "$LOG_FILE" 2>/dev/null
    case "$err" in
      *"Permission denied"*|*"Operation not permitted"*)
        fail "$2 权限不足，无法删除：$1"
        warn "处理办法：打开「终端」，执行下面这行命令后回车（需输入开机密码，输入时不显示）："
        echo "    sudo rm -rf \"$1\"" | tee -a "$LOG_FILE" 2>/dev/null
        return 1 ;;
    esac
    if [ $attempt -lt 3 ]; then
      log "  文件可能被占用，$((attempt * 2)) 秒后自动重试（还可重试 $((3 - attempt)) 次）……"
      sleep $((attempt * 2))
    fi
  done
  fail "$2 自动重试 3 次后仍删除失败：$1"
  warn "处理办法：关闭所有相关程序（或重启电脑）后重新双击「卸载ClaudeCode.command」；也可手动删除该文件夹"
  return 1
}

# 清理上次被中断的运行残留的临时文件
cleanup_stale_tmp() {
  local f
  for f in "$HOME/.npmrc.uninstall-tmp" "$HOME/.zprofile.uninstall-tmp" "$HOME/.bash_profile.uninstall-tmp"; do
    if [ -f "$f" ]; then
      rm -f "$f"
      warn "已清理上次中断残留的临时文件：$f"
    fi
  done
}

# ---------- 1. 扫描 ----------
echo "==============================================" | tee -a "$LOG_FILE" 2>/dev/null
echo "  Claude Code 卸载工具 Mac 版 $VERSION_SHOW" | tee -a "$LOG_FILE" 2>/dev/null
[ -n "$LOG_FILE_FALLBACK_NOTICE" ] && echo "  [注意] 安装器目录无写权限，日志改存：$LOG_FILE" | tee -a "$LOG_FILE" 2>/dev/null
[ -n "$LOG_FILE" ] && echo "  （日志：$LOG_FILE）" | tee -a "$LOG_FILE" 2>/dev/null
echo "==============================================" | tee -a "$LOG_FILE" 2>/dev/null
log "卸载过程中随时可按 Ctrl+C 中断；中断后重新双击本工具会继续完成剩余部分"
cleanup_stale_tmp

step "1/3 检查已安装组件"
FOUND_CLAUDE=0; { [ -x "$NPM_GLOBAL/bin/claude" ] || [ -d "$CLAUDE_PKG_DIR" ]; } && FOUND_CLAUDE=1
FOUND_VSCODE=0; [ -x "$VSCODE_APP/Contents/Resources/app/bin/code" ] && FOUND_VSCODE=1
FOUND_DATA=0; { [ -d "$HOME/.claude" ] || [ -f "$HOME/.claude.json" ]; } && FOUND_DATA=1
echo "  [日志] 扫描结果：Claude=$FOUND_CLAUDE VSCode(仅扩展卸载用)=$FOUND_VSCODE 个人数据=$FOUND_DATA" >> "$LOG_FILE" 2>/dev/null

show() { if [ "$1" = "1" ]; then echo "  [发现] $2" | tee -a "$LOG_FILE" 2>/dev/null; else echo "  [未安装] $2" | tee -a "$LOG_FILE" 2>/dev/null; fi }
show $FOUND_CLAUDE "Claude Code：$CLAUDE_PKG_DIR"
[ "$FOUND_VSCODE" = "1" ] && echo "  [发现] VS Code 已安装（将只卸载其中的 Claude Code 扩展，VS Code 本体保留）" | tee -a "$LOG_FILE" 2>/dev/null
[ "$FOUND_DATA" = "1" ] && echo "  [发现] 个人数据：$HOME/.claude（默认保留）" | tee -a "$LOG_FILE" 2>/dev/null
echo "  [说明] 本工具只卸载 Claude Code 本体；Node.js / VS Code 等其他组件不会被卸载" | tee -a "$LOG_FILE" 2>/dev/null

if [ "$FOUND_CLAUDE" = "0" ] && [ "$FOUND_DATA" = "0" ]; then
  ok "未发现 Claude Code 或其数据，无需卸载"
  RUN_STATUS="完成"
  echo "  [日志] ==== 卸载日志 结束（运行状态：$RUN_STATUS）====" >> "$LOG_FILE" 2>/dev/null
  exit 0
fi

# ---------- 2. 确认 ----------
step "2/3 确认卸载"
if [ "$FOUND_CLAUDE" = "1" ]; then
  warn "请先保存并关闭：正在运行的 claude 会话和终端窗口"
  printf "  关闭后按回车继续（想取消请按 Ctrl+C 或直接关掉本窗口）……"
  read dummy
  echo "" | tee -a "$LOG_FILE" 2>/dev/null
  echo "  [日志] 用户已确认程序关闭，继续" >> "$LOG_FILE" 2>/dev/null
  echo "  即将删除以下内容（个人数据除外）：" | tee -a "$LOG_FILE" 2>/dev/null
  echo "    Claude Code 本体：$CLAUDE_PKG_DIR 与 claude 命令（$NPM_GLOBAL/bin/claude）" | tee -a "$LOG_FILE" 2>/dev/null
  [ "$FOUND_VSCODE" = "1" ] && echo "    VS Code 里的 Claude Code 扩展（尽力而为，VS Code 本体与设置不动）" | tee -a "$LOG_FILE" 2>/dev/null
  echo "  不会卸载 / 不会改动：Node.js、VS Code 本体、终端 PATH、~/.npmrc" | tee -a "$LOG_FILE" 2>/dev/null
  log "执行过程中随时可按 Ctrl+C 中断；已删除的部分不会恢复，中断后重跑本工具会继续"
  printf "  确认卸载请输入 Y（回车或其他任意键取消）："
  read confirm
  case "$confirm" in
    [Yy]) echo "  [日志] 用户输入 Y，确认卸载" >> "$LOG_FILE" 2>/dev/null ;;
    *) echo "" | tee -a "$LOG_FILE" 2>/dev/null
       RUN_STATUS="已取消"
       echo "  已取消，未做任何改动" | tee -a "$LOG_FILE" 2>/dev/null
       echo "  [日志] ==== 卸载日志 结束（运行状态：$RUN_STATUS）====" >> "$LOG_FILE" 2>/dev/null
       exit 0 ;;
  esac
fi

WIPE_DATA=""
if [ "$FOUND_DATA" = "1" ]; then
  echo "" | tee -a "$LOG_FILE" 2>/dev/null
  echo "  个人数据包括：" | tee -a "$LOG_FILE" 2>/dev/null
  echo "    $HOME/.claude（配置、聊天记录、全局指令、API Key）" | tee -a "$LOG_FILE" 2>/dev/null
  echo "    $HOME/.claude.json" | tee -a "$LOG_FILE" 2>/dev/null
  printf "  要彻底清空请输入 D，回车保留（推荐：重装后免重新配置）："
  read WIPE_DATA
  if [[ "$WIPE_DATA" =~ ^[Dd]$ ]]; then
    echo "  [日志] 个人数据处理选择：D（删除）" >> "$LOG_FILE" 2>/dev/null
  else
    echo "  [日志] 个人数据处理选择：保留" >> "$LOG_FILE" 2>/dev/null
  fi
fi

# ---------- 3. 执行 ----------
step "3/3 执行卸载"
RUN_STATUS="进行中"

if [ "$FOUND_CLAUDE" = "1" ]; then
  # 优先 npm 正规卸载（Node.js 保留未动，npm 一直可用）
  npm_cmd="$NODE_DIR/bin/npm"
  if [ -x "$npm_cmd" ] && [ -d "$CLAUDE_PKG_DIR/claude-code" ]; then
    log "正在通过 npm 卸载 Claude Code……"
    "$npm_cmd" uninstall -g '@anthropic-ai/claude-code' >>"$LOG_FILE" 2>&1
    echo "  [日志] npm uninstall 命令已执行（退出码 $?）" >> "$LOG_FILE" 2>/dev/null
  fi
  # 手动兜底：npm 卸载后仍可能残留的包目录 / 平台包 / claude 命令
  c_ok=1
  if [ -d "$CLAUDE_PKG_DIR/claude-code" ]; then
    remove_safely "$CLAUDE_PKG_DIR/claude-code" "Claude Code 包目录" || c_ok=0
  fi
  if [ -d "$CLAUDE_PKG_DIR" ]; then
    remove_safely "$CLAUDE_PKG_DIR/claude-code-darwin-arm64" "Claude Code 平台包" || c_ok=0
    remove_safely "$CLAUDE_PKG_DIR/claude-code-darwin-x64" "Claude Code 平台包" || c_ok=0
    # 空壳清理：@anthropic-ai 下已无内容时一并删除（避免留下空目录）
    if [ -d "$CLAUDE_PKG_DIR" ] && [ -z "$(ls -A "$CLAUDE_PKG_DIR" 2>/dev/null)" ]; then
      remove_safely "$CLAUDE_PKG_DIR" "@anthropic-ai 空目录" || c_ok=0
    fi
  fi
  remove_safely "$NPM_GLOBAL/bin/claude" "claude 命令" || c_ok=0
  if [ "$c_ok" = "1" ]; then add_result "Claude Code" "成功（$CLAUDE_PKG_DIR + claude 命令）"; else add_result "Claude Code" "失败（见日志）"; fi
fi

# VS Code 的 Claude Code 扩展（尽力而为，失败不影响；不退出 VS Code、不动其本体）
if [ "$FOUND_VSCODE" = "1" ]; then
  code_bin="$VSCODE_APP/Contents/Resources/app/bin/code"
  if [ -x "$code_bin" ]; then
    log "正在卸载 VS Code 的 Claude Code 扩展（尽力而为）……"
    "$code_bin" --uninstall-extension anthropic.claude-code >>"$LOG_FILE" 2>&1
    echo "  [日志] VS Code 扩展卸载命令已执行（退出码 $?）" >> "$LOG_FILE" 2>/dev/null
  fi
fi

# 个人数据（仅在用户输入 D 时删除）
if [ "$FOUND_DATA" = "1" ]; then
  if [[ "$WIPE_DATA" =~ ^[Dd]$ ]]; then
    d_ok=1
    remove_safely "$HOME/.claude" "Claude 配置" || d_ok=0
    remove_safely "$HOME/.claude.json" ".claude.json" || d_ok=0
    if [ "$d_ok" = "1" ]; then add_result "个人数据" "成功（已彻底删除）"; else add_result "个人数据" "失败（见日志）"; fi
  else
    add_result "个人数据" "已保留（含配置 / 聊天记录 / API Key）"
  fi
fi

# ---------- 4. 报告 ----------
RUN_STATUS="完成"
echo "  [日志] 执行阶段完成，耗时 $(( $(date +%s) - START_TS )) 秒" >> "$LOG_FILE" 2>/dev/null
write_report

echo "" | tee -a "$LOG_FILE" 2>/dev/null
echo "==============================================" | tee -a "$LOG_FILE" 2>/dev/null
if [ "$FAILED" = "0" ]; then
  ok "全部完成。Claude Code 已卸载（Node.js / VS Code 等其他组件未动）"
else
  warn "有 $FAILED 项未完全删除：按上面的处理办法操作后，重新双击「卸载ClaudeCode.command」再跑一次即可"
fi
echo "  [日志] ==== 卸载日志 结束（运行状态：$RUN_STATUS，退出码 $((FAILED == 0 ? 0 : 1))）====" >> "$LOG_FILE" 2>/dev/null
exit $((FAILED == 0 ? 0 : 1))
