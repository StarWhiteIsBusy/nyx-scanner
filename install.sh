#!/usr/bin/env bash
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
  printf '\r\033[K[%s] %3d%%' "$bar" "$pct"
  printf '\n\033[K  当前: %s\033[1A' "$label"
  sleep 0.15
}

write_file() {
  local rel="$1"
  mkdir -p "$DEST/$(dirname "$rel")"
  cat > "$DEST/$rel"
}

main() {
  local total=8
  local i=0 pct

  show 3 "准备安装目录"
  mkdir -p "$DEST"
  i=$((i + 1)); pct=$((3 + 1 * 84 / total))
  write_file "plugin.toml" <<'PLUGIN_TOML'
id           = "starwhite/scan_wifi"
name         = "Nyx Scanner"
version      = "1.0.0"
plugin_api   = 18
author       = "starwhite"
license      = "MIT"
icon         = "qrcode"
description  = "快捷键唤起摄像头扫码窗:WiFi 二维码一键连接(支持隐藏 SSID/开放网络/转义符,失败自动重试),网址二维码一键打开"
tags         = ["wifi", "qrcode", "utility"]
dependencies = ["python3", "ffmpeg", "zbar-tools", "zenity", "nmcli"]

[[setting]]
key             = "camera_device"
type            = "string"
label_key       = "settings.camera_device.label"
description_key = "settings.camera_device.description"
default         = "/dev/video0"

[[setting]]
key             = "camera_resolution"
type            = "select"
label_key       = "settings.camera_resolution.label"
description_key = "settings.camera_resolution.description"
default         = "1280x720"
options = [
  { value = "640x480",  label_key = "settings.camera_resolution.640" },
  { value = "1280x720", label_key = "settings.camera_resolution.1280" },
  { value = "1920x1080", label_key = "settings.camera_resolution.1920" },
]

[[setting]]
key             = "wifi_refresh_seconds"
type            = "int"
label_key       = "settings.wifi_refresh_seconds.label"
description_key = "settings.wifi_refresh_seconds.description"
default         = 10
min             = 2
max             = 120

[[setting]]
key             = "popup_timeout_ms"
type            = "int"
label_key       = "settings.popup_timeout_ms.label"
description_key = "settings.popup_timeout_ms.description"
default         = 3000
min             = 1000
max             = 15000

[[panel]]
id                      = "scanner"
entry                   = "panel_scanner.luau"
width                   = 560
height                  = 460
placement               = "floating"
position                = "center"
dismiss_on_outside_click = false
PLUGIN_TOML
  show "$pct" "plugin.toml"

  i=$((i + 1)); pct=$((3 + 2 * 84 / total))
  write_file "panel_scanner.luau" <<'PANEL_SCANNER_LUAU'
--!nonstrict
-- 扫描窗口:浮动面板,摄像头画面铺满窗口,
-- 识别到 WiFi 二维码 -> 底部紧凑弹窗(SSID + 密码 + 确认连接)
-- 非 WiFi 二维码/出错 -> 紧凑错误弹窗,超时自动消失。
-- 也可选择本地图片扫描:识别成功后放大二维码 3 秒,6 秒后返回摄像头。

local framesDir = nil
local framePath = nil
local sweep = 0
local popup = nil -- { kind = "wifi"/"url"/"error"/"image_error", ssid, password, elapsed }
local connecting = false
local timeoutMs = 3000
local lastTickMs = 0
local render
local startStream
-- 图片模式状态
local imageMode = false
local imagePath = nil
local imageZoomPath = nil
local zoomUntilMs = nil
local imageEndMs = nil
local scannerPanelId = "starwhite/scan_wifi:scanner"
local pendingPickPath = nil
-- 截图流程:helper 已解码完成,面板重开时直接恢复状态
local pendingScreenshot = nil -- { image_path, zoom_path, popup }
local pendingImageError = false

-- runStream 在面板关闭后仍会存活,宿主也没有停止句柄/onClose 回调;
-- 因此用帧 tick 的活跃时间判断面板是否仍打开:开着就续流,关了就让
-- helper 自行限时退出(摄像头在 ~20s 内释放)。
local function panelOpen()
  return noctalia.nowMs() - lastTickMs <= 1000
end

local function quote(s)
  s = s or ""
  s = string.gsub(s, "'", "'\\''")
  return "'" .. s .. "'"
end

local function rescan()
  noctalia.runAsync("nmcli device wifi rescan", function() end)
end

local function onLine(line)
  local data = noctalia.json.decode(line)
  if type(data) ~= "table" then return end
  if data.type == "frame" then
    framePath = data.path
    render()
  elseif data.type == "qr" then
    rescan()
    if data.wifi and data.wifi.ssid then
      popup = { kind = "wifi", ssid = data.wifi.ssid,
        password = data.wifi.password or "", elapsed = 0 }
    elseif data.url and data.url ~= "" then
      popup = { kind = "url", url = data.url, elapsed = 0 }
    else
      popup = { kind = "error", elapsed = 0 }
    end
    render()
  elseif data.type == "error" then
    popup = { kind = "error", elapsed = 0 }
    render()
  elseif data.type == "exit" then
    if panelOpen() then startStream() end
  end
end

startStream = function()
  local camera = noctalia.getConfig("camera_device") or "/dev/video0"
  local res = noctalia.getConfig("camera_resolution") or "1280x720"
  framesDir = noctalia.pluginDataDir() .. "/frames"
  local helper = noctalia.pluginDir() .. "/helper/scan_helper.py"
  local cmd = "python3 " .. quote(helper) .. " " .. quote(camera)
    .. " " .. quote(res) .. " " .. quote(framesDir) .. " 15 300"
  noctalia.runStream(cmd, onLine)
end

local function launchImageScan(path)
  local helper = noctalia.pluginDir() .. "/helper/scan_helper.py"
  local workdir = framesDir or (noctalia.pluginDataDir() .. "/frames")
  local cmd2 = "python3 " .. quote(helper) .. " --image " .. quote(path)
    .. " " .. quote(workdir)
  -- 解码需要 1~3 秒,期间显示原图 + 识别中提示,避免用户误以为时间线已开始
  popup = { kind = "decoding", elapsed = 0 }
  render()
  noctalia.runAsync(cmd2, function(res2)
    local line2 = (res2.stdout or ""):match("^[^\n]+")
    local data2 = line2 and noctalia.json.decode(line2)
    if type(data2) ~= "table" or data2.type ~= "qr" then
      popup = { kind = "image_error", elapsed = 0 }
      -- 无二维码也显示图片 3 秒再回摄像头
      imageEndMs = noctalia.nowMs() + 3000
    else
      rescan()
      if data2.wifi and data2.wifi.ssid then
        popup = { kind = "wifi", ssid = data2.wifi.ssid,
          password = data2.wifi.password or "", elapsed = 0 }
      elseif data2.url and data2.url ~= "" then
        popup = { kind = "url", url = data2.url, elapsed = 0 }
      else
        popup = { kind = "error", elapsed = 0 }
      end
      if data2.zoom_path then
        local now2 = noctalia.nowMs()
        imageZoomPath = data2.zoom_path
        zoomUntilMs = now2 + 3000
        imageEndMs = now2 + 6000
      else
        -- 识别出内容但无定位放大时,同样显示 3 秒后回摄像头
        imageEndMs = noctalia.nowMs() + 3000
      end
    end
    render()
  end, 60000)
end

local function onPickImage()
  local title = noctalia.tr("scanner.pick_image")
  local filter = "图片 | *.png *.jpg *.jpeg *.webp *.bmp *.gif *.ico"
  -- 面板是 layer-shell 覆盖层,会盖住一切普通窗口(含 zenity);
  -- 所以先关面板再弹选图窗口,选完/取消后自动重开。
  -- runAsync 默认 5s 超时会杀掉选图对话框;runStream 无超时,可一直等用户选择。
  -- 用 echo 前缀区分:选中输出 __PICK__<路径>,取消输出 __CANCEL__。
  local zen = "zenity --file-selection --title=" .. quote(title)
    .. " --file-filter=" .. quote(filter) .. " 2>/dev/null"
  local cmd = "p=$(" .. zen .. "); rc=$?; if [ $rc -eq 0 ] && [ -n \"$p\" ]; then"
    .. " echo \"__PICK__$p\"; else echo __CANCEL__; fi"
  panel.close()
  noctalia.runStream(cmd, function(line)
    local data = noctalia.string.trim(line)
    if string.sub(data, 1, 8) == "__PICK__" then
      pendingPickPath = string.sub(data, 9)
    end
    noctalia.togglePanel(scannerPanelId)
  end)
end

local function onScreenshot()
  -- 与选图一致:先关面板(niri 选区 UI 是合成器顶层,不受 layer-shell 面板影响,
  -- 但先关闭更干净);helper 截完图并解码后再重开面板恢复状态。
  -- 收到 helper 的 restart 结果(等待期间用户按 alt+s 重新打开截图 UI)时
  -- 视为重启工具:重开面板回到摄像头扫描界面。
  local helper = noctalia.pluginDir() .. "/helper/scan_helper.py"
  local workdir = framesDir or (noctalia.pluginDataDir() .. "/frames")
  local cmd = "python3 " .. quote(helper) .. " --screenshot " .. quote(workdir)
  panel.close()
  -- 等面板完全关闭(含关闭动画)后再启动截图,避免与选区 UI 重叠
  noctalia.runAsync("sleep 0.5", function()
    noctalia.log("screenshot: running helper")
    noctalia.runAsync(cmd, function(res)
      local line = (res.stdout or ""):match("^[^\n]+")
      noctalia.log("screenshot: result=" .. tostring(line)
        .. " exit=" .. tostring(res.exitCode)
        .. " stderr=" .. tostring(res.stderr or ""))
      local data = line and noctalia.json.decode(line)
      pendingImageError = false
      if type(data) == "table" and data.type == "qr" then
        local popupInfo = nil
        if data.wifi and data.wifi.ssid then
          popupInfo = { kind = "wifi", ssid = data.wifi.ssid,
            password = data.wifi.password or "", elapsed = 0 }
        elseif data.url and data.url ~= "" then
          popupInfo = { kind = "url", url = data.url, elapsed = 0 }
        else
          popupInfo = { kind = "error", elapsed = 0 }
        end
        pendingScreenshot = {
          image_path = data.image_path,
          zoom_path = data.zoom_path,
          popup = popupInfo,
        }
      elseif type(data) == "table" and data.type == "error" then
        pendingImageError = {
          image_path = data.image_path,
        }
      end
      if type(data) ~= "table" or data.type ~= "cancel" then
        if panelOpen() then
          -- 等待期间用户已用 Alt+S 打开面板:直接消费结果,不再切换面板
          noctalia.log("screenshot: panel open, consume directly")
          consumePending()
        else
          noctalia.togglePanel(scannerPanelId)
        end
      end
      -- cancel(Esc 取消或 20s 超时):静默退出,面板保持关闭;若用户已
      -- 主动打开面板(Alt+S),则保持摄像头界面不动
      end, 60000)
    end)
end

local function stopStream()
  -- 只杀摄像头抓帧进程,不误伤 --screenshot/--image 的单次 helper
  local pattern = noctalia.pluginDir() .. "/helper/scan_helper.py /dev/video"
  noctalia.runAsync("pkill -f " .. quote(pattern), function() end)
end

local function failDetail(res)
  local out = ""
  if res.stdout and #res.stdout > 0 then out = res.stdout end
  if res.stderr and #res.stderr > 0 then out = res.stderr end
  return out
end

local attempts = 0

local function doConnect()
  attempts = attempts + 1
  local cmd = "nmcli --wait 25 device wifi connect " .. quote(popup.ssid)
  if popup.password ~= "" then
    cmd = cmd .. " password " .. quote(popup.password)
  end
  noctalia.runAsync(cmd, function(res)
    if res.exitCode == 0 then
      noctalia.notify(noctalia.tr("scanner.connected"), popup.ssid)
      popup = nil
      panel.close()
      return
    end
    if attempts >= 3 then
      connecting = false
      noctalia.notifyError(noctalia.tr("scanner.connect_failed"),
        popup.ssid .. "\n" .. failDetail(res))
      render()
      return
    end
    -- 失败后重新扫描一次,等 2 秒让扫描结果生效再重试
    rescan()
    noctalia.runAsync("sleep 2", doConnect)
  end)
end

local function onOpenUrl()
  if not popup or popup.kind ~= "url" then return end
  local url = popup.url
  popup = nil
  render()
  -- xdg-open 会等待浏览器启动完成,后台化避免卡住界面
  noctalia.runAsync("nohup xdg-open " .. quote(url) .. " >/dev/null 2>&1 &", function(res)
    if res.exitCode == 0 then
      noctalia.notify(noctalia.tr("scanner.url_opened"), url)
      panel.close()
    else
      noctalia.notifyError(noctalia.tr("scanner.url_open_failed"), url)
    end
  end)
end

local function onConfirm()
  if connecting or not popup or popup.kind ~= "wifi" then return end
  connecting = true
  attempts = 0
  render()
  doConnect()
end

render = function()
  local children = {}

  -- 头部(浮层在画面上方)
  children[#children + 1] = ui.row({ gap = 8, align = "center", paddingH = 10, paddingV = 0 }, {
    ui.label({ text = noctalia.tr("scanner.title"), fontSize = 16, fontWeight = "bold",
      color = "primary" }),
    ui.button({
      glyph = "folder", width = 28, height = 28, variant = "ghost",
      tooltip = noctalia.tr("scanner.pick_image"),
      onClick = onPickImage,
    }),
    ui.button({
      glyph = "camera", width = 28, height = 28, variant = "ghost",
      tooltip = noctalia.tr("scanner.screenshot"),
      onClick = onScreenshot,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ text = noctalia.tr("scanner.hint"), fontSize = 11, color = "secondary" }),
    ui.button({
      glyph = "close", width = 28, height = 28, variant = "ghost",
      tooltip = noctalia.tr("panel.close.tooltip"),
      onClick = function() panel.close() end,
    }),
  })

  -- 摄像头画面(固定高度;弹窗覆盖画面下边缘,取景框大小不变)
  local displayPath = framePath
  if imageMode then
    displayPath = imageZoomPath or imagePath
  end
  local overlay = {
    ui.image({
      path = displayPath or "",
      height = 390,
      fit = "cover",
      radius = 10,
      border = "primary",
      borderWidth = 2,
      visible = displayPath ~= nil,
    }),
  }

  local popupWrap = nil
  if popup ~= nil and not connecting then
    if popup.kind == "wifi" then
      popupWrap = ui.row({
        gap = 10, align = "center", paddingH = 14, paddingV = 10,
        fill = "surface_variant/0.75", radius = 12, border = "outline", borderWidth = 1,
      }, {
        ui.glyph({ name = "lock", size = 14, color = "primary" }),
        ui.label({ text = popup.ssid, fontSize = 13.5, fontWeight = "bold", flexGrow = 1 }),
        ui.label({ text = noctalia.tr("scanner.password"), fontSize = 11.5, color = "secondary" }),
        ui.label({ text = popup.password == "" and "—" or popup.password,
          fontSize = 11.5, maxLines = 1 }),
        ui.button({
          text = noctalia.tr("scanner.confirm"), variant = "primary",
          controlSize = "sm",
          onClick = onConfirm,
        }),
      })
    elseif popup.kind == "url" then
      popupWrap = ui.row({
        gap = 10, align = "center", paddingH = 14, paddingV = 10,
        fill = "surface_variant/0.75", radius = 12, border = "outline", borderWidth = 1,
      }, {
        ui.glyph({ name = "world", size = 14, color = "primary" }),
        ui.label({ text = popup.url, fontSize = 13.5, fontWeight = "bold",
          flexGrow = 1, maxLines = 1 }),
        ui.button({
          text = noctalia.tr("scanner.open"), variant = "primary",
          controlSize = "sm",
          onClick = onOpenUrl,
        }),
      })
    else
      local errText = popup.kind == "image_error"
        and noctalia.tr("scanner.no_qr_in_image") or noctalia.tr("scanner.unknown")
      -- 倒计时:错误提示统一按 timeoutMs(3s)倒数
      local remaining = math.max(0, math.ceil((timeoutMs - popup.elapsed) / 1000))
      local dismissText = string.gsub(noctalia.tr("scanner.dismiss"), "{n}",
        tostring(remaining))
      popupWrap = ui.column({
        gap = 2, paddingH = 14, paddingV = 10,
        fill = "surface_variant/0.75", radius = 12, border = "outline", borderWidth = 1,
      }, {
        ui.label({ text = errText, fontSize = 13.5, fontWeight = "bold" }),
        ui.label({ text = dismissText, fontSize = 11.5, color = "secondary" }),
      })
    end
  elseif popup and popup.kind == "decoding" then
    popupWrap = ui.row({
      gap = 8, align = "center", paddingH = 14, paddingV = 10,
      fill = "surface_variant/0.75", radius = 12, border = "outline", borderWidth = 1,
    }, {
      ui.glyph({ name = "loader", size = 14, color = "primary" }),
      ui.label({ text = noctalia.tr("scanner.decoding"), fontSize = 13.5,
        fontWeight = "bold", color = "secondary" }),
    })
  elseif connecting then
    popupWrap = ui.row({
      gap = 8, align = "center", paddingH = 14, paddingV = 10,
      fill = "surface_variant/0.75", radius = 12,
    }, {
      ui.glyph({ name = "loader", size = 14, color = "primary" }),
      ui.label({ text = noctalia.tr("scanner.connecting"), fontSize = 13, color = "secondary" }),
    })
  end

  local hasPopup = popupWrap ~= nil
  if popupWrap then
    -- 弹窗:宽度收进扫描框内(paddingH),上移覆盖画面下边缘
    overlay[#overlay + 1] = ui.column({ paddingH = 10 }, { popupWrap })
  end
  -- connecting 弹窗较矮:上移量按自身高度算,下边缘与确认窗口对齐
  local coverGap = 8
  if hasPopup then
    coverGap = -66
    if connecting then
      coverGap = -52
    end
  end
  children[#children + 1] = ui.column({ gap = coverGap }, overlay)

  panel.render(ui.column({ gap = 8, fill = true, paddingH = 6, paddingV = 6 }, children))
end

-- 从截图流程返回:helper 已解码完,直接恢复结果(面板重开时 onOpen 调用;
-- 若等待期间用户已用 Alt+S 打开面板,则由结果回调直接调用)
local function consumePending()
  if pendingScreenshot ~= nil then
    local p = pendingScreenshot
    pendingScreenshot = nil
    imageMode = true
    imagePath = p.image_path
    imageZoomPath = nil
    zoomUntilMs = nil
    imageEndMs = nil
    if p.zoom_path then
      local now2 = noctalia.nowMs()
      imageZoomPath = p.zoom_path
      zoomUntilMs = now2 + 3000
      imageEndMs = now2 + 6000
    else
      -- 无放大时显示图片 3 秒后回摄像头
      imageEndMs = noctalia.nowMs() + 3000
    end
    if p.popup then popup = p.popup end
    -- 无法识别的二维码(unknown):弹窗倒数 3 秒后直接回摄像头,
    -- 不沿用放大图的 6 秒时间线
    if popup and popup.kind == "error" then
      imageEndMs = noctalia.nowMs() + 3000
      zoomUntilMs = nil
    end
  elseif pendingImageError then
    local e = pendingImageError
    pendingImageError = nil
    imageMode = true
    imagePath = e.image_path
    imageZoomPath = nil
    zoomUntilMs = nil
    -- 无二维码:显示截图 3 秒再回摄像头
    imageEndMs = noctalia.nowMs() + 3000
    popup = { kind = "image_error", elapsed = 0 }
  end
  render()
end

function onOpen(_context)
  timeoutMs = noctalia.getConfig("popup_timeout_ms") or 3000
  popup = nil
  connecting = false
  framePath = nil
  sweep = 0
  imageMode = false
  imagePath = nil
  imageZoomPath = nil
  zoomUntilMs = nil
  imageEndMs = nil
  lastTickMs = noctalia.nowMs()
  panel.setNeedsFrameTick(true)
  rescan()
  startStream()
  -- 从选图窗口返回:恢复图片模式并启动解码
  if pendingPickPath ~= nil then
    local path = pendingPickPath
    pendingPickPath = nil
    imageMode = true
    imagePath = path
    imageZoomPath = nil
    zoomUntilMs = nil
    imageEndMs = nil
    render()
    launchImageScan(path)
  end
  consumePending()
end

function onClose()
  panel.setNeedsFrameTick(false)
  stopStream()
end

local lastRenderMs = 0
local lastBeatMs = 0

function onFrameTick(deltaMs)
  lastTickMs = noctalia.nowMs()
  -- 面板打开时每秒写心跳,helper 据此续命(关闭后 5s 内自动退出)
  if framesDir ~= nil and lastTickMs - lastBeatMs >= 1000 then
    lastBeatMs = lastTickMs
    noctalia.writeFile(framesDir .. "/heartbeat", tostring(lastTickMs))
  end
  if popup ~= nil and not connecting and popup.kind ~= "decoding" then
    popup.elapsed = popup.elapsed + deltaMs
    -- 图片扫描状态下确认窗口(wifi/url)维持 6s,与图片模式时长一致;
    -- 错误提示保持默认 3s
    local limit = timeoutMs
    if imageMode and (popup.kind == "wifi" or popup.kind == "url") then
      limit = 6000
    end
    if popup.elapsed >= limit then
      popup = nil
    end
  end
  -- 图片模式时间线:放大 3s 后回原图,6s 后回摄像头
  if imageMode then
    local now = noctalia.nowMs()
    if imageZoomPath and zoomUntilMs ~= nil and now >= zoomUntilMs then
      imageZoomPath = nil
      zoomUntilMs = nil
    end
    if imageEndMs ~= nil and now >= imageEndMs then
      imageMode = false
      imagePath = nil
      imageZoomPath = nil
      zoomUntilMs = nil
      imageEndMs = nil
    end
  end
  local now = noctalia.nowMs()
  if now - lastRenderMs >= 100 then
    lastRenderMs = now
    render()
  end
end
PANEL_SCANNER_LUAU
  show "$pct" "panel_scanner.luau"

  i=$((i + 1)); pct=$((3 + 3 * 84 / total))
  write_file "helper/scan_helper.py" <<'SCAN_HELPER_PY'
#!/usr/bin/env python3
"""scan_helper: ffmpeg 抓帧 -> zbarimg 解码 -> stdout JSON 行。

用法: scan_helper.py <camera> <resolution> <workdir> <rate> [lifetime]
stdout 每行一个 JSON:
  {"type": "frame", "path": "..."}         帧已写入, 供 UI 轮换显示
  {"type": "qr", "text": "...", "wifi": {...}|null}  识别到二维码
  {"type": "error", "message": "..."}      捕获/解码出错
  {"type": "exit"}                          到达生命周期上限或收到 SIGTERM

lifetime(秒,默认 20)内循环;面板关闭后 runStream 不会被宿主终止,
helper 必须自我限时退出,否则摄像头会被一直占用。
"""
import fcntl
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
from queue import Empty, Queue


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def sh_ok(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=8)
        return r.returncode == 0, r.stdout, r.stderr
    except Exception as e:
        return False, b"", str(e).encode("utf-8", "replace")


def _unescape(s):
    return (s.replace(r"\\", "\x00")
             .replace(r"\:", ":")
             .replace(r"\;", ";")
             .replace(r"\,", ",")
             .replace(r"\"", '"')
             .replace("\x00", "\\"))


def _split_escaped(text, sep):
    parts, cur = [], []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text) and text[i + 1] == sep:
            cur.append(sep)
            i += 2
        elif c == sep:
            parts.append("".join(cur))
            cur = []
            i += 1
        else:
            cur.append(c)
            i += 1
    parts.append("".join(cur))
    return parts


def parse_wifi(text):
    """解析 WIFI:T:WPA;S:ssid;P:pass;H:true;; 规范。"""
    if text[:5].upper() == "WIFI:":
        text = text[5:]
    fields = {}
    for part in _split_escaped(text, ";"):
        if ":" in part:
            k, _, v = part.partition(":")
            fields[k.strip().upper()] = _unescape(v)
    ssid = fields.get("S")
    if not ssid:
        return None
    info = {"ssid": ssid, "password": fields.get("P", "")}
    t = fields.get("T", "WPA").upper()
    if t in ("NOPASS", "WPS"):
        info["password"] = ""
    info["type"] = t
    return info


def decode_text(path, prep=None):
    """zbarimg 解码一张图片;失败则 PIL 2x+灰度+对比度增强后重试。

    返回 (ok, text);增强副本存为 prep(默认 path + ".enh.png")。
    """
    dk, dout, _derr = sh_ok(["zbarimg", "--raw", "-q", path])
    if dk and dout.strip():
        return True, dout.strip().decode("utf-8", "replace")
    try:
        from PIL import Image, ImageOps
        im = Image.open(path).convert("L")
        im = im.resize((im.width * 2, im.height * 2), Image.BILINEAR)
        im = ImageOps.autocontrast(im, cutoff=1)
        prep = prep or (path + ".enh.png")
        im.save(prep)
        dk, dout, _derr = sh_ok(["zbarimg", "--raw", "-q", prep])
        if dk and dout.strip():
            return True, dout.strip().decode("utf-8", "replace")
    except Exception:
        pass
    return False, ""


def locate_qr(path, prep=None):
    """python-zbar 定位图片中二维码,返回 bbox (x, y, w, h) 或 None。"""
    try:
        import zbar
    except ImportError:
        return None
    from PIL import Image
    for p in (path, prep or (path + ".enh.png")):
        try:
            im = Image.open(p).convert("L")
            scanner = zbar.ImageScanner()
            scanner.parse_config("enable")
            img = zbar.Image(im.width, im.height, "Y800", im.tobytes())
            if scanner.scan(img) == 0:
                continue
            for sym in img:
                loc = list(sym.location)
                if len(loc) < 3:
                    continue
                xs = [pt[0] for pt in loc]
                ys = [pt[1] for pt in loc]
                return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)
        except Exception:
            continue
    return None


def make_zoom(path, bbox, out_path, canvas_w, canvas_h):
    """裁剪二维码区域(外扩 15%)等比缩放,白底居中,输出画布尺寸不变。"""
    from PIL import Image
    x, y, w, h = bbox
    x0 = max(0, x - w * 0.15)
    y0 = max(0, y - h * 0.15)
    x1 = x + w * 1.15
    y1 = y + h * 1.15
    im = Image.open(path)
    box = (x0, y0, min(im.width, x1), min(im.height, y1))
    crop = im.crop(box)
    # 按最长边贴近画布(92%),允许超出画布被裁;上限 10 倍防止小码过度放大。
    # 旧逻辑按最短边 0.9 缩放,二维码占比大时反而比原图 cover 显示更小,
    # 观感上"先小后大"。改为最长边后,放大图永远明显大于原图。
    scale = min(10.0, max(canvas_w / crop.width, canvas_h / crop.height) * 0.92)
    new = crop.resize((max(1, int(crop.width * scale)),
                       max(1, int(crop.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGB", (canvas_w, canvas_h), (255, 255, 255))
    canvas.paste(new, ((canvas_w - new.width) // 2, (canvas_h - new.height) // 2))
    canvas.save(out_path, "JPEG", quality=92)


def normalize_url(text):
    """把二维码文本归一化为可打开的网址;非网址返回 None。

    支持省略协议的域名形式(如 example.com、www.example.com、
    sub.domain.com.cn/path?q=1),统一补 https:// 前缀。
    """
    t = text.strip()
    if t.startswith(("http://", "https://")):
        return t
    if re.match(r"^(www\.|([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,})([/?#].*)?$", t):
        return "https://" + t
    return None


def decode_image(path, workdir):
    """--image 模式:解码一张图片并输出一行 JSON,单次运行后退出。"""
    if not os.path.isfile(path):
        emit({"type": "error", "message": "file not found: " + path})
        return
    prep = os.path.join(workdir, os.path.basename(path) + ".enh.png")
    ok, text = decode_text(path, prep)
    if not ok:
        emit({"type": "error", "message": "no QR code found in image", "image_path": path})
        return
    wifi, url = None, None
    if text.upper().startswith("WIFI:"):
        wifi = parse_wifi(text)
    else:
        url = normalize_url(text)
    out = {"type": "qr", "text": text, "wifi": wifi, "url": url}
    bbox = locate_qr(path, prep)
    if bbox:
        try:
            zoom = os.path.join(workdir, "qr_zoom.jpg")
            make_zoom(path, bbox, zoom, 548, 390)
            out["zoom_path"] = zoom
        except Exception:
            pass
    emit(out)


def screenshot_dir():
    """读取 niri 配置的 screenshot-path 所在目录,解析 ~ 展开。"""
    conf = os.path.expanduser("~/.config/niri/config.kdl")
    try:
        with open(conf, encoding="utf-8") as f:
            for line in f:
                m = re.search(r'screenshot-path\s+"([^"]+)"', line)
                if m:
                    d = os.path.dirname(os.path.expanduser(m.group(1)))
                    if os.path.isdir(d):
                        return d
    except OSError:
        pass
    for cand in ("~/图片/Screenshots", "~/Pictures/Screenshots"):
        d = os.path.expanduser(cand)
        if os.path.isdir(d):
            return d
    return os.path.expanduser("~/图片/Screenshots")


def dir_snapshot(d):
    """文件名+大小+mtime 集合,用于识别新截图。"""
    s = set()
    try:
        for name in os.listdir(d):
            full = os.path.join(d, name)
            if os.path.isfile(full):
                st = os.stat(full)
                s.add((name, st.st_size, int(st.st_mtime)))
    except OSError:
        pass
    return s


def screenshot_scan(workdir):
    """--screenshot 模式:调用 niri 交互选区截图 -> 解码 -> 输出一行 JSON。

    niri 的 IPC 截图复用用户配置的截图 UI 与保存路径,
    完成后在配置目录里找新增文件。
    """
    if shutil.which("niri") is None:
        emit({"type": "error", "message": "niri not found"})
        return
    d = screenshot_dir()
    before = dir_snapshot(d)
    try:
        rc = subprocess.call(["niri", "msg", "action", "screenshot"])
    except Exception as e:
        emit({"type": "error", "message": "niri screenshot failed: " + str(e)})
        return
    if rc != 0:
        emit({"type": "error", "message": "niri screenshot failed"})
        return
    # niri msg action screenshot 只触发截图 UI 就返回,文件在用户完成框选后才保存。
    # 纯轮询等待新文件(0.1s 间隔,最长 20 秒)。Esc 取消不产生任何事件,只能靠
    # 超时兜底。不用 event-stream 检测:面板(overlay)打开同样产生焦点变化事件,
    # 与截图 UI 无法区分。等待期间用户按 Alt+S 打开面板时,由 Lua 侧负责展示,
    # 不依赖 helper 事件。
    path = None
    deadline = time.time() + 20.0
    while time.time() < deadline:
        new = dir_snapshot(d) - before
        if new:
            name, _size, _mtime = sorted(new)[-1]
            path = os.path.join(d, name)
            break
        time.sleep(0.1)
    if not path:
        emit({"type": "cancel"})
        return
    prep = os.path.join(workdir, os.path.basename(path) + ".enh.png")
    ok, text = decode_text(path, prep)
    if not ok:
        emit({"type": "error", "message": "no QR code found in image", "image_path": path})
        return
    wifi, url = None, None
    if text.upper().startswith("WIFI:"):
        wifi = parse_wifi(text)
    else:
        url = normalize_url(text)
    out = {"type": "qr", "image_path": path, "text": text, "wifi": wifi, "url": url}
    bbox = locate_qr(path, prep)
    if bbox:
        try:
            zoom = os.path.join(workdir, "qr_zoom.jpg")
            make_zoom(path, bbox, zoom, 548, 390)
            out["zoom_path"] = zoom
        except Exception:
            pass
    emit(out)


def main():
    camera = sys.argv[1] if len(sys.argv) > 1 else "/dev/video0"
    res = sys.argv[2] if len(sys.argv) > 2 else "1280x720"
    workdir = sys.argv[3] if len(sys.argv) > 3 else "."
    rate = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0
    lifetime = float(sys.argv[5]) if len(sys.argv) > 5 else 20.0

    os.makedirs(workdir, exist_ok=True)

    stop = False

    def handler(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)

    if shutil.which("ffmpeg") is None:
        emit({"type": "error", "message": "ffmpeg not found"})
        return
    if shutil.which("zbarimg") is None:
        emit({"type": "error", "message": "zbarimg not found"})
        return

    start = time.monotonic()
    alt = 0

    hb = os.path.join(workdir, "heartbeat")
    try:
        open(hb, "w").close()
    except Exception:
        pass

    def heartbeat_alive():
        try:
            return time.time() - os.path.getmtime(hb) <= 5.0
        except OSError:
            return False

    try:
        proc = subprocess.Popen(
            ["ffmpeg", "-loglevel", "quiet", "-f", "v4l2",
             "-input_format", "mjpeg", "-video_size", res, "-i", camera,
             "-vf", "fps=" + str(max(rate, 1.0)), "-q:v", "5",
             "-f", "image2pipe", "-c:v", "mjpeg", "pipe:1"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except Exception as e:
        emit({"type": "error", "message": "ffmpeg start failed: " + str(e)})
        return

    stop_ev = threading.Event()
    decode_q = Queue(maxsize=2)

    def decode_worker():
        from PIL import Image, ImageOps
        last_dec = 0.0
        while not stop_ev.is_set():
            try:
                path = decode_q.get(timeout=0.2)
            except Empty:
                continue
            now = time.monotonic()
            if now - last_dec < 0.5:
                continue
            last_dec = now
            ok, text = decode_text(path)
            if ok:
                wifi = None
                url = None
                if text.upper().startswith("WIFI:"):
                    wifi = parse_wifi(text)
                else:
                    url = normalize_url(text)
                emit({"type": "qr", "text": text, "wifi": wifi, "url": url})

    worker = threading.Thread(target=decode_worker, daemon=True)
    worker.start()

    fd = proc.stdout.fileno()
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    buf = b""
    while not stop and time.monotonic() - start < lifetime and heartbeat_alive():
        try:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                continue
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if not chunk:
            break
        buf += chunk
        while True:
            s = buf.find(b"\xff\xd8")
            if s < 0:
                buf = b""
                break
            if s > 0:
                buf = buf[s:]
            e = buf.find(b"\xff\xd9", 2)
            if e < 0:
                break
            jpeg = buf[:e + 2]
            buf = buf[e + 2:]

            path = os.path.join(workdir, "frame_a.jpg" if alt % 2 == 0 else "frame_b.jpg")
            alt += 1
            try:
                from io import BytesIO
                from PIL import Image, ImageEnhance
                img = Image.open(BytesIO(jpeg))
                img = ImageEnhance.Contrast(img).enhance(1.4)
                img.save(path, format="JPEG", quality=90)
            except Exception:
                try:
                    with open(path, "wb") as f:
                        f.write(jpeg)
                except Exception:
                    continue
            emit({"type": "frame", "path": path})
            try:
                decode_q.put_nowait(path)
            except Exception:
                pass

    stop_ev.set()
    try:
        proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=2)
    except Exception:
        pass

    emit({"type": "exit"})


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--image":
        workdir = sys.argv[3] if len(sys.argv) > 3 else "."
        os.makedirs(workdir, exist_ok=True)
        decode_image(sys.argv[2], workdir)
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--screenshot":
        workdir = sys.argv[2] if len(sys.argv) > 2 else "."
        os.makedirs(workdir, exist_ok=True)
        screenshot_scan(workdir)
        sys.exit(0)
    main()
SCAN_HELPER_PY
  chmod +x "$DEST/helper/scan_helper.py"
  show "$pct" "helper/scan_helper.py (+可执行权限)"

  i=$((i + 1)); pct=$((3 + 4 * 84 / total))
  write_file "translations/en.json" <<'EN_JSON'
{
  "settings.camera_device.label": "Camera device",
  "settings.camera_device.description": "Camera device path used for QR scanning",
  "settings.camera_resolution.label": "Camera resolution",
  "settings.camera_resolution.description": "Capture resolution; higher reads farther but costs more CPU",
  "settings.camera_resolution.640": "640×480",
  "settings.camera_resolution.1280": "1280×720",
  "settings.camera_resolution.1920": "1920×1080",
  "settings.wifi_refresh_seconds.label": "WiFi refresh seconds",
  "settings.wifi_refresh_seconds.description": "How often the WiFi panel list refreshes",
  "settings.popup_timeout_ms.label": "Popup timeout (ms)",
  "settings.popup_timeout_ms.description": "How long the unrecognized-QR notice stays visible",
  "panel.title": "Network",
  "panel.scan.tooltip": "Scan WiFi QR code",
  "panel.close.tooltip": "Close",
  "current.title": "Current connection",
  "wifi.title": "WiFi",
  "wifi.refresh.tooltip": "Refresh",
  "wifi.disabled": "WiFi is off",
  "group.connected": "Connected",
  "group.saved": "Saved",
  "group.available": "Available",
  "ap.connect": "Connect",
  "ap.forget": "Forget",
  "ap.disconnect": "Disconnect",
  "password.title": "Enter password",
  "password.placeholder": "Password",
  "password.connect": "Connect",
  "password.cancel": "Cancel",
  "scanner.title": "Scan QR code",
  "scanner.hint": "Point a QR code at the camera",
  "scanner.detected": "Detected",
  "scanner.password": "Password",
  "scanner.confirm": "Connect",
  "scanner.unknown": "This QR code cannot be recognized",
  "scanner.pick_image": "Pick an image to scan",
  "scanner.screenshot": "Take a screenshot to scan",
  "scanner.no_qr_in_image": "No QR code found in the image",
  "scanner.dismiss": "Back to scanning in {n}s",
  "scanner.decoding": "Decoding…",
  "scanner.connecting": "Connecting…",
  "scanner.connected": "Connected",
  "scanner.connect_failed": "Connection failed",
  "scanner.open": "Open",
  "scanner.url_opened": "Opened in default browser",
  "scanner.url_open_failed": "Failed to open URL",
  "widget.tooltip": "WiFi"
}
EN_JSON
  show "$pct" "translations/en.json"

  i=$((i + 1)); pct=$((3 + 5 * 84 / total))
  write_file "translations/zh.json" <<'ZH_JSON'
{
  "settings.camera_device.label": "摄像头设备",
  "settings.camera_device.description": "用于扫描二维码的摄像头设备路径",
  "settings.camera_resolution.label": "摄像头分辨率",
  "settings.camera_resolution.description": "摄像头捕获分辨率,越高识别越远但越费CPU",
  "settings.camera_resolution.640": "640×480",
  "settings.camera_resolution.1280": "1280×720",
  "settings.camera_resolution.1920": "1920×1080",
  "settings.wifi_refresh_seconds.label": "WiFi 刷新间隔(秒)",
  "settings.wifi_refresh_seconds.description": "WiFi 面板列表自动刷新的间隔",
  "settings.popup_timeout_ms.label": "弹窗超时(毫秒)",
  "settings.popup_timeout_ms.description": "「二维码未识别出wifi」提示自动消失的时间",
  "panel.title": "网络",
  "panel.scan.tooltip": "扫描 WiFi 二维码",
  "panel.close.tooltip": "关闭",
  "current.title": "当前连接",
  "wifi.title": "WiFi",
  "wifi.refresh.tooltip": "刷新",
  "wifi.disabled": "WiFi 已关闭",
  "group.connected": "已连接",
  "group.saved": "已保存",
  "group.available": "可用",
  "ap.connect": "连接",
  "ap.forget": "忘记",
  "ap.disconnect": "断开",
  "password.title": "输入密码",
  "password.placeholder": "密码",
  "password.connect": "连接",
  "password.cancel": "取消",
  "scanner.title": "扫码测试XYZ",
  "scanner.hint": "将二维码对准摄像头",
  "scanner.detected": "已识别",
  "scanner.password": "密码",
  "scanner.confirm": "确认连接",
  "scanner.unknown": "该二维码无法被识别",
  "scanner.pick_image": "选择图片扫描",
  "scanner.screenshot": "截屏并扫描",
  "scanner.no_qr_in_image": "图片中未找到二维码",
  "scanner.dismiss": "{n} 秒后回到扫描界面",
  "scanner.decoding": "识别中…",
  "scanner.connecting": "连接中…",
  "scanner.connected": "已连接",
  "scanner.connect_failed": "连接失败",
  "scanner.open": "打开",
  "scanner.url_opened": "已用默认浏览器打开",
  "scanner.url_open_failed": "打开网址失败",
  "widget.tooltip": "WiFi"
}
ZH_JSON
  show "$pct" "translations/zh.json"

  i=$((i + 1)); pct=$((3 + 6 * 84 / total))
  write_file "translations/zh-Hans.json" <<'ZH_HANS_JSON'
{
  "settings.camera_device.label": "摄像头设备",
  "settings.camera_device.description": "用于扫描二维码的摄像头设备路径",
  "settings.camera_resolution.label": "摄像头分辨率",
  "settings.camera_resolution.description": "摄像头捕获分辨率,越高识别越远但越费CPU",
  "settings.camera_resolution.640": "640×480",
  "settings.camera_resolution.1280": "1280×720",
  "settings.camera_resolution.1920": "1920×1080",
  "settings.wifi_refresh_seconds.label": "WiFi 刷新间隔(秒)",
  "settings.wifi_refresh_seconds.description": "WiFi 面板列表自动刷新的间隔",
  "settings.popup_timeout_ms.label": "弹窗超时(毫秒)",
  "settings.popup_timeout_ms.description": "「二维码未识别出wifi」提示自动消失的时间",
  "panel.title": "网络",
  "panel.scan.tooltip": "扫描 WiFi 二维码",
  "panel.close.tooltip": "关闭",
  "current.title": "当前连接",
  "wifi.title": "WiFi",
  "wifi.refresh.tooltip": "刷新",
  "wifi.disabled": "WiFi 已关闭",
  "group.connected": "已连接",
  "group.saved": "已保存",
  "group.available": "可用",
  "ap.connect": "连接",
  "ap.forget": "忘记",
  "ap.disconnect": "断开",
  "password.title": "输入密码",
  "password.placeholder": "密码",
  "password.connect": "连接",
  "password.cancel": "取消",
  "scanner.title": "扫描二维码",
  "scanner.hint": "将二维码对准摄像头",
  "scanner.detected": "已识别",
  "scanner.password": "密码",
  "scanner.confirm": "确认连接",
  "scanner.unknown": "该二维码无法被识别",
  "scanner.pick_image": "选择图片扫描",
  "scanner.screenshot": "截屏并扫描",
  "scanner.no_qr_in_image": "图片中未找到二维码",
  "scanner.dismiss": "{n} 秒后回到扫描界面",
  "scanner.decoding": "识别中…",
  "scanner.connecting": "连接中…",
  "scanner.connected": "已连接",
  "scanner.connect_failed": "连接失败",
  "scanner.open": "打开",
  "scanner.url_opened": "已用默认浏览器打开",
  "scanner.url_open_failed": "打开网址失败",
  "widget.tooltip": "WiFi"
}
ZH_HANS_JSON
  show "$pct" "translations/zh-Hans.json"

  i=$((i + 1)); pct=$((3 + 7 * 84 / total))
  write_file "README.md" <<'README_MD'
# Nyx Scanner — Noctalia QR Scanner Plugin

**English | [中文](#中文)**

A Noctalia plugin that turns your webcam into a QR scanner: scan a WiFi QR code to connect with one tap, scan a URL QR code to open it in your browser.

---

## Features

### Scan & connect WiFi

- Floating scanning window with live preview (15fps), full-window view
- On WiFi QR detection, a confirm popup shows SSID + password; confirm to connect (loading state, success/failure notifications)
- Handles all formats: `WIFI:` prefix, escaped SSIDs (`:;,\`), hidden SSID (`H:true`), open networks (`T:nopass`), WPS
- Auto enhance-and-retry on failed decode: 2× upscale + grayscale + contrast stretch
- Retry chain: auto rescan + up to 3 connection attempts with error details in notifications
- Camera stays active while the panel is open (heartbeat keep-alive); released automatically on close

### URL QR codes

- `http/https` links pop up with an **Open** button (default browser)
- Domain-only URLs are supported (e.g. `example.com`, `www.example.com`, `sub.domain.com.cn/path?q=1`) — `https://` is prepended automatically

### Screenshot scanning

- Camera button in the header launches niri's region screenshot (reuses the system screenshot UI and save path); the image is decoded automatically after selection
- WiFi / URL / plain-text QR codes all supported; no QR found shows the screenshot for 3s with a "no QR code found" message
- Press Esc to cancel: silently closes without reopening the panel; pressing Alt+S within the 20s wait reopens the camera view
- Detected QR region is zoomed in for display

### Image scanning

- Folder button in the header opens a file picker (`png/jpg/jpeg/webp/bmp/gif/ico`); the image is shown in the same viewport size
- Shows "Decoding…" while analyzing; then zooms to the QR region for 3s, back to the image, and returns to the camera after 6s
- WiFi/URL QRs inside images pop up as usual; "no QR code found in the image" when nothing detected
- Camera keeps running in the background during image scan

### Unrecognized QR codes

- Valid QR without WiFi/URL content (e.g. plain text) shows "This QR code cannot be recognized" and returns to the scanning view after a 3s countdown

## Installation

**Online (one-liner):**

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install-online.sh | bash
```

The `install.sh` itself is standalone — you can also pipe it directly:

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install.sh | bash
```

**Online uninstall:**

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/uninstall-online.sh | bash
```

**Local:**

```bash
./install.sh            # installs to ~/.local/share/noctalia/plugins/nyx-scanner/
./install.sh <dir>      # installs to a custom directory (skips enabling)
./uninstall.sh          # uninstall (stop helper, disable plugin, remove data)
```

Restart Noctalia after installing, then enable `starwhite/scan_wifi` in Settings → Plugins. Settings: camera device, resolution, popup timeout.

## Dependencies

`python3` `ffmpeg` `zbar-tools` (zbarimg) `zenity` (file picker) `nmcli` (NetworkManager); optional `python3-pil` (higher decode rate).

## Key binding

niri (`~/.config/niri/config.kdl`):

```kdl
Alt+S { spawn "noctalia" "msg" "panel-toggle" "starwhite/scan_wifi:scanner" }
```

Reload with `niri msg action load-config-file`. Noctalia's own keybind settings only manage built-in actions and cannot bind plugin panels.

## Structure

- `panel_scanner.luau` — scanning panel (camera view + popups + screenshot/image scan + heartbeat)
- `helper/scan_helper.py` — ffmpeg capture → zbarimg decode → JSON lines; PIL enhance retry + heartbeat exit; `--image` mode (decode + zbar locate + zoom crop); `--screenshot` mode (niri region screenshot + new-file polling)
- `translations/` — en / zh / zh-Hans (Noctalia language name `zh-Hans`; for English UI add `[appearance] language = "zh-Hans"` under `~/.local/state/noctalia/settings.toml`)
- `install.sh` — single-file installer (embeds all plugin files); `uninstall.sh` — uninstaller

## Maintenance

After changes, reinstall:

```bash
./install.sh && killall noctalia && setsid noctalia &   # restart Noctalia to apply
```

Regenerate the single-file installer: `python3 /tmp/opencode/gen_install.py` (generator lives in the repo).

---

# 中文

按快捷键唤起摄像头扫码窗,扫一下二维码:WiFi 二维码一键连接,网址二维码一键打开。

## 功能

### 扫码连接 WiFi

- 浮动扫描窗实时取景(15fps),画面铺满窗口
- 识别 WiFi 二维码后弹出确认框,显示 SSID 与密码,确认即连接;连接中显示加载态,成功/失败都有通知
- 兼容各格式:`WIFI:` 前缀、SSID 含转义符(`:;,\`)、隐藏 SSID(`H:true`)、开放网络(`T:nopass`)与 WPS 二维码
- 识别失败自动增强重试:放大 2 倍 + 灰度 + 对比度拉伸,提高小/模糊二维码的识别率
- 连接带重试链:失败自动重新扫描后最多重试 3 次,错误详情进通知
- 扫码窗开着就持续扫描(心跳保活);关闭后自动释放摄像头,不占资源

### 网址二维码

- 扫到 `http/https` 链接直接弹窗,点击「打开」用默认浏览器跳转,无需手动输入
- 支持省略协议的域名形式(如 `example.com`、`www.example.com`、`sub.domain.com.cn/path?q=1`),自动补全 `https://`

### 截图扫码

- 标题右侧的相机按钮,一键调起 niri 选区截图(沿用系统截图 UI 与保存路径),框选完自动识别并弹窗
- 支持 WiFi / 网址 / 纯文本二维码;截图无二维码会显示截图 3 秒并提示「图片中未找到二维码」
- 按 Esc 取消截图:静默关闭,不自动重开面板;20 秒等待期内按 Alt+S 可重新打开面板(摄像头界面)
- 识别的截图图片会放大定位到二维码区域展示

### 图片扫码

- 标题右侧的文件夹按钮,用文件选择器选一张本地图片(`png/jpg/jpeg/webp/bmp/gif/ico`),图片会以同取景框尺寸显示
- 解码期间显示「识别中…」;识别到二维码后放大定位到二维码区域 3 秒,再回原图;识别后 6 秒自动回到摄像头画面
- 图片里的 WiFi/网址二维码同样弹窗可连接/打开;图片中无二维码会提示「图片中未找到二维码」
- 图片扫码期间摄像头画面仍实时取景(不暂停)

### 无法识别的二维码

- 识别成功但不含 WiFi/网址信息的二维码(纯文本等),弹窗提示「该二维码无法被识别」,倒数 3 秒后回到扫描界面

## 安装

**在线一键安装:**

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install-online.sh | bash
```

`install.sh` 本身是独立单文件,也可直接管道执行:

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install.sh | bash
```

**在线卸载:**

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/uninstall-online.sh | bash
```

**本地安装:**

```bash
./install.sh            # 安装到 ~/.local/share/noctalia/plugins/nyx-scanner/
./install.sh <目录>     # 安装到自定义目录(跳过启用步骤)
./uninstall.sh          # 卸载(停止 helper、禁用插件、删除数据)
```

安装后重启 Noctalia,在「设置 → 插件」启用 `starwhite/scan_wifi`。设置项:摄像头设备、分辨率、弹窗超时。

## 依赖

`python3` `ffmpeg` `zbar-tools`(zbarimg) `zenity`(文件选择器) `nmcli`(networkmanager);可选 `python3-pil`(无它时二维码识别率下降)。

## 快捷键

niri(`~/.config/niri/config.kdl`):

```kdl
Alt+S { spawn "noctalia" "msg" "panel-toggle" "starwhite/scan_wifi:scanner" }
```

改完 `niri msg action load-config-file` 生效。Noctalia 的快捷键设置栏只管理其内置操作,无法绑定插件面板。

## 结构

- `panel_scanner.luau` — 扫描浮窗(摄像头画面 + 识别弹窗 + 截图/图片扫码 + 心跳保活)
- `helper/scan_helper.py` — ffmpeg 抓帧 → zbarimg 解码 → JSON 行输出;带 PIL 增强重试与心跳退出;`--image` 模式支持图片解码 + zbar 定位 + 二维码放大图;`--screenshot` 模式调 niri 选区截图并轮询新文件解码
- `translations/` — en / zh / zh-Hans(Noctalia 语言名 `zh-Hans`;若面板为英文,在 `~/.local/state/noctalia/settings.toml` 加 `[appearance] language = "zh-Hans"`)
- `install.sh` — 单文件安装程序(全部插件文件内嵌);`uninstall.sh` — 卸载

## 维护

改动后重装:

```bash
./install.sh && killall noctalia && setsid noctalia &   # 重启 Noctalia 生效
```

重新生成单文件安装脚本:`python3 /tmp/opencode/gen_install.py`(见仓库内生成器)。
README_MD
  show "$pct" "README.md"


  if [[ "$DEST" == "$REAL_DEST" ]] && command -v noctalia >/dev/null 2>&1; then
    show 95 "启用插件 $PLUGIN_ID"
    noctalia msg plugins enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  else
    show 95 "跳过启用(非默认安装目录)"
  fi

  show 100 "安装成功"

  printf '\n\033[K'
  local s
  for s in 3 2 1; do
    printf '\r\033[K安装成功，%ds后退出' "$s"
    sleep 1
  done
  printf '\n'
}

main "$@"
