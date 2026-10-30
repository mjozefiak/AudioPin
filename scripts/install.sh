#!/bin/zsh
# Builds AudioPin, installs it into ~/Applications and launches it.
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/scripts/build-app.sh"
DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x AudioPin 2>/dev/null && sleep 1 || true
rm -rf "$DEST/AudioPin.app"
cp -R "$ROOT/dist/AudioPin.app" "$DEST/"
open "$DEST/AudioPin.app"
echo "Installed and launched: $DEST/AudioPin.app"
