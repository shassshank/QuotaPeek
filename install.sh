#!/bin/bash
# Installs AIUsageWidget: builds the menu bar app, copies it plus the collector
# scripts into ~/Library/Application Support/AIUsageWidget/bin, wires the
# Claude Code and Antigravity statusLine hooks, and installs LaunchAgents so
# the app and the Codex poller start at login.
#
# Safe to re-run: it merges JSON config (doesn't clobber unrelated settings)
# and overwrites its own previously-installed files.
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
cp "$REPO_DIR/Scripts/claude-statusline-hook.py" "$BIN_DIR/"
cp "$REPO_DIR/Scripts/antigravity-statusline-hook.py" "$BIN_DIR/"
cp "$REPO_DIR/Scripts/codex-usage-poll.py" "$BIN_DIR/"
chmod +x "$BIN_DIR"/*.py "$BIN_DIR/AIUsageWidget"

echo "==> Wiring Claude Code statusLine hook (~/.claude/settings.json)"
"$PYTHON3" - "$BIN_DIR/claude-statusline-hook.py" <<'EOF'
import json, os, shlex, sys
hook_path = sys.argv[1]
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}
# statusLine.command runs as a raw shell command line (it supports inline
# shell snippets like `jq -r '...'`), so a bare path is NOT shell-quoted for
# you. "Application Support" has a space in it, which silently breaks
# execution (shell treats it as two words -> "command not found", the
# status line just goes blank) unless the path itself is quoted here.
settings["statusLine"] = {"type": "command", "command": shlex.quote(hook_path)}
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"  updated {path}")
EOF

echo "==> Wiring Antigravity statusLine hook (~/.gemini/antigravity-cli/settings.json)"
"$PYTHON3" - "$BIN_DIR/antigravity-statusline-hook.py" <<'EOF'
import json, os, shlex, sys
hook_path = sys.argv[1]
path = os.path.expanduser("~/.gemini/antigravity-cli/settings.json")
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}
settings["statusLine"] = {"type": "command", "command": shlex.quote(hook_path), "enabled": True}
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"  updated {path}")
EOF

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
echo "Claude usage populates the next time Claude Code renders its status line (any active session)."
echo "Antigravity: same, but its statusLine payload schema is unconfirmed - check"
echo "  $APP_SUPPORT/antigravity-statusline-debug.json after first use and refine"
echo "  Scripts/antigravity-statusline-hook.py if usage doesn't show up."
echo "Codex usage populates within 15 minutes (first poll runs immediately)."
