#!/usr/bin/env python3
"""Claude Code statusline hook: prints the statusline, then hands the
payload's rate limits to QuotaPeek (fire-and-forget)."""
import os
import sys

import quotapeek_hook as qp


def location_segment(payload, cwd):
    dirname = os.path.basename(cwd) if cwd else None
    if not qp.is_git_repo(cwd):
        return f"dir: {dirname}" if dirname else None
    workspace = payload.get("workspace")
    repo_name = None
    if isinstance(workspace, dict):
        repo = workspace.get("repo")
        if isinstance(repo, dict) and isinstance(repo.get("name"), str):
            repo_name = repo["name"]
    return f"git: {repo_name or qp.git_remote_repo_name(cwd) or dirname}" if dirname or repo_name else None


def window(entry):
    if not isinstance(entry, dict):
        return None
    pct = entry.get("used_percentage", entry.get("used_percent"))
    if not isinstance(pct, (int, float)):
        return None
    return {"used_percent": pct, "resets_at": entry.get("resets_at")}


def context_percent(payload):
    ctx = payload.get("context_window")
    pct = ctx.get("used_percentage") if isinstance(ctx, dict) else None
    return int(pct) if isinstance(pct, (int, float)) else None


def build_status_line(payload):
    rate_limits = payload.get("rate_limits") if isinstance(payload.get("rate_limits"), dict) else {}
    cwd = qp.find_cwd(payload, allow_string_workspace=True)
    segments = [p for p in [qp.as_str(payload.get("model")), location_segment(payload, cwd)] if p]
    for entry in (window(rate_limits.get("five_hour")), window(rate_limits.get("seven_day"))):
        line = qp.usage_line(entry)
        if line:
            segments.append(line)
    ctx_pct = context_percent(payload)
    if ctx_pct is not None:
        segments.append(f"ctx {ctx_pct}%")
    return " | ".join(segments) if segments else "Claude Code"


def main():
    payload = qp.read_payload(sys.stdin)
    try:
        line = build_status_line(payload) or "Claude Code"
    except Exception as exc:
        qp.log_error("claude build_status_line", exc)
        line = "Claude Code"
    extras = qp.other_agent_segments(exclude_provider="claude")
    if extras:
        line = f"{line} | {' | '.join(extras)}"
    print(line, flush=True)
    rate_limits = payload.get("rate_limits")
    if isinstance(rate_limits, dict) and rate_limits:
        qp.send_reading("claude", {
            "config_dir": os.environ.get("CLAUDE_CONFIG_DIR", ""),
            "rate_limits": rate_limits,
        })


if __name__ == "__main__":
    main()
