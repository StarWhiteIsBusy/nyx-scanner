#!/usr/bin/env python3
"""Regenerate install.sh embedding the final plugin files."""
import os

SRC = "/home/starwhite/project/nyx-scanner"
OUT = os.path.join(SRC, "install.sh")

FILES = [
    ("plugin.toml", "PLUGIN_TOML"),
    ("panel_scanner.luau", "PANEL_SCANNER_LUAU"),
    ("helper/scan_helper.py", "SCAN_HELPER_PY"),
    ("translations/en.json", "EN_JSON"),
    ("translations/zh.json", "ZH_JSON"),
    ("translations/zh-Hans.json", "ZH_HANS_JSON"),
    ("README.md", "README_MD"),
]

TOTAL = len(FILES) + 1  # +1 for final enable step

header = """#!/usr/bin/env bash
# Nyx Scanner(starwhite/scan_wifi)插件 — 单文件安装程序
# 所有插件文件均内嵌于本脚本,可复制到任意位置独立安装。
# 用法: ./install.sh [目标目录]
set -euo pipefail

PLUGIN_NAME="nyx-scanner"
PLUGIN_ID="starwhite/scan_wifi"
REAL_DEST="$HOME/.local/share/noctalia/plugins/$PLUGIN_NAME"
DEST="${1:-$REAL_DEST}"

BAR_WIDTH=42

# 绘制进度:第 1 行进度条+百分比,第 2 行当前文件,均原地刷新
show() {
  local pct="$1" label="$2"
  local filled=$((pct * BAR_WIDTH / 100))
  ((filled > BAR_WIDTH)) && filled=$BAR_WIDTH
  local bar=""
  local i
  for ((i = 0; i < filled; i++)); do bar+="="; done
  for ((i = filled; i < BAR_WIDTH; i++)); do bar+=" "; done
  printf '\\r\\033[K[%s] %3d%%' "$bar" "$pct"
  printf '\\n\\033[K  当前: %s\\033[1A' "$label"
  sleep 0.15
}

write_file() {
  local rel="$1"
  mkdir -p "$DEST/$(dirname "$rel")"
  cat > "$DEST/$rel"
}

main() {
  local total=__TOTAL__
  local i=0 pct

  show 3 "准备安装目录"
  mkdir -p "$DEST"
""".replace("__TOTAL__", str(TOTAL))

footer = """
  if [[ "$DEST" == "$REAL_DEST" ]] && command -v noctalia >/dev/null 2>&1; then
    show 95 "启用插件 $PLUGIN_ID"
    noctalia msg plugins enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  else
    show 95 "跳过启用(非默认安装目录)"
  fi

  show 100 "安装成功"

  printf '\\n\\033[K'
  local s
  for s in 3 2 1; do
    printf '\\r\\033[K安装成功，%ds后退出' "$s"
    sleep 1
  done
  printf '\\n'
}

main "$@"
"""

def heredoc(tag, path, rel):
    body = open(path, encoding="utf-8").read().rstrip("\n") + "\n"
    last = body.rstrip("\n").split("\n")[-1]
    guard = ""
    if last.strip() == tag:
        guard = " # terminator-guard"
    return "  write_file \"%s\" <<'%s'\n%s%s%s\n" % (
        rel, tag, body, tag + guard, "")

parts = [header]
for i, (rel, tag) in enumerate(FILES, start=1):
    path = os.path.join(SRC, rel)
    pct = "3 + %d * 84 / total" % i
    parts.append("  i=$((i + 1)); pct=$((%s))\n" % pct)
    parts.append(heredoc(tag, path, rel))
    label = rel
    if rel == "helper/scan_helper.py":
        parts.append("  chmod +x \"$DEST/helper/scan_helper.py\"\n")
        label += " (+可执行权限)"
    parts.append("  show \"$pct\" \"%s\"\n\n" % label)
parts.append(footer)

with open(OUT, "w", encoding="utf-8") as f:
    f.write("".join(parts))

os.chmod(OUT, 0o755)
print("wrote", OUT, len("".join(parts)), "bytes")
