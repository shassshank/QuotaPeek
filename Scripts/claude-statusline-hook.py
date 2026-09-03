#!/usr/bin/env python3
"""
Claude Code statusLine hook.

Claude Code invokes this with a JSON payload on stdin every time it renders
the status line during an active session, and expects a short line of text
on stdout to display. We piggyback on that: write the rate_limits block out
to the shared usage cache the AIUsageWidget menu bar app reads, and pass
through a normal-looking status line so nothing visibly changes for the user.

Everything below is defensive on purpose: if this script ever throws before
printing something, Claude Code's status line goes blank for the user. A
debug dump of the raw payload is also written on every invocation so the
real field shapes can be inspected and the fallback line tightened.
"""
import json
import os
import sys
import time

CACHE_DIR = os.path.expanduser("~/Library/Application Support/AIUsageWidget")
CACHE_FILE = os.path.join(CACHE_DIR, "usage.json")
DEBUG_FILE = os.path.join(CACHE_DIR, "claude-statusline-debug.json")


def load_cache():
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_cache(cache):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp_path = CACHE_FILE + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(cache, f)
    os.replace(tmp_path, CACHE_FILE)


def as_str(value):
    """Best-effort turn any JSON value into a short display string."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("display_name", "name", "id", "value"):
            if isinstance(value.get(key), str):
                return value[key]
    return None


def window(entry):
    if not isinstance(entry, dict):
        return None
    used_percent = entry.get("utilization")
    if used_percent is None:
        used_percent = entry.get("used_percent")
    return {
        "used_percent": used_percent,
        "resets_at": entry.get("resets_at"),
    }


def fallback_status_line(payload):
    model = as_str(payload.get("model"))
    workspace = payload.get("workspace")
    cwd = None
    if isinstance(workspace, dict):
        cwd = workspace.get("current_dir") or workspace.get("cwd")
    elif isinstance(workspace, str):
        cwd = workspace
    dirname = os.path.basename(cwd) if isinstance(cwd, str) and cwd else None
    parts = [p for p in [model, dirname] if p]
    return " | ".join(parts) if parts else "Claude Code"


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
    except json.JSONDecodeError:
        payload = {}

    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(DEBUG_FILE, "w") as f:
            json.dump(payload, f, indent=2)
    except OSError:
        pass

    try:
        rate_limits = payload.get("rate_limits")
        if not isinstance(rate_limits, dict):
            rate_limits = {}
        cache = load_cache()
        cache["claude"] = {
            "five_hour": window(rate_limits.get("five_hour")),
            "weekly": window(rate_limits.get("seven_day")),
            "updated_at": int(time.time()),
        }
        save_cache(cache)
    except Exception:
        pass

    try:
        line = fallback_status_line(payload)
    except Exception:
        line = "Claude Code"
    print(line or "Claude Code")


if __name__ == "__main__":
    main()
