#!/bin/bash
# build-app-bundle.sh — Assemble the Swift binary into a proper macOS .app
# bundle (with the widget extension inside) and ad-hoc codesign it.
#
# Usage: Scripts/build-app-bundle.sh [--version X.Y.Z] [--build N]
#
# Prerequisites:
#   - .build/release/QuotaPeek   (swift build -c release output)
#   - .build/release/QuotaPeekWidget  (same build; embedded as PlugIns/QuotaPeekWidget.appex)
#   - Info.plist                      (repo root)
#   - QuotaPeek.entitlements      (repo root)
#   - Resources/QuotaPeekWidget-Info.plist, QuotaPeekWidget.entitlements
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
VERSION="1.0.0"
BUILD_NUMBER="1"

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "ERROR: --version requires a non-empty value" >&2
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        --build)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "ERROR: --build requires a non-empty value" >&2
                exit 1
            fi
            BUILD_NUMBER="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Both executables must come from the same build. A universal build
# (`swift build --arch arm64 --arch x86_64`) puts them under .build/apple
# instead; BIN_DIR overrides both.
BIN_DIR="${BIN_DIR:-}"
if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="$REPO_DIR/.build/release"
    if [[ ! -f "$BIN_DIR/QuotaPeekWidget" && -f "$REPO_DIR/.build/apple/Products/Release/QuotaPeekWidget" ]]; then
        BIN_DIR="$REPO_DIR/.build/apple/Products/Release"
    fi
fi
SWIFT_BINARY="$BIN_DIR/QuotaPeek"
WIDGET_BINARY="$BIN_DIR/QuotaPeekWidget"
WIDGET_INFO_PLIST="$REPO_DIR/Resources/QuotaPeekWidget-Info.plist"
WIDGET_ENTITLEMENTS="$REPO_DIR/QuotaPeekWidget.entitlements"
APP_BUNDLE="$REPO_DIR/.build/release/QuotaPeek.app"
INFO_PLIST="$REPO_DIR/Info.plist"
ENTITLEMENTS="$REPO_DIR/QuotaPeek.entitlements"
APP_ICON="$REPO_DIR/Resources/AppIcon.icns"
MENU_BAR_ICON_1X="$REPO_DIR/Resources/MenuBarIcon.png"
MENU_BAR_ICON_2X="$REPO_DIR/Resources/MenuBarIcon@2x.png"
MENU_BAR_ICON_3X="$REPO_DIR/Resources/MenuBarIcon@3x.png"

# Verify prerequisites
for f in "$SWIFT_BINARY" "$WIDGET_BINARY" "$INFO_PLIST" "$ENTITLEMENTS" \
         "$WIDGET_INFO_PLIST" "$WIDGET_ENTITLEMENTS" "$APP_ICON" \
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

# Embed the WidgetKit extension (built by SwiftPM as a plain executable).
WIDGET_APPEX="$APP_BUNDLE/Contents/PlugIns/QuotaPeekWidget.appex"
mkdir -p "$WIDGET_APPEX/Contents/MacOS"
# Stamp the extension as requiring macOS 14 (desktop widgets, content
# margins and containerBackground all start there). WidgetKit keys its
# modern layout on the binary's minimum OS: built for 13 it renders the
# widget edge to edge with no system margins.
xcrun vtool -set-build-version macos 14.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
    -output "$WIDGET_APPEX/Contents/MacOS/QuotaPeekWidget" "$WIDGET_BINARY"
cp "$WIDGET_INFO_PLIST" "$WIDGET_APPEX/Contents/Info.plist"

# Compile the widget's asset catalog and declare its accent and background
# colours (NSAccentColorName / NSWidgetBackgroundColorName), as Xcode does.
# macOS uses them to tint the widget on an unfocused desktop; without them
# it falls back to light glass and the white-tinted text disappears.
WIDGET_ASSETS="$REPO_DIR/Resources/WidgetAssets.xcassets"
mkdir -p "$WIDGET_APPEX/Contents/Resources"
PARTIAL_PLIST="$(mktemp -t quotapeek-widget-assets).plist"
if ! xcrun actool "$WIDGET_ASSETS" --compile "$WIDGET_APPEX/Contents/Resources" \
        --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --accent-color WidgetAccentColor --widget-background-color WidgetBackground \
        --output-partial-info-plist "$PARTIAL_PLIST" --output-format human-readable-text \
        --errors --warnings >/dev/null; then
    echo "ERROR: actool failed to compile $WIDGET_ASSETS." >&2
    echo "       If it reports a plug-in failure, run: sudo xcodebuild -runFirstLaunch" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Merge $PARTIAL_PLIST" "$WIDGET_APPEX/Contents/Info.plist"
rm -f "$PARTIAL_PLIST"

# Generate Info.plists with stamped version/build numbers
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
for plist in "$APP_BUNDLE/Contents/Info.plist" "$WIDGET_APPEX/Contents/Info.plist"; do
"${PYTHON3:-python3}" -c '
import sys, re
p, ver, bld = sys.argv[1], sys.argv[2], sys.argv[3]
with open(p, "r", encoding="utf-8") as f:
    t = f.read()
t = re.sub(
    r"(<key>CFBundleVersion</key>\s*<string>)\d+(</string>)",
    lambda m: m.group(1) + bld + m.group(2), t)
t = re.sub(
    r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)",
    lambda m: m.group(1) + ver + m.group(2), t)
with open(p, "w", encoding="utf-8") as f:
    f.write(t)
' "$plist" "$VERSION" "$BUILD_NUMBER"
done

# Record the SDK/toolchain the way Xcode does. WidgetKit gates modern
# behaviour on these keys: without them it treats the extension as built
# with an old SDK and draws it edge to edge on black, without the system
# content margins or the standard widget background.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')"
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk 'NR==2 {print $3}')"
# "27.2" -> "2720", "16" -> "1600" (Xcode's DTXcode format).
DT_XCODE="$(awk -v v="$XCODE_VERSION" 'BEGIN { n = split(v, p, "."); printf "%d%d%d", p[1], (n > 1 ? p[2] : 0), (n > 2 ? p[3] : 0) }')"
for plist in "$APP_BUNDLE/Contents/Info.plist" "$WIDGET_APPEX/Contents/Info.plist"; do
    for kv in "DTPlatformName:macosx" "DTPlatformVersion:$SDK_VERSION" "DTPlatformBuild:$SDK_BUILD" \
              "DTSDKName:macosx$SDK_VERSION" "DTSDKBuild:$SDK_BUILD" "DTXcode:$DT_XCODE" \
              "DTXcodeBuild:$XCODE_BUILD" "DTCompiler:com.apple.compilers.llvm.clang.1_0"; do
        key="${kv%%:*}"; value="${kv#*:}"
        /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
    done
done

# Create a minimal PkgInfo (standard for macOS .app bundles)
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc code signing"

# Sign the widget extension first with its own (sandbox) entitlements, then
# the app around it. Never --deep here: it would re-sign the extension with
# the app's entitlements, dropping the sandbox WidgetKit requires.
codesign --sign - --force --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_APPEX"
echo "  signed $WIDGET_APPEX"
codesign --sign - --force --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
echo "  signed $APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Bundle ready at $APP_BUNDLE"
