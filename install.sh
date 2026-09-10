#!/bin/bash
# Installs AIUsageWidget:
#   - copies the daemon (Backend/) and the menu bar app (a thin UI shell that
#     only talks to the daemon's local HTTP API - it never touches Keychain
#     or any provider API directly), plus the statusLine hook scripts, into
#     ~/Library/Application Support/AIUsageWidget/bin
#   - installs LaunchAgents so the daemon and the app start at login
#   - registers the statusLine hook in ~/.claude/settings.json and
#     ~/.gemini/antigravity-cli/settings.json (merged in, existing settings
#     preserved) - this is what powers the "Injection" route
#   - the hook scripts read their own auth token from the auth-token file
#     at run time, so they're copied to BIN_DIR as-is
#
# Two ways to get the files installed, auto-detected:
#   - Local checkout (this script sitting next to Backend/ and Package.swift):
#     builds the Go daemon and Swift app from source.
#   - Piped via curl, or run with --remote: downloads a prebuilt release
#     tarball from GitHub instead of building anything locally.
#     curl -fsSL https://raw.githubusercontent.com/<owner>/AIUsageWidget/main/install.sh | bash
#
#     Files delivered via `curl` (or any programmatic download) do NOT
#     receive the com.apple.quarantine extended attribute that macOS
#     attaches to files downloaded through a browser, AirDrop, Mail, etc.
#     Gatekeeper's "unidentified developer" block and the notarization check
#     are triggered by the presence of that quarantine xattr - no xattr, no
#     block. This means an ad-hoc-signed binary installed via `curl | bash`
#     runs without any notarization or paid Developer ID certificate. This
#     is the same mechanism Homebrew, Rustup, nvm, and every other
#     curl-pipe-bash installer relies on.
#
# Safe to re-run: it overwrites its own previously-installed files only, and
# the settings.json merge only ever touches the "statusLine" key.
set -euo pipefail

GITHUB_REPO="${AIW_GITHUB_REPO:-<owner>/AIUsageWidget}"
APP_SUPPORT="$HOME/Library/Application Support/AIUsageWidget"
BIN_DIR="$APP_SUPPORT/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PYTHON3="$(command -v python3 || echo python3)"

MODE=""
VERSION=""

# Lifecycle commands run without rebuilding or reinstalling.
case "${1:-}" in
    --app-login-on|--app-login-off|--daemon-start|--daemon-stop)
        case "$1" in
            --app-login-on) service=com.aiusagewidget.app; action=load ;;
            --app-login-off) service=com.aiusagewidget.app; action=unload ;;
            --daemon-start) service=com.aiusagewidget.daemon; action=load ;;
            --daemon-stop) service=com.aiusagewidget.daemon; action=unload ;;
        esac
        exec launchctl "$action" -w "$LAUNCH_AGENTS/$service.plist"
        ;;
    "") ;;
    --remote) MODE="remote" ;;
    --local) MODE="local" ;;
    --version) VERSION="${2:?--version requires an argument}"; MODE="remote" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# A local checkout is this script sitting next to Backend/ and Package.swift.
# Piped via `curl | bash`, BASH_SOURCE[0] isn't a real file on disk, so this
# naturally falls through to remote mode.
REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$candidate/Backend/go.mod" && -f "$candidate/Package.swift" ]]; then
        REPO_DIR="$candidate"
    fi
fi

if [[ -z "$MODE" ]]; then
    if [[ -n "$REPO_DIR" ]]; then MODE="local"; else MODE="remote"; fi
fi

if [[ "$MODE" == "local" && -z "$REPO_DIR" ]]; then
    echo "ERROR: --local requires running this script from a full source checkout" >&2
    exit 1
fi

if [[ "$MODE" == "local" ]]; then
    echo "==> Building Go daemon"
    cd "$REPO_DIR/Backend"
    go build -o "$REPO_DIR/.build-go/aiusaged" .

    echo "==> Building Swift menu bar app"
    cd "$REPO_DIR"
    swift build -c release

    echo "==> Assembling .app bundle and ad-hoc signing"
    bash "$REPO_DIR/Scripts/build-app-bundle.sh"

    echo "==> Installing to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    cp "$REPO_DIR/.build-go/aiusaged" "$BIN_DIR/aiusaged"
    rm -rf "$BIN_DIR/AIUsageWidget.app"
    cp -R "$REPO_DIR/.build/release/AIUsageWidget.app" "$BIN_DIR/AIUsageWidget.app"
    cp "$REPO_DIR/Scripts/claude-statusline-hook.py" "$BIN_DIR/"
    cp "$REPO_DIR/Scripts/antigravity-statusline-hook.py" "$BIN_DIR/"
    cp "$REPO_DIR/Scripts/uninstall.sh" "$BIN_DIR/uninstall.sh"
    cp "$REPO_DIR/Scripts/run-with-log-rotation.sh" "$BIN_DIR/run-with-log-rotation.sh"
    chmod +x "$BIN_DIR/uninstall.sh" "$BIN_DIR/run-with-log-rotation.sh"
    chmod +x "$BIN_DIR"/*.py "$BIN_DIR/aiusaged"

    TEMPLATE_DIR="$REPO_DIR/LaunchAgents"
else
    if [[ -z "$VERSION" ]]; then
        echo "==> Fetching latest release tag from GitHub"
        VERSION=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
        if [[ -z "$VERSION" ]]; then
            echo "ERROR: Could not determine latest release version." >&2
            echo "Specify explicitly: $0 --version vX.Y.Z" >&2
            exit 1
        fi
    fi
    echo "==> Installing AIUsageWidget $VERSION"

    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/aiusagewidget-macos.tar.gz"
    TMPDIR_INSTALL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

    echo "==> Downloading $DOWNLOAD_URL"
    curl -fSL "$DOWNLOAD_URL" -o "$TMPDIR_INSTALL/aiusagewidget-macos.tar.gz"

    echo "==> Extracting"
    tar xzf "$TMPDIR_INSTALL/aiusagewidget-macos.tar.gz" -C "$TMPDIR_INSTALL"

    echo "==> Installing to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    if [[ -d "$TMPDIR_INSTALL/AIUsageWidget.app" ]]; then
        rm -rf "$BIN_DIR/AIUsageWidget.app"
        cp -R "$TMPDIR_INSTALL/AIUsageWidget.app" "$BIN_DIR/AIUsageWidget.app"
    fi
    cp "$TMPDIR_INSTALL/aiusaged" "$BIN_DIR/aiusaged"
    cp "$TMPDIR_INSTALL/claude-statusline-hook.py" "$BIN_DIR/"
    cp "$TMPDIR_INSTALL/antigravity-statusline-hook.py" "$BIN_DIR/"
    cp "$TMPDIR_INSTALL/run-with-log-rotation.sh" "$BIN_DIR/"
    cp "$TMPDIR_INSTALL/uninstall.sh" "$BIN_DIR/"
    chmod +x "$BIN_DIR"/*.py "$BIN_DIR/aiusaged" "$BIN_DIR/run-with-log-rotation.sh" "$BIN_DIR/uninstall.sh"

    TEMPLATE_DIR="$TMPDIR_INSTALL"
fi

echo "==> Installing LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"
for name in com.aiusagewidget.daemon com.aiusagewidget.app; do
    template="$TEMPLATE_DIR/$name.plist.template"
    dest="$LAUNCH_AGENTS/$name.plist"
    if [[ ! -f "$template" ]]; then
        echo "  warning: $template not found, skipping" >&2
        continue
    fi
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
echo "The background daemon (aiusaged) polls Antigravity via Keychain-read OAuth tokens,"
echo "and Codex via a free local RPC call, by default."
echo ""
echo "Claude Code and Antigravity will also start pushing live usage data (the"
echo "Injection route) the next time you run either CLI, since their statusLine hooks"
echo "are now registered. Open the app's Settings window (gear icon in the popover) to"
echo "choose which route each provider uses, or enable both for automatic fallback."
echo ""
echo "Claude inference polling is off by default (consent-first): until you either run"
echo "Claude Code once (Injection route) or turn on inference polling in Settings, the"
echo "Claude row will show 'inference polling is disabled'. Enabling it sends a real"
echo "one-token inference request every 60s (~1,440/day) to read live rate-limit headers."
echo "Quitting the app leaves the daemon running. Use $0 --daemon-stop to stop it durably."
echo "Use $0 --app-login-off or --app-login-on to persist app login preferences."
