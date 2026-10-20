#!/bin/bash
# Installs (or updates) Sunscreen. Run in Terminal:
#   curl -fsSL https://rmmarketingmcc.github.io/sunscreen/install.sh | bash
set -euo pipefail

URL="https://github.com/rmmarketingmcc/sunscreen/releases/latest/download/Sunscreen.zip"
DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Sunscreen..."
curl -fsSL "$URL" -o "$TMP/Sunscreen.zip"
osascript -e 'quit app "Sunscreen"' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST/Sunscreen.app"
ditto -x -k "$TMP/Sunscreen.zip" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Sunscreen.app" 2>/dev/null || true
open "$DEST/Sunscreen.app"
echo
echo "Done! Look for the little sun (or moon) at the top right of your screen."
