#!/bin/bash
# Installs QuotaPeek:
#   - installs the menu bar app (which also contains the macOS widget) in
#     /Applications (or ~/Applications if /Applications isn't writable)
#   - copies the statusLine hook scripts into
#     ~/Library/Application Support/QuotaPeek/bin
#   - installs a LaunchAgent so the app starts at login
#   - registers the statusLine hook in ~/.claude/settings.json and
#     ~/.gemini/antigravity-cli/settings.json (merged in, existing settings
#     preserved); the hooks send each reading to the running app
#
# There is no background service: the app reads the agents' hooks and
# Codex's session logs itself, and on first launch adds an account for each
# agent it finds.
#
# Three ways to get the files installed, auto-detected:
#   - Local checkout (this script sitting next to Package.swift): builds the
#     Swift app from source.
#   - Piped via curl, or run with --remote: downloads a prebuilt release
#     tarball from GitHub instead of building anything locally.
#     curl -fsSL https://raw.githubusercontent.com/shassshank/QuotaPeek/master/install.sh | bash
#   - Run with --from-dir <dir>: same as --remote's file-placement step, but
#     sourced from an already-local directory (containing QuotaPeek.app, the
#     hook scripts and the LaunchAgent template) instead of downloading a
#     tarball. This is what the "Install QuotaPeek.command" bundled inside
#     the release DMG runs, pointed at its own directory.
#
#     Files delivered via `curl` (or any programmatic download) do NOT
#     receive the com.apple.quarantine extended attribute that macOS
#     attaches to files downloaded through a browser, AirDrop, Mail, etc.
#     Gatekeeper's "unidentified developer" block and the notarization check
#     are triggered by the presence of that quarantine xattr - no xattr, no
#     block. This means an ad-hoc-signed binary installed via `curl | bash`
#     runs without any notarization or paid Developer ID certificate. This
#     is the same mechanism Homebrew, Rustup, nvm, and every other
#     curl-pipe-bash installer relies on. A DMG downloaded via a browser DOES
#     carry the quarantine xattr, so "Install QuotaPeek.command" (like the
#     .app itself) needs the one-time right-click → Open on first run.
#
# Safe to re-run: it overwrites its own previously-installed files only, and
# the settings.json merge only ever touches the "statusLine" key.
set -euo pipefail

GITHUB_REPO="${QUOTAPEEK_GITHUB_REPO:-shassshank/QuotaPeek}"
APP_SUPPORT="$HOME/Library/Application Support/QuotaPeek"
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
APP_BUNDLE_DEST="$APP_INSTALL_DIR/QuotaPeek.app"

MODE=""
VERSION=""
FROM_DIR=""

# Lifecycle commands run without rebuilding or reinstalling.
case "${1:-}" in
    --app-login-on)
        exec launchctl enable "gui/$(id -u)/com.quotapeek.app"
        ;;
    --app-login-off)
        exec launchctl disable "gui/$(id -u)/com.quotapeek.app"
        ;;
    "") ;;
    --remote) MODE="remote" ;;
    --local) MODE="local" ;;
    --from-dir) FROM_DIR="${2:?--from-dir requires a directory argument}"; MODE="fromdir" ;;
    --version) VERSION="${2:?--version requires an argument}"; MODE="remote" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# A local checkout is this script sitting next to Package.swift.
# Piped via `curl | bash`, BASH_SOURCE[0] isn't a real file on disk, so this
# naturally falls through to remote mode.
REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$candidate/Package.swift" && -f "$candidate/Scripts/build-app-bundle.sh" ]]; then
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

if [[ "$MODE" == "fromdir" && ! -d "$FROM_DIR/QuotaPeek.app" ]]; then
    echo "ERROR: --from-dir $FROM_DIR does not look like an extracted QuotaPeek release (no QuotaPeek.app found)" >&2
    exit 1
fi

if [[ "$MODE" == "local" ]]; then
    echo "==> Building Swift menu bar app"
    cd "$REPO_DIR"
    swift build -c release

    echo "==> Assembling .app bundle and ad-hoc signing"
    bash "$REPO_DIR/Scripts/build-app-bundle.sh"

    echo "==> Installing to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    rm -rf "$BIN_DIR/QuotaPeek.app" # migrate away from the old (pre-/Applications) install location
    echo "==> Installing app bundle to $APP_BUNDLE_DEST"
    rm -rf "$APP_BUNDLE_DEST"
    cp -R "$REPO_DIR/.build/release/QuotaPeek.app" "$APP_BUNDLE_DEST"
    cp "$REPO_DIR/Scripts/claude-statusline-hook.py" "$BIN_DIR/"
    cp "$REPO_DIR/Scripts/antigravity-statusline-hook.py" "$BIN_DIR/"
    cp "$REPO_DIR/Scripts/quotapeek_hook.py" "$BIN_DIR/"
    cp "$REPO_DIR/Scripts/uninstall.sh" "$BIN_DIR/uninstall.sh"
    cp "$REPO_DIR/Scripts/run-with-log-rotation.sh" "$BIN_DIR/run-with-log-rotation.sh"
    chmod +x "$BIN_DIR/uninstall.sh" "$BIN_DIR/run-with-log-rotation.sh"
    chmod +x "$BIN_DIR"/*.py

    TEMPLATE_DIR="$REPO_DIR/LaunchAgents"
elif [[ "$MODE" == "fromdir" ]]; then
    SOURCE_DIR="$FROM_DIR"
    TEMPLATE_DIR="$FROM_DIR"
else
    if [[ -z "$VERSION" ]]; then
        echo "==> Fetching latest release tag from GitHub"
        if ! RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest"); then
            echo "ERROR: Could not reach GitHub to determine latest release version (curl failed)." >&2
            echo "Specify explicitly: $0 --version vX.Y.Z" >&2
            exit 1
        fi
        if [[ -z "$RELEASE_JSON" ]]; then
            echo "ERROR: GitHub returned an empty response for the latest release." >&2
            echo "Specify explicitly: $0 --version vX.Y.Z" >&2
            exit 1
        fi
        # Prefer a real JSON parse; python3 is already assumed present elsewhere
        # in this script (see setup_detected_accounts/merge_statusline). Fall
        # back to a tightened grep/sed extraction if python3 is unavailable.
        if command -v python3 >/dev/null 2>&1; then
            VERSION="$(printf '%s' "$RELEASE_JSON" | "$PYTHON3" -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tag_name") or "")
except Exception:
    pass
')"
        else
            VERSION=$(printf '%s' "$RELEASE_JSON" \
                | grep -m1 '"tag_name"' \
                | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
        fi
        if [[ -z "$VERSION" ]]; then
            echo "ERROR: Could not determine latest release version from GitHub's response." >&2
            echo "Specify explicitly: $0 --version vX.Y.Z" >&2
            exit 1
        fi
    fi
    echo "==> Installing QuotaPeek $VERSION"

    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/quotapeek-macos.tar.gz"
    TMPDIR_INSTALL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

    echo "==> Downloading $DOWNLOAD_URL"
    curl -fSL "$DOWNLOAD_URL" -o "$TMPDIR_INSTALL/quotapeek-macos.tar.gz"
    CHECKSUMS_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/SHA256SUMS"
    if ! curl -fSL "$CHECKSUMS_URL" -o "$TMPDIR_INSTALL/SHA256SUMS"; then
        echo "ERROR: Could not download required SHA256SUMS for $VERSION; installation aborted." >&2
        exit 1
    fi

    # Select only the tarball entry: the manifest also covers the DMG.
    EXPECTED_SHA256=$(awk '$2 == "quotapeek-macos.tar.gz" && NF == 2 {print $1}' "$TMPDIR_INSTALL/SHA256SUMS")
    if [[ ! "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "ERROR: SHA256SUMS must contain exactly one valid tarball checksum; installation aborted." >&2
        exit 1
    fi
    echo "==> Verifying tarball SHA256"
    if ! (cd "$TMPDIR_INSTALL" && printf '%s  quotapeek-macos.tar.gz\n' "$EXPECTED_SHA256" | shasum -a 256 -c -); then
        echo "ERROR: Tarball SHA256 verification failed; installation aborted." >&2
        exit 1
    fi

    echo "==> Extracting"
    tar xzf "$TMPDIR_INSTALL/quotapeek-macos.tar.gz" -C "$TMPDIR_INSTALL"

    SOURCE_DIR="$TMPDIR_INSTALL"
    TEMPLATE_DIR="$TMPDIR_INSTALL"
fi

if [[ "$MODE" == "remote" || "$MODE" == "fromdir" ]]; then
    echo "==> Installing to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    rm -rf "$BIN_DIR/QuotaPeek.app" # migrate away from the old (pre-/Applications) install location
    if [[ -d "$SOURCE_DIR/QuotaPeek.app" ]]; then
        echo "==> Installing app bundle to $APP_BUNDLE_DEST"
        rm -rf "$APP_BUNDLE_DEST"
        cp -R "$SOURCE_DIR/QuotaPeek.app" "$APP_BUNDLE_DEST"
    fi
    cp "$SOURCE_DIR/claude-statusline-hook.py" "$BIN_DIR/"
    cp "$SOURCE_DIR/antigravity-statusline-hook.py" "$BIN_DIR/"
    cp "$SOURCE_DIR/quotapeek_hook.py" "$BIN_DIR/"
    cp "$SOURCE_DIR/run-with-log-rotation.sh" "$BIN_DIR/"
    cp "$SOURCE_DIR/uninstall.sh" "$BIN_DIR/"
    chmod +x "$BIN_DIR"/*.py "$BIN_DIR/run-with-log-rotation.sh" "$BIN_DIR/uninstall.sh"
fi


echo "==> Installing LaunchAgent"
mkdir -p "$LAUNCH_AGENTS"
for name in com.quotapeek.app; do
    template="$TEMPLATE_DIR/$name.plist.template"
    dest="$LAUNCH_AGENTS/$name.plist"
    if [[ ! -f "$template" ]]; then
        echo "  warning: $template not found, skipping" >&2
        continue
    fi
    "$PYTHON3" - "$template" "$dest" "$BIN_DIR" "$HOME" "$APP_SUPPORT" "$APP_BUNDLE_DEST" <<'PY'
import sys
tmpl, dest, bin_dir, home, app_support, app_bundle = sys.argv[1:7]
with open(tmpl, "r", encoding="utf-8") as f:
    c = f.read()
c = (c.replace("__BIN_DIR__", bin_dir)
      .replace("__HOME__", home)
      .replace("__APP_SUPPORT__", app_support)
      .replace("__APP_BUNDLE__", app_bundle))
with open(dest, "w", encoding="utf-8") as f:
    f.write(c)
PY
    was_disabled=false
    if launchctl print-disabled "gui/$(id -u)/" 2>/dev/null | grep -E "\"$name\"\s*=>\s*disabled" >/dev/null 2>&1; then
        was_disabled=true
    fi
    launchctl unload "$dest" >/dev/null 2>&1 || true
    if [ "$was_disabled" = true ]; then
        echo "  preserving disabled state for $dest (skipping load)"
    else
        launchctl load -w "$dest"
        echo "  loaded $dest"
    fi
done

has_cli() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || \
        [ -e "$HOME/.local/bin/$cmd" ] || \
        [ -e "/opt/homebrew/bin/$cmd" ] || \
        [ -e "/usr/local/bin/$cmd" ]
}

merge_statusline() {
    local settings_file="$1"
    local command="$2"
    mkdir -p "$(dirname "$settings_file")"
    if [ ! -f "$settings_file" ]; then
        echo '{}' > "$settings_file"
    fi
    "$PYTHON3" - "$settings_file" "$command" "${3:-}" <<'PY'
import datetime, json, os, shutil, sys, tempfile
path, command = sys.argv[1], sys.argv[2]
interval = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

if not os.path.exists(path) or os.path.getsize(path) == 0:
    data = {}
else:
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        data = {}

desired = {"type": "command", "command": command, "enabled": True}
if interval:
    desired["refreshInterval"] = int(interval)

existing = data.get("statusLine")
if isinstance(existing, dict) and all(existing.get(k) == v for k, v in desired.items()):
    sys.exit(0)

is_ours = (
    isinstance(existing, dict)
    and existing.get("type") == "command"
    and isinstance(existing.get("command", ""), str)
    and "QuotaPeek" in existing.get("command", "")
)

if "statusLine" in data and not is_ours:
    backup = path + ".bak." + datetime.datetime.now().strftime("%Y%m%dT%H%M%S%f")
    shutil.copy2(path, backup)
    print("  backed up settings to " + backup)

data["statusLine"] = desired
fd, tmp = tempfile.mkstemp(prefix=".settings-", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

echo "==> Registering statusLine hooks"
# BIN_DIR lives under ~/Library/Application Support, which has a space in it -
# the command string must quote each path so a naive whitespace-splitting
# executor (not just a real shell) doesn't tear "Application Support" in two.
# Only register each hook for a CLI that's actually installed - writing into
# ~/.claude/settings.json or ~/.gemini/antigravity-cli/settings.json when that
# CLI isn't even present would create dead config for an app that doesn't exist.
if has_cli claude; then
    merge_statusline "$HOME/.claude/settings.json" "\"$PYTHON3\" \"$BIN_DIR/claude-statusline-hook.py\"" 3
else
    echo "  claude not detected; skipping Claude statusLine hook."
fi
if security find-generic-password -s gemini -a antigravity >/dev/null 2>&1; then
    merge_statusline "$HOME/.gemini/antigravity-cli/settings.json" "\"$PYTHON3\" \"$BIN_DIR/antigravity-statusline-hook.py\""
else
    echo "  antigravity not detected; skipping Antigravity statusLine hook."
fi

echo ""
echo "Installed. The menu bar icon should appear now (top menu bar)."
echo "QuotaPeek adds an account for each agent it finds; manage them in Settings > Accounts."
echo "The macOS widget is in the widget gallery: right-click the desktop > Edit Widgets > QuotaPeek."
if [[ -f "$0" ]]; then
    SCRIPT_CMD="$0"
else
    SCRIPT_CMD="./install.sh"
fi
echo "Use Settings (or 'launchctl [enable|disable] gui/\$(id -u)/com.quotapeek.app', or '$SCRIPT_CMD --app-login-off/--app-login-on') to manage app login preferences."
