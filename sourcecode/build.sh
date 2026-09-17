#!/bin/zsh
# ============================================================
# 统一打包脚本 —— 在 macOS 开发机上运行
# 用途：把 sourcecode/ 下双平台源码打成待分发 zip（输出到 Dist/），
#       zip 文件名与程序启动横幅统一显示 v1.x(yyyymmdd)。
# 版本规则：小版本号维护在 sourcecode/VERSION（每次修改发布 +1）；
#           日期取打包当天，组合成完整版本串 v1.x(yyyymmdd) 写入包内
#           VERSION 文件（main.ps1 / installer-mac.sh 启动时读取显示）。
# 用法：zsh build.sh            # 双平台全打
#       zsh build.sh win|mac    # 只打一个平台
# 产出：Dist/Windows/ClaudeCode安装器-Windows-v1.x(yyyymmdd).zip
#       Dist/Mac/ClaudeCode安装器-Mac-v1.x(yyyymmdd).zip
# 说明：用 Python zipfile 打包——自动置 EFS/UTF-8 标志位，Windows 解压
#       中文文件名不乱码（见 docs/问题备案.md #007）；打包后自动校验：
#       EFS 标志 / bat 为 CRLF / 逐文件 SHA256 与源一致。
# ============================================================
setopt KSH_ARRAYS
set -e

SRC_ROOT="$(cd "$(dirname "$0")" && pwd)"   # sourcecode/
PROJ_ROOT="$(cd "$SRC_ROOT/.." && pwd)"     # 项目根
DIST_DIR="$PROJ_ROOT/Dist"

VER="$(head -1 "$SRC_ROOT/VERSION" | tr -d '[:space:]')"
VER="${VER#v}"
STAMP="$(date +%Y%m%d)"
FULL="v${VER}(${STAMP})"
TARGET="${1:-all}"

echo "==== Claude Code 安装器打包 ===="
echo "版本：$FULL（维护于 sourcecode/VERSION）"

# ---------- 组装 staging 并打 zip ----------
# 参数：$1=平台(Windows/Mac)  $2=随包说明文档文件名
pack() {
  local plat="$1" docname="$2"
  local src="$SRC_ROOT/$plat"
  local zipname="ClaudeCode安装器-${plat}-${FULL}.zip"
  local top="ClaudeCode安装器-${plat}-${FULL}"
  local stage_root
  stage_root="$(mktemp -d)"
  local stage="$stage_root/$top"
  mkdir -p "$stage"

  # 复制源码，排除开发专用与运行产物
  rsync -a --exclude '.DS_Store' --exclude 'logs' --exclude 'cache' \
        --exclude '安装报告.txt' --exclude '问题反馈-安装日志-*.zip' \
        "$src/" "$stage/"
  if [ "$plat" = "Windows" ]; then
    rm -f "$stage/make-offline-bundle.sh"          # 离线包生成器是开发工具，不随包分发
    if [ -z "$(ls -A "$stage/payload" 2>/dev/null)" ]; then
      rm -rf "$stage/payload"                       # payload 为空（在线安装模式）不打入
    fi
  fi
  printf '%s\n' "$FULL" > "$stage/VERSION"          # 包内 VERSION：程序启动读取显示
  cp "$PROJ_ROOT/docs/$docname" "$stage/"

  mkdir -p "$DIST_DIR/$plat"
  local zippath="$DIST_DIR/$plat/$zipname"
  rm -f "$zippath"
  python3 - "$stage" "$zippath" "$top" <<'PYEOF'
import os, sys, zipfile, hashlib

stage, zippath, top = sys.argv[1], sys.argv[2], sys.argv[3]

# 打包（EFS/UTF-8 标志位由 Python zipfile 自动设置）
with zipfile.ZipFile(zippath, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            zf.write(full, '{0}/{1}'.format(top, os.path.relpath(full, stage)))

# 校验
with zipfile.ZipFile(zippath) as zf:
    infos = [i for i in zf.infolist() if not i.is_dir()]
    bad = [i.filename for i in infos if not (i.flag_bits & 0x800)]
    assert not bad, 'EFS 标志缺失: {0}'.format(bad)          # 中文文件名 Windows 解压乱码防线
    for i in infos:
        data = zf.read(i)
        if i.filename.lower().endswith('.bat'):
            assert b'\r\n' in data, 'bat 非 CRLF: {0}'.format(i.filename)
        src = os.path.join(stage, os.path.relpath(i.filename, top))
        assert hashlib.sha256(data).hexdigest() == \
               hashlib.sha256(open(src, 'rb').read()).hexdigest(), \
               'SHA256 不一致: {0}'.format(i.filename)
print('  [OK] {0}（{1} 个文件；EFS / CRLF / SHA256 校验通过）'.format(
    os.path.basename(zippath), len(infos)))
PYEOF

  rm -rf "$stage_root"
}

case "$TARGET" in
  win)  pack Windows "使用说明.md" ;;
  mac)  pack Mac     "使用说明-Mac.md" ;;
  all)  pack Windows "使用说明.md"
        pack Mac     "使用说明-Mac.md" ;;
  *)    echo "用法：zsh build.sh [win|mac|all]" >&2; exit 1 ;;
esac

echo ""
echo "==== 完成 ===="
ls -lh "$DIST_DIR/Windows/" "$DIST_DIR/Mac/" 2>/dev/null
echo "发布：把对应 zip 发给用户即可（解压后双击安装，包内自带使用说明与版本号）。"
