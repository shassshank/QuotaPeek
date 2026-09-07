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

# Lifecycle commands run without rebuilding or reinstalling.
case "${1:-}" in
    --app-login-on|--app-login-off|--daemon-start|--daemon-stop)
        case "$1" in
            --app-login-on) service=com.aiusagewidget.app; action=load ;;
            --app-login-off) service=com.aiusagewidget.app; action=unload ;;
            --daemon-start) service=com.aiusagewidget.daemon; action=load ;;
            --daemon-stop) service=com.aiusagewidget.daemon; action=unload ;;
        esac
        exec launchctl "$action" -w "$HOME/Library/LaunchAgents/$service.plist"
        ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

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
# Add auth to installed hook copies; repository hook sources remain untouched.
"$PYTHON3" - "$BIN_DIR" <<'PYAUTH'
from pathlib import Path
import sys
for name in ("claude-statusline-hook.py", "antigravity-statusline-hook.py"):
    path = Path(sys.argv[1]) / name
    source = path.read_text()
    old = 'headers={"Content-Type": "application/json"}'
    new = 'headers={"Content-Type": "application/json", "X-Auth-Token": open(os.path.expanduser("~/Library/Application Support/AIUsageWidget/auth-token")).read().strip()}'
    if old not in source:
        raise SystemExit("Cannot add hook authentication: " + name)
    path.write_text(source.replace(old, new))
PYAUTH
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
import json, sys, shutil, datetime, os, tempfile
path, command = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
desired = {"type": "command", "command": command, "enabled": True}
existing = data.get("statusLine")
if isinstance(existing, dict) and all(existing.get(k) == v for k, v in desired.items()):
    sys.exit(0)
if "statusLine" in data:
    backup = path + ".bak." + datetime.datetime.now().strftime("%Y%m%dT%H%M%S%f")
    shutil.copy2(path, backup)
    print("  backed up settings to " + backup)
data["statusLine"] = desired
fd, tmp = tempfile.mkstemp(prefix=".settings-", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
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

echo "Claude polling sends a real one-token inference request every 60s by default (~1,440/day)."
echo "Set claude_polling_mode to disabled in daemon config to stop these requests."
echo "Quitting the app leaves the daemon running. Use $0 --daemon-stop to stop it durably."
echo "Use $0 --app-login-off or --app-login-on to persist app login preferences."
