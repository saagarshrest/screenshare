#!/usr/bin/env python3
"""ShareScreen host for Linux (X11) and Windows: use an Android phone as an extra display.

Speaks the same protocol as the Mac app, so the existing Android app works as is:
  - UDP 8782  discovery: broadcasts "MACSCREEN 8780 <name>", answers "MACSCREEN?"
  - HTTP 8780 /ping -> "macscreen h264:8783"
  - TCP 8783  video: packets of [type u8][length u32 BE][payload]
              1 = config (width u32, height u32, SPS+PPS Annex-B)
              2 = keyframe, 3 = frame (Annex-B H.264), 4 = status text

The extra monitor is made with xrandr (a driver VIRTUAL output if there is one,
otherwise a logical monitor next to your screen). ffmpeg captures it with x11grab
and encodes H.264 with x264 tuned for zero latency.
"""

import argparse
import atexit
import http.server
import os
import re
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

HTTP_PORT = 8780
DISCOVERY_PORT = 8782
VIDEO_PORT = 8783
MONITOR_NAME = "ShareScreen"
IS_WINDOWS = sys.platform == "win32"
MAX_BACKLOG = 600_000  # bytes queued per viewer before we skip to the next keyframe


def ffmpeg_path():
    bundled = os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))),
                           "ffmpeg.exe" if IS_WINDOWS else "ffmpeg")
    return bundled if os.path.exists(bundled) else "ffmpeg"


# ---------------------------------------------------------------- Windows monitors

def windows_monitors():
    """[(index, x, y, width, height, is_primary)] in Desktop Duplication order."""
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # real pixels, not scaled
    except (AttributeError, OSError):
        user32.SetProcessDPIAware()

    class MONITORINFO(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                    ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]

    found = []
    proc = ctypes.WINFUNCTYPE(ctypes.c_int, wintypes.HMONITOR, wintypes.HDC,
                              ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

    def callback(handle, _dc, _rect, _data):
        info = MONITORINFO()
        info.cbSize = ctypes.sizeof(MONITORINFO)
        user32.GetMonitorInfoW(handle, ctypes.byref(info))
        r = info.rcMonitor
        found.append((len(found), r.left, r.top, r.right - r.left, r.bottom - r.top, bool(info.dwFlags & 1)))
        return 1

    user32.EnumDisplayMonitors(None, None, proc(callback), 0)
    return found


def log(*args):
    print("[sharescreen]", *args, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- virtual display

def run(cmd, check=True):
    log("$", " ".join(cmd))
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def modeline(w, h, fps):
    """Reduced-blanking style modeline; exact timings don't matter for a virtual output."""
    htotal, vtotal = w + 160, h + 35
    clock = htotal * vtotal * fps / 1e6
    return [f"{clock:.2f}", str(w), str(w + 48), str(w + 80), str(htotal),
            str(h), str(h + 3), str(h + 8), str(vtotal), "+hsync", "-vsync"]


class VirtualDisplay:
    """Adds an extra monitor to the right of the current X screen. Returns (x, y)."""

    def __init__(self, width, height, fps):
        self.w, self.h, self.fps = width, height, fps
        self.cleanup = []

    def screen_size(self):
        out = run(["xrandr", "--current"]).stdout
        m = re.search(r"current (\d+) x (\d+)", out)
        return (int(m.group(1)), int(m.group(2))), out

    def create(self):
        (sw, sh), out = self.screen_size()
        virtual = re.findall(r"^(VIRTUAL[-\d]*) disconnected", out, re.M)
        if virtual:
            return self._driver_output(virtual[0], sw)
        return self._logical_monitor(sw, sh)

    def _driver_output(self, output, sw):
        mode = f"sharescreen_{self.w}x{self.h}"
        run(["xrandr", "--newmode", mode] + modeline(self.w, self.h, self.fps), check=False)
        run(["xrandr", "--addmode", output, mode])
        # Teardown order: turn off, remove the mode from the output, delete the mode.
        self.cleanup = [["xrandr", "--output", output, "--off"],
                        ["xrandr", "--delmode", output, mode], ["xrandr", "--rmmode", mode]]
        run(["xrandr", "--output", output, "--mode", mode, "--pos", f"{sw}x0"])
        log(f"using driver output {output}")
        return sw, 0

    def _logical_monitor(self, sw, sh):
        # Grow the framebuffer and declare a monitor in the new area. Window
        # managers that honour RandR monitors treat it like a real screen.
        run(["xrandr", "--fb", f"{sw + self.w}x{max(sh, self.h)}"])
        run(["xrandr", "--delmonitor", MONITOR_NAME], check=False)
        run(["xrandr", "--setmonitor", MONITOR_NAME,
             f"{self.w}/0x{self.h}/0+{sw}+0", "none"])
        self.cleanup = [["xrandr", "--delmonitor", MONITOR_NAME], ["xrandr", "--fb", f"{sw}x{sh}"]]
        log("using a logical RandR monitor (no VIRTUAL output on this driver)")
        return sw, 0

    def destroy(self):
        for cmd in self.cleanup:
            run(cmd, check=False)
        self.cleanup = []


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
    """Splits an Annex-B stream with AUDs (x264 aud=1) into whole frames."""

    AUD = b"\x00\x00\x00\x01\x09"

    def __init__(self):
        self.buf = b""

    def feed(self, chunk):
        self.buf += chunk
        units = []
        while True:
            first = self.buf.find(self.AUD)
            if first < 0:
                break
            nxt = self.buf.find(self.AUD, first + len(self.AUD))
            if nxt < 0:
                self.buf = self.buf[first:]
                break
            units.append(self.buf[first:nxt])
            self.buf = self.buf[nxt:]
        return units


# ---------------------------------------------------------------- video server

class Viewer:
    def __init__(self, sock, addr):
        self.sock, self.addr = sock, addr
        self.queue, self.pending = [], 0
        self.cond = threading.Condition()
        self.waiting_for_key = True
        self.alive = True

    def push(self, packet):
        with self.cond:
            self.queue.append(packet)
            self.pending += len(packet)
            self.cond.notify()

    def sender(self, on_dead):
        try:
            while self.alive:
                with self.cond:
                    while not self.queue and self.alive:
                        self.cond.wait(1)
                    batch, self.queue = self.queue, []
                for packet in batch:
                    self.sock.sendall(packet)
                    with self.cond:
                        self.pending -= len(packet)
        except OSError:
            pass
        on_dead(self)

    def reader(self, on_key, on_dead):
        try:
            while self.alive:
                data = self.sock.recv(1024)
                if not data:
                    break
                self.waiting_for_key = True  # phone reset its decoder
                on_key()
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


def packet(kind, payload):
    return struct.pack(">BI", kind, len(payload)) + payload


class VideoServer:
    def __init__(self, width, height):
        self.size = (width, height)
        self.viewers = set()
        self.lock = threading.Lock()
        self.config = None
        self.status = "Starting the Linux display…"
        self.on_viewers_changed = lambda n: None
        self.on_need_key = lambda: None

    def start(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", VIDEO_PORT))
        srv.listen(8)
        threading.Thread(target=self._accept, args=(srv,), daemon=True).start()

    def _accept(self, srv):
        while True:
            sock, addr = srv.accept()
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            v = Viewer(sock, addr)
            log("viewer connected", addr[0])
            v.push(packet(4, self.status.encode()))
            with self.lock:
                self.viewers.add(v)
                n = len(self.viewers)
            threading.Thread(target=v.sender, args=(self._remove,), daemon=True).start()
            threading.Thread(target=v.reader, args=(self.on_need_key, self._remove), daemon=True).start()
            self.on_viewers_changed(n)
            self.on_need_key()

    def _remove(self, v):
        with self.lock:
            if v not in self.viewers:
                return
            self.viewers.discard(v)
            n = len(self.viewers)
        v.close()
        log("viewer left", v.addr[0])
        self.on_viewers_changed(n)

    def send_status(self, text):
        self.status = text
        with self.lock:
            for v in self.viewers:
                v.waiting_for_key = True
                v.push(packet(4, text.encode()))

    def send_unit(self, unit):
        nals = split_nals(unit)
        types = {t for t, _ in nals}
        is_key = 5 in types
        if 7 in types:
            csd = b"".join(n for t, n in nals if t in (7, 8))
            self.config = struct.pack(">II", *self.size) + csd
        frame = b"".join(n for t, n in nals if t not in (7, 8, 9))
        if not frame:
            return
        need_key = False
        with self.lock:
            for v in self.viewers:
                if v.waiting_for_key:
                    if not is_key or self.config is None:
                        need_key = True
                        continue
                    v.waiting_for_key = False
                    v.push(packet(1, self.config))
                elif v.pending > MAX_BACKLOG:
                    v.waiting_for_key = True
                    need_key = True
                    continue
                elif is_key:
                    v.push(packet(1, self.config))
                v.push(packet(2 if is_key else 3, frame))
        if need_key:
            self.on_need_key()


# ---------------------------------------------------------------- encoder

class Encoder:
    """Runs ffmpeg only while someone is watching. New viewers get a keyframe
    within one GOP (half a second)."""

    def __init__(self, args, origin, server):
        self.args, self.origin, self.server = args, origin, server
        self.proc = None
        self.lock = threading.Lock()

    def command(self):
        a = self.args
        gop = max(1, a.fps // 2)
        if a.source == "test":
            src = ["-re", "-f", "lavfi", "-i", f"testsrc2=size={a.width}x{a.height}:rate={a.fps}"]
        elif IS_WINDOWS:
            src = ["-f", "lavfi", "-i",
                   f"ddagrab=output_idx={a.monitor}:framerate={a.fps}:draw_mouse=1,hwdownload,format=bgra,"
                   f"crop={a.width}:{a.height}:0:0"]
        else:
            display = os.environ.get("DISPLAY", ":0")
            x, y = self.origin
            src = ["-f", "x11grab", "-draw_mouse", "1", "-framerate", str(a.fps),
                   "-video_size", f"{a.width}x{a.height}", "-i", f"{display}+{x},{y}"]
        if a.encoder in ("nvenc", "qsv", "amf"):
            enc = ["-pix_fmt", "yuv420p" if a.encoder != "qsv" else "nv12", "-c:v", f"h264_{a.encoder}",
                   "-bf", "0", "-g", str(gop), "-aud", "1", "-b:v", f"{a.bitrate}M"]
            enc += {"nvenc": ["-preset", "p1", "-tune", "ull", "-zerolatency", "1"],
                    "qsv": ["-preset", "veryfast", "-low_power", "1"],
                    "amf": ["-usage", "ultralowlatency"]}[a.encoder]
        elif a.encoder == "vaapi":
            enc = ["-vaapi_device", "/dev/dri/renderD128", "-vf", "format=nv12,hwupload",
                   "-c:v", "h264_vaapi", "-bf", "0", "-g", str(gop), "-aud", "1",
                   "-b:v", f"{a.bitrate}M"]
        else:
            enc = ["-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast",
                   "-tune", "zerolatency", "-profile:v", "high", "-bf", "0", "-g", str(gop),
                   "-b:v", f"{a.bitrate}M", "-maxrate", f"{a.bitrate * 2}M",
                   "-bufsize", f"{a.bitrate}M", "-x264-params", "aud=1:repeat-headers=1"]
        return [ffmpeg_path(), "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer"] + src + enc + ["-f", "h264", "-"]

    def viewers_changed(self, n):
        with self.lock:
            if n and not self.proc:
                self.proc = subprocess.Popen(self.command(), stdout=subprocess.PIPE,
                                             creationflags=0x08000000 if IS_WINDOWS else 0)
                threading.Thread(target=self._pump, args=(self.proc,), daemon=True).start()
                log("encoder started")
            elif not n and self.proc:
                self._stop()

    def _pump(self, proc):
        reader = AccessUnitReader()
        while True:
            chunk = proc.stdout.read1(1 << 16)
            if not chunk:
                break
            for unit in reader.feed(chunk):
                self.server.send_unit(unit)
        if proc.wait() != 0 and self.proc is proc:
            self.server.send_status("Screen capture stopped. Check the terminal for errors.")

    def _stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(2)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.proc = None
        log("encoder stopped")

    def stop(self):
        with self.lock:
            if self.proc:
                self._stop()


# ---------------------------------------------------------------- HTTP + discovery

class PingHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (f"macscreen h264:{VIDEO_PORT}" if self.path.startswith("/ping")
                else "ShareScreen for Linux is running. Open the ShareScreen app on your phone.").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def start_http():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    httpd = socketserver.ThreadingTCPServer(("0.0.0.0", HTTP_PORT), PingHandler)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()


def broadcast_addresses():
    targets = {"255.255.255.255"}
    for ip in local_ips():  # assume /24, the usual home / hotspot network
        targets.add(ip.rsplit(".", 1)[0] + ".255")
    if IS_WINDOWS:
        return targets
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
                sock.sendto(message, addr)

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


def local_ips():
    if IS_WINDOWS:
        try:
            return [ip for ip in socket.gethostbyname_ex(socket.gethostname())[2]
                    if not ip.startswith("127.")]
        except OSError:
            return []
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split()
        return [ip for ip in out if "." in ip]
    except OSError:
        return []


# ---------------------------------------------------------------- main

def main():
    p = argparse.ArgumentParser(description="Use an Android phone as an extra display.")
    p.add_argument("--width", type=int, default=2400, help="virtual display width (default 2400)")
    p.add_argument("--height", type=int, default=1080, help="virtual display height (default 1080)")
    p.add_argument("--portrait", action="store_true", help="swap width and height")
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--bitrate", type=int, default=12, help="Mbit/s (default 12)")
    p.add_argument("--mirror", action="store_true", help="mirror the main screen instead of extending")
    p.add_argument("--encoder", choices=["x264", "vaapi", "nvenc", "qsv", "amf"], default="x264",
                   help="x264 (CPU, works everywhere); vaapi on Linux; nvenc/qsv/amf "
                        "(NVIDIA/Intel/AMD GPU) on Windows")
    p.add_argument("--monitor", type=int, default=None,
                   help="Windows: which monitor to stream (see --list-monitors). "
                        "Default: the last non-primary one, else the main screen")
    p.add_argument("--list-monitors", action="store_true", help="Windows: list monitors and exit")
    p.add_argument("--source", choices=["screen", "test"], default="screen", help=argparse.SUPPRESS)
    args = p.parse_args()
    if args.portrait:
        args.width, args.height = args.height, args.width
    args.width -= args.width % 2
    args.height -= args.height % 2

    display = None
    origin = (0, 0)
    if IS_WINDOWS and args.source == "screen":
        monitors = windows_monitors()
        if args.list_monitors:
            for i, x, y, w, h, primary in monitors:
                print(f"{i}: {w}x{h} at {x},{y}{'  (main)' if primary else ''}")
            return
        if args.monitor is None:
            extra = [m for m in monitors if not m[5]]
            args.monitor = (extra[-1] if extra else monitors[0])[0]
            if not extra:
                log("only one monitor found, so the phone mirrors your main screen.")
                log("to extend instead, install a virtual display driver (see the README) and restart.")
        if not 0 <= args.monitor < len(monitors):
            sys.exit(f"No monitor {args.monitor}. Run with --list-monitors.")
        _, _, _, w, h, _ = monitors[args.monitor]
        args.width, args.height = w & ~1, h & ~1
    elif args.source == "screen":
        if os.environ.get("XDG_SESSION_TYPE") == "wayland" or not os.environ.get("DISPLAY"):
            sys.exit("ShareScreen needs an X11 session. On Ubuntu, log out, click the gear icon "
                     "and pick \"Ubuntu on Xorg\", then try again.")
        if args.mirror:
            out = run(["xrandr", "--current"]).stdout
            m = re.search(r"current (\d+) x (\d+)", out)
            args.width, args.height = int(m.group(1)) & ~1, int(m.group(2)) & ~1
        else:
            display = VirtualDisplay(args.width, args.height, args.fps)
            atexit.register(display.destroy)
            origin = display.create()

    server = VideoServer(args.width, args.height)
    encoder = Encoder(args, origin, server)
    atexit.register(encoder.stop)
    server.on_viewers_changed = encoder.viewers_changed
    try:
        server.start()
        start_http()
        start_discovery()
    except OSError as e:
        sys.exit(f"Can't open ports {HTTP_PORT}/{DISCOVERY_PORT}/{VIDEO_PORT} ({e}). "
                 "Is ShareScreen already running?")
    server.status = "Connected. Waiting for the first frame…"

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"ready: {args.width}x{args.height} @ {args.fps} fps, {args.bitrate} Mbit/s")
    log("open ShareScreen on your phone; it finds this computer automatically.")
    ips = local_ips()
    if ips:
        log("or enter this address on the phone:", ", ".join(ips))
    log("USB: adb reverse tcp:8780 tcp:8780 && adb reverse tcp:8783 tcp:8783")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
