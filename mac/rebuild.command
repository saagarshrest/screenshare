#!/bin/bash
# Double-click to rebuild and restart ShareScreen.
cd "$(dirname "$0")"
osascript -e 'quit app "ShareScreen"' 2>/dev/null
sleep 1
bash ./build.sh || { echo "Build failed — see above."; read -n1; exit 1; }
open "ShareScreen.app"
echo
echo "Done. Allow Screen Recording when asked, then quit and reopen ShareScreen."
