#!/bin/bash
# uninstall.sh — Fully remove QuotaPeek from the system.
#
# This script is installed at:
#   ~/Library/Application Support/QuotaPeek/bin/uninstall.sh
# The Swift UI's Settings "Uninstall" button shells out to exactly that path.
#
# Actions:
#   1. Unload both LaunchAgents (launchctl unload -w)
#   2. Remove both plist files from ~/Library/LaunchAgents
#   3. Remove ~/Library/Application Support/QuotaPeek entirely
#   4. Remove QuotaPeek.app from /Applications or ~/Applications
#   5. Reverse the statusLine hook injection in settings files:
#      - ~/.claude/settings.json
#      - ~/.gemini/antigravity-cli/settings.json
#      Restores from .bak.<timestamp> backup ONLY if the current statusLine
#      value still matches what the installer wrote.  If the user has since
#      changed statusLine to something else, we leave the file alone (don't
#      clobber user changes) but still remove the key if it equals ours.
set -euo pipefail

PYTHON3="${PYTHON3:-$(command -v python3 || echo python3)}"
APP_SUPPORT="$HOME/Library/Application Support/QuotaPeek"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "==> Stopping and removing LaunchAgents"
for label in com.quotapeek.daemon com.quotapeek.app; do
    plist="$LAUNCH_AGENTS/$label.plist"
    if [[ -f "$plist" ]]; then
        launchctl unload -w "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "  removed $plist"
    fi
done

echo "==> Reversing statusLine hook injection"

reverse_statusline() {
    local settings_file="$1"

    if [[ ! -f "$settings_file" ]]; then
        return
    fi

    "$PYTHON3" - "$settings_file" <<'PY'
import json, sys, os, glob

path = sys.argv[1]

try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, IOError):
    print("  warning: could not parse " + path + ", skipping")
    sys.exit(0)

existing = data.get("statusLine")
if existing is None:
    print("  no statusLine key in " + path + ", nothing to undo")
    sys.exit(0)

# Detect whether the current statusLine is one WE installed (our hooks
# always have "QuotaPeek" in the command path).
is_ours = (
    isinstance(existing, dict)
    and existing.get("type") == "command"
    and isinstance(existing.get("command", ""), str)
    and "QuotaPeek" in existing.get("command", "")
)

if not is_ours:
    print("  statusLine in " + path + " was modified by user, leaving as-is")
    sys.exit(0)

# Look for the most recent .bak.* backup made by the installer.
backups = sorted(glob.glob(path + ".bak.*"))
restored = False
if backups:
    latest_backup = backups[-1]
    try:
        with open(latest_backup) as bf:
            backup_data = json.load(bf)
        backup_sl = backup_data.get("statusLine")
        # Restore the prior statusLine value from backup.
        if backup_sl is not None:
            data["statusLine"] = backup_sl
            print("  restored prior statusLine from " + latest_backup)
            restored = True
        else:
            # Backup had no statusLine → remove the key entirely.
            del data["statusLine"]
            print("  removed statusLine (backup had none)")
            restored = True
    except (json.JSONDecodeError, IOError):
        print("  warning: backup " + latest_backup + " unreadable, removing statusLine key instead")

if not restored:
    # No usable backup — just remove the key we inserted.
    del data["statusLine"]
    print("  removed statusLine key (no backup found)")

import tempfile
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

reverse_statusline "$HOME/.claude/settings.json"
reverse_statusline "$HOME/.gemini/antigravity-cli/settings.json"

echo "==> Removing application support directory"
if [[ -d "$APP_SUPPORT" ]]; then
    rm -rf "$APP_SUPPORT"
    echo "  removed $APP_SUPPORT"
fi

echo "==> Removing app bundle"
for dir in "/Applications" "$HOME/Applications"; do
    bundle="$dir/QuotaPeek.app"
    if [[ -d "$bundle" ]]; then
        rm -rf "$bundle"
        echo "  removed $bundle"
    fi
done

echo ""
echo "QuotaPeek has been fully uninstalled."
echo "Backup copies of your settings files (.bak.*) were left in place"
echo "in case you need to recover any prior configuration."
