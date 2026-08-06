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
