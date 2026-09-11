#!/bin/bash
# build-dmg.sh — Create a .dmg disk image for drag-to-Applications install.
#
# Usage: Scripts/build-dmg.sh [--version X.Y.Z]
#
# Prerequisites:
#   - .build/release/QuotaPeek.app  (from Scripts/build-app-bundle.sh)
#
# Output:
#   - .build/release/QuotaPeek-X.Y.Z.dmg
#
# NOTE: Since we use ad-hoc signing (no Apple Developer ID / notarization),
# users who download this .dmg from a browser will see a Gatekeeper warning
# on first launch ("QuotaPeek can't be opened because it is from an
# unidentified developer").  The workaround is:
#   1. Right-click (or Control-click) the app in /Applications
#   2. Select "Open" from the context menu
#   3. Click "Open" in the confirmation dialog
# This only needs to be done once — macOS remembers the exception.
#
# The curl-pipe-bash installer (install.sh --remote) and Homebrew cask
# do NOT have this issue because they bypass Gatekeeper's quarantine xattr.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) shift ;;
    esac
done

APP_BUNDLE="$REPO_DIR/.build/release/QuotaPeek.app"
DMG_NAME="QuotaPeek-${VERSION}.dmg"
DMG_PATH="$REPO_DIR/.build/release/$DMG_NAME"
DMG_STAGING="$REPO_DIR/.build/release/dmg-staging"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: App bundle not found at $APP_BUNDLE" >&2
    echo "Run Scripts/build-app-bundle.sh first." >&2
    exit 1
fi

echo "==> Creating DMG staging area"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy the app bundle into the staging area
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# Create a symbolic link to /Applications for drag-to-install UX
ln -s /Applications "$DMG_STAGING/Applications"

echo "==> Building $DMG_NAME"
rm -f "$DMG_PATH"

# Create a compressed DMG from the staging directory.
# -volname:  the name shown when the DMG is mounted
# -srcfolder: the directory whose contents become the DMG root
# -ov:       overwrite if exists
# -format UDZO: zlib-compressed (good size, universal compatibility)
hdiutil create \
    -volname "QuotaPeek" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo "==> DMG ready at $DMG_PATH"
echo ""
echo "For browser-downloaded copies: right-click → Open on first launch."
