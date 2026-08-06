# Nyx Scanner — Noctalia 扫码插件 / Noctalia QR Scanner Plugin

按快捷键唤起摄像头扫码窗,扫一下二维码:WiFi 二维码一键连接,网址二维码一键打开。
Hotkey-launched camera QR scanner: one-tap WiFi connection, one-click URL opening.

## 功能 / Features

### 扫码连接 WiFi / Scan & connect WiFi

- 浮动扫描窗实时取景(15fps),画面铺满窗口
- Floating scanning window with live preview (15fps), full-window view
- 识别 WiFi 二维码后弹出确认框,显示 SSID 与密码,确认即连接;连接中显示加载态,成功/失败都有通知
- On WiFi QR detection, a confirm popup shows SSID + password; confirm to connect with loading state and success/failure notifications
- 兼容各格式:`WIFI:` 前缀、SSID 含转义符(`:;,\`)、隐藏 SSID(`H:true`)、开放网络(`T:nopass`)与 WPS 二维码
- Handles all formats: `WIFI:` prefix, escaped SSIDs (`:;,\`), hidden SSID (`H:true`), open networks (`T:nopass`), WPS
- 识别失败自动增强重试:放大 2 倍 + 灰度 + 对比度拉伸,提高小/模糊二维码的识别率
- Auto enhance-and-retry on failed decode: 2× upscale + grayscale + contrast stretch
- 连接带重试链:失败自动重新扫描后最多重试 3 次,错误详情进通知
- Retry chain: auto rescan + up to 3 connection attempts, error details in notifications
- 扫码窗开着就持续扫描(心跳保活);关闭后自动释放摄像头,不占资源
- Camera stays active while the panel is open (heartbeat keep-alive); released automatically on close

### 网址二维码 / URL QR codes

- 扫到 `http/https` 链接直接弹窗,点击「打开」用默认浏览器跳转,无需手动输入
- `http/https` links pop up with an **Open** button (default browser)
- 支持省略协议的域名形式(如 `example.com`、`www.example.com`、`sub.domain.com.cn/path?q=1`),自动补全 `https://`
- Domain-only URLs supported (e.g. `example.com`, `www.example.com`) — `https://` prepended automatically

### 截图扫码 / Screenshot scanning

- 标题右侧的相机按钮,一键调起 niri 选区截图(沿用系统截图 UI 与保存路径),框选完自动识别并弹窗
- Camera button launches niri's region screenshot (reuses system screenshot UI and save path); image decoded automatically after selection
- 支持 WiFi / 网址 / 纯文本二维码;截图无二维码会显示截图 3 秒并提示「图片中未找到二维码」
- WiFi / URL / plain-text QR codes supported; no QR found shows the screenshot for 3s with a "no QR code found" message
- 按 Esc 取消截图:静默关闭,不自动重开面板;20 秒等待期内按 Alt+S 可重新打开面板(摄像头界面)
- Press Esc to cancel: silently closes without reopening the panel; Alt+S within the 20s wait reopens the camera view
- 识别的截图图片会放大定位到二维码区域展示
- Detected QR region is zoomed in for display

### 图片扫码 / Image scanning

- 标题右侧的文件夹按钮,用文件选择器选一张本地图片(`png/jpg/jpeg/webp/bmp/gif/ico`),图片会以同取景框尺寸显示
- Folder button opens a file picker (`png/jpg/jpeg/webp/bmp/gif/ico`); the image is shown in the same viewport size
- 解码期间显示「识别中…」;识别到二维码后放大定位到二维码区域 3 秒,再回原图;识别后 6 秒自动回到摄像头画面
- Shows "Decoding…" while analyzing; zooms to the QR region for 3s, back to the image, returns to the camera after 6s
- 图片里的 WiFi/网址二维码同样弹窗可连接/打开;图片中无二维码会提示「图片中未找到二维码」
- WiFi/URL QRs inside images pop up as usual; "no QR code found in the image" when nothing detected
- 图片扫码期间摄像头画面仍实时取景(不暂停)
- Camera keeps running in the background during image scan

### 无法识别的二维码 / Unrecognized QR codes

- 识别成功但不含 WiFi/网址信息的二维码(纯文本等),弹窗提示「该二维码无法被识别」,倒数 3 秒后回到扫描界面
- Valid QR without WiFi/URL content (e.g. plain text) shows "This QR code cannot be recognized" and returns after a 3s countdown

## 安装 / Installation

**在线一键安装 / Online one-liner:**

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/install.sh | bash
```

**在线卸载 / Online uninstall:**

```bash
curl -fsSL https://raw.githubusercontent.com/StarWhiteIsBusy/nyx-scanner/refs/heads/main/uninstall.sh | bash
```

**本地安装与卸载 / Local:**

```bash
./install.sh            # 安装到 ~/.local/share/noctalia/plugins/nyx-scanner/ / installs to the default plugin dir
./install.sh <目录>     # 安装到自定义目录(跳过启用步骤) / custom directory (skips enabling)
./uninstall.sh          # 卸载(停止 helper、禁用插件、删除数据) / uninstall (stop helper, disable plugin, remove data)
```

安装后重启 Noctalia,在「设置 → 插件」启用 `starwhite/scan_wifi`。设置项:摄像头设备、分辨率、弹窗超时。
Restart Noctalia after installing, then enable `starwhite/scan_wifi` in Settings → Plugins. Settings: camera device, resolution, popup timeout.

## 依赖 / Dependencies

`python3` `ffmpeg` `zbar-tools`(zbarimg) `zenity`(文件选择器) `nmcli`(networkmanager);可选 `python3-pil`(无它时二维码识别率下降)。
`python3` `ffmpeg` `zbar-tools` (zbarimg) `zenity` (file picker) `nmcli` (NetworkManager); optional `python3-pil` (higher decode rate).

## 快捷键 / Key binding

niri(`~/.config/niri/config.kdl`):

```kdl
Alt+S { spawn "noctalia" "msg" "panel-toggle" "starwhite/scan_wifi:scanner" }
```

改完 `niri msg action load-config-file` 生效。Noctalia 的快捷键设置栏只管理其内置操作,无法绑定插件面板。
Reload with `niri msg action load-config-file`. Noctalia's own keybind settings only manage built-in actions and cannot bind plugin panels.

## 结构 / Structure

- `panel_scanner.luau` — 扫描浮窗(摄像头画面 + 识别弹窗 + 截图/图片扫码 + 心跳保活) / scanning panel
- `helper/scan_helper.py` — ffmpeg 抓帧 → zbarimg 解码 → JSON 行输出;`--image`/`--screenshot` 模式 / capture → decode → JSON lines; image & screenshot modes
- `translations/` — en / zh / zh-Hans(Noctalia 语言名 `zh-Hans`;若面板为英文,在 `~/.local/state/noctalia/settings.toml` 加 `[appearance] language = "zh-Hans"` / for English UI set `zh-Hans`)
- `install.sh` / `uninstall.sh` — 单文件安装/卸载程序,可直接 `curl ... | bash` 在线执行 / single-file installer & uninstaller, pipe via curl

