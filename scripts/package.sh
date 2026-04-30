#!/usr/bin/env bash
#
# Build a Release TileBar.app and wrap it in a styled DMG installer.
#
# Output:  dist/TileBar-<version>.dmg
# Version: pulled from TileBar/Info.plist (CFBundleShortVersionString)
#
# Prerequisites:
#   brew install create-dmg
#   A `TileBarLocal` self-signed code-signing identity in Keychain.
#
# Note on Gatekeeper: this DMG is *self-signed*, not Apple-notarized,
# so first-launch will show "developer cannot be verified". Recipients
# need to either right-click → Open, or System Settings → Privacy &
# Security → Open Anyway. README documents this.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TileBar"
SCHEME="TileBar"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
BG_IMG="$ROOT/scripts/dmg-background.png"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$ROOT/TileBar/Info.plist")
DMG="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

if ! command -v create-dmg >/dev/null; then
    echo "error: create-dmg not found. Install: brew install create-dmg" >&2
    exit 1
fi

echo "==> Cleaning previous artifacts"
rm -rf "$BUILD_DIR" "$DMG"
mkdir -p "$DIST_DIR"

echo "==> Building Release ($APP_NAME $VERSION)"
BUILD_LOG="$DIST_DIR/build.log"
if ! xcodebuild \
    -project "$ROOT/TileBar.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    > "$BUILD_LOG" 2>&1; then
    echo "Build failed. Last 30 lines of $BUILD_LOG:" >&2
    tail -30 "$BUILD_LOG" >&2
    exit 1
fi
APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: build did not produce $APP" >&2; exit 1; }

echo "==> Verifying signature"
codesign -dv "$APP" 2>&1 | grep "Authority=" | head -2 || true

echo "==> Building DMG → $DMG"
# Coordinates here must match the arrow drawn in dmg-background.png:
#   icon size 100  →  icon span ~50px around its center.
#   App icon center (140, 190); Applications shortcut center (400, 190).
# create-dmg sometimes flakes on first run when AppleScript needs a
# moment to attach to a fresh Finder process; one quiet retry is
# usually all it takes.
attempt=1
until [ $attempt -gt 2 ]; do
    if create-dmg \
        --volname "$APP_NAME $VERSION" \
        --background "$BG_IMG" \
        --window-pos 200 120 \
        --window-size 540 380 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 140 190 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 400 190 \
        --no-internet-enable \
        "$DMG" \
        "$APP"; then
        break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -le 2 ]; then
        echo "create-dmg flaked; retrying once after 2s..."
        rm -f "$DMG"
        sleep 2
    else
        echo "error: create-dmg failed twice; aborting" >&2
        exit 1
    fi
done

echo
echo "==> Done"
ls -lh "$DMG"
