#!/usr/bin/env bash
# Builds ShareScreen.deb (needs dpkg-deb, i.e. run on Debian/Ubuntu).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.0}"
ROOT="$(mktemp -d)/sharescreen"
install -Dm755 ../host/sharescreen.py          "$ROOT/usr/lib/sharescreen/sharescreen.py"
install -Dm644 sharescreen.desktop      "$ROOT/usr/share/applications/sharescreen.desktop"
install -Dm644 ../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png \
                                        "$ROOT/usr/share/icons/hicolor/192x192/apps/sharescreen.png" 2>/dev/null || true
mkdir -p "$ROOT/usr/bin" "$ROOT/DEBIAN"
ln -s ../lib/sharescreen/sharescreen.py "$ROOT/usr/bin/sharescreen"
cat > "$ROOT/DEBIAN/control" <<CTRL
Package: sharescreen
Version: ${VERSION#v}
Section: video
Priority: optional
Architecture: all
Depends: python3 (>= 3.8), ffmpeg, x11-xserver-utils
Maintainer: saagarshrest <saagarshrest@users.noreply.github.com>
Homepage: https://github.com/saagarshrest/screenshare
Description: Use your Android phone as an extra display
 Streams a virtual X11 monitor to the ShareScreen Android app as
 low-latency H.264 over Wi-Fi or USB.
CTRL
dpkg-deb --root-owner-group --build "$ROOT" ShareScreen.deb
echo "Built $(pwd)/ShareScreen.deb"
