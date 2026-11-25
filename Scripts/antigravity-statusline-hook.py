#!/usr/bin/env python3
"""Antigravity (agy) statusline hook: prints the statusline, then hands the
payload's quota to QuotaPeek (fire-and-forget)."""
import os
import sys
import time

import quotapeek_hook as qp


def location_segment(cwd, vcs):
    dirname = os.path.basename(cwd) if cwd else None
    is_git = isinstance(vcs, dict) and vcs.get("type") == "git"
    if not is_git:
        return f"dir: {dirname}" if dirname else None
    return f"git: {qp.git_remote_repo_name(cwd) or dirname}" if dirname else None


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


def build_status_line(payload):
    five_hour, weekly = split_quota(payload)
    segments = [p for p in [qp.as_str(payload.get("model")),
                            location_segment(qp.find_cwd(payload), payload.get("vcs"))] if p]
    for entry in (five_hour, weekly):
        line = qp.usage_line(entry)
        if line:
            segments.append(line)
    return " | ".join(segments) if segments else "Antigravity"


def main():
    payload = qp.read_payload(sys.stdin)
    try:
        line = build_status_line(payload) or "Antigravity"
    except Exception as exc:
        qp.log_error("antigravity build_status_line", exc)
        line = "Antigravity"
    print(line, flush=True)
    quota = payload.get("quota")
    if isinstance(quota, dict) and quota:
        # agy has no profile/config-dir concept, so no account hint is sent;
        # the app matches it to the single Antigravity account.
        qp.send_reading("antigravity", {"quota": quota})


if __name__ == "__main__":
    main()
