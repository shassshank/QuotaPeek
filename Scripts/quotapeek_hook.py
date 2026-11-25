"""Shared helpers for the QuotaPeek statusline hooks.

Installed next to the hooks in ~/Library/Application Support/QuotaPeek/bin;
Python puts the running script's directory on sys.path, so the hooks simply
`import quotapeek_hook`.

Contract with the app (no daemon, no HTTP):
- Readings go to the app as one small JSON datagram over a Unix socket.
  Sending is non-blocking and fire-and-forget: if QuotaPeek is closed or busy
  the reading is dropped and the agent is never slowed down.
- The "other agents" segment comes from snapshot.json, which the app writes
  when numbers change and deletes when it quits.
- Unexpected exceptions append one line to hook-errors.log (capped); the
  normal path never touches the disk.
"""
import json
import os
import socket
import time

# QUOTAPEEK_SUPPORT_DIR exists for tests; the app always uses the default.
SUPPORT_DIR = os.environ.get("QUOTAPEEK_SUPPORT_DIR") or os.path.expanduser("~/Library/Application Support/QuotaPeek")
SNAPSHOT_PATH = os.path.join(SUPPORT_DIR, "snapshot.json")
HOOK_ERROR_LOG = os.path.join(SUPPORT_DIR, "hook-errors.log")
HOOK_ERROR_LOG_MAX_BYTES = 64 * 1024


def socket_path():
    # sun_path holds at most 103 bytes; mirror the app's fallback rule.
    preferred = os.path.join(SUPPORT_DIR, "qp.sock")
    if len(preferred.encode("utf-8")) <= 103:
        return preferred
    return f"/tmp/quotapeek-{os.getuid()}.sock"


def log_error(where, exc):
    """Append one line for an unexpected failure. Never raises."""
    try:
        try:
            if os.path.getsize(HOOK_ERROR_LOG) >= HOOK_ERROR_LOG_MAX_BYTES:
                os.replace(HOOK_ERROR_LOG, HOOK_ERROR_LOG + ".1")
        except OSError:
            pass
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        with open(HOOK_ERROR_LOG, "a", encoding="utf-8") as f:
            f.write(f"{stamp} {where}: {type(exc).__name__}: {exc}\n")
    except Exception:
        pass


def send_reading(provider, fields):
    """Send one reading to the app. `fields` holds the raw sub-objects the app
    parses (e.g. rate_limits, quota, config_dir). Never raises, never blocks."""
    try:
        message = {"v": 1, "provider": provider, "observed_at_ms": int(time.time() * 1000)}
        message.update(fields)
        data = json.dumps(message, separators=(",", ":")).encode("utf-8")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            sock.setblocking(False)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 64 * 1024)
            except OSError:
                pass
            sock.sendto(data, socket_path())
        finally:
            sock.close()
    except (FileNotFoundError, ConnectionRefusedError, BlockingIOError):
        pass  # QuotaPeek not running, or busy: dropping the reading is fine.
    except Exception as exc:
        log_error(f"send_reading({provider})", exc)


def read_snapshot():
    """The app's latest numbers, or None when QuotaPeek is not running."""
    try:
        with open(SNAPSHOT_PATH, encoding="utf-8") as f:
            snapshot = json.load(f)
    except FileNotFoundError:
        return None
    except Exception as exc:
        log_error("read_snapshot", exc)
        return None
    if not isinstance(snapshot, dict) or snapshot.get("v") != 1:
        return None
    pid = snapshot.get("pid")
    if isinstance(pid, int):
        try:
            os.kill(pid, 0)  # Snapshot left behind by a crashed app: ignore it.
        except ProcessLookupError:
            return None
        except PermissionError:
            pass
    return snapshot


def valid_percent(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and value == value and 0 <= value <= 100)


def other_agent_segments(exclude_provider):
    """Compact "Codex 12% ▓░░ 3h" segments for every other provider, from the
    first usable account of each."""
    try:
        snapshot = read_snapshot()
        if not snapshot or snapshot.get("statusline_show_other_agents") is False:
            return []
        accounts = snapshot.get("accounts")
        if not isinstance(accounts, list):
            return []
        selected = {}
        for account in accounts:
            if not isinstance(account, dict):
                continue
            provider = account.get("provider")
            if provider == exclude_provider or provider in selected:
                continue
            if account.get("state") in ("unknown", "error"):
                continue
            data = account.get("data")
            if not isinstance(data, dict) or not valid_percent(data.get("used_percent_5h")):
                continue
            pct = data["used_percent_5h"]
            line = f"{pct:.0f}% {progress_bar(pct)}"
            reset = format_reset(data.get("resets_at_5h"))
            if reset:
                line = f"{line} {reset}"
            if provider == "antigravity":
                # The main figure is the Gemini group's 5h window; Claude/GPT
                # ("third party") models share one pool - show both its windows.
                breakdown = []
                if valid_percent(data.get("used_percent_5h_third_party")):
                    breakdown.append(f"5h:{data['used_percent_5h_third_party']:.0f}%")
                if valid_percent(data.get("used_percent_weekly_third_party")):
                    breakdown.append(f"wk:{data['used_percent_weekly_third_party']:.0f}%")
                if breakdown:
                    line = f"{line} (C/G {' '.join(breakdown)})"
            selected[provider] = line
        labels = (("claude", "Claude"), ("codex", "Codex"), ("antigravity", "Antigravity"))
        return [f"{label} {selected[p]}" for p, label in labels if p in selected]
    except Exception as exc:
        log_error("other_agent_segments", exc)
        return []


# --- statusline formatting shared by both hooks ---------------------------

def as_str(value):
    if isinstance(value, str):
        return value or None
    if isinstance(value, dict):
        for key in ("display_name", "name", "id", "value"):
            if isinstance(value.get(key), str) and value[key]:
                return value[key]
    return None


def find_cwd(payload, allow_string_workspace=False):
    if isinstance(payload.get("cwd"), str) and payload["cwd"]:
        return payload["cwd"]
    workspace = payload.get("workspace")
    if isinstance(workspace, dict):
        for key in ("current_dir", "project_dir"):
            if isinstance(workspace.get(key), str) and workspace[key]:
                return workspace[key]
    elif allow_string_workspace and isinstance(workspace, str) and workspace:
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


def _git(cwd, *args):
    # Imported lazily: subprocess is only needed when the fast file-based
    # lookups fail, so the common path skips its import cost.
    import subprocess
    try:
        result = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=2)
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception:
        return None


def is_git_repo(cwd):
    if not cwd or not os.path.isdir(cwd):
        return False
    if find_git_dir(cwd) is not None:
        return True
    return _git(cwd, "rev-parse", "--is-inside-work-tree") == "true"


def _repo_name_from_url(url):
    name = url.rstrip("/").rsplit("/", 1)[-1]
    return name[: -len(".git")] if name.endswith(".git") else name


def git_remote_repo_name(cwd):
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        git_dir = find_git_dir(cwd)
        if git_dir:
            common_git_dir = git_dir
            commondir_file = os.path.join(git_dir, "commondir")
            if os.path.isfile(commondir_file):
                try:
                    with open(commondir_file, "r", encoding="utf-8", errors="replace") as f:
                        common_git_dir = os.path.normpath(os.path.join(git_dir, f.read().strip()))
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
                                return _repo_name_from_url(url)
    except Exception:
        pass
    url = _git(cwd, "remote", "get-url", "origin")
    return _repo_name_from_url(url) if url else None


def progress_bar(pct, width=10):
    pct = max(0, min(100, pct))
    filled = round(pct * width / 100)
    return "▓" * filled + "░" * (width - filled)


def format_reset(resets_at):
    if not isinstance(resets_at, (int, float)) or isinstance(resets_at, bool):
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


def usage_line(entry):
    if not entry:
        return None
    pct = entry["used_percent"]
    line = f"{pct:.0f}% {progress_bar(pct)}"
    reset = format_reset(entry.get("resets_at"))
    return f"{line} {reset}" if reset else line


def read_payload(stdin):
    raw = stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
        return payload if isinstance(payload, dict) else {}
    except Exception:
        return {}
