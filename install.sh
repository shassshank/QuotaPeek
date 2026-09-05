#!/bin/bash
# Installs AIUsageWidget:
#   - builds the Go background daemon (Backend/) that owns all provider
#     collection, credential access, config, and error state
#   - builds the Swift menu bar app (a thin UI shell that only talks to the
#     daemon's local HTTP API - it never touches Keychain or any provider
#     API directly)
#   - copies both, plus the statusLine hook scripts, into
#     ~/Library/Application Support/AIUsageWidget/bin
#   - installs LaunchAgents so the daemon and the app start at login
#   - registers the statusLine hook in ~/.claude/settings.json and
#     ~/.gemini/antigravity-cli/settings.json (merged in, existing settings
#     preserved) - this is what powers the "Injection" route
#
# Safe to re-run: it overwrites its own previously-installed files only, and
# the settings.json merge only ever touches the "statusLine" key.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/AIUsageWidget"
BIN_DIR="$APP_SUPPORT/bin"
PYTHON3="$(command -v python3)"

echo "==> Building Go daemon"
cd "$REPO_DIR/Backend"
go build -o "$REPO_DIR/.build-go/aiusaged" .

echo "==> Building Swift menu bar app"
cd "$REPO_DIR"
swift build -c release

echo "==> Installing to $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/.build-go/aiusaged" "$BIN_DIR/aiusaged"
cp "$REPO_DIR/.build/release/AIUsageWidget" "$BIN_DIR/AIUsageWidget"
cp "$REPO_DIR/Scripts/claude-statusline-hook.py" "$BIN_DIR/"
cp "$REPO_DIR/Scripts/antigravity-statusline-hook.py" "$BIN_DIR/"
chmod +x "$BIN_DIR"/*.py "$BIN_DIR/aiusaged" "$BIN_DIR/AIUsageWidget"

echo "==> Installing LaunchAgents"
mkdir -p "$HOME/Library/LaunchAgents"
for name in com.aiusagewidget.daemon com.aiusagewidget.app; do
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

merge_statusline() {
    local settings_file="$1"
    local command="$2"
    mkdir -p "$(dirname "$settings_file")"
    if [ ! -f "$settings_file" ]; then
        echo '{}' > "$settings_file"
    fi
    "$PYTHON3" - "$settings_file" "$command" <<'PY'
import json, sys
path, command = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["statusLine"] = {"type": "command", "command": command, "enabled": True}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

echo "==> Registering statusLine hooks (Injection route)"
# BIN_DIR lives under ~/Library/Application Support, which has a space in it -
# the command string must quote each path so a naive whitespace-splitting
# executor (not just a real shell) doesn't tear "Application Support" in two.
merge_statusline "$HOME/.claude/settings.json" "\"$PYTHON3\" \"$BIN_DIR/claude-statusline-hook.py\""
merge_statusline "$HOME/.gemini/antigravity-cli/settings.json" "\"$PYTHON3\" \"$BIN_DIR/antigravity-statusline-hook.py\""

echo ""
echo "Installed. The menu bar icon should appear now (a gauge icon in the top menu bar)."
echo "The background daemon (aiusaged) polls Claude and Antigravity via Keychain-read"
echo "OAuth tokens, and Codex via a free local RPC call, by default."
echo ""
echo "Claude Code and Antigravity will also start pushing live usage data (the"
echo "Injection route) the next time you run either CLI, since their statusLine hooks"
echo "are now registered. Open the app's Settings window (gear icon in the popover) to"
echo "choose which route each provider uses, or enable both for automatic fallback."
