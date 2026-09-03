#!/usr/bin/env python3
"""
Claude Code statusLine hook.

Claude Code invokes this with a JSON payload on stdin every time it renders
the status line during an active session, and expects a short line of text
on stdout to display. This does two things at once:
  1. Renders a real status line (dir, git branch, model, session cost).
  2. Piggybacks on the same invocation to write any rate_limits block out to
     the shared usage cache the AIUsageWidget menu bar app reads.

Everything below is defensive on purpose: if this script ever throws before
printing something, Claude Code's status line goes blank for the user (this
happened once already - an earlier version assumed `model` was always a
nested dict, which crashed when a captured real payload didn't match). A
debug dump of the raw payload is also written on every invocation so the
real field shapes can be inspected and this can be tightened further.
"""
import json
import os
import subprocess
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
        return value or None
    if isinstance(value, dict):
        for key in ("display_name", "name", "id", "value"):
            if isinstance(value.get(key), str) and value[key]:
                return value[key]
    return None


def find_cwd(payload):
    for key in ("cwd",):
        if isinstance(payload.get(key), str) and payload[key]:
            return payload[key]
    workspace = payload.get("workspace")
    if isinstance(workspace, dict):
        for key in ("current_dir", "cwd", "project_dir"):
            if isinstance(workspace.get(key), str) and workspace[key]:
                return workspace[key]
    elif isinstance(workspace, str) and workspace:
        return workspace
    return None


def git_branch(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    branch = result.stdout.strip()
    return branch or None


def session_cost(payload):
    cost = payload.get("cost")
    if isinstance(cost, dict):
        usd = cost.get("total_cost_usd")
        if isinstance(usd, (int, float)):
            return f"${usd:.2f}"
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


def usage_summary(rate_limits, cached_claude):
    five_hour = window(rate_limits.get("five_hour")) if rate_limits else None
    weekly = window(rate_limits.get("seven_day")) if rate_limits else None
    if not five_hour and cached_claude:
        five_hour = cached_claude.get("five_hour")
    if not weekly and cached_claude:
        weekly = cached_claude.get("weekly")

    parts = []
    if five_hour and five_hour.get("used_percent") is not None:
        parts.append(f"5h {int(five_hour['used_percent'])}%")
    if weekly and weekly.get("used_percent") is not None:
        parts.append(f"wk {int(weekly['used_percent'])}%")
    return " ".join(parts) if parts else None


def build_status_line(payload, rate_limits, cached_claude):
    cwd = find_cwd(payload)
    dirname = os.path.basename(cwd) if cwd else None
    branch = git_branch(cwd)
    model = as_str(payload.get("model"))
    cost = session_cost(payload)
    usage = usage_summary(rate_limits, cached_claude)

    segments = []
    if dirname:
        segments.append(f"{dirname}" + (f" ({branch})" if branch else ""))
    if model:
        segments.append(model)
    if cost:
        segments.append(cost)
    if usage:
        segments.append(usage)

    return " | ".join(segments) if segments else "Claude Code"


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
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        rate_limits = {}

    try:
        cache["claude"] = {
            "five_hour": window(rate_limits.get("five_hour")) or (cache.get("claude") or {}).get("five_hour"),
            "weekly": window(rate_limits.get("seven_day")) or (cache.get("claude") or {}).get("weekly"),
            "updated_at": int(time.time()),
        }
        save_cache(cache)
    except Exception:
        pass

    try:
        line = build_status_line(payload, rate_limits, cache.get("claude"))
    except Exception:
        line = "Claude Code"
    print(line or "Claude Code")


if __name__ == "__main__":
    main()
