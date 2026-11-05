#!/bin/bash
# Builds "ShareScreen.app" next to this script. Needs Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacScreen"

APP="ShareScreen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ShareScreen"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ShareScreen</string>
  <key>CFBundleDisplayName</key><string>ShareScreen</string>
  <key>CFBundleIdentifier</key><string>np.com.saagarshrest.macscreen</string>
  <key>CFBundleExecutable</key><string>ShareScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>ShareScreen streams your extra display to your phone over the local network.</string>
</dict>
</plist>
PLIST

# Sign with a fixed, self-made certificate so macOS keeps the Screen Recording
# permission across rebuilds. (An ad-hoc signature changes every build, which is
# why the permission kept "forgetting" itself.) Created once in your login keychain.
IDENTITY="MacScreen Local Signing"
if [ -n "${MACSCREEN_ADHOC:-}" ]; then
  IDENTITY="-"   # CI builds: ad-hoc signature
elif ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "Creating a one-time signing certificate (macOS may ask for your password)…"
  TMP="$(mktemp -d)"
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$IDENTITY
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CFG
  openssl() { /usr/bin/openssl "$@"; }
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -extensions ext \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  # macOS Keychain only reads the old PKCS#12 format (SHA1/3DES), so ask for it explicitly.
  P12="-export -inkey $TMP/key.pem -in $TMP/cert.pem -out $TMP/id.p12 -passout pass:macscreen"
  openssl pkcs12 $P12 -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
    || openssl pkcs12 $P12 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P macscreen -T /usr/bin/codesign
  security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem" || true
  rm -rf "$TMP"
fi
codesign --force --deep --sign "$IDENTITY" "$APP" || codesign --force --deep --sign - "$APP"
touch "$APP" # refresh the Finder icon
echo "Built: $(pwd)/$APP"

# Installer: a .dmg with the app and an Applications shortcut to drag it onto.
if [ "${1:-}" = "dmg" ]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f ShareScreen.dmg
  hdiutil create -volname "ShareScreen" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov ShareScreen.dmg >/dev/null
  rm -rf "$STAGE"
  echo "Installer: $(pwd)/ShareScreen.dmg"
fi
