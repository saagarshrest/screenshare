#!/usr/bin/env python3
"""ShareScreen host for Linux and Windows: use an Android phone as an extra display.

Speaks the same protocol as the Mac app, so the same Android app works with all three:
  - UDP 8782  discovery: broadcasts "MACSCREEN 8780 <name>", answers "MACSCREEN?"
  - HTTP 8780 /ping -> "macscreen h264:8783"; / -> browser viewer page
  - WS   8781 browser viewer: binary JPEG frames, text status
  - TCP  8783 video: packets of [type u8][length u32 BE][payload]
              1 = config (width u32, height u32, SPS+PPS Annex-B)
              2 = keyframe, 3 = frame (Annex-B H.264), 4 = status text
              5 = audio (PCM s16le, 48 kHz, stereo)

Capture:
  - Linux X11: xrandr virtual monitor + ffmpeg x11grab
  - Linux Wayland: xdg-desktop-portal ScreenCast (virtual monitor on GNOME/KDE) + GStreamer
  - Windows: ffmpeg ddagrab (Desktop Duplication) on any monitor
"""

import argparse
import atexit
import base64
import hashlib
import http.server
import os
import re
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

HTTP_PORT = 8780
WS_PORT = 8781
DISCOVERY_PORT = 8782
VIDEO_PORT = 8783
MONITOR_NAME = "ShareScreen"
VERSION = "1.1.0"
IS_WINDOWS = sys.platform == "win32"
MAX_BACKLOG = 600_000      # bytes queued per viewer before we skip to the next keyframe
MAX_GOP_CACHE = 4_000_000  # bytes of the current GOP kept for instant start
NO_WINDOW = 0x08000000 if IS_WINDOWS else 0

# Same presets as the Mac app. Long side capped at 1920: what phone decoders handle at 60 fps.
QUALITIES = {
    "fast":     {"title": "Fast (best for Wi‑Fi)", "max": 1280, "bitrate": 5,  "jpeg": 9},
    "balanced": {"title": "Balanced",              "max": 1920, "bitrate": 10, "jpeg": 6},
    "sharp":    {"title": "Sharp (best over USB)", "max": 1920, "bitrate": 20, "jpeg": 4},
}


LOG_PATH = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache"),
                        "ShareScreen", "sharescreen.log")
_log_file = None


def log(*args):
    """To the terminal, or to LOG_PATH when there is none (the windowed Windows app)."""
    global _log_file
    out = sys.stderr
    if out is None:
        if _log_file is None:
            os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
            _log_file = open(LOG_PATH, "w", encoding="utf-8", buffering=1)
            sys.stdout = sys.stdout or _log_file
        out = _log_file
    print(time.strftime("%H:%M:%S"), *args, file=out, flush=True)


def resource(name):
    return os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.realpath(__file__))), name)


def ffmpeg_path():
    bundled = resource("ffmpeg.exe" if IS_WINDOWS else "ffmpeg")
    return bundled if os.path.exists(bundled) else "ffmpeg"


def run(cmd, check=True):
    log("$", " ".join(cmd))
    return subprocess.run(cmd, check=check, capture_output=True, text=True, creationflags=NO_WINDOW)


def fit(w, h, longest):
    scale = min(1.0, longest / max(w, h))
    return int(w * scale) & ~1, int(h * scale) & ~1


# ---------------------------------------------------------------- monitors

def windows_monitors():
    """[(index, x, y, width, height, is_primary)] in EnumDisplayMonitors order.
    Also records which ones are virtual (a display driver with no real screen)."""
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # real pixels, not scaled
    except (AttributeError, OSError):
        user32.SetProcessDPIAware()

    class MONITORINFOEX(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                    ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD),
                    ("szDevice", wintypes.WCHAR * 32)]

    class DISPLAY_DEVICE(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("DeviceName", wintypes.WCHAR * 32),
                    ("DeviceString", wintypes.WCHAR * 128), ("StateFlags", wintypes.DWORD),
                    ("DeviceID", wintypes.WCHAR * 128), ("DeviceKey", wintypes.WCHAR * 128)]

    adapters = {}  # \.\DISPLAY1 -> "NVIDIA GeForce ..." / "Virtual Display Driver"
    n = 0
    while True:
        d = DISPLAY_DEVICE()
        d.cb = ctypes.sizeof(d)
        if not user32.EnumDisplayDevicesW(None, n, ctypes.byref(d), 0):
            break
        adapters[d.DeviceName] = d.DeviceString
        n += 1

    found = []
    _monitor_virtual.clear()
    proc = ctypes.WINFUNCTYPE(ctypes.c_int, wintypes.HMONITOR, wintypes.HDC,
                              ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

    def callback(handle, _dc, _rect, _data):
        info = MONITORINFOEX()
        info.cbSize = ctypes.sizeof(MONITORINFOEX)
        user32.GetMonitorInfoW(handle, ctypes.byref(info))
        r = info.rcMonitor
        name = adapters.get(info.szDevice, "").lower()
        _monitor_virtual[len(found)] = any(k in name for k in VIRTUAL_DISPLAY_HINTS)
        found.append((len(found), r.left, r.top, r.right - r.left, r.bottom - r.top, bool(info.dwFlags & 1)))
        return 1

    user32.EnumDisplayMonitors(None, None, proc(callback), 0)
    return found


VIRTUAL_DISPLAY_HINTS = ("virtual", "idd", "parsec", "spacedesk", "usbmmidd", "amyuni")
_monitor_virtual = {}


def reuse_port(sock):
    """Quick restarts on macOS/Linux. On Windows SO_REUSEADDR would let a second
    copy silently share the ports with the first, so ask for exclusive use."""
    if IS_WINDOWS:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)


_ddagrab_sizes = None


def ddagrab_output(monitor, monitors):
    """The ddagrab output_idx showing this monitor, or None. Desktop Duplication
    numbers screens its own way (per GPU, and it can't see screens on a second
    GPU), so match by size, in order among same-sized monitors."""
    global _ddagrab_sizes
    if _ddagrab_sizes is None:
        _ddagrab_sizes = []
        for i in range(len(monitors) + 1):
            try:
                r = subprocess.run([ffmpeg_path(), "-hide_banner", "-f", "lavfi", "-i",
                                    f"ddagrab=output_idx={i}:framerate=5", "-frames:v", "1", "-f", "null", "-"],
                                   capture_output=True, text=True, timeout=10, creationflags=NO_WINDOW)
            except (OSError, subprocess.SubprocessError):
                break
            m = re.search(r"Video: .*?(\d{2,5})x(\d{2,5})", r.stderr)
            if not m:
                break
            _ddagrab_sizes.append((int(m.group(1)) & ~1, int(m.group(2)) & ~1))
    size = lambda m: (m[3] & ~1, m[4] & ~1)
    rank = [m[0] for m in monitors if size(m) == size(monitor)].index(monitor[0])
    outputs = [i for i, s in enumerate(_ddagrab_sizes) if s == size(monitor)]
    return outputs[rank] if rank < len(outputs) else None


def modeline(w, h, fps):
    """Reduced-blanking style modeline; exact timings don't matter for a virtual output."""
    htotal, vtotal = w + 160, h + 35
    clock = htotal * vtotal * fps / 1e6
    return [f"{clock:.2f}", str(w), str(w + 48), str(w + 80), str(htotal),
            str(h), str(h + 3), str(h + 8), str(vtotal), "+hsync", "-vsync"]


class X11VirtualDisplay:
    """Adds extra monitors to the right of the current X screen (one per phone)."""

    def __init__(self):
        self.cleanup = []
        self.base = None  # (width, height) of the X screen before we touched it
        self.slots = []   # [(name, x, w, h)]

    def _screen(self):
        out = run(["xrandr", "--current"]).stdout
        m = re.search(r"current (\d+) x (\d+)", out)
        return (int(m.group(1)), int(m.group(2))), out

    def add(self, w, h, fps):
        """Create one more monitor; returns its (x, y) origin."""
        (sw, sh), out = self._screen()
        if self.base is None:
            self.base = (sw, sh)
        index = len(self.slots)
        name = f"{MONITOR_NAME}{index + 1}" if index else MONITOR_NAME
        used = {slot[0] for slot in self.slots}
        virtual = [o for o in re.findall(r"^(VIRTUAL[-\d]*) disconnected", out, re.M) if o not in used]
        if virtual:
            output = name = virtual[0]
            mode = f"sharescreen_{w}x{h}_{index}"
            run(["xrandr", "--newmode", mode] + modeline(w, h, fps), check=False)
            run(["xrandr", "--addmode", output, mode])
            run(["xrandr", "--output", output, "--mode", mode, "--pos", f"{sw}x0"])
            self.cleanup = [["xrandr", "--output", output, "--off"],
                            ["xrandr", "--delmode", output, mode], ["xrandr", "--rmmode", mode]] + self.cleanup
            log(f"using driver output {output}")
        else:
            # Grow the framebuffer and declare a monitor in the new area. Window
            # managers that honour RandR monitors treat it like a real screen.
            run(["xrandr", "--fb", f"{sw + w}x{max(sh, h)}"])
            run(["xrandr", "--delmonitor", name], check=False)
            run(["xrandr", "--setmonitor", name, f"{w}/0x{h}/0+{sw}+0", "none"])
            self.cleanup = [["xrandr", "--delmonitor", name]] + self.cleanup
            log("using a logical RandR monitor")
        self.slots.append((name, sw, w, h))
        return sw, 0

    def destroy(self):
        for cmd in self.cleanup:
            run(cmd, check=False)
        if self.base and not any(c[1] == "--output" for c in self.cleanup):
            run(["xrandr", "--fb", f"{self.base[0]}x{self.base[1]}"], check=False)
        self.cleanup, self.slots, self.base = [], [], None


# ---------------------------------------------------------------- H.264 parsing

def split_nals(data):
    """Annex-B buffer -> list of (nal_type, bytes incl. start code)."""
    out, starts, i = [], [], 0
    while True:
        i = data.find(b"\x00\x00\x01", i)
        if i < 0:
            break
        start = i - 1 if i > 0 and data[i - 1] == 0 else i
        starts.append((start, i + 3))
        i += 3
    for n, (start, payload) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(data)
        if payload < len(data):
            out.append((data[payload] & 0x1F, data[start:end]))
    return out


class AccessUnitReader:
    """Splits an Annex-B stream with access unit delimiters into whole frames."""

    AUD = re.compile(b"\x00\x00\x00?\x01\x09")

    def __init__(self):
        self.buf = b""

    def feed(self, chunk):
        self.buf += chunk
        units = []
        while True:
            first = self.AUD.search(self.buf)
            if not first:
                break
            nxt = self.AUD.search(self.buf, first.end())
            if not nxt:
                self.buf = self.buf[first.start():]
                break
            units.append(self.buf[first.start():nxt.start()])
            self.buf = self.buf[nxt.start():]
        return units


# ---------------------------------------------------------------- video server

def packet(kind, payload):
    return struct.pack(">BI", kind, len(payload)) + payload


class Viewer:
    def __init__(self, sock, addr):
        self.sock, self.addr = sock, addr
        self.queue, self.pending = [], 0
        self.cond = threading.Condition()
        self.waiting_for_key = True
        self.alive = True
        self.stream = None  # the Stream this phone watches

    def push(self, data):
        with self.cond:
            self.queue.append(data)
            self.pending += len(data)
            self.cond.notify()

    def sender(self, on_dead):
        try:
            while self.alive:
                with self.cond:
                    while not self.queue and self.alive:
                        self.cond.wait(1)
                    batch, self.queue = self.queue, []
                for data in batch:
                    self.sock.sendall(data)
                    with self.cond:
                        self.pending -= len(data)
        except OSError:
            pass
        on_dead(self)

    def reader(self, on_reset, on_dead):
        try:
            while self.alive:
                data = self.sock.recv(1024)
                if not data:
                    break
                on_reset(self)  # the phone reset its decoder
        except OSError:
            pass
        on_dead(self)

    def close(self):
        self.alive = False
        with self.cond:
            self.cond.notify()
        try:
            self.sock.close()
        except OSError:
            pass


class Stream:
    """One encoded video stream and the phones watching it.

    Keeps the current GOP (config + keyframe + frames since), so a phone that
    connects or resets its decoder gets a picture immediately instead of
    waiting for the next keyframe."""

    def __init__(self, width, height):
        self.size = (width, height)
        self.viewers = set()
        self.lock = threading.Lock()
        self.config = None
        self.gop, self.gop_bytes, self.gop_ok = [], 0, False
        self.status = "Starting the display…"

    def attach(self, v):
        with self.lock:
            v.stream = self
            self.viewers.add(v)
            v.push(packet(4, self.status.encode()))
            self._replay(v)

    def detach(self, v):
        with self.lock:
            self.viewers.discard(v)
            return len(self.viewers)

    def reset_viewer(self, v):
        with self.lock:
            v.waiting_for_key = True
            self._replay(v)

    def _replay(self, v):
        if self.gop_ok and self.gop:
            for data in self.gop:
                v.push(data)
            v.waiting_for_key = False

    def send_status(self, text):
        with self.lock:
            self.status = text
            self.gop, self.gop_bytes, self.gop_ok = [], 0, False
            for v in self.viewers:
                v.waiting_for_key = True
                v.push(packet(4, text.encode()))

    def send_audio(self, pcm):
        data = packet(5, pcm)
        with self.lock:
            for v in self.viewers:
                if not v.waiting_for_key and v.pending < MAX_BACKLOG:
                    v.push(data)

    def send_unit(self, unit):
        nals = split_nals(unit)
        types = {t for t, _ in nals}
        is_key = 5 in types
        frame = b"".join(n for t, n in nals if t not in (7, 8, 9))
        with self.lock:
            if 7 in types:
                csd = b"".join(n for t, n in nals if t in (7, 8))
                self.config = struct.pack(">II", *self.size) + csd
            if not frame or self.config is None:
                return
            cfg = packet(1, self.config)
            data = packet(2 if is_key else 3, frame)
            if is_key:
                self.gop, self.gop_bytes, self.gop_ok = [cfg, data], len(cfg) + len(data), True
            elif self.gop_ok:
                self.gop.append(data)
                self.gop_bytes += len(data)
                if self.gop_bytes > MAX_GOP_CACHE:
                    self.gop, self.gop_ok = [], False
            for v in self.viewers:
                if v.waiting_for_key:
                    if not is_key:
                        continue
                    v.waiting_for_key = False
                    v.push(cfg)
                elif v.pending > MAX_BACKLOG:
                    v.waiting_for_key = True  # network can't keep up: skip to the next keyframe
                    continue
                elif is_key:
                    v.push(cfg)
                v.push(data)


class VideoServer:
    """Accepts phones on 8783 and hands each one to a Stream chosen by the host."""

    def __init__(self, host):
        self.host = host
        self.viewers = set()
        self.lock = threading.Lock()
        self.sock = None

    def start(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        reuse_port(srv)
        srv.bind(("0.0.0.0", VIDEO_PORT))
        srv.listen(8)
        self.sock = srv
        threading.Thread(target=self._accept, args=(srv,), daemon=True).start()

    def count(self):
        with self.lock:
            return len(self.viewers)

    def _accept(self, srv):
        while True:
            try:
                sock, addr = srv.accept()
            except OSError:
                return
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
            v = Viewer(sock, addr)
            log("phone connected", addr[0])
            with self.lock:
                self.viewers.add(v)
            threading.Thread(target=v.sender, args=(self._remove,), daemon=True).start()
            threading.Thread(target=v.reader, args=(lambda v: v.stream and v.stream.reset_viewer(v),
                                                    self._remove), daemon=True).start()
            self.host.phone_connected(v)

    def _remove(self, v):
        with self.lock:
            if v not in self.viewers:
                return
            self.viewers.discard(v)
        v.close()
        log("phone left", v.addr[0])
        self.host.phone_left(v)


# ---------------------------------------------------------------- encoders

ENCODER_ARGS = {
    "x264": lambda gop, br: ["-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast",
                             "-tune", "zerolatency", "-profile:v", "high", "-bf", "0", "-g", str(gop),
                             "-b:v", f"{br}M", "-maxrate", f"{br * 2}M", "-bufsize", f"{br}M",
                             "-x264-params", "aud=1:repeat-headers=1"],
    "nvenc": lambda gop, br: ["-pix_fmt", "yuv420p", "-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ull",
                              "-zerolatency", "1", "-bf", "0", "-g", str(gop), "-aud", "1",
                              "-b:v", f"{br}M", "-maxrate", f"{br * 2}M", "-bufsize", f"{br}M"],
    "qsv": lambda gop, br: ["-pix_fmt", "nv12", "-c:v", "h264_qsv", "-preset", "veryfast",
                            "-low_power", "1", "-bf", "0", "-g", str(gop), "-aud", "1", "-b:v", f"{br}M"],
    "amf": lambda gop, br: ["-pix_fmt", "yuv420p", "-c:v", "h264_amf", "-usage", "ultralowlatency",
                            "-bf", "0", "-g", str(gop), "-aud", "1", "-b:v", f"{br}M"],
    "vaapi": lambda gop, br: ["-vaapi_device", "/dev/dri/renderD128", "-vf", "format=nv12,hwupload",
                              "-c:v", "h264_vaapi", "-bf", "0", "-g", str(gop), "-aud", "1", "-b:v", f"{br}M"],
}


def pick_encoder():
    """First GPU encoder that actually works on this machine, else x264 (CPU)."""
    candidates = ["nvenc", "qsv", "amf"] if IS_WINDOWS else (["vaapi"] if os.path.exists("/dev/dri/renderD128") else [])
    for name in candidates:
        cmd = [ffmpeg_path(), "-hide_banner", "-loglevel", "error", "-f", "lavfi",
               "-i", "testsrc2=size=640x360:rate=30", "-frames:v", "5"]
        args = ENCODER_ARGS[name](30, 5)
        if name == "vaapi":
            args[3] = "format=nv12,hwupload"
        try:
            ok = subprocess.run(cmd + args + ["-f", "null", "-"], capture_output=True, timeout=15,
                                creationflags=NO_WINDOW).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        if ok:
            log(f"using the {name} hardware encoder")
            return name
    log("using the x264 CPU encoder")
    return "x264"


class Pipeline:
    """One ffmpeg (or GStreamer) process: screen -> H.264 -> Stream. Runs while watched."""

    def __init__(self, stream, source_args, out_size, fps, bitrate, encoder, scale_filter=True):
        self.stream = stream
        self.source_args, self.out_size, self.fps = source_args, out_size, fps
        self.bitrate, self.encoder, self.scale_filter = bitrate, encoder, scale_filter
        self.proc = None
        self.lock = threading.Lock()

    def command(self):
        if self.source_args and self.source_args[0] == "gst":
            return self.source_args[1:]
        gop = max(1, self.fps // 2)
        enc = ENCODER_ARGS[self.encoder](gop, self.bitrate)
        w, h = self.out_size
        scale = f"scale={w}:{h}:flags=bicubic"
        if self.encoder == "vaapi":
            enc[3] = f"{scale},format=nv12,hwupload"
        elif self.scale_filter:
            enc = ["-vf", scale] + enc
        return ([ffmpeg_path(), "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer"]
                + self.source_args + enc + ["-f", "h264", "-"])

    def running(self):
        return self.proc is not None

    def start(self):
        with self.lock:
            if self.proc:
                return
            self.proc = subprocess.Popen(self.command(), stdout=subprocess.PIPE, creationflags=NO_WINDOW,
                                         pass_fds=getattr(self, "pass_fds", ()))
            threading.Thread(target=self._pump, args=(self.proc,), daemon=True).start()
            log("encoder started", f"{self.out_size[0]}x{self.out_size[1]}", self.encoder)

    def _pump(self, proc):
        reader = AccessUnitReader()
        while True:
            chunk = proc.stdout.read1(1 << 16)
            if not chunk:
                break
            for unit in reader.feed(chunk):
                self.stream.send_unit(unit)
        if proc.wait() != 0 and self.proc is proc:
            self.stream.send_status("Screen capture stopped. Check the ShareScreen log for errors.")

    def stop(self):
        with self.lock:
            if not self.proc:
                return
            proc, self.proc = self.proc, None
        proc.terminate()
        try:
            proc.wait(2)
        except subprocess.TimeoutExpired:
            proc.kill()
        log("encoder stopped")


class JpegPipeline:
    """MJPEG for the browser viewer: ffmpeg -> individual JPEGs -> WebSocket."""

    def __init__(self, source_args, out_size, quality, on_frame):
        self.source_args, self.out_size, self.quality, self.on_frame = source_args, out_size, quality, on_frame
        self.proc = None

    def start(self):
        if self.proc or not self.source_args or self.source_args[0] == "gst":
            return
        w, h = self.out_size
        cmd = ([ffmpeg_path(), "-hide_banner", "-loglevel", "error"] + self.source_args
               + ["-vf", f"scale={w}:{h},fps=30", "-c:v", "mjpeg", "-q:v", str(self.quality),
                  "-f", "mjpeg", "-"])
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, creationflags=NO_WINDOW)
        threading.Thread(target=self._pump, args=(self.proc,), daemon=True).start()

    def _pump(self, proc):
        buf = b""
        while True:
            chunk = proc.stdout.read1(1 << 16)
            if not chunk:
                return
            buf += chunk
            while True:
                end = buf.find(b"\xff\xd9")
                if end < 0:
                    break
                start = buf.find(b"\xff\xd8")
                if 0 <= start < end:
                    self.on_frame(buf[start:end + 2])
                buf = buf[end + 2:]

    def stop(self):
        if self.proc:
            self.proc.terminate()
            self.proc = None


# ---------------------------------------------------------------- audio

class AudioCapture:
    """Computer sound -> PCM s16le 48 kHz stereo -> every stream. Off by default."""

    CHUNK = 48000 * 4 // 50  # 20 ms

    def __init__(self, on_pcm):
        self.on_pcm = on_pcm
        self.proc = None
        self.thread = None
        self.running = False

    def start(self):
        if self.running:
            return
        self.running = True
        if IS_WINDOWS:
            self.thread = threading.Thread(target=self._windows_loop, daemon=True)
            self.thread.start()
            return
        cmd = None
        if shutil.which("parec") and shutil.which("pactl"):
            sink = run(["pactl", "get-default-sink"], check=False).stdout.strip() or "@DEFAULT_SINK@"
            cmd = ["parec", "--device", f"{sink}.monitor", "--format=s16le", "--rate=48000",
                   "--channels=2", "--latency-msec=20", "--raw"]
        elif shutil.which("pw-record"):
            cmd = ["pw-record", "--target", "@DEFAULT_MONITOR@", "--format", "s16", "--rate", "48000",
                   "--channels", "2", "-"]
        if not cmd:
            log("sound: no PulseAudio/PipeWire tools found (install pulseaudio-utils)")
            self.running = False
            return
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        self.thread = threading.Thread(target=self._pipe_loop, args=(self.proc,), daemon=True)
        self.thread.start()
        log("sound on")

    def _pipe_loop(self, proc):
        while self.running:
            data = proc.stdout.read(self.CHUNK)
            if not data:
                break
            self.on_pcm(data)

    def _windows_loop(self):
        try:
            import numpy
            import soundcard
        except ImportError:
            log("sound: the soundcard package is missing")
            self.running = False
            return
        try:
            speaker = soundcard.default_speaker()
            mic = soundcard.get_microphone(speaker.name, include_loopback=True)
            with mic.recorder(samplerate=48000, channels=2, blocksize=960) as rec:
                log("sound on")
                while self.running:
                    frames = rec.record(numframes=960)
                    pcm = (numpy.clip(frames, -1, 1) * 32767).astype("<i2").tobytes()
                    self.on_pcm(pcm)
        except Exception as e:  # device unplugged, exclusive mode, ...
            log("sound stopped:", e)
        self.running = False

    def stop(self):
        self.running = False
        if self.proc:
            self.proc.terminate()
            self.proc = None


# ---------------------------------------------------------------- Wayland (portal + GStreamer)

class WaylandScreenCast:
    """Asks xdg-desktop-portal for a screen (or a new virtual monitor on GNOME 46+/KDE 6)
    and returns a PipeWire fd + node id that GStreamer can read."""

    VIRTUAL, MONITOR = 4, 1

    def __init__(self):
        self.session = None
        self.fd = None
        self.node = None
        self.size = None

    def open(self, virtual=True):
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        portal = Gio.DBusProxy.new_sync(bus, 0, None, "org.freedesktop.portal.Desktop",
                                        "/org/freedesktop/portal/desktop",
                                        "org.freedesktop.portal.ScreenCast", None)
        sender = bus.get_unique_name()[1:].replace(".", "_")
        loop = GLib.MainLoop()
        counter = [0]

        def call(method, signature, args, options):
            """Portal requests answer through a Request object's Response signal."""
            counter[0] += 1
            token = f"sharescreen{os.getpid()}_{counter[0]}"
            path = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
            result = {}

            def on_response(_conn, _sender, _path, _iface, _signal, params, _data):
                result["code"], result["results"] = params.unpack()
                loop.quit()

            sub = bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
                                       "Response", path, None, 0, on_response, None)
            options = dict(options, handle_token=GLib.Variant("s", token))
            portal.call_sync(method, GLib.Variant(signature, (*args, options)), 0, -1, None)
            loop.run()
            bus.signal_unsubscribe(sub)
            if result.get("code") != 0:
                raise RuntimeError("Screen sharing was cancelled or isn't allowed.")
            return result["results"]

        available = portal.get_cached_property("AvailableSourceTypes")
        types = available.unpack() if available else self.MONITOR
        source = self.VIRTUAL if virtual and types & self.VIRTUAL else self.MONITOR
        if virtual and source != self.VIRTUAL:
            log("this desktop can't make a virtual monitor; pick a screen to mirror in the dialog")

        created = call("CreateSession", "(a{sv})", (),
                       {"session_handle_token": GLib.Variant("s", f"sharescreen{os.getpid()}")})
        self.session = created["session_handle"]
        call("SelectSources", "(oa{sv})", (self.session,), {
            "types": GLib.Variant("u", source), "multiple": GLib.Variant("b", False),
            "cursor_mode": GLib.Variant("u", 2)})  # cursor drawn into the video
        started = call("Start", "(osa{sv})", (self.session, ""), {})
        self.node, props = started["streams"][0]
        if "size" in props:
            self.size = (int(props["size"][0]) & ~1, int(props["size"][1]) & ~1)
        res, fds = portal.call_with_unix_fd_list_sync(
            "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (self.session, {})), 0, -1, None, None)
        self.fd = fds.get(res.unpack()[0])
        os.set_inheritable(self.fd, True)
        self._keep = (bus, portal)  # the session lives as long as this D-Bus connection
        return self

    def close(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None


# ---------------------------------------------------------------- browser viewer

VIEWER_HTML = r"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#000000"><title>ShareScreen</title>
<style>
  html, body { margin: 0; height: 100%; background: #000; overflow: hidden; touch-action: none; }
  canvas { position: fixed; inset: 0; width: 100%; height: 100%; object-fit: contain; display: block; }
  #status { position: fixed; inset: 0; display: flex; flex-direction: column; gap: 10px;
            align-items: center; justify-content: center; padding: 24px; text-align: center;
            color: #8b9099; font: 15px/1.4 -apple-system, system-ui, Roboto, sans-serif; }
  #status b { color: #e8eaed; font-weight: 600; font-size: 17px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #5b8def; animation: p 1.2s ease-in-out infinite; }
  @keyframes p { 50% { opacity: .25; } }
</style></head><body>
<canvas id="c"></canvas>
<div id="status"><div class="dot"></div><b>ShareScreen</b><span id="msg">Connecting to your computer…</span></div>
<script>
  const canvas = document.getElementById('c'), ctx = canvas.getContext('2d', { alpha: false });
  const statusBox = document.getElementById('status'), msg = document.getElementById('msg');
  let latest = null, drawing = false;
  function showStatus(t) { msg.textContent = t; statusBox.style.display = 'flex'; }
  function draw() {
    if (drawing || !latest) return;
    const blob = latest; latest = null; drawing = true;
    createImageBitmap(blob).then(img => {
      if (canvas.width !== img.width || canvas.height !== img.height) { canvas.width = img.width; canvas.height = img.height; }
      ctx.drawImage(img, 0, 0); if (img.close) img.close(); statusBox.style.display = 'none';
    }).catch(() => {}).finally(() => { drawing = false; if (latest) requestAnimationFrame(draw); });
  }
  function connect() {
    const ws = new WebSocket('ws://' + location.hostname + ':8781/');
    ws.binaryType = 'blob';
    ws.onmessage = e => { if (typeof e.data === 'string') { showStatus(e.data); return; } latest = e.data; requestAnimationFrame(draw); };
    ws.onclose = () => { showStatus('Waiting for your computer…'); setTimeout(connect, 1000); };
  }
  connect();
  document.addEventListener('click', () => { const el = document.documentElement;
    if (!document.fullscreenElement && el.requestFullscreen) el.requestFullscreen().catch(() => {}); });
  async function keepAwake() { try { if ('wakeLock' in navigator) await navigator.wakeLock.request('screen'); } catch (e) {} }
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') keepAwake(); });
  keepAwake();
</script></body></html>"""


class WebSocketServer:
    """Minimal WebSocket server (send-only) for the browser viewer on 8781.
    Each client holds at most one pending frame; newer frames replace it."""

    GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, on_count):
        self.clients = {}  # sock -> [pending frame, condition]
        self.lock = threading.Lock()
        self.on_count = on_count
        self.status = "Starting the display…"

    def start(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        reuse_port(srv)
        srv.bind(("0.0.0.0", WS_PORT))
        srv.listen(8)
        threading.Thread(target=self._accept, args=(srv,), daemon=True).start()

    def _accept(self, srv):
        while True:
            sock, _ = srv.accept()
            threading.Thread(target=self._handshake, args=(sock,), daemon=True).start()

    def _handshake(self, sock):
        try:
            sock.settimeout(5)
            req = b""
            while b"\r\n\r\n" not in req and len(req) < 8192:
                chunk = sock.recv(1024)
                if not chunk:
                    return sock.close()
                req += chunk
            m = re.search(rb"Sec-WebSocket-Key:\s*(\S+)", req, re.I)
            if not m:
                return sock.close()
            accept = base64.b64encode(hashlib.sha1(m.group(1) + self.GUID).digest())
            sock.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                         b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            sock.settimeout(None)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            return sock.close()
        slot = [self._frame(self.status.encode(), text=True), threading.Condition()]
        with self.lock:
            self.clients[sock] = slot
            n = len(self.clients)
        self.on_count(n)
        threading.Thread(target=self._drain, args=(sock,), daemon=True).start()
        try:
            while True:
                pending, cond = slot
                with cond:
                    while slot[0] is None:
                        cond.wait()
                    data, slot[0] = slot[0], None
                sock.sendall(data)
        except OSError:
            pass
        self._drop(sock)

    def _drain(self, sock):
        try:
            while sock.recv(1024):
                pass
        except OSError:
            pass
        self._drop(sock)

    def _drop(self, sock):
        with self.lock:
            slot = self.clients.pop(sock, None)
            n = len(self.clients)
        if slot:
            with slot[1]:
                slot[0] = b""  # wake the sender so it exits on the closed socket
                slot[1].notify()
            try:
                sock.close()
            except OSError:
                pass
            self.on_count(n)

    @staticmethod
    def _frame(payload, text=False):
        head = bytes([0x81 if text else 0x82])
        n = len(payload)
        if n < 126:
            head += bytes([n])
        elif n < 65536:
            head += bytes([126]) + struct.pack(">H", n)
        else:
            head += bytes([127]) + struct.pack(">Q", n)
        return head + payload

    def count(self):
        with self.lock:
            return len(self.clients)

    def broadcast(self, payload, text=False):
        if text:
            self.status = payload.decode()
        data = self._frame(payload, text)
        with self.lock:
            slots = list(self.clients.values())
        for slot in slots:
            with slot[1]:
                slot[0] = data
                slot[1].notify()


class HttpHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/ping"):
            body, kind = f"macscreen h264:{VIDEO_PORT}".encode(), "text/plain; charset=utf-8"
        else:
            body, kind = VIEWER_HTML.encode(), "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def start_http():
    socketserver.ThreadingTCPServer.allow_reuse_address = not IS_WINDOWS  # see reuse_port()
    httpd = socketserver.ThreadingTCPServer(("0.0.0.0", HTTP_PORT), HttpHandler)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()


# ---------------------------------------------------------------- network helpers

def local_ips():
    ips = []
    try:  # the address used to reach the LAN; works on every OS without extra tools
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        if IS_WINDOWS:
            ips += socket.gethostbyname_ex(socket.gethostname())[2]
        else:
            ips += subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split()
    except OSError:
        pass
    seen = []
    for ip in ips:
        if "." in ip and not ip.startswith("127.") and ip not in seen:
            seen.append(ip)
    return seen


def broadcast_addresses():
    targets = {"255.255.255.255"}
    for ip in local_ips():  # assume /24, the usual home / hotspot network
        targets.add(ip.rsplit(".", 1)[0] + ".255")
    if not IS_WINDOWS:
        try:
            out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True).stdout
            targets.update(re.findall(r"brd (\d+\.\d+\.\d+\.\d+)", out))
        except OSError:
            pass
    return targets


def start_discovery():
    message = f"MACSCREEN {HTTP_PORT} {socket.gethostname()}".encode()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", DISCOVERY_PORT))

    def listen():
        while True:
            try:
                data, addr = sock.recvfrom(512)
            except OSError:  # Windows reports ICMP "port unreachable" here
                continue
            if data.startswith(b"MACSCREEN?"):
                try:
                    sock.sendto(message, addr)
                except OSError:
                    pass

    def announce():
        while True:
            for target in broadcast_addresses():
                try:
                    sock.sendto(message, (target, DISCOVERY_PORT))
                except OSError:
                    pass
            time.sleep(1)

    threading.Thread(target=listen, daemon=True).start()
    threading.Thread(target=announce, daemon=True).start()


def viewer_url():
    ips = local_ips()
    return f"http://{ips[0] if ips else '127.0.0.1'}:{HTTP_PORT}/"


def print_qr(url):
    try:
        import qrcode
    except ImportError:
        return
    qr = qrcode.QRCode(border=1)
    qr.add_data(url)
    if sys.stderr is not None:
        qr.print_ascii(out=sys.stderr, invert=True)


# ---------------------------------------------------------------- host controller

class Host:
    """Owns the monitors, encoders and servers. The tray and the CLI both drive this."""

    def __init__(self, args):
        self.args = args
        self.enabled = True
        self.quality = args.quality
        self.encoder = args.encoder
        self.lock = threading.RLock()
        self.streams = []       # [(Stream, Pipeline, source_args, out_size)]
        self.assign = {}        # Viewer -> index into self.streams
        self.x11 = None
        self.wayland = []
        self.listeners = []     # callbacks for the tray: fn()
        self.server = VideoServer(self)
        self.ws = WebSocketServer(self._browser_count)
        self.jpeg = None
        self.audio = AudioCapture(self._on_pcm)
        self.sound = args.sound

    # --- setup

    def start(self):
        if self.encoder == "auto":
            self.encoder = "x264" if self.args.source == "test" else pick_encoder()
        self.server.start()
        self.ws.start()
        start_http()
        start_discovery()
        with self.lock:
            self._ensure_streams(1)

    def changed(self):
        for fn in self.listeners:
            try:
                fn()
            except Exception:
                pass

    def summary(self):
        phones = self.server.count()
        if not self.enabled:
            return "Off"
        return f"{phones} phone{'s' if phones != 1 else ''} connected" if phones else "Waiting for your phone…"

    def _preset(self):
        q = QUALITIES[self.quality]
        return q["max"], self.args.bitrate or q["bitrate"], q["jpeg"]

    def _make_source(self, index):
        """Returns (source_args, capture_size) for monitor slot `index`."""
        a = self.args
        if a.source == "test":
            return ["-re", "-f", "lavfi", "-i", f"testsrc2=size={a.width}x{a.height}:rate={a.fps}"], (a.width, a.height)
        if IS_WINDOWS:
            monitors = windows_monitors()
            if a.monitor is not None:
                pick = [m for m in monitors if m[0] == a.monitor] or monitors[:1]
            else:
                # Virtual monitors first: a real second screen already has a picture.
                extra = sorted((m for m in monitors if not m[5]),
                               key=lambda m: not _monitor_virtual.get(m[0], False))
                pick = (extra[index:index + 1] or ([] if index else monitors[:1]))
                if not extra and index == 0:
                    log("only one monitor found, so the phone mirrors your main screen.")
                    log("to extend instead, install the Virtual Display Driver (see the README) and restart.")
            if not pick:
                return None, None
            i, x, y, w, h, _ = pick[0]
            w, h = w & ~1, h & ~1
            out = ddagrab_output(pick[0], monitors)
            if out is not None:
                return ["-f", "lavfi", "-i", f"ddagrab=output_idx={out}:framerate={a.fps}:draw_mouse=1,"
                        f"hwdownload,format=bgra,crop={w}:{h}:0:0"], (w, h)
            # Desktop Duplication can't reach this screen (e.g. it's on a second GPU
            # in an Intel + NVIDIA PC), so capture its desktop rectangle through GDI.
            log(f"monitor {i} isn't reachable by Desktop Duplication; using GDI capture.")
            return ["-f", "gdigrab", "-framerate", str(min(a.fps, 30)), "-draw_mouse", "1",
                    "-offset_x", str(x), "-offset_y", str(y), "-video_size", f"{w}x{h}",
                    "-i", "desktop"], (w, h)
        if is_wayland():
            return self._wayland_source(index)
        display = os.environ.get("DISPLAY", ":0")
        if a.mirror:
            out = run(["xrandr", "--current"]).stdout
            m = re.search(r"current (\d+) x (\d+)", out)
            w, h = int(m.group(1)) & ~1, int(m.group(2)) & ~1
            x = y = 0
        else:
            if self.x11 is None:
                self.x11 = X11VirtualDisplay()
                atexit.register(self.x11.destroy)
            w, h = a.width, a.height
            x, y = self.x11.add(w, h, a.fps)
        return ["-f", "x11grab", "-draw_mouse", "1", "-framerate", str(a.fps),
                "-video_size", f"{w}x{h}", "-i", f"{display}+{x},{y}"], (w, h)

    def _wayland_source(self, index):
        cast = WaylandScreenCast().open(virtual=not self.args.mirror)
        self.wayland.append(cast)
        atexit.register(cast.close)
        size = cast.size or (self.args.width, self.args.height)
        longest, bitrate, _ = self._preset()
        w, h = fit(size[0], size[1], longest)
        gop = max(1, self.args.fps // 2)
        cmd = ["gst", "gst-launch-1.0", "-q",
               "pipewiresrc", f"fd={cast.fd}", f"path={cast.node}", "do-timestamp=true", "keepalive-time=1000",
               "!", "videoconvert", "!", "videoscale", "!", "videorate",
               "!", f"video/x-raw,format=I420,width={w},height={h},framerate={self.args.fps}/1",
               "!", "x264enc", "tune=zerolatency", "speed-preset=ultrafast", f"bitrate={bitrate * 1000}",
               f"key-int-max={gop}", "bframes=0", "aud=true", "byte-stream=true",
               "!", "video/x-h264,profile=high,stream-format=byte-stream", "!", "fdsink", "fd=1"]
        return cmd, size, cast.fd

    def _ensure_streams(self, count):
        while len(self.streams) < count:
            index = len(self.streams)
            made = self._make_source(index)
            fd = None
            if len(made) == 3:
                source, size, fd = made
            else:
                source, size = made
            if source is None:
                return False
            longest, bitrate, _ = self._preset()
            out = fit(size[0], size[1], longest) if source[0] != "gst" else size
            stream = Stream(*out)
            pipe = Pipeline(stream, source, out, self.args.fps, bitrate, self.encoder)
            if fd is not None:
                pipe.pass_fds = (fd,)
            stream.status = "Connected. Waiting for the first frame…"
            self.streams.append((stream, pipe, source, size))
        return True

    # --- phones

    def phone_connected(self, v):
        with self.lock:
            if not self.enabled:
                v.push(packet(4, b"ShareScreen is turned off on the computer."))
                return
            used = set(self.assign.values())
            index = 0
            if self.args.multi:
                index = next((i for i in range(len(self.streams) + 1) if i not in used), 0)
                if index >= len(self.streams) and not self._ensure_streams(index + 1):
                    index = 0
            self.assign[v] = index
            stream, pipe, _, _ = self.streams[index]
            stream.attach(v)
            pipe.start()
            if self.sound:
                self.audio.start()
        self.changed()

    def phone_left(self, v):
        with self.lock:
            index = self.assign.pop(v, None)
            if index is not None:
                stream, pipe, _, _ = self.streams[index]
                if stream.detach(v) == 0:
                    pipe.stop()
            if not self.assign:
                self.audio.stop()
        self.changed()

    def _on_pcm(self, pcm):
        for stream, _, _, _ in list(self.streams):
            stream.send_audio(pcm)

    # --- browser viewer

    def _browser_count(self, n):
        with self.lock:
            if n and not self.jpeg and self.enabled and self.streams:
                stream, _, source, size = self.streams[0]
                longest, _, quality = self._preset()
                self.jpeg = JpegPipeline(source, fit(size[0], size[1], min(longest, 1280)), quality,
                                         lambda jpg: self.ws.broadcast(jpg))
                self.jpeg.start()
            elif not n and self.jpeg:
                self.jpeg.stop()
                self.jpeg = None
        self.changed()

    # --- tray actions

    def restart_streams(self):
        """Re-create encoders after a quality/encoder change, keeping phones connected."""
        with self.lock:
            for stream, pipe, source, size in self.streams:
                was = pipe.running()
                pipe.stop()
                longest, bitrate, _ = self._preset()
                out = fit(size[0], size[1], longest) if source[0] != "gst" else size
                stream.size = out
                stream.send_status("Changing quality…")
                pipe.out_size, pipe.bitrate, pipe.encoder = out, bitrate, self.encoder
                if was:
                    pipe.start()
            if self.jpeg:
                self.jpeg.stop()
                self.jpeg = None
                self._browser_count(self.ws.count())
        self.changed()

    def set_monitor(self, index):
        """Windows: stream a different monitor (None = automatic)."""
        with self.lock:
            self.args.monitor = index
            viewers = list(self.assign)
            for stream, pipe, _, _ in self.streams:
                pipe.stop()
            self.streams, self.assign = [], {}
            if self.jpeg:
                self.jpeg.stop()
                self.jpeg = None
            self._ensure_streams(1)
            for v in viewers:
                v.waiting_for_key = True
                self.phone_connected(v)
            self._browser_count(self.ws.count())
        self.changed()

    def set_quality(self, name):
        self.quality = name
        self.restart_streams()

    def set_sound(self, on):
        with self.lock:
            self.sound = on
            if on and self.assign:
                self.audio.start()
            elif not on:
                self.audio.stop()
        self.changed()

    def set_enabled(self, on):
        with self.lock:
            self.enabled = on
            for stream, pipe, _, _ in self.streams:
                if on and stream.viewers:
                    pipe.start()
                    stream.send_status("Connected. Waiting for the first frame…")
                elif not on:
                    pipe.stop()
                    stream.send_status("ShareScreen is turned off on the computer.")
            if not on:
                self.audio.stop()
                if self.jpeg:
                    self.jpeg.stop()
                    self.jpeg = None
                self.ws.broadcast(b"ShareScreen is turned off on the computer.", text=True)
        self.changed()

    def shutdown(self):
        with self.lock:
            for _, pipe, _, _ in self.streams:
                pipe.stop()
            if self.jpeg:
                self.jpeg.stop()
            self.audio.stop()
            if self.x11:
                self.x11.destroy()
            for cast in self.wayland:
                cast.close()


def is_wayland():
    return not IS_WINDOWS and (os.environ.get("XDG_SESSION_TYPE") == "wayland"
                               or (os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY")))


# ---------------------------------------------------------------- main

def parse_args(argv=None):
    p = argparse.ArgumentParser(prog="sharescreen", description="Use an Android phone as an extra display.")
    p.add_argument("--width", type=int, default=2400, help="Linux: virtual display width (default 2400)")
    p.add_argument("--height", type=int, default=1080, help="Linux: virtual display height (default 1080)")
    p.add_argument("--portrait", action="store_true", help="swap width and height")
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--quality", choices=list(QUALITIES), default="balanced",
                   help="fast (Wi‑Fi), balanced, sharp (USB). Default: balanced")
    p.add_argument("--bitrate", type=int, default=0, help="Mbit/s; overrides the quality preset")
    p.add_argument("--mirror", action="store_true", help="mirror the main screen instead of extending")
    p.add_argument("--multi", action="store_true",
                   help="each phone gets its own extra monitor (Linux X11; Windows: one per virtual monitor)")
    p.add_argument("--sound", action="store_true", help="also play the computer's sound on the phone")
    p.add_argument("--encoder", choices=["auto"] + list(ENCODER_ARGS), default="auto",
                   help="auto (default: GPU if it works, else x264), x264, nvenc, qsv, amf, vaapi")
    p.add_argument("--monitor", type=int, default=None,
                   help="Windows: which monitor to stream (see --list-monitors)")
    p.add_argument("--list-monitors", action="store_true", help="Windows: list monitors and exit")
    p.add_argument("--no-tray", action="store_true", help="run in the terminal without a tray icon")
    p.add_argument("--version", action="store_true", help="show version and license notices")
    p.add_argument("--source", choices=["screen", "test"], default="screen", help=argparse.SUPPRESS)
    args = p.parse_args(argv)
    if args.portrait:
        args.width, args.height = args.height, args.width
    args.width -= args.width % 2
    args.height -= args.height % 2
    return args


def check_session(args):
    if args.source != "screen" or IS_WINDOWS:
        return
    if is_wayland():
        if not shutil.which("gst-launch-1.0"):
            sys.exit("Wayland needs GStreamer: sudo apt install gstreamer1.0-tools "
                     "gstreamer1.0-pipewire gstreamer1.0-plugins-ugly")
        try:
            import gi  # noqa: F401
        except ImportError:
            sys.exit("Wayland needs PyGObject: sudo apt install python3-gi")
    elif not os.environ.get("DISPLAY"):
        sys.exit("No graphical session found. Run ShareScreen from your desktop.")


def main(argv=None):
    sys.modules.setdefault("sharescreen", sys.modules[__name__])  # one copy for tray.py
    if sys.stderr is None:  # windowed app: send all output to the log file
        log(f"ShareScreen {VERSION}", " ".join(sys.argv[1:]))
    args = parse_args(argv)
    if args.version:
        print(f"ShareScreen {VERSION} (MIT) - https://github.com/saagarshrest/screenshare")
        notice = resource("THIRD_PARTY_NOTICES.txt")
        if os.path.exists(notice):
            print(open(notice, encoding="utf-8").read())
        return
    if IS_WINDOWS and args.list_monitors:
        for i, x, y, w, h, primary in windows_monitors():
            print(f"{i}: {w}x{h} at {x},{y}{'  (main)' if primary else ''}")
        return
    if IS_WINDOWS and getattr(sys, "frozen", False):
        log("includes FFmpeg (GPL v3). Run with --version for license and source details.")
    check_session(args)

    host = Host(args)
    try:
        host.start()
    except OSError as e:
        sys.exit(f"Can't open ports {HTTP_PORT}-{VIDEO_PORT} ({e}). Is ShareScreen already running?")
    except RuntimeError as e:
        sys.exit(str(e))
    atexit.register(host.shutdown)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    log(f"ready ({QUALITIES[host.quality]['title']}, {host.encoder}).")
    log("open ShareScreen on your phone; it finds this computer automatically.")
    url = viewer_url()
    log("no app? open this in the phone's browser:", url)
    print_qr(url)
    log("USB: adb reverse tcp:8780 tcp:8780 && adb reverse tcp:8781 tcp:8781 && adb reverse tcp:8783 tcp:8783")

    if not args.no_tray and args.source == "screen":
        try:
            import tray
        except ImportError:
            tray = None
        if tray and tray.available():
            tray.run(host)  # blocks until Quit
            return
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
