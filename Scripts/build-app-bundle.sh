#!/bin/bash
# build-app-bundle.sh — Assemble the Swift binary into a proper macOS .app
# bundle and ad-hoc codesign both the app and the Go daemon binary.
#
# Usage: Scripts/build-app-bundle.sh [--version X.Y.Z] [--build N]
#
# Prerequisites:
#   - .build/release/QuotaPeek   (swift build -c release output)
#   - .build-go/quotapeekd             (go build output)
#   - Info.plist                      (repo root)
#   - QuotaPeek.entitlements      (repo root)
#   - Resources/AppIcon.icns          (repo root)
#
# Output:
#   - .build/release/QuotaPeek.app/  (ready-to-distribute bundle)
#
# Ad-hoc code signing (--sign -):
#   Apple Silicon (arm64) binaries are *required* to carry at least an ad-hoc
#   signature to run at all — the kernel refuses to map unsigned arm64 code.
#   On Intel this is technically optional but harmless and avoids a Gatekeeper
#   "damaged" complaint on recent macOS versions.  Ad-hoc signing is FREE and
#   requires no Apple Developer Program membership or Apple ID.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${2:-1.0.0}"
BUILD_NUMBER="${4:-1}"

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build)   BUILD_NUMBER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

SWIFT_BINARY="$REPO_DIR/.build/release/QuotaPeek"
if [[ ! -f "$SWIFT_BINARY" && -f "$REPO_DIR/.build/apple/Products/Release/QuotaPeek" ]]; then
    # `swift build --arch ... --arch ...` (universal binary) outputs here instead.
    SWIFT_BINARY="$REPO_DIR/.build/apple/Products/Release/QuotaPeek"
fi
GO_BINARY="$REPO_DIR/.build-go/quotapeekd"
APP_BUNDLE="$REPO_DIR/.build/release/QuotaPeek.app"
INFO_PLIST="$REPO_DIR/Info.plist"
ENTITLEMENTS="$REPO_DIR/QuotaPeek.entitlements"
APP_ICON="$REPO_DIR/Resources/AppIcon.icns"
MENU_BAR_ICON_1X="$REPO_DIR/Resources/MenuBarIcon.png"
MENU_BAR_ICON_2X="$REPO_DIR/Resources/MenuBarIcon@2x.png"
MENU_BAR_ICON_3X="$REPO_DIR/Resources/MenuBarIcon@3x.png"

# Verify prerequisites
for f in "$SWIFT_BINARY" "$GO_BINARY" "$INFO_PLIST" "$ENTITLEMENTS" "$APP_ICON" \
         "$MENU_BAR_ICON_1X" "$MENU_BAR_ICON_2X" "$MENU_BAR_ICON_3X"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f" >&2
        exit 1
    fi
done

echo "==> Assembling QuotaPeek.app bundle"

# Create bundle directory structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the Swift binary into the bundle
cp "$SWIFT_BINARY" "$APP_BUNDLE/Contents/MacOS/QuotaPeek"

# Copy the app icon and menu bar status item icon into the bundle
cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$MENU_BAR_ICON_1X" "$MENU_BAR_ICON_2X" "$MENU_BAR_ICON_3X" "$APP_BUNDLE/Contents/Resources/"

# Generate Info.plist with stamped version/build numbers
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
"${PYTHON3:-python3}" -c "
import sys, re
p = sys.argv[1]
with open(p) as f: t = f.read()
t = re.sub(
    r'(<key>CFBundleVersion</key>\s*<string>)\d+(</string>)',
    r'\g<1>${BUILD_NUMBER}\g<2>', t)
t = re.sub(
    r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)',
    r'\g<1>${VERSION}\g<2>', t)
with open(p, 'w') as f: f.write(t)
" "$APP_BUNDLE/Contents/Info.plist"

# Create a minimal PkgInfo (standard for macOS .app bundles)
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc code signing"

# Sign the Go daemon binary (standalone, not inside the bundle)
codesign --sign - --force "$GO_BINARY"
echo "  signed $GO_BINARY"

# Sign the .app bundle (--deep signs nested code/frameworks too)
codesign --sign - --deep --force --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
echo "  signed $APP_BUNDLE"

echo "==> Bundle ready at $APP_BUNDLE"
