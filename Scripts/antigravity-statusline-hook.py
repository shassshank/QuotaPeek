#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import urllib.request

INGEST_URL = "http://127.0.0.1:47831/ingest/antigravity"


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
    return None


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


def location_segment(cwd, vcs):
    dirname = os.path.basename(cwd) if cwd else None
    is_git = isinstance(vcs, dict) and vcs.get("type") == "git"
    if not is_git:
        return f"dir: {dirname}" if dirname else None
    return f"git: {git_remote_repo_name(cwd) or dirname}" if dirname else None


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


def window_from_quota_entry(entry):
    if not isinstance(entry, dict):
        return None
    remaining = entry.get("remaining_fraction")
    if not isinstance(remaining, (int, float)):
        return None
    used_percent = round((1 - remaining) * 100, 1)
    reset_in_seconds = entry.get("reset_in_seconds")
    resets_at = time.time() + reset_in_seconds if isinstance(reset_in_seconds, (int, float)) else None
    return {"used_percent": used_percent, "resets_at": resets_at}


def split_quota(payload):
    five_hour = None
    weekly = None
    quota = payload.get("quota")
    if isinstance(quota, dict):
        for key, entry in quota.items():
            parsed = window_from_quota_entry(entry)
            if parsed is None:
                continue
            label = key.lower()
            if "week" in label or "7d" in label:
                weekly = weekly or parsed
            elif "5h" in label or "5 hour" in label:
                five_hour = five_hour or parsed
    return five_hour, weekly


def usage_line(entry):
    if not entry:
        return None
    pct = entry["used_percent"]
    line = f"{pct:.0f}% {progress_bar(pct)}"
    reset = format_reset(entry.get("resets_at"))
    return f"{line} {reset}" if reset else line


def build_status_line(payload):
    five_hour, weekly = split_quota(payload)
    segments = [p for p in [as_str(payload.get("model")), location_segment(find_cwd(payload), payload.get("vcs"))] if p]
    for entry in (five_hour, weekly):
        line = usage_line(entry)
        if line:
            segments.append(line)
    return " | ".join(segments) if segments else "Antigravity"


def post_ingest(raw):
    try:
        payload = json.loads(raw)
        # Antigravity (the agy CLI) has no profile/config-dir concept to report,
        # unlike Claude/Codex. Leave accountId empty so the daemon matches this
        # push to its default Antigravity account.
        payload["accountId"] = ""
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
        line = "Antigravity"
    print(line or "Antigravity")
    post_ingest(raw)


if __name__ == "__main__":
    main()
