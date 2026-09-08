#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import urllib.request

INGEST_URL = "http://127.0.0.1:47831/ingest/claude"


def as_str(value):
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


def is_git_repo(cwd):
    if not cwd or not os.path.isdir(cwd):
        return False
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        return result.returncode == 0 and result.stdout.strip() == "true"
    except Exception:
        return False


def git_remote_repo_name(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except Exception:
        return None
    url = result.stdout.strip()
    if not url:
        return None
    name = url.rstrip("/").rsplit("/", 1)[-1]
    return name[: -len(".git")] if name.endswith(".git") else name


def location_segment(payload, cwd):
    dirname = os.path.basename(cwd) if cwd else None
    if not is_git_repo(cwd):
        return f"dir: {dirname}" if dirname else None
    workspace = payload.get("workspace")
    repo_name = None
    if isinstance(workspace, dict):
        repo = workspace.get("repo")
        if isinstance(repo, dict) and isinstance(repo.get("name"), str):
            repo_name = repo["name"]
    return f"git: {repo_name or git_remote_repo_name(cwd) or dirname}" if dirname or repo_name else None


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


def window(entry):
    if not isinstance(entry, dict):
        return None
    pct = entry.get("used_percentage", entry.get("used_percent"))
    if not isinstance(pct, (int, float)):
        return None
    return {"used_percent": pct, "resets_at": entry.get("resets_at")}


def usage_line(entry):
    if not entry:
        return None
    pct = entry["used_percent"]
    line = f"{pct:.0f}% {progress_bar(pct)}"
    reset = format_reset(entry.get("resets_at"))
    return f"{line} {reset}" if reset else line


def context_percent(payload):
    ctx = payload.get("context_window")
    pct = ctx.get("used_percentage") if isinstance(ctx, dict) else None
    return int(pct) if isinstance(pct, (int, float)) else None


def build_status_line(payload):
    rate_limits = payload.get("rate_limits") if isinstance(payload.get("rate_limits"), dict) else {}
    segments = [p for p in [as_str(payload.get("model")), location_segment(payload, find_cwd(payload))] if p]
    for entry in (window(rate_limits.get("five_hour")), window(rate_limits.get("seven_day"))):
        line = usage_line(entry)
        if line:
            segments.append(line)
    ctx_pct = context_percent(payload)
    if ctx_pct is not None:
        segments.append(f"ctx {ctx_pct}%")
    return " | ".join(segments) if segments else "Claude Code"


def post_ingest(raw):
    try:
        payload = json.loads(raw)
        payload["configDir"] = os.environ.get("CLAUDE_CONFIG_DIR", "")
        raw = json.dumps(payload)
        token_path = os.path.expanduser("~/Library/Application Support/AIUsageWidget/auth-token")
        with open(token_path) as token_file:
            token = token_file.read().strip()
        req = urllib.request.Request(
            INGEST_URL,
            data=raw.encode("utf-8", errors="replace"),
            headers={"Content-Type": "application/json", "X-Auth-Token": token},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=1).close()
    except Exception:
        pass


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
    except Exception:
        payload = {}
    try:
        line = build_status_line(payload)
    except Exception:
        line = "Claude Code"
    print(line or "Claude Code")
    post_ingest(raw)


if __name__ == "__main__":
    main()
