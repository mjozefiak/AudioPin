#!/bin/zsh
# Builds dist/AudioPin.app (ad-hoc signed, for building from source).
set -euo pipefail
APP_NAME="AudioPin"
ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
cd "$ROOT"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

OUT="$ROOT/dist/$APP_NAME.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# App icon (rendered once and kept in Resources/AppIcon.icns)
if [[ ! -f Resources/AppIcon.icns ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  swift scripts/make-icon.swift "$TMP/icon.png"
  swift scripts/make-icon.swift "$TMP/icon-small.png" --small   # simplified mark for 16/32 px
  ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  src() { (( $1 <= 32 )) && echo "$TMP/icon-small.png" || echo "$TMP/icon.png"; }
  for s in 16 32 128 256 512; do
    sips -z $s $s "$(src $s)" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$(src $((s*2)))" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

# Localizations: compile the String Catalog into <lang>.lproj/Localizable.strings
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$OUT/Contents/Resources"

plutil -lint "$OUT/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none --options runtime "$OUT"
codesign --verify --strict "$OUT"
echo "Built: $OUT"
