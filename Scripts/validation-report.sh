#!/bin/bash
# Side-by-side validation report for the daemon-free path (temporary: removed
# together with the daemon). Read-only.
#   Scripts/validation-report.sh [hours]   (default: last 24 hours)
set -u
S="$HOME/Library/Application Support/QuotaPeek"
HOURS="${1:-24}"
SINCE=$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%S)

echo "== QuotaPeek validation report (last ${HOURS}h, since ${SINCE}Z)"
echo
echo "-- processes"
ps -axo rss=,etime=,comm= | grep -E "/(quotapeekd|QuotaPeek)$" |
    awk '{n=$0; sub(".*/","",n); printf "  %-11s %6.1f MB  up %s\n", n, $1/1024, $2}'

echo
echo "-- errors.log by kind"
if [ -f "$S/errors.log" ]; then
    awk -v s="$SINCE" '$1 >= s' "$S/errors.log" |
        sed -E 's/^[^ ]+ //; s/(compare [a-z]+\/[^:]+): .*/\1/; s/[0-9]+ bytes/N bytes/' |
        sort | uniq -c | sort -rn | sed 's/^/  /'
    echo "  (latest compare notes)"
    awk -v s="$SINCE" '$1 >= s && /compare/' "$S/errors.log" | tail -5 | sed 's/^/    /'
else
    echo "  (none)"
fi

echo
echo "-- hook-errors.log"
if [ -f "$S/hook-errors.log" ]; then tail -5 "$S/hook-errors.log" | sed 's/^/  /'; else echo "  (none)"; fi

echo
echo "-- now: app (merged) vs daemon"
TOKEN=$(cat "$S/auth-token" 2>/dev/null)
DAEMON=$(curl -s -m 3 -H "X-Auth-Token: $TOKEN" http://127.0.0.1:47831/status 2>/dev/null)
/usr/bin/python3 - "$S/snapshot.json" "$DAEMON" <<'PY'
import json, sys, time
snap_path, daemon_raw = sys.argv[1], sys.argv[2]
def rows(accounts):
    out = {}
    for a in accounts or []:
        d = a.get("data") or {}
        age = int(time.time() - a["as_of"]) if a.get("as_of") else None
        out[a["provider"]] = (d.get("used_percent_5h"), d.get("used_percent_weekly"), a.get("state"), age)
    return out
try:
    app = rows(json.load(open(snap_path)).get("accounts"))
except Exception:
    app = {}
try:
    daemon = rows(json.loads(daemon_raw).get("accounts"))
except Exception:
    daemon = {}
fmt = lambda r: "-" if not r else f"5h {r[0]}% wk {r[1]}% {r[2]} ({r[3]}s old)"
for p in ("claude", "codex", "antigravity"):
    print(f"  {p:<12} app:    {fmt(app.get(p))}")
    print(f"  {'':<12} daemon: {fmt(daemon.get(p))}")
PY
