"""Tray icon for the Windows and Linux host (like the Mac menu-bar app).

Uses pystray: the Windows notification area, or AppIndicator on Linux desktops.
"""

import os
import subprocess
import sys
import tempfile
import threading
import webbrowser

import sharescreen as core

try:
    import pystray
    from PIL import Image
except ImportError:  # the CLI still works without a tray
    pystray = None

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
AUTOSTART_DESKTOP = os.path.expanduser("~/.config/autostart/sharescreen.desktop")


def available():
    if pystray is None:
        return False
    if core.IS_WINDOWS:
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def icon_image():
    path = core.resource("icon.png")
    if not os.path.exists(path):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "icon.png")
    try:
        return Image.open(path).convert("RGBA").resize((64, 64))
    except OSError:
        img = Image.new("RGBA", (64, 64), (91, 141, 239, 255))
        return img


def open_path(path):
    if core.IS_WINDOWS:
        os.startfile(path)  # noqa: S606 - opening our own temp file
    else:
        subprocess.Popen(["xdg-open", path])


# ---------------------------------------------------------------- start at login

def autostart_enabled():
    if core.IS_WINDOWS:
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
                winreg.QueryValueEx(key, "ShareScreen")
                return True
        except OSError:
            return False
    return os.path.exists(AUTOSTART_DESKTOP)


def set_autostart(on):
    if core.IS_WINDOWS:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
            if on:
                winreg.SetValueEx(key, "ShareScreen", 0, winreg.REG_SZ, f'"{sys.executable}"')
            else:
                try:
                    winreg.DeleteValue(key, "ShareScreen")
                except OSError:
                    pass
        return
    if on:
        os.makedirs(os.path.dirname(AUTOSTART_DESKTOP), exist_ok=True)
        with open(AUTOSTART_DESKTOP, "w") as f:
            f.write("[Desktop Entry]\nType=Application\nName=ShareScreen\nExec=sharescreen\n"
                    "Icon=sharescreen\nX-GNOME-Autostart-enabled=true\n")
    elif os.path.exists(AUTOSTART_DESKTOP):
        os.remove(AUTOSTART_DESKTOP)


# ---------------------------------------------------------------- QR code

def show_qr():
    url = core.viewer_url()
    try:
        import qrcode
    except ImportError:
        webbrowser.open(url)
        return
    qr = qrcode.make(url, box_size=12, border=3).convert("RGB")
    w, h = qr.size
    from PIL import ImageDraw
    card = Image.new("RGB", (w, h + 70), "white")
    card.paste(qr, (0, 0))
    ImageDraw.Draw(card).text((24, h + 10), f"Scan with your phone's camera, or open\n{url}", fill="black")
    path = os.path.join(tempfile.gettempdir(), "sharescreen-qr.png")
    card.save(path)
    open_path(path)


# ---------------------------------------------------------------- menu

def build_menu(host):
    item, menu = pystray.MenuItem, pystray.Menu

    def quality_item(name):
        return item(core.QUALITIES[name]["title"], lambda: host.set_quality(name),
                    checked=lambda _: host.quality == name, radio=True)

    entries = [
        item(lambda _: f"ShareScreen: {host.summary()}", None, enabled=False),
        item(lambda _: f"Address: {core.viewer_url()}", None, enabled=False),
        menu.SEPARATOR,
        item("Extra display on", lambda: host.set_enabled(not host.enabled), checked=lambda _: host.enabled),
        item("Play sound on phone", lambda: host.set_sound(not host.sound), checked=lambda _: host.sound),
        item("Stream quality", menu(*[quality_item(n) for n in core.QUALITIES])),
    ]
    if core.IS_WINDOWS and host.args.source == "screen":
        def monitor_items():
            yield item("Automatic", lambda: host.set_monitor(None),
                       checked=lambda _: host.args.monitor is None, radio=True)
            for i, _x, _y, w, h, primary in core.windows_monitors():
                yield item(f"Monitor {i + 1}: {w}×{h}{' (main)' if primary else ''}",
                           (lambda idx: lambda: host.set_monitor(idx))(i),
                           checked=(lambda idx: lambda _: host.args.monitor == idx)(i), radio=True)
        entries.append(item("Monitor", menu(monitor_items)))
    entries += [
        item("Show QR code…", lambda: threading.Thread(target=show_qr, daemon=True).start()),
        item("Start at login", lambda: set_autostart(not autostart_enabled()),
             checked=lambda _: autostart_enabled()),
        menu.SEPARATOR,
        item("Open log", lambda: open_path(core.LOG_PATH) if os.path.exists(core.LOG_PATH) else None,
             visible=lambda _: sys.stderr is None),
        item("Help", lambda: webbrowser.open("https://github.com/saagarshrest/screenshare#readme")),
        item("Quit ShareScreen", lambda icon: icon.stop()),
    ]
    return menu(*entries)


def run(host):
    icon = pystray.Icon("ShareScreen", icon_image(), "ShareScreen", build_menu(host))

    def refresh():
        icon.title = f"ShareScreen: {host.summary()}"
        try:
            icon.update_menu()
        except Exception:
            pass

    host.listeners.append(refresh)
    icon.run(setup=lambda i: (setattr(i, "visible", True), refresh()))
    host.shutdown()
