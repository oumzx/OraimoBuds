#!/bin/bash
# Builds OraimoBuds.app as a real, double-clickable macOS app bundle from
# the SPM package (no Xcode.app required — swift build + manual bundle
# assembly + ad-hoc codesign, which is what SMAppService/login-item
# registration needs to work reliably).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OraimoBuds"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy libjl_bluetooth.so flat into Contents/Resources (NOT as SPM's
# top-level *_*.bundle folder — that sits outside Contents/ and breaks
# codesign's sealed-resources check). OraimoBudsApp.swift's
# locateNativeCryptoLib() looks for it at exactly this path first.
RESOURCE_BUNDLE="${APP_NAME}_${APP_NAME}.bundle"
for RES in libjl_bluetooth.so MenuBarIcon.png; do
    if [ -f "$BUILD_DIR/$RESOURCE_BUNDLE/$RES" ]; then
        cp "$BUILD_DIR/$RESOURCE_BUNDLE/$RES" "$APP_BUNDLE/Contents/Resources/$RES"
    else
        echo "!! $RES not found under $BUILD_DIR/$RESOURCE_BUNDLE" >&2
        exit 1
    fi
done

echo "==> ad-hoc codesigning"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "    Move it to /Applications for a stable Login Item / Dock experience:"
echo "    mv \"$APP_BUNDLE\" /Applications/"
