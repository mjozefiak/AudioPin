#!/bin/zsh
# Builds dist/AudioPin.dmg: the classic drag-and-drop installer window
# (AudioPin.app on the left, an Applications shortcut on the right).
#
# Usage: ./scripts/make-dmg.sh [--skip-build]
#   --skip-build  reuse an existing dist/AudioPin.app (or set SKIP_BUILD=1)
#
# The window layout is stored in the volume's .DS_Store. It is written directly by
# scripts/make-dmg-dsstore.swift instead of scripting Finder, so it needs no GUI session,
# no Automation permission and no third-party tools, and works the same on CI.
set -euo pipefail
APP_NAME="AudioPin"
VOL_NAME="AudioPin"
ROOT="${0:A:h:h}"
SKIP_BUILD="${SKIP_BUILD:-0}"
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done
cd "$ROOT"

[[ "$SKIP_BUILD" == 1 ]] || "$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Missing $APP — run scripts/build-app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/$APP_NAME.dmg"
DMG_VERSIONED="$ROOT/dist/$APP_NAME-$VERSION.dmg"

if [[ -d "/Volumes/$VOL_NAME" ]]; then
  echo "A volume named '$VOL_NAME' is already mounted; eject it first." >&2; exit 1
fi

TMP="$(mktemp -d)"
DEVICE=""
cleanup() {
  [[ -n "$DEVICE" ]] && hdiutil detach "$DEVICE" -force -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# 1. Staging folder: app, Applications symlink, hidden background, volume icon.
STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$TMP/bg.png" 1
swift scripts/make-dmg-background.swift "$TMP/bg@2x.png" 2
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# 2. Writable image, mounted so the layout can be applied.
RW="$TMP/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ -format UDRW -size 64m "$RW"
ATTACH_OUT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse)"
DEVICE="$(echo "$ATTACH_OUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT="$(echo "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

# Custom volume icon (best-effort: SetFile ships with Xcode / Command Line Tools).
if command -v SetFile >/dev/null 2>&1; then
  SetFile -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a C "$MOUNT" 2>/dev/null || echo "warning: could not set the volume icon" >&2
fi

# 3. Window layout.
swift scripts/make-dmg-dsstore.swift "$MOUNT" "$APP_NAME.app"

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync
for i in {1..5}; do
  hdiutil detach "$DEVICE" -quiet && { DEVICE=""; break; }
  sleep 2
done
[[ -z "$DEVICE" ]] || { hdiutil detach "$DEVICE" -force -quiet; DEVICE=""; }

# 4. Compressed, read-only, ad-hoc signed final image.
rm -f "$DMG" "$DMG_VERSIONED"
hdiutil convert -quiet "$RW" -format ULFO -o "$DMG"
codesign --force --sign - --timestamp=none "$DMG"
hdiutil verify -quiet "$DMG"
cp "$DMG" "$DMG_VERSIONED"

echo "Built: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), version $VERSION)"
echo "Also:  $DMG_VERSIONED"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
