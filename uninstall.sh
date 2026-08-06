#!/usr/bin/env bash
# 卸载 Nyx Scanner(starwhite/scan_wifi)插件
# 用法: ./uninstall.sh [插件目录]
set -euo pipefail

PLUGIN_NAME="nyx-scanner"
PLUGIN_ID="starwhite/scan_wifi"
REAL_DEST="$HOME/.local/share/noctalia/plugins/$PLUGIN_NAME"
DATA_DIR="$HOME/.local/state/noctalia/plugins/data/starwhite/scan_wifi"
DEST="${1:-$REAL_DEST}"

BAR_WIDTH=42

# 绘制进度:第 1 行进度条+百分比,第 2 行当前动作,均原地刷新
show() {
  local pct="$1" label="$2"
  local filled=$((pct * BAR_WIDTH / 100))
  ((filled > BAR_WIDTH)) && filled=$BAR_WIDTH
  local bar=""
  local i
  for ((i = 0; i < filled; i++)); do bar+="="; done
  for ((i = filled; i < BAR_WIDTH; i++)); do bar+=" "; done
  printf '\r\033[K[%s] %3d%%' "$bar" "$pct"
  printf '\n\033[K  当前: %s\033[1A' "$label"
  sleep 0.15
}

echo "将卸载插件: $PLUGIN_ID"
echo "  插件目录: $DEST"
echo "  数据目录: $DATA_DIR"
printf '确认卸载? [y/N] '
read -r ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "已取消"; exit 1; }

main() {
  local total=5
  local i=0 pct

  show 3 "准备卸载"

  i=$((i + 1)); pct=$((3 + i * 84 / total))
  show "$pct" "停止扫码 helper(释放摄像头)"
  if pgrep -f "scan_helper[.]py" >/dev/null 2>&1; then
    pkill -f "scan_helper[.]py" || true
  fi

  i=$((i + 1)); pct=$((3 + i * 84 / total))
  show "$pct" "禁用插件 $PLUGIN_ID"
  if command -v noctalia >/dev/null 2>&1 && pgrep -x noctalia >/dev/null 2>&1; then
    noctalia msg plugins disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  fi

  i=$((i + 1)); pct=$((3 + i * 84 / total))
  show "$pct" "删除插件目录 $PLUGIN_NAME"
  if [[ -d "$DEST" ]]; then
    rm -rf "$DEST"
  fi

  i=$((i + 1)); pct=$((3 + i * 84 / total))
  show "$pct" "删除数据目录 scan_wifi"
  if [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
  fi

  show 100 "卸载成功"

  printf '\n\033[K'
  local s
  for s in 3 2 1; do
    printf '\r\033[K卸载成功，%ds后退出' "$s"
    sleep 1
  done
  printf '\n'

  echo "可手动清理(本脚本未改动):"
  echo "  1. niri 快捷键绑定: ~/.config/niri/config.kdl 中的 Alt+S 行"
  echo "  2. Noctalia 语言设置: ~/.local/state/noctalia/settings.toml 中 [appearance] language = \"zh-Hans\"(如不再需要中文)"
}

main "$@"
