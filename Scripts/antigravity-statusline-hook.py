#!/usr/bin/env python3
"""
Antigravity CLI statusLine hook.

Antigravity's statusLine payload schema hasn't been confirmed yet (unlike
Claude Code's, which is documented in the binary). This script:
  1. Always dumps the raw stdin payload to a debug file so the schema can be
     inspected after the hook fires once for real.
  2. Best-effort searches the payload for anything that looks like a usage /
     rate-limit block and writes it to the shared cache if found.
  3. Prints a harmless passthrough status line either way.

Once you've seen a real payload in the debug file, update `find_rate_limits`
below to map the real field names, the same way claude-statusline-hook.py
does for Claude Code's confirmed `rate_limits.five_hour` / `seven_day` shape.
"""
import json
import os
import sys
import time

CACHE_DIR = os.path.expanduser("~/Library/Application Support/AIUsageWidget")
CACHE_FILE = os.path.join(CACHE_DIR, "usage.json")
DEBUG_FILE = os.path.join(CACHE_DIR, "antigravity-statusline-debug.json")

USAGE_KEY_HINTS = ("usage", "quota", "rate_limit", "ratelimit", "limit")
PERCENT_KEY_HINTS = ("used_percent", "usedpercent", "percent_used", "utilization")
RESET_KEY_HINTS = ("resets_at", "reset_at", "resetsat", "reset_time")


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


def find_first(obj, hints):
    """Recursively search a JSON tree for the first key containing any hint substring."""
    if isinstance(obj, dict):
        for key, value in obj.items():
            if any(hint in key.lower() for hint in hints) and not isinstance(value, (dict, list)):
                return value
        for value in obj.values():
            found = find_first(value, hints)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = find_first(item, hints)
            if found is not None:
                return found
    return None


def find_rate_limits(payload):
    percent = find_first(payload, PERCENT_KEY_HINTS)
    resets_at = find_first(payload, RESET_KEY_HINTS)
    if percent is None:
        return None
    return {"used_percent": percent, "resets_at": resets_at}


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        payload = {}

    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(DEBUG_FILE, "w") as f:
        json.dump(payload, f, indent=2)

    cache = load_cache()
    guessed = find_rate_limits(payload)
    cache["antigravity"] = {
        "five_hour": guessed,
        "weekly": None,
        "updated_at": int(time.time()),
        "error": None if guessed else "schema unconfirmed - see antigravity-statusline-debug.json",
    }
    save_cache(cache)

    print("Antigravity")


if __name__ == "__main__":
    main()
