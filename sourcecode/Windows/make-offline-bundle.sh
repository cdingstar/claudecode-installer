#!/usr/bin/env bash
# ============================================================
# 离线包生成器 —— 在有网的电脑（macOS/Linux/带 curl 的 Windows）上运行
# 用途：把全部安装包预先下载到 payload/，随安装器一起分发。
#       目标电脑即使无网也能装（安装器优先使用本地离线包）。
# 用法：bash make-offline-bundle.sh
# 产出：payload/*.zip|exe|7z.exe|tgz + payload/SHA256SUMS.txt
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"
PAYLOAD_DIR="payload"
mkdir -p "$PAYLOAD_DIR"

NODE_VERSION="22.23.2"
GIT_VERSION="2.55.0.5"
GIT_TAG="v2.55.0.windows.5"
PYTHON_VERSION="3.12.10"

# 下载函数：带重试（3 次）+ 断点续传
fetch() {
  local url="$1" out="$2" tries=0
  if [[ -s "$out" ]]; then
    echo "  [跳过] 已存在 $(basename "$out")"
    return 0
  fi
  while (( tries < 3 )); do
    tries=$((tries + 1))
    echo "  [下载] 第 ${tries} 次：$url"
    if curl -fL --retry 3 -C - --connect-timeout 20 -o "$out.part" "$url"; then
      mv "$out.part" "$out"
      return 0
    fi
    sleep $((tries * 2))
  done
  echo "  [失败] $url" >&2
  return 1
}

echo "==== Claude Code 安装器离线包生成 ===="

echo "[1/5] Node.js v${NODE_VERSION}（阿里云镜像）"
fetch "https://mirrors.aliyun.com/nodejs-release/v${NODE_VERSION}/node-v${NODE_VERSION}-win-x64.zip" \
      "$PAYLOAD_DIR/node-v${NODE_VERSION}-win-x64.zip"

echo "[2/5] Git for Windows ${GIT_VERSION}（华为云镜像，Portable 免安装版）"
fetch "https://mirrors.huaweicloud.com/git-for-windows/${GIT_TAG}/PortableGit-${GIT_VERSION}-64-bit.7z.exe" \
      "$PAYLOAD_DIR/PortableGit-${GIT_VERSION}-64-bit.7z.exe"

echo "[3/5] Python ${PYTHON_VERSION}（华为云镜像）"
fetch "https://mirrors.huaweicloud.com/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-amd64.exe" \
      "$PAYLOAD_DIR/python-${PYTHON_VERSION}-amd64.exe"

echo "[4/5] Claude Code（npmmirror 镜像，主包 + win32-x64 平台包）"
CC_VER=$(curl -fsSL "https://registry.npmmirror.com/@anthropic-ai/claude-code/latest" | grep -oE '"version":"[^"]+"' | head -1 | cut -d'"' -f4)
if [[ -z "$CC_VER" ]]; then
  echo "  [失败] 无法获取 Claude Code 最新版本号" >&2
  exit 1
fi
echo "  版本：$CC_VER"
fetch "https://registry.npmmirror.com/@anthropic-ai/claude-code/-/claude-code-${CC_VER}.tgz" \
      "$PAYLOAD_DIR/claude-code-${CC_VER}.tgz"
fetch "https://registry.npmmirror.com/@anthropic-ai/claude-code-win32-x64/-/claude-code-win32-x64-${CC_VER}.tgz" \
      "$PAYLOAD_DIR/claude-code-win32-x64-${CC_VER}.tgz"

echo "[5/5] 生成校验清单 SHA256SUMS.txt"
( cd "$PAYLOAD_DIR" && shasum -a 256 *.zip *.exe *.7z.exe *.tgz > SHA256SUMS.txt 2>/dev/null || true )
cat "$PAYLOAD_DIR/SHA256SUMS.txt"

echo ""
echo "==== 完成 ===="
du -sh "$PAYLOAD_DIR"
echo "离线包就绪。将整个安装器目录打 zip 分发即可（目标电脑无需联网）。"
