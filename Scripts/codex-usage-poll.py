#!/usr/bin/env python3
"""
Fetches Codex's live rate-limit data via the app-server JSON-RPC protocol,
run fresh over stdio (`codex app-server`, default `--listen stdio://`) rather
than the persistent daemon's control socket (which speaks a different,
admin-only protocol and isn't meant for this).

Confirmed live: sending newline-delimited JSON-RPC `initialize` then
`account/rateLimits/read` to a freshly spawned `codex app-server` process
returns immediately, at no token/usage cost:

  {"id":2,"result":{"rateLimits":{
    "primary":   {"usedPercent":4, "windowDurationMins":300,   "resetsAt":...},
    "secondary": {"usedPercent":3, "windowDurationMins":10080, "resetsAt":...},
    "planType":"plus"
  }}}

windowDurationMins 300 = 5 hour window, 10080 = 7 day (weekly) window.

This replaces an earlier version of this script that polled via
`codex exec --json`, which turned out not to carry rate-limit data at all
(that only ever came from a since-removed feature, `responses_websockets`).
"""
import json
import os
import subprocess
import threading
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
    return {"used_percent": entry.get("usedPercent"), "resets_at": entry.get("resetsAt")}


def fetch_rate_limits(codex_bin, timeout=10):
    proc = subprocess.Popen(
        [codex_bin, "app-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    responses = {}
    lock = threading.Lock()

    def reader():
        buf = b""
        while True:
            chunk = proc.stdout.read(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "id" in msg:
                    with lock:
                        responses[msg["id"]] = msg

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    def send(obj):
        proc.stdin.write((json.dumps(obj) + "\n").encode())
        proc.stdin.flush()

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "aiusagewidget", "version": "0.1.0"}}})
        send({"id": 2, "method": "account/rateLimits/read", "params": None})

        deadline = time.time() + timeout
        while time.time() < deadline:
            with lock:
                if 2 in responses:
                    break
            time.sleep(0.1)

        with lock:
            result = responses.get(2)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    if not result or "result" not in result:
        return None, (result or {}).get("error")
    return result["result"].get("rateLimits"), None


def main():
    codex_bin = os.path.expanduser("~/.local/bin/codex")
    if not os.path.exists(codex_bin):
        codex_bin = "codex"

    cache = load_cache()
    try:
        rate_limits, err = fetch_rate_limits(codex_bin)
    except (OSError, subprocess.SubprocessError) as e:
        rate_limits, err = None, str(e)

    if rate_limits is None:
        cache["codex"] = {"error": err or "no response from codex app-server", "updated_at": int(time.time())}
    else:
        cache["codex"] = {
            "five_hour": window(rate_limits.get("primary")),
            "weekly": window(rate_limits.get("secondary")),
            "plan_type": rate_limits.get("planType"),
            "updated_at": int(time.time()),
        }
    save_cache(cache)


if __name__ == "__main__":
    main()
