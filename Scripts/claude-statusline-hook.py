#!/usr/bin/env python3
"""
Claude Code statusLine hook.

Claude Code invokes this with a JSON payload on stdin every time it renders
the status line during an active session, and expects a short line of text
on stdout to display. We piggyback on that: write the rate_limits block out
to the shared usage cache the AIUsageWidget menu bar app reads, and pass
through a normal-looking status line so nothing visibly changes for the user.
"""
import json
import os
import sys
import time

CACHE_DIR = os.path.expanduser("~/Library/Application Support/AIUsageWidget")
CACHE_FILE = os.path.join(CACHE_DIR, "usage.json")


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


def window(entry):
    if not entry:
        return None
    return {
        "used_percent": entry.get("utilization"),
        "resets_at": entry.get("resets_at"),
    }


def fallback_status_line(payload):
    model = (payload.get("model") or {}).get("display_name")
    cwd = (payload.get("workspace") or {}).get("current_dir")
    parts = [p for p in [model, os.path.basename(cwd) if cwd else None] if p]
    return " | ".join(parts) if parts else "Claude Code"


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        payload = {}

    rate_limits = payload.get("rate_limits") or {}
    cache = load_cache()
    cache["claude"] = {
        "five_hour": window(rate_limits.get("five_hour")),
        "weekly": window(rate_limits.get("seven_day")),
        "updated_at": int(time.time()),
    }
    save_cache(cache)

    # Preserve a normal-looking status line so the hook is invisible in day-to-day use.
    print(fallback_status_line(payload))


if __name__ == "__main__":
    main()
