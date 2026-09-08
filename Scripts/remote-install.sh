#!/bin/bash
# remote-install.sh — Install AIUsageWidget from a prebuilt GitHub Release.
#
# Intended invocation:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/AIUsageWidget/main/Scripts/remote-install.sh | bash
#   curl -fsSL <release-url>/remote-install.sh | bash -s -- [--version vX.Y.Z]
#
# Why this sidesteps Gatekeeper / notarization:
#   Files delivered via `curl` (or any programmatic download) do NOT receive the
#   com.apple.quarantine extended attribute that macOS attaches to files
#   downloaded through a browser, AirDrop, Mail, etc.  Gatekeeper's
#   "unidentified developer" block and the notarization check are triggered by
#   the presence of that quarantine xattr — no xattr, no block.  This means an
#   ad-hoc-signed binary installed via `curl | bash` will run without any
#   notarization or paid Developer ID certificate.  This is the same mechanism
#   that Homebrew, Rustup, nvm, and every other curl-pipe-bash installer relies
#   on.
#
# Expected GitHub Release convention:
#   - Tag:   vX.Y.Z
#   - Asset: aiusagewidget-macos.tar.gz
#   - Tarball contents (flat):
#       AIUsageWidget.app/        (ad-hoc signed .app bundle)
#       aiusaged                  (ad-hoc signed Go daemon binary)
#       claude-statusline-hook.py
#       antigravity-statusline-hook.py
#       run-with-log-rotation.sh
#       uninstall.sh
#       com.aiusagewidget.daemon.plist.template
#       com.aiusagewidget.app.plist.template
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────
GITHUB_REPO="${AIW_GITHUB_REPO:-<owner>/AIUsageWidget}"
VERSION=""
APP_SUPPORT="$HOME/Library/Application Support/AIUsageWidget"
BIN_DIR="$APP_SUPPORT/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PYTHON3="$(command -v python3 || echo python3)"

# ── Argument parsing ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# ── Resolve latest version if not specified ────────────────────────────
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

# ── Download and extract ──────────────────────────────────────────────
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/aiusagewidget-macos.tar.gz"
TMPDIR_INSTALL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

echo "==> Downloading $DOWNLOAD_URL"
curl -fSL "$DOWNLOAD_URL" -o "$TMPDIR_INSTALL/aiusagewidget-macos.tar.gz"

echo "==> Extracting"
tar xzf "$TMPDIR_INSTALL/aiusagewidget-macos.tar.gz" -C "$TMPDIR_INSTALL"

# ── Install binaries ─────────────────────────────────────────────────
echo "==> Installing to $BIN_DIR"
mkdir -p "$BIN_DIR"

# App bundle
if [[ -d "$TMPDIR_INSTALL/AIUsageWidget.app" ]]; then
    rm -rf "$BIN_DIR/AIUsageWidget.app"
    cp -R "$TMPDIR_INSTALL/AIUsageWidget.app" "$BIN_DIR/AIUsageWidget.app"
fi

# Daemon binary
cp "$TMPDIR_INSTALL/aiusaged" "$BIN_DIR/aiusaged"

# Hook scripts
cp "$TMPDIR_INSTALL/claude-statusline-hook.py" "$BIN_DIR/"
cp "$TMPDIR_INSTALL/antigravity-statusline-hook.py" "$BIN_DIR/"

# Utility scripts
cp "$TMPDIR_INSTALL/run-with-log-rotation.sh" "$BIN_DIR/"
cp "$TMPDIR_INSTALL/uninstall.sh" "$BIN_DIR/"
chmod +x "$BIN_DIR"/*.py "$BIN_DIR/aiusaged" "$BIN_DIR/run-with-log-rotation.sh" "$BIN_DIR/uninstall.sh"

# Add auth tokens to installed hook copies (mirrors install.sh logic).
"$PYTHON3" - "$BIN_DIR" <<'PYAUTH'
from pathlib import Path
import sys, os
for name in ("claude-statusline-hook.py", "antigravity-statusline-hook.py"):
    path = Path(sys.argv[1]) / name
    source = path.read_text()
    old = 'headers={"Content-Type": "application/json"}'
    new = 'headers={"Content-Type": "application/json", "X-Auth-Token": open(os.path.expanduser("~/Library/Application Support/AIUsageWidget/auth-token")).read().strip()}'
    if old not in source:
        # Already patched or hook format changed — skip silently.
        continue
    path.write_text(source.replace(old, new))
PYAUTH

# ── Install LaunchAgents ──────────────────────────────────────────────
echo "==> Installing LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"

for name in com.aiusagewidget.daemon com.aiusagewidget.app; do
    template="$TMPDIR_INSTALL/$name.plist.template"
    dest="$LAUNCH_AGENTS/$name.plist"
    if [[ ! -f "$template" ]]; then
        echo "  warning: $template not found in release, skipping" >&2
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

# ── Register statusLine hooks ────────────────────────────────────────
echo "==> Registering statusLine hooks (Injection route)"

# Shared merge_statusline function — same logic as install.sh.
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

merge_statusline "$HOME/.claude/settings.json" "\"$PYTHON3\" \"$BIN_DIR/claude-statusline-hook.py\""
merge_statusline "$HOME/.gemini/antigravity-cli/settings.json" "\"$PYTHON3\" \"$BIN_DIR/antigravity-statusline-hook.py\""

echo ""
echo "Installed. The menu bar icon should appear now (a gauge icon in the top menu bar)."
echo "To uninstall: $BIN_DIR/uninstall.sh"
