#!/bin/bash
# build-dmg.sh — Create a .dmg disk image for drag-to-Applications install.
#
# Usage: Scripts/build-dmg.sh [--version X.Y.Z]
#
# Prerequisites:
#   - .build/release/QuotaPeek.app  (from Scripts/build-app-bundle.sh)
#   - .build-go/quotapeekd          (from `go build` in Backend/)
#
# Output:
#   - .build/release/QuotaPeek-X.Y.Z.dmg
#
# The DMG is not just the .app: dragging QuotaPeek.app to /Applications
# alone isn't enough to run it, since the app only talks to the daemon over
# its local HTTP API and never sets up the daemon itself. So alongside
# QuotaPeek.app, the DMG also bundles the daemon binary, the statusLine hook
# scripts, the LaunchAgent templates, and "Install QuotaPeek.command" — a
# double-clickable wrapper that runs install.sh in `--from-dir` mode against
# those bundled files (the same file-placement logic install.sh's --remote
# mode uses for a curl install, just pointed at local files instead of a
# download). Users still drag QuotaPeek.app to /Applications for Spotlight/
# Launchpad visibility, but must also run Install QuotaPeek.command once to
# get the daemon, hooks, and LaunchAgents set up.
#
# NOTE: Since we use ad-hoc signing (no Apple Developer ID / notarization),
# users who download this .dmg from a browser will see a Gatekeeper warning
# on first launch of the app OR the installer command ("... can't be opened
# because it is from an unidentified developer"). The workaround is:
#   1. Right-click (or Control-click) the item
#   2. Select "Open" from the context menu
#   3. Click "Open" in the confirmation dialog
# This only needs to be done once per item — macOS remembers the exception.
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
DAEMON_BIN="$REPO_DIR/.build-go/quotapeekd"
DMG_NAME="QuotaPeek-${VERSION}.dmg"
DMG_PATH="$REPO_DIR/.build/release/$DMG_NAME"
DMG_STAGING="$REPO_DIR/.build/release/dmg-staging"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: App bundle not found at $APP_BUNDLE" >&2
    echo "Run Scripts/build-app-bundle.sh first." >&2
    exit 1
fi

if [[ ! -f "$DAEMON_BIN" ]]; then
    echo "ERROR: Daemon binary not found at $DAEMON_BIN" >&2
    echo "Run 'go build -o ../.build-go/quotapeekd .' from Backend/ first." >&2
    exit 1
fi

echo "==> Creating DMG staging area"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy the app bundle into the staging area
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# Bundle the daemon, hook scripts, LaunchAgent templates, and install.sh
# itself so "Install QuotaPeek.command" below can run a real local install
# (install.sh --from-dir) instead of a bare drag that leaves the daemon
# unset up.
cp "$DAEMON_BIN" "$DMG_STAGING/quotapeekd"
cp "$REPO_DIR/Scripts/claude-statusline-hook.py" "$DMG_STAGING/"
cp "$REPO_DIR/Scripts/antigravity-statusline-hook.py" "$DMG_STAGING/"
cp "$REPO_DIR/Scripts/run-with-log-rotation.sh" "$DMG_STAGING/"
cp "$REPO_DIR/Scripts/uninstall.sh" "$DMG_STAGING/"
cp "$REPO_DIR/LaunchAgents/com.quotapeek.daemon.plist.template" "$DMG_STAGING/"
cp "$REPO_DIR/LaunchAgents/com.quotapeek.app.plist.template" "$DMG_STAGING/"
cp "$REPO_DIR/install.sh" "$DMG_STAGING/install.sh"
chmod +x "$DMG_STAGING"/*.py "$DMG_STAGING/quotapeekd" "$DMG_STAGING/run-with-log-rotation.sh" "$DMG_STAGING/uninstall.sh" "$DMG_STAGING/install.sh"

cat > "$DMG_STAGING/Install QuotaPeek.command" <<'SCRIPT'
#!/bin/bash
# Double-click to install: sets up the daemon, hooks, and LaunchAgents
# using the files bundled next to this script in the same DMG/folder.
set -euo pipefail
cd "$(dirname "$0")"
exec bash install.sh --from-dir "$(pwd)"
SCRIPT
chmod +x "$DMG_STAGING/Install QuotaPeek.command"

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
echo "Users double-click 'Install QuotaPeek.command' inside the mounted DMG"
echo "(it installs the app, daemon, hooks, and LaunchAgents in one step)."
echo "For browser-downloaded copies: right-click → Open on first launch."
