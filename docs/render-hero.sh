#!/usr/bin/env bash
# Renders docs/hero.html to docs/hero.png (1600x820) with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1600,820 --screenshot="$PWD/hero.png" "file://$PWD/hero.html"
