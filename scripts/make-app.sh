#!/bin/bash
# Builds "LumaGrader Photo Studio.app" (release) into ./dist, and with --install copies it
# to /Applications (and removes the old DarkLab.app / Darkroom.app there).
#
#   ./scripts/make-app.sh              → dist/LumaGrader Photo Studio.app (this Mac's chip)
#   ./scripts/make-app.sh --install    → also /Applications/LumaGrader Photo Studio.app
#   ./scripts/make-app.sh --universal  → Apple silicon + Intel in one app (for sharing;
#                                         slower build). Used by make-dmg.sh.
#
# Needs Xcode (or its command line tools). Your catalog and photos are not touched.
set -euo pipefail

APP_NAME="LumaGrader Photo Studio"
# Short name for the menu bar (macOS shows CFBundleName there).
SHORT_NAME="LumaGrader"
# The Swift target (and so the executable) keeps its old name; the bundle id stays the
# same too, so settings, panel states and import folders carry over.
EXEC_NAME="Darkroom"
OLD_APP_NAMES=("Darkroom" "DarkLab")
BUNDLE_ID="com.rax.darkroom"
VERSION="0.27.1"
BUILD_NUMBER="39"

INSTALL=0
UNIVERSAL=0
for ARG in "$@"; do
  case "$ARG" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "✗ Unknown option: $ARG" >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# The Command Line Tools' Swift lacks the SwiftUI macro plugins (@State fails with
# "plugin for module 'SwiftUIMacros' not found"). Prefer the full Xcode toolchain.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -n 1 || true)"
  if [[ -n "$XCODE_APP" ]]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    echo "▸ Using $XCODE_APP"
  else
    echo "✗ Xcode not found in /Applications. Install Xcode from the App Store." >&2
    exit 1
  fi
fi

BUILD_ARGS=(-c release)
if [[ $UNIVERSAL == 1 ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
  echo "▸ Building $APP_NAME $VERSION (release, Apple silicon + Intel)…"
else
  echo "▸ Building $APP_NAME $VERSION (release)…"
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$SHORT_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>NSHumanReadableCopyright</key><string>LumaGrader Photo Studio</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ Signing (local, ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built: $APP ($(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo "?"))"

if [[ $INSTALL == 1 ]]; then
  TARGET="/Applications/$APP_NAME.app"
  if [[ ! -w "/Applications" ]]; then
    TARGET="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
  fi
  if pgrep -x "$EXEC_NAME" >/dev/null; then
    echo "▸ Quitting the running app…"
    osascript -e "quit app id \"$BUNDLE_ID\"" || true
    sleep 1
  fi
  # The app used to be called Darkroom, then DarkLab: remove those copies so only one is left.
  for OLD_NAME in "${OLD_APP_NAMES[@]}"; do
    for OLD in "/Applications/$OLD_NAME.app" "$HOME/Applications/$OLD_NAME.app"; do
      if [[ -d "$OLD" ]]; then
        rm -rf "$OLD"
        echo "▸ Removed the old $OLD_NAME.app"
      fi
    done
  done
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  echo "✓ Installed: $TARGET"
  open "$TARGET"
fi
