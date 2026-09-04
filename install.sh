#!/bin/bash
# Installs AIUsageWidget: builds the menu bar app, copies it plus the Codex
# collector script into ~/Library/Application Support/AIUsageWidget/bin, and
# installs LaunchAgents so the app and the Codex poller start at login.
#
# This never edits any other tool's config file. Claude Code usage is fetched
# by the app itself (Keychain-read OAuth token + a direct Anthropic API call);
# Codex usage is fetched by spawning `codex app-server` fresh each poll.
#
# Safe to re-run: it overwrites its own previously-installed files only.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/AIUsageWidget"
BIN_DIR="$APP_SUPPORT/bin"
PYTHON3="$(command -v python3)"

echo "==> Building release binary"
cd "$REPO_DIR"
swift build -c release

echo "==> Installing to $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/.build/release/AIUsageWidget" "$BIN_DIR/AIUsageWidget"
cp "$REPO_DIR/Scripts/codex-usage-poll.py" "$BIN_DIR/"
chmod +x "$BIN_DIR"/*.py "$BIN_DIR/AIUsageWidget"

echo "==> Installing LaunchAgents"
mkdir -p "$HOME/Library/LaunchAgents"
for name in com.aiusagewidget.codexpoll com.aiusagewidget.app; do
    template="$REPO_DIR/LaunchAgents/$name.plist.template"
    dest="$HOME/Library/LaunchAgents/$name.plist"
    sed -e "s#__PYTHON3__#$PYTHON3#g" \
        -e "s#__BIN_DIR__#$BIN_DIR#g" \
        -e "s#__HOME__#$HOME#g" \
        -e "s#__APP_SUPPORT__#$APP_SUPPORT#g" \
        "$template" > "$dest"
    launchctl unload "$dest" >/dev/null 2>&1 || true
    launchctl load "$dest"
    echo "  loaded $dest"
done

echo ""
echo "Installed. The menu bar icon should appear now (a gauge icon in the top menu bar)."
echo "Claude usage populates within a few seconds of launch (macOS will prompt you once"
echo "to allow the app to read Claude Code's Keychain item - choose 'Always Allow')."
echo "Codex usage populates within a couple of minutes (first poll runs immediately)."
echo "Antigravity usage isn't wired up yet."
