#!/usr/bin/env bash
# 通过 curl 在线卸载 Nyx Scanner(Noctalia 扫码插件)
# 从 GitHub 拉取最新 uninstall.sh 并执行;支持自定义插件目录参数。
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/uninstall-online.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/uninstall-online.sh | bash -s /自定义/目录
set -euo pipefail

URL="https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/uninstall.sh"
TMP="$(mktemp /tmp/nyx-scanner-uninstall.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

echo "==> 下载卸载脚本: $URL"
curl -fsSL "$URL" -o "$TMP"
echo "==> 校验语法..."
bash -n "$TMP"
echo "==> 执行卸载..."
bash "$TMP" "$@"
