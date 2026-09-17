#!/bin/bash
# 单独重新配置模型（换供应商 / 换 Key）—— 双击本文件运行
cd "$(dirname "$0")"
SKIP_CONFIG_ONLY=1 zsh installer-mac.sh config-only
echo ""
echo "10 秒后自动关闭窗口……"
sleep 10
