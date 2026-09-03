#!/usr/bin/env python3
"""
Codex CLI has no free push-based usage hook (unlike Claude Code / Antigravity's
statusLine), so this runs a minimal `codex exec` turn periodically (via
LaunchAgent, see LaunchAgents/com.aiusagewidget.codexpoll.plist) purely to
capture the `codex.rate_limits` event that rides along on every response,
confirmed live from ~/.codex/logs_2.sqlite:

  {"type":"codex.rate_limits","plan_type":"plus","rate_limits":{
    "primary":   {"used_percent":4,  "window_minutes":300,   "reset_at":...},
    "secondary": {"used_percent":48, "window_minutes":10080, "reset_at":...}
  }}

window_minutes 300 = 5 hour window, 10080 = 7 day (weekly) window.

Note this itself costs a small amount of the very usage it measures - keep
the poll interval long (LaunchAgent default: 15 min).
"""
import json
import os
import subprocess
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
    return {"used_percent": entry.get("used_percent"), "resets_at": entry.get("reset_at")}


def main():
    codex_bin = os.path.expanduser("~/.local/bin/codex")
    if not os.path.exists(codex_bin):
        codex_bin = "codex"

    try:
        result = subprocess.run(
            [codex_bin, "exec", "--json", "ok"],
            capture_output=True, text=True, timeout=120,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        cache = load_cache()
        cache["codex"] = {"error": str(e), "updated_at": int(time.time())}
        save_cache(cache)
        return

    rate_limits = None
    plan_type = None
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "codex.rate_limits":
            rate_limits = event.get("rate_limits") or {}
            plan_type = event.get("plan_type")
            break

    cache = load_cache()
    if rate_limits is None:
        cache["codex"] = {"error": "no rate_limits event in codex output", "updated_at": int(time.time())}
    else:
        cache["codex"] = {
            "five_hour": window(rate_limits.get("primary")),
            "weekly": window(rate_limits.get("secondary")),
            "plan_type": plan_type,
            "updated_at": int(time.time()),
        }
    save_cache(cache)


if __name__ == "__main__":
    main()
