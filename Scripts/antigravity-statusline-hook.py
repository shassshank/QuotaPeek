#!/usr/bin/env python3
"""
Antigravity CLI statusLine hook.

Confirmed schema (antigravity.google/docs/cli/statusline/), a different
shape from Claude Code's:

  {
    "cwd": "...",
    "model": {"id": "...", "display_name": "..."},
    "workspace": {"current_dir": "...", "project_dir": "..."},
    "context_window": {"used_percentage": 14.24, ...},
    "vcs": {"type": "git", "branch": "main", "dirty": false},
    "quota": {
      "gemini-weekly": {
        "remaining_fraction": 0.9378,
        "reset_time": "2026-07-06T07:50:32Z",
        "reset_in_seconds": 560580
      }
    }
  }

`quota` is a dict keyed by an arbitrary plan/window name (only one window,
"gemini-weekly", was documented - there may be no separate 5-hour-style
window at all for this product). Renders the same layout as
claude-statusline-hook.py: model | git:/dir: <name> | <window segments> |
ctx %. Piggybacks on the same invocation to write usage into the shared
cache the AIUsageWidget menu bar app reads.

Everything below is defensive: if this throws before printing, Antigravity's
status line goes blank. A debug dump of the raw payload is written every
invocation in case a future payload doesn't match this schema.
"""
import json
import os
import subprocess
import sys
import time

CACHE_DIR = os.path.expanduser("~/Library/Application Support/AIUsageWidget")
CACHE_FILE = os.path.join(CACHE_DIR, "usage.json")
DEBUG_FILE = os.path.join(CACHE_DIR, "antigravity-statusline-debug.json")


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
    if value is None:
        return None
    if isinstance(value, str):
        return value or None
    if isinstance(value, dict):
        for key in ("display_name", "name", "id", "value"):
            if isinstance(value.get(key), str) and value[key]:
                return value[key]
    return None


def find_cwd(payload):
    if isinstance(payload.get("cwd"), str) and payload["cwd"]:
        return payload["cwd"]
    workspace = payload.get("workspace")
    if isinstance(workspace, dict):
        for key in ("current_dir", "project_dir"):
            if isinstance(workspace.get(key), str) and workspace[key]:
                return workspace[key]
    return None


def git_remote_repo_name(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    url = result.stdout.strip()
    if not url:
        return None
    name = url.rstrip("/").rsplit("/", 1)[-1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    return name or None


def location_segment(cwd, vcs):
    dirname = os.path.basename(cwd) if cwd else None
    is_git = isinstance(vcs, dict) and vcs.get("type") == "git"
    if not is_git:
        return f"dir: {dirname}" if dirname else None
    name = git_remote_repo_name(cwd) or dirname
    return f"git: {name}" if name else None


def progress_bar(pct, width=10):
    pct = max(0, min(100, pct))
    filled = round(pct * width / 100)
    return "▓" * filled + "░" * (width - filled)


def format_reset(resets_at):
    if not isinstance(resets_at, (int, float)):
        return None
    delta = resets_at - time.time()
    if delta <= 0:
        return "now"
    total_minutes = int(delta // 60)
    days, rem_minutes = divmod(total_minutes, 24 * 60)
    hours, minutes = divmod(rem_minutes, 60)
    if days > 0:
        return f"{days}d{hours}h"
    if hours > 0:
        return f"{hours}h{minutes}m"
    return f"{minutes}m"


def context_percent(payload):
    ctx = payload.get("context_window")
    if isinstance(ctx, dict):
        pct = ctx.get("used_percentage")
        if isinstance(pct, (int, float)):
            return int(pct)
    return None


def window_from_quota_entry(entry):
    if not isinstance(entry, dict):
        return None
    remaining = entry.get("remaining_fraction")
    used_percent = None
    if isinstance(remaining, (int, float)):
        used_percent = round((1 - remaining) * 100, 1)
    resets_at = entry.get("reset_in_seconds")
    if isinstance(resets_at, (int, float)):
        resets_at = time.time() + resets_at
    else:
        resets_at = None
    if used_percent is None:
        return None
    return {"used_percent": used_percent, "resets_at": resets_at}


def split_quota(payload):
    """quota is a dict keyed by an arbitrary plan/window name. Best-effort
    bucket keys mentioning 'week' as the weekly window, anything else as the
    shorter window (labeled five_hour to match the shared cache schema, even
    though this product may not actually have a 5-hour-specific window)."""
    quota = payload.get("quota")
    five_hour = None
    weekly = None
    if isinstance(quota, dict):
        for key, entry in quota.items():
            parsed = window_from_quota_entry(entry)
            if parsed is None:
                continue
            if "week" in key.lower():
                weekly = weekly or parsed
            else:
                five_hour = five_hour or parsed
    return five_hour, weekly


def usage_line(entry):
    if not entry or entry.get("used_percent") is None:
        return None
    pct = entry["used_percent"]
    line = f"{pct:.0f}% {progress_bar(pct)}"
    reset = format_reset(entry.get("resets_at"))
    if reset:
        line += f" {reset}"
    return line


def build_status_line(payload, five_hour, weekly, ctx_pct, cwd):
    model = as_str(payload.get("model"))
    location = location_segment(cwd, payload.get("vcs"))

    segments = [p for p in [model, location] if p]
    five_hour_seg = usage_line(five_hour)
    weekly_seg = usage_line(weekly)
    if five_hour_seg:
        segments.append(five_hour_seg)
    if weekly_seg:
        segments.append(weekly_seg)
    if ctx_pct is not None:
        segments.append(f"ctx {ctx_pct}%")

    return " | ".join(segments) if segments else "Antigravity"


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

    cache = load_cache()
    five_hour, weekly = split_quota(payload)

    try:
        prev = cache.get("antigravity") or {}
        cache["antigravity"] = {
            "five_hour": five_hour or prev.get("five_hour"),
            "weekly": weekly or prev.get("weekly"),
            "updated_at": int(time.time()),
        }
        save_cache(cache)
    except Exception:
        pass

    try:
        cwd = find_cwd(payload)
        ctx_pct = context_percent(payload)
        cached = cache.get("antigravity") or {}
        line = build_status_line(
            payload,
            five_hour or cached.get("five_hour"),
            weekly or cached.get("weekly"),
            ctx_pct,
            cwd,
        )
    except Exception:
        line = "Antigravity"
    print(line or "Antigravity")


if __name__ == "__main__":
    main()
