#!/bin/bash
# run-with-log-rotation.sh — Log rotation wrapper for LaunchAgent processes.
#
# Usage:  run-with-log-rotation.sh <logfile> <binary> [args...]
#
# Checks the target log file size before exec'ing the real binary.
# If the log exceeds MAX_LOG_BYTES (default 5 MB), rotates the current
# log to <logfile>.1 (one prior copy kept) and truncates the current file.
#
# This script is meant to be the ProgramArguments[0] in a LaunchAgent plist,
# with the log path and real binary passed as subsequent arguments.
set -euo pipefail

MAX_LOG_BYTES="${AIW_MAX_LOG_BYTES:-5242880}"   # 5 MB default

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <logfile> <binary> [args...]" >&2
    exit 1
fi

LOGFILE="$1"; shift
BINARY="$1"; shift

# Rotate if the log exists and exceeds the threshold.
if [[ -f "$LOGFILE" ]]; then
    size=$(stat -f%z "$LOGFILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$MAX_LOG_BYTES" ]]; then
        # Keep exactly one previous generation.
        cp -f "$LOGFILE" "${LOGFILE}.1"
        : > "$LOGFILE"               # truncate
    fi
fi

# exec replaces this process with the real binary so launchd sees the
# correct PID for KeepAlive / process-lifecycle management.
exec "$BINARY" "$@"
