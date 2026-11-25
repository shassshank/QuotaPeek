#!/bin/bash
# Snapshot QuotaPeek's resource cost: resident memory and lifetime CPU of the
# app (and the legacy daemon, if still running), plus the average wall time of
# one Claude statusline hook run. Read-only; safe to run any time.
set -u

APP_SUPPORT="$HOME/Library/Application Support/QuotaPeek"
HOOK="${HOOK:-$APP_SUPPORT/bin/claude-statusline-hook.py}"
PYTHON="${PYTHON:-/opt/homebrew/bin/python3}"
RUNS="${RUNS:-10}"

echo "== processes (rss MB, cpu time, uptime)"
for name in quotapeekd QuotaPeek.app/Contents/MacOS/QuotaPeek; do
    ps -axo rss=,time=,etime=,comm= | grep -E "/$name\$" |
        awk -v n="$(basename "$name")" '{printf "%-12s %6.1f MB  cpu %s  up %s\n", n, $1/1024, $2, $3}'
done

if [ -f "$HOOK" ]; then
    payload='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$PWD"'"},"rate_limits":{}}'
    start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    for _ in $(seq "$RUNS"); do
        printf '%s' "$payload" | "$PYTHON" "$HOOK" >/dev/null 2>&1
    done
    end=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    echo "== hook: $(basename "$HOOK")"
    awk -v s="$start" -v e="$end" -v r="$RUNS" 'BEGIN{printf "avg %.1f ms over %d runs\n", (e-s)*1000/r, r}'
fi
