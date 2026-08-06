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
