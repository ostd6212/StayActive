#!/bin/bash
# Installs StayActive.app into /Applications and resets any stale
# Accessibility grant tied to a previous build (so a fresh, correctly
# signed prompt can appear).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$SCRIPT_DIR/StayActive.app"
BUNDLE_ID="com.dmytro.stayactive"

if [ ! -d "$APP" ]; then
    echo "ERROR: $APP not found. Run build.sh first."
    exit 1
fi

echo "==> Removing previous install (if any)"
rm -rf /Applications/StayActive.app

echo "==> Installing to /Applications"
mv "$APP" /Applications/

echo "==> Resetting Accessibility TCC entry for $BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID" || true

echo "==> Launching StayActive"
open /Applications/StayActive.app

echo ""
echo "Installed. If this is a fresh build with a new/changed signing"
echo "identity, macOS will show an Accessibility permission dialog now."
