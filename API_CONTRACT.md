# AIUsageWidget daemon API contract (v1)

This is the single source of truth for the boundary between the Go daemon
(`Backend/`) and the Swift menu bar shell (`Sources/AIUsageWidget/`). Both
sides build against this document in parallel — do not invent fields that
aren't here without updating this file first.

## Transport

The daemon listens on `127.0.0.1:47831` only (never `0.0.0.0`, never a unix
socket — TCP loopback keeps the Swift client simple with `URLSession`).
Plain HTTP is fine; nothing here ever leaves localhost. All bodies are JSON.

## Types

```jsonc
// One provider's current usage snapshot.
Provider {
  "id": "claude" | "codex" | "antigravity",
  "routes_enabled": ["keychain", "injection"],   // enabled subset; [] (never null) when disabled
  "active_route": "keychain" | "injection" | "none", // which one supplied `data` right now
  "data": {
    "used_percent_5h": 42.1,        // 0-100, null if this provider has no 5h window
    "resets_at_5h": 1767561600,     // unix seconds, null if unknown
    "used_percent_weekly": 18.0,    // 0-100, null if this provider has no weekly window
    "resets_at_weekly": 1768080000, // unix seconds, null if unknown
    "context_window_used_percent": 12.4 // 0-100, null if not applicable/unknown
  } | null,                          // null if no data has ever arrived from any route
  "as_of": 1767550000,               // unix seconds `data` was captured, null if data is null
  "last_error": {
    "route": "keychain" | "injection",
    "message": "human-readable, never contains raw tokens/secrets",
    "at": 1767549000
  } | null
}

Config {
  "claude":      { "routes_enabled": ["keychain", "injection"], "keychain_poll_interval_sec": 60 },
  "codex":       { "routes_enabled": ["injection"],              "keychain_poll_interval_sec": 120 },
  "antigravity": { "routes_enabled": ["keychain"],               "keychain_poll_interval_sec": 60 }
}
// Fresh injection quota data is preferred, independent of routes_enabled order.
// Both routes are stale after max(2 * keychain_poll_interval_sec, 600) seconds.
// If neither is fresh, show the newest enabled quota sample. Context-only
// payloads never replace quota samples. Headline errors belong only to the
// active route (or preferred enabled route when there is no sample).
// Codex has no keychain route today (no confirmed OAuth quota API) — its "injection"
// route is the free `codex app-server` JSON-RPC poll (no hook involved, just named the
// same for UI/config consistency). routes_enabled for codex should only ever contain
// "injection" until/unless a keychain-based Codex collector is added later.

ErrorEntry {
  "provider": "claude" | "codex" | "antigravity",
  "route": "keychain" | "injection",
  "message": "string, secrets redacted",
  "at": 1767549000
}
```

## Endpoints

### `GET /status`
Returns `{ "providers": [Provider, Provider, Provider] }`, always all three,
always in the order claude, codex, antigravity.

### `POST /refresh`
Triggers an immediate live re-fetch for every provider whose `routes_enabled`
includes `keychain` (injection-route providers can't be force-refreshed —
they only update when the hook fires). Blocks until those fetches finish
(bounded by a ~10s internal timeout per provider) and returns the same shape
as `GET /status`. A provider whose only route is injection is returned
unchanged.

### `GET /config`
Returns the current `Config`.

### `PUT /config`
Body: full or partial `Config` (only include the providers you're changing).
Persists to `~/Library/Application Support/AIUsageWidget/config.json` and
takes effect immediately (reschedules keychain poll timers). Returns the
resulting full `Config`.

### `GET /errors?limit=50`
Returns `{ "errors": [ErrorEntry, ...] }`, most recent first, capped at
`limit` (default 50, max 200). This is a ring buffer in memory, not
persisted across daemon restarts.

### `POST /ingest/claude`
### `POST /ingest/antigravity`
Called by the corresponding statusLine hook script on every invocation, body
is that provider's *raw* statusLine JSON payload verbatim (schemas below).
The daemon parses it, and if parsing succeeds, updates that provider's
`data`/`as_of` with `active_route = "injection"` (subject to the fallback
preference rule above once keychain data also exists). If parsing fails, the
daemon records an `ErrorEntry` with `route: "injection"` and does **not**
overwrite existing data. Always returns `200 {"ok": true}` — the hook script
never blocks on the response and ignores it either way; this endpoint exists
for the daemon's benefit, not the hook's.

Raw payload schemas (for the daemon's parser, not re-exposed to Swift):

```jsonc
// Claude Code statusLine payload (subset actually used)
{
  "rate_limits": {
    // Both windows accept used_percent as an alias for used_percentage.
    "five_hour": { "used_percentage": 42.1, "resets_at": 1767561600 },
    "seven_day": { "used_percentage": 18.0, "resets_at": 1768080000 }
  },
  "context_window": { "used_percentage": 12.4 }
  // rate_limits absent entirely until the session's first API response,
  // and absent for API-key (non-subscription) auth — treat as "no data yet",
  // not an error.
}

// Antigravity statusLine payload (subset actually used)
{
  "quota": {
    "<arbitrary-window-key>": {
      "remaining_fraction": 0.9378,      // usage = (1 - remaining_fraction) * 100
      "reset_in_seconds": 3600          // seconds from daemon receipt; converted to unix seconds
      // Legacy reset_time (RFC3339 or unix seconds) is also accepted.
      // reset_in_seconds takes precedence when both fields are present.
    }
    // only one window ("gemini-weekly") is confirmed to exist; map it to
    // used_percent_weekly. If a key containing "hour" ever appears, map it
    // to used_percent_5h instead of pattern-matching loosely — see the old
    // audit finding about over-eager "hour" substring matching.
  },
  "context_window": { "used_percentage": 12.4 }
}
```

## Error message redaction rule (applies everywhere, including `ErrorEntry.message`)

Never include: OAuth access/refresh tokens, API keys, full response bodies
from a provider (truncate to the first 200 chars and strip anything matching
common token/secret key names first), or full request headers. A message
should look like `"antigravity: token refresh failed (401)"`, not a token
dump.
