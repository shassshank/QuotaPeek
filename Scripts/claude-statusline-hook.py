#!/usr/bin/env python3
"""
Claude Code statusLine hook.

Claude Code invokes this with JSON session data on stdin every time it
renders the status line (documented: https://code.claude.com/docs/en/statusline),
and displays whatever this prints to stdout - it fully replaces the built-in
status line row (though not the footer badges). This does two things:
  1. Renders a multi-line status line: model + current git repo, a 5-hour
     usage bar with reset time, a weekly usage bar with reset time, and
     context window %.
  2. Piggybacks on the same invocation to write the rate_limits block out to
     the shared usage cache the AIUsageWidget menu bar app reads.

Everything below is defensive on purpose: if this script ever throws before
printing something, Claude Code's status line goes blank for the user (this
happened once already, from a bad field-name assumption). A debug dump of
the raw payload is also written on every invocation.

Confirmed field names (official docs, not guessed):
  model.display_name
  workspace.current_dir / cwd
  cost.total_cost_usd
  context_window.used_percentage
  rate_limits.five_hour.used_percentage, .resets_at
  rate_limits.seven_day.used_percentage, .resets_at
  rate_limits.* is absent until the session's first API response, and absent
  entirely for API-key (non-subscription) auth.
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
    if isinstance(payload.get("cwd"), str) and payload["cwd"]:
        return payload["cwd"]
    workspace = payload.get("workspace")
    if isinstance(workspace, dict):
        for key in ("current_dir", "project_dir"):
            if isinstance(workspace.get(key), str) and workspace[key]:
                return workspace[key]
    elif isinstance(workspace, str) and workspace:
        return workspace
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


def repo_name(payload, cwd):
    workspace = payload.get("workspace")
    if isinstance(workspace, dict):
        repo = workspace.get("repo")
        if isinstance(repo, dict) and isinstance(repo.get("name"), str) and repo["name"]:
            return repo["name"]
    remote_name = git_remote_repo_name(cwd)
    if remote_name:
        return remote_name
    return os.path.basename(cwd) if cwd else None


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
        return f"{days}d {hours}h"
    if hours > 0:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def context_percent(payload):
    ctx = payload.get("context_window")
    if isinstance(ctx, dict):
        pct = ctx.get("used_percentage")
        if isinstance(pct, (int, float)):
            return int(pct)
    return None


def window(entry):
    if not isinstance(entry, dict):
        return None
    used_percent = entry.get("used_percentage")
    if used_percent is None:
        used_percent = entry.get("used_percent")  # tolerate older/alt naming
    return {"used_percent": used_percent, "resets_at": entry.get("resets_at")}


def usage_line(label, entry):
    if not entry or entry.get("used_percent") is None:
        return None
    pct = entry["used_percent"]
    line = f"{label} {progress_bar(pct)} {pct:.0f}%"
    reset = format_reset(entry.get("resets_at"))
    if reset:
        line += f" resets {reset}"
    return line


def build_status_line(payload, rate_limits, cached_claude):
    cwd = find_cwd(payload)
    model = as_str(payload.get("model"))
    repo = repo_name(payload, cwd)
    ctx_pct = context_percent(payload)

    five_hour = window(rate_limits.get("five_hour")) if rate_limits else None
    weekly = window(rate_limits.get("seven_day")) if rate_limits else None
    if not five_hour and cached_claude:
        five_hour = cached_claude.get("five_hour")
    if not weekly and cached_claude:
        weekly = cached_claude.get("weekly")

    header_parts = [p for p in [model, repo] if p]
    lines = [" | ".join(header_parts)] if header_parts else []

    five_hour_line = usage_line("5h", five_hour)
    weekly_line = usage_line("wk", weekly)
    if five_hour_line:
        lines.append(five_hour_line)
    if weekly_line:
        lines.append(weekly_line)

    if ctx_pct is not None:
        lines.append(f"ctx {ctx_pct}%")

    return "\n".join(lines) if lines else "Claude Code"


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
        prev_claude = cache.get("claude") or {}
        cache["claude"] = {
            "five_hour": window(rate_limits.get("five_hour")) or prev_claude.get("five_hour"),
            "weekly": window(rate_limits.get("seven_day")) or prev_claude.get("weekly"),
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
