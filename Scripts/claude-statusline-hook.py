#!/usr/bin/env python3
import json
import math
import os
import subprocess
import sys
import time
import urllib.request

INGEST_URL = "http://127.0.0.1:47831/ingest/claude"
STATUS_URL = "http://127.0.0.1:47831/status"


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


def find_git_dir(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None
    cur = os.path.abspath(cwd)
    while True:
        candidate = os.path.join(cur, ".git")
        if os.path.isdir(candidate):
            return candidate
        if os.path.isfile(candidate):
            try:
                with open(candidate, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read().strip()
                if content.startswith("gitdir:"):
                    gitdir = content[len("gitdir:"):].strip()
                    if not os.path.isabs(gitdir):
                        gitdir = os.path.abspath(os.path.join(cur, gitdir))
                    if os.path.isdir(gitdir):
                        return gitdir
            except Exception:
                pass
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def git_head_branch(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        git_dir = find_git_dir(cwd)
        if git_dir:
            head_path = os.path.join(git_dir, "HEAD")
            if os.path.isfile(head_path):
                with open(head_path, "r", encoding="utf-8", errors="replace") as f:
                    line = f.read().strip()
                if line.startswith("ref: refs/heads/"):
                    return line[len("ref: refs/heads/"):].strip()
                return line[:7]
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            branch = result.stdout.strip()
            return branch if branch else None
    except Exception:
        pass
    return None


def is_git_repo(cwd):
    if not cwd or not os.path.isdir(cwd):
        return False
    if find_git_dir(cwd) is not None:
        return True
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
        git_dir = find_git_dir(cwd)
        if git_dir:
            commondir_file = os.path.join(git_dir, "commondir")
            common_git_dir = git_dir
            if os.path.isfile(commondir_file):
                try:
                    with open(commondir_file, "r", encoding="utf-8", errors="replace") as f:
                        rel = f.read().strip()
                    common_git_dir = os.path.normpath(os.path.join(git_dir, rel))
                except Exception:
                    pass
            config_path = os.path.join(common_git_dir, "config")
            if os.path.isfile(config_path):
                in_origin = False
                with open(config_path, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("["):
                            in_origin = (line.lower() == '[remote "origin"]')
                        elif in_origin and (line.startswith("url =") or line.startswith("url=")):
                            url = line.split("=", 1)[1].strip()
                            if url:
                                name = url.rstrip("/").rsplit("/", 1)[-1]
                                return name[: -len(".git")] if name.endswith(".git") else name
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        url = result.stdout.strip()
        if url:
            name = url.rstrip("/").rsplit("/", 1)[-1]
            return name[: -len(".git")] if name.endswith(".git") else name
    except Exception:
        pass
    return None


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


def extra_status_segments():
    # Keep all daemon-dependent work isolated from Claude's own rendering.
    try:
        token_path = os.path.expanduser("~/Library/Application Support/AIUsageWidget/auth-token")
        with open(token_path) as token_file:
            token = token_file.read().strip()
        req = urllib.request.Request(STATUS_URL, headers={"X-Auth-Token": token})
        with urllib.request.urlopen(req, timeout=0.2) as response:
            status = json.load(response)
        if not isinstance(status, dict):
            return []
        if status.get("statusline_show_other_agents") is False:
            return []
        if not isinstance(status.get("accounts"), list):
            return []
        selected = {}
        for account in status["accounts"]:
            if not isinstance(account, dict):
                continue
            provider = account.get("provider")
            if provider not in ("codex", "antigravity"):
                continue
            if account.get("state") in ("unknown", "error"):
                continue
            data = account.get("data")
            if not isinstance(data, dict):
                continue
            # Both Codex and Antigravity (Gemini group) expose a genuine 5h bucket.
            pct_field, reset_field = "used_percent_5h", "resets_at_5h"
            pct = data.get(pct_field)
            if not isinstance(pct, (int, float)) or isinstance(pct, bool):
                continue
            if not math.isfinite(pct) or not 0 <= pct <= 100:
                continue
            # One compact number per provider, from its first usable account.
            if provider in selected:
                continue
            line = f"{pct:.0f}% {progress_bar(pct)}"
            reset = format_reset(data.get(reset_field))
            if reset:
                line = f"{line} {reset}"
            if provider == "antigravity":
                # Main figure above is the Gemini group's 5h window. The Claude/GPT
                # ("third party") models share one combined quota pool per window,
                # not separate per-model numbers - show both of its windows here.
                cg_5h = data.get("used_percent_5h_third_party")
                cg_weekly = data.get("used_percent_weekly_third_party")
                has_5h = isinstance(cg_5h, (int, float)) and not isinstance(cg_5h, bool) and math.isfinite(cg_5h) and 0 <= cg_5h <= 100
                has_weekly = isinstance(cg_weekly, (int, float)) and not isinstance(cg_weekly, bool) and math.isfinite(cg_weekly) and 0 <= cg_weekly <= 100
                breakdown = []
                if has_5h:
                    breakdown.append(f"5h:{cg_5h:.0f}%")
                if has_weekly:
                    breakdown.append(f"wk:{cg_weekly:.0f}%")
                if breakdown:
                    line = f"{line} (C/G {' '.join(breakdown)})"
            selected[provider] = line
        return [f"{label} {selected[provider]}" for provider, label in
                (("codex", "Codex"), ("antigravity", "Antigravity")) if provider in selected]
    except Exception:
        pass
    return []


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
    extras = extra_status_segments()
    if extras:
        print(" | ".join(extras))
    post_ingest(raw)


if __name__ == "__main__":
    main()
