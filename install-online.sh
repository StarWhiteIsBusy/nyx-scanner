#!/usr/bin/env bash
# 通过 curl 在线安装 Nyx Scanner(Noctalia 扫码插件)
# 从 GitHub 拉取最新 install.sh 并执行;支持自定义目录参数。
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install-online.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install-online.sh | bash -s /自定义/目录
set -euo pipefail

URL="https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install.sh"
TMP="$(mktemp /tmp/nyx-scanner-install.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

echo "==> 下载安装程序: $URL"
curl -fsSL "$URL" -o "$TMP"
echo "==> 校验语法..."
bash -n "$TMP"
echo "==> 执行安装..."
bash "$TMP" "$@"
