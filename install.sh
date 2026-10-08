#!/bin/sh
# ============================================================
# 通用一键入口 (POSIX sh, 无需 bash)
# 自动识别系统, 补齐 bash/curl, 然后执行主部署脚本
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | sh
# 带参数:
#   curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | NAME="澳门" PORT=8443 sh
# ============================================================
set -e

MAIN_URL="https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/vless-reality-deploy.sh"

if [ -f /etc/alpine-release ]; then
  echo "检测到 Alpine, 补齐 bash/curl..."
  apk add --no-cache bash curl >/dev/null 2>&1
else
  if ! command -v curl >/dev/null 2>&1; then
    echo "安装 curl..."
    apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1
  fi
  if ! command -v bash >/dev/null 2>&1; then
    echo "安装 bash..."
    apt-get update -qq && apt-get install -y -qq bash >/dev/null 2>&1
  fi
fi

# 环境变量会自动透传给主脚本
curl -fsSL "$MAIN_URL" | bash
