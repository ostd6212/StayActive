#!/bin/bash
# Builds, bundles and codesigns StayActive.app.
# Requires: Xcode Command Line Tools, and setup_certificate.sh already run
# (identity "StayActive Dev" present in `security find-identity -v -p codesigning`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP="StayActive.app"
SIGN_IDENTITY="StayActive Dev"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "==> Compiling main.swift"
swiftc -O main.swift -framework IOKit -o "$APP/Contents/MacOS/StayActive"

echo "==> Copying Info.plist and icon.icns"
cp Info.plist "$APP/Contents/Info.plist"

if [ -f icon.icns ]; then
    cp icon.icns "$APP/Contents/Resources/icon.icns"
else
    echo "WARNING: icon.icns not found next to build.sh."
    echo "         Run: swift generate_icon.swift && iconutil -c icns icon.iconset"
fi

echo "==> Code signing with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "==> Verifying signature"
codesign -dv --verbose=4 "$APP"

echo ""
echo "Build complete: $SCRIPT_DIR/$APP"
