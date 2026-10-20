#!/bin/bash
# Builds the installer for sharing: dist/LumaGrader-Photo-Studio-<version>.dmg (+ a .zip of it for
# sites that don't accept .dmg, like the Ko-fi Shop)
#
#   ./scripts/make-dmg.sh           → Apple silicon + Intel (falls back to this Mac's chip
#                                     if the universal build fails)
#   ./scripts/make-dmg.sh --native  → this Mac's chip only (faster)
#
# The disk opens to a window with the app, an Applications shortcut to drag it onto, and
# "Read Me First.txt" (how to open an app that isn't notarized). The window layout needs
# Terminal to control Finder: allow it if macOS asks. If not allowed, the DMG still works,
# just with a plain window.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="LumaGrader Photo Studio"
VOL_NAME="LumaGrader Photo Studio"
VERSION="$(grep '^VERSION=' scripts/make-app.sh | cut -d'"' -f2)"
DIST="$ROOT/dist"
DMG="$DIST/LumaGrader-Photo-Studio-$VERSION.dmg"

# 1. The app
if [[ "${1:-}" == "--native" ]]; then
  bash scripts/make-app.sh
elif ! bash scripts/make-app.sh --universal; then
  echo "! The universal build failed; building for this Mac's chip only."
  bash scripts/make-app.sh
fi
APP="$DIST/$APP_NAME.app"
codesign --verify --deep "$APP"

# 2. What goes on the disk
WORK="$(mktemp -d /tmp/lumagrader-dmg.XXXXXX)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
DEVICE=""
cleanup() {
  if [[ -n "$DEVICE" ]]; then hdiutil detach "$DEVICE" -force -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "▸ Preparing the disk…"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/Read Me First.txt" "$STAGE/"
# One TIFF holding both sizes, so the background is sharp on Retina screens.
tiffutil -cathidpicheck "$ROOT/Resources/dmg-background.png" "$ROOT/Resources/dmg-background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null
cp "$ROOT/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

# A disk with the same name already open would get mounted as "LumaGrader Photo Studio 1".
if [[ -d "/Volumes/$VOL_NAME" ]]; then
  hdiutil detach "/Volumes/$VOL_NAME" -force -quiet || true
fi

# 3. Writable disk, with room for Finder's layout file
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW \
  -size "${SIZE_MB}m" -ov "$RW" -quiet
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')"
MOUNT="/Volumes/$VOL_NAME"

# Custom disk icon (best effort: SetFile comes with Xcode)
if command -v SetFile >/dev/null 2>&1; then
  SetFile -c icnC "$MOUNT/.VolumeIcon.icns" || true
  SetFile -a C "$MOUNT" || true
fi

# 4. Window layout: 660×480, icons 96 pt
echo "▸ Arranging the window (allow Terminal to control Finder if asked)…"
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 628}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    set position of item "Read Me First.txt" of container window to {330, 400}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  echo "! Couldn't arrange the window (Finder access not allowed). The DMG still works."
fi

sync
chmod -Rf go-w "$MOUNT" || true
for _ in 1 2 3 4 5; do
  if hdiutil detach "$DEVICE" -quiet; then DEVICE=""; break; fi
  sleep 2
done
if [[ -n "$DEVICE" ]]; then
  hdiutil detach "$DEVICE" -force -quiet
  DEVICE=""
fi

# 5. Compressed, read-only installer
echo "▸ Compressing…"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
hdiutil verify "$DMG" -quiet

# Zipped copy for sites that don't accept .dmg uploads (Ko-fi Shop, some forms).
ZIP="${DMG%.dmg}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$DMG" "$ZIP"

echo "✓ Installer: $DMG ($(du -h "$DMG" | cut -f1))"
echo "  SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "✓ Zipped for uploading (Ko-fi): $ZIP ($(du -h "$ZIP" | cut -f1))"
open -R "$DMG"
