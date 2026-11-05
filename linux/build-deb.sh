#!/usr/bin/env bash
# Builds ShareScreen.deb (needs dpkg-deb, i.e. run on Debian/Ubuntu).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.1.0}"
ROOT="$(mktemp -d)/sharescreen"
LIB="$ROOT/usr/lib/sharescreen"
install -Dm755 ../host/sharescreen.py  "$LIB/sharescreen.py"
install -Dm644 ../host/tray.py         "$LIB/tray.py"
install -Dm644 ../host/icon.png        "$LIB/icon.png"
install -Dm644 sharescreen.desktop     "$ROOT/usr/share/applications/sharescreen.desktop"
install -Dm644 ../host/icon.png        "$ROOT/usr/share/icons/hicolor/1024x1024/apps/sharescreen.png"
install -Dm644 ../LICENSE              "$ROOT/usr/share/doc/sharescreen/copyright"
mkdir -p "$ROOT/usr/bin" "$ROOT/DEBIAN"
ln -s ../lib/sharescreen/sharescreen.py "$ROOT/usr/bin/sharescreen"
cat > "$ROOT/DEBIAN/control" <<CTRL
Package: sharescreen
Version: ${VERSION#v}
Section: video
Priority: optional
Architecture: all
Depends: python3 (>= 3.8), ffmpeg, x11-xserver-utils
Recommends: python3-pystray, python3-pil, python3-qrcode, python3-gi,
 gir1.2-ayatanaappindicator3-0.1, gstreamer1.0-tools, gstreamer1.0-pipewire,
 gstreamer1.0-plugins-base, gstreamer1.0-plugins-ugly, pulseaudio-utils
Maintainer: saagarshrest <saagarshrest@users.noreply.github.com>
Homepage: https://github.com/saagarshrest/screenshare
Description: Use your Android phone as an extra display
 Streams an extra monitor to the ShareScreen Android app as low-latency
 H.264 over Wi-Fi or USB. Works on X11 (xrandr virtual monitor) and on
 Wayland (xdg-desktop-portal, with a virtual monitor on GNOME 46+ and KDE 6).
 Has a tray icon, a browser viewer with QR code, and optional sound.
CTRL
dpkg-deb --root-owner-group --build "$ROOT" ShareScreen.deb
echo "Built $(pwd)/ShareScreen.deb"
