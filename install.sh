#!/bin/bash
# Installs AIUsageWidget:
#   - installs the menu bar app (a thin UI shell that only talks to the
#     daemon's local HTTP API - it never touches Keychain or any provider
#     API directly) as a normal .app bundle in /Applications (or
#     ~/Applications if /Applications isn't writable)
#   - copies the daemon (Backend/) and the statusLine hook scripts into
#     ~/Library/Application Support/AIUsageWidget/bin
#   - installs LaunchAgents so the daemon and the app start at login
#   - optionally auto-detects installed AI CLIs (Claude, Codex, Antigravity)
#     and registers them as accounts, with consent asked up front
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

# The .app bundle itself lives in /Applications like any other Mac app, so
# Spotlight/Launchpad/Finder can find it. Falls back to ~/Applications (no
# admin group membership required) if /Applications isn't writable.
APP_INSTALL_DIR="/Applications"
if [[ ! -w "$APP_INSTALL_DIR" ]]; then
    APP_INSTALL_DIR="$HOME/Applications"
    mkdir -p "$APP_INSTALL_DIR"
fi
APP_BUNDLE_DEST="$APP_INSTALL_DIR/AIUsageWidget.app"

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

# Check before starting the daemon: its first startup creates config.json.
DETECT_ACCOUNTS=false
if [ ! -e "$APP_SUPPORT/config.json" ]; then
    echo "Accounts are optional. Detection uses installed CLIs and existing login credentials."
    REPLY=""
    read -r -p "No existing configuration found. Auto-detect installed AI CLIs (Claude, Codex, Antigravity) and add them as accounts? [y/N] " REPLY || true
    case "$REPLY" in
        y|Y) DETECT_ACCOUNTS=true ;;
    esac
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
    rm -rf "$BIN_DIR/AIUsageWidget.app" # migrate away from the old (pre-/Applications) install location
    echo "==> Installing app bundle to $APP_BUNDLE_DEST"
    rm -rf "$APP_BUNDLE_DEST"
    cp -R "$REPO_DIR/.build/release/AIUsageWidget.app" "$APP_BUNDLE_DEST"
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
    rm -rf "$BIN_DIR/AIUsageWidget.app" # migrate away from the old (pre-/Applications) install location
    if [[ -d "$TMPDIR_INSTALL/AIUsageWidget.app" ]]; then
        echo "==> Installing app bundle to $APP_BUNDLE_DEST"
        rm -rf "$APP_BUNDLE_DEST"
        cp -R "$TMPDIR_INSTALL/AIUsageWidget.app" "$APP_BUNDLE_DEST"
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
        -e "s#__APP_BUNDLE__#$APP_BUNDLE_DEST#g" \
        "$template" > "$dest"
    launchctl unload "$dest" >/dev/null 2>&1 || true
    launchctl load "$dest"
    echo "  loaded $dest"
done

# POST /accounts creates credentials/account metadata; PUT /config enables routes.
setup_detected_accounts() {
    local token="" ready=false provider body patch config_dir interval
    local deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -s "$APP_SUPPORT/auth-token" ]; then
            token="$(cat "$APP_SUPPORT/auth-token")"
            if curl --silent --fail --max-time 0.2 \
                -H "X-Auth-Token: $token" http://127.0.0.1:47831/config >/dev/null; then
                ready=true
                break
            fi
        fi
        sleep 0.1
    done
    if [ "$ready" != true ]; then
        echo "  Daemon not ready; add accounts later in Settings > Add Account."
        return
    fi
    for provider in claude codex antigravity; do
        config_dir=""
        interval=60
        case "$provider" in
            claude|codex)
                if ! command -v "$provider" >/dev/null 2>&1; then
                    echo "  $provider not detected."
                    continue
                fi
                if [ "$provider" = claude ]; then
                    config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
                else
                    config_dir="${CODEX_HOME:-$HOME/.codex}"
                fi
                ;;
            antigravity)
                if ! security find-generic-password -s gemini -a antigravity >/dev/null 2>&1; then
                    echo "  antigravity not detected."
                    continue
                fi
                interval=120
                ;;
        esac
        # JSON encoding handles spaces/quotes in paths. Antigravity's existing
        # credential format matches loadAntigravityCreds in Backend/collectors.go.
        # Keep OAuth credentials out of command arguments and diagnostic output.
        if ! body="$("$PYTHON3" - "$provider" "$config_dir" <<'PY'
import base64, json, os, subprocess, sys
provider, config_dir = sys.argv[1:]
try:
    body = {"provider": provider, "label": "Default"}
    if provider == "antigravity":
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout.decode().strip()
        prefix = "go-keyring-base64:"
        if not raw.startswith(prefix):
            raise ValueError("credential encoding")
        creds = json.loads(base64.b64decode(raw[len(prefix):], validate=True))
        refresh = creds["token"]["refresh_token"]
        if not isinstance(refresh, str) or not refresh.strip():
            raise ValueError("missing refresh token")
        email = creds.get("email", "")
        body["credentialLocation"] = {"kind": "daemon_token"}
        body["oauthBootstrap"] = {"refreshToken": refresh, "email": email if isinstance(email, str) else ""}
    else:
        body["credentialLocation"] = {"kind": "config_dir", "configDir": os.path.abspath(config_dir)}
    print(json.dumps(body))
except Exception:
    sys.exit(1)
PY
)"; then
            echo "  Could not read $provider credentials; add it later in Settings."
            continue
        fi
        if ! printf '%s' "$body" | curl --silent --show-error --fail --max-time 5 \
            -H "X-Auth-Token: $token" -H "Content-Type: application/json" \
            --data-binary @- http://127.0.0.1:47831/accounts >/dev/null; then
            echo "  Could not add $provider; retry in Settings > Add Account."
            continue
        fi
        body=""
        patch="$("$PYTHON3" - "$provider" "$interval" <<'PY'
import json, sys
print(json.dumps({sys.argv[1]: {"routes_enabled": ["keychain"], "keychain_poll_interval_sec": int(sys.argv[2])}}))
PY
)"
        if printf '%s' "$patch" | curl --silent --show-error --fail --max-time 5 \
            -X PUT -H "X-Auth-Token: $token" -H "Content-Type: application/json" \
            --data-binary @- http://127.0.0.1:47831/config >/dev/null; then
            echo "  Added $provider account with Keychain route enabled."
        else
            echo "  Added $provider account; enable its route in Settings."
        fi
    done
}

if [ "$DETECT_ACCOUNTS" = true ]; then
    setup_detected_accounts
fi

merge_statusline() {
    local settings_file="$1"
    local command="$2"
    mkdir -p "$(dirname "$settings_file")"
    if [ ! -f "$settings_file" ]; then
        echo '{}' > "$settings_file"
    fi
    "$PYTHON3" - "$settings_file" "$command" "${3:-}" <<'PY'
import json, sys, shutil, datetime, os, tempfile
path, command = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
desired = {"type": "command", "command": command, "enabled": True}
if sys.argv[3]:
    desired["refreshInterval"] = int(sys.argv[3])
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
merge_statusline "$HOME/.claude/settings.json" "\"$PYTHON3\" \"$BIN_DIR/claude-statusline-hook.py\"" 3
merge_statusline "$HOME/.gemini/antigravity-cli/settings.json" "\"$PYTHON3\" \"$BIN_DIR/antigravity-statusline-hook.py\""

echo ""
echo "Installed. The menu bar icon should appear now (a gauge icon in the top menu bar)."
echo "Accounts are no longer auto-configured by default. Add detected accounts using"
echo "the fresh-install prompt, or later via Settings > Add Account."
echo ""
echo "StatusLine hooks are registered. Open Settings (gear icon in the popover) to"
echo "add accounts and choose their collection routes, including passive Claude injection."
echo ""
echo "Claude inference polling remains off by default. For an added Claude account,"
echo "enable Injection in Settings and run Claude Code for passive updates."
echo "Enabling inference polling in Settings sends a real"
echo "one-token inference request every 60s (~1,440/day) to read live rate-limit headers."
echo "Quitting the app also stops the background daemon; run $0 --daemon-start to bring it back without relaunching the app."
echo "Use $0 --app-login-off or --app-login-on to persist app login preferences."
