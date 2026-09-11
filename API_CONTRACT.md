# AIUsageWidget daemon API contract (v1)

This is the single source of truth for the boundary between the Go daemon
(`Backend/`) and the Swift menu bar shell (`Sources/AIUsageWidget/`). Both
sides build against this document in parallel — do not invent fields that
aren't here without updating this file first.

## Transport

The daemon listens on `127.0.0.1:47831` only (never `0.0.0.0`, never a unix
socket — TCP loopback keeps the Swift client simple with `URLSession`).
Plain HTTP is fine; nothing here ever leaves localhost. All bodies are JSON.

Every endpoint, including `GET /status` and `GET /accounts`, requires
`X-Auth-Token`. Missing or incorrect
credentials return HTTP 401 without performing the operation. At startup the
daemon generates a random 256-bit token and atomically writes
`~/Library/Application Support/AIUsageWidget/auth-token` with mode 0600. The
Swift client and installed injection hooks read this file for each request,
so restarting the daemon does not require restarting clients. Re-run the installer
to upgrade existing installed hooks to authenticated requests. This is a per-user
secret: processes running as the same user can also read it; it is not an app identity check.
Responses are encoded before headers are committed; encoding failures are logged
and return HTTP 500 with `{"error":"response encoding failed"}`.

## Types

```jsonc
// One provider's current usage snapshot.
Provider {
  "id": "claude" | "codex" | "antigravity",
  "credentialSource": "keychain" | "oauth" | "api-key" | "env" | "unknown",
  "effectiveAccount": "account identifier or email" | null,
  "lastSuccessAt": 1767550000 | null, // int64 Unix seconds
  "lastFailureAt": 1767549000 | null, // int64 Unix seconds
  "lastError": "most recent failed poll message, secrets redacted" | null,
  "routes_enabled": ["keychain", "injection"],   // enabled subset; [] (never null) when disabled
  "active_route": "keychain" | "injection" | "none", // which one supplied `data` right now
  "data": {
    "used_percent_5h": 42.1,        // 0-100, null if this provider has no 5h window
    "resets_at_5h": 1767561600,     // unix seconds, null if unknown
    "used_percent_weekly": 18.0,    // 0-100, null if this provider has no weekly window (primary/Gemini quota for Antigravity)
    "resets_at_weekly": 1768080000, // unix seconds, null if unknown
    "used_percent_5h_third_party": 0.0, // 0-100, null if not applicable (Antigravity Claude/GPT 3P 5h quota)
    "resets_at_5h_third_party": 1767561600, // unix seconds, null if unknown
    "used_percent_weekly_third_party": 6.0, // 0-100, null if not applicable (Antigravity Claude/GPT 3P weekly quota)
    "resets_at_weekly_third_party": 1768400000, // unix seconds, null if unknown
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
  "statusline_show_other_agents": true, // boolean; default true
  "staleAfterSeconds": 600,          // positive int64 seconds; default 600
  "collectionPaused": false,        // boolean; default false
  "claude_polling_mode": "inference", // "inference" (default) or "disabled"
  "claude":      { "routes_enabled": ["keychain", "injection"], "keychain_poll_interval_sec": 60 },
  "codex":       { "routes_enabled": ["injection"],              "keychain_poll_interval_sec": 120 },
  "antigravity": { "routes_enabled": ["keychain"],               "keychain_poll_interval_sec": 60 }
}
// Fresh injection quota data is preferred, independent of routes_enabled order.
// Both routes are stale after max(2 * keychain_poll_interval_sec, staleAfterSeconds) seconds.
// If neither is fresh, show the newest enabled quota sample. Context-only
// payloads never replace quota samples. Headline errors belong only to the
// active route (or preferred enabled route when there is no sample).
// After 10 minutes with no authenticated GET /status or /accounts request,
// scheduled polling backs off to a 15-minute cadence regardless of the
// configured interval, and returns to normal cadence immediately on the
// next such request. A client that polls /status on its normal cadence
// (the app and both statusLine hooks do) never triggers this backoff.
// Codex injection uses the free `codex app-server` JSON-RPC poll.
// Codex keychain uses stored OAuth credentials to fetch ChatGPT quota.
// Each provider config also accepts optional notify_threshold_percent: integer
// 1-100. Absent/null disables notifications; disabled values are omitted in output.
// The Swift app sends a local notification when either 5h or weekly used percent
// crosses the threshold. The daemon only persists and returns this setting.

ErrorEntry {
  "provider": "claude" | "codex" | "antigravity",
  "route": "keychain" | "injection",
  "message": "string, secrets redacted",
  "at": 1767549000
}
```

## Endpoints

### `GET /status`
Requires `X-Auth-Token`.
Returns `{ "statusline_show_other_agents": true, "accounts": [Account, ...], "providers": [Provider, Provider, Provider] }`,
always all three, always in the order claude, codex, antigravity.

Polls are single-flight per provider/route across scheduled polls, refreshes,
and diagnostics. An overlapping refresh skips the busy route and returns current
stored data; an overlapping diagnostic returns `ok:false` with a busy message.
`as_of` reflects request start, not response completion. Internally comparisons
retain subsecond precision so late older samples cannot replace newer samples.

### `POST /refresh`
Triggers an immediate live re-fetch for every enabled synchronous route, including
both Codex routes. Claude/Antigravity injection routes only update on pushes.
Blocks until fetches finish (bounded by a ~10s internal timeout per provider)
and returns the same shape as `GET /status`.

### `POST /test-route`
Body: `{"provider":"claude"|"codex"|"antigravity","route":"keychain"|"injection"}`.
Tests exactly the requested route, even if its route is disabled, with an 8-second timeout.
Claude inference remains prohibited when `claude_polling_mode` is `disabled`.
Keychain routes use the corresponding collector; Codex injection uses app-server
RPC. Successful fetches save fresh quota via the normal sample store. Failed
probes update the new poll-health fields but do not modify samples, headline
`last_error`, or the `/errors` ring and cannot clobber displayed data.

Claude/Antigravity injection is push-only: no fetch is attempted. `ok` reports
whether that provider's injection quota sample is at most
`max(2 * keychain_poll_interval_sec, staleAfterSeconds)` seconds old, independently of enabled
or displayed routes. The message explains that the daemon cannot trigger a push
and whether a recent quota push was received.

Diagnostic success and failure both return HTTP 200:
```json
{"ok":true,"provider":"claude","route":"keychain"}
```
```json
{"ok":false,"provider":"claude","route":"keychain","message":"Claude credentials expired, run claude CLI to refresh"}
```
`message` is optional human-readable detail, with secrets redacted. Malformed
JSON, missing fields, or unknown provider/route values return HTTP 400.

### `GET /config`
Returns the current `Config`.

### `PUT /config`
Body: full or partial `Config` (only include the providers you're changing).
Persists to `~/Library/Application Support/AIUsageWidget/config.json` and
takes effect immediately (reschedules keychain poll timers). Returns the
resulting full `Config`. Each included provider replaces its full config, so include
`routes_enabled` and `keychain_poll_interval_sec` along with
`notify_threshold_percent` (for example, 80). Omit the threshold or send null to
disable notifications for that provider. Omitted providers remain unchanged.
Thresholds outside 1-100, or non-integer values, return HTTP 400.

Top-level `claude_polling_mode` accepts `"inference"` (default for existing installs)
or `"disabled"`; omission on PUT preserves the current setting. Inference mode
sends a real Messages API completion (`"hi"`, `max_tokens:1`) to read quota headers.
At the default 60-second interval this is approximately 1,440 calls/day, consumes
quota, and may incur charges according to the provider account. Refresh and route
tests also make real calls. Disabled mode prevents these Claude calls, including
manual refresh/tests; enable Claude injection for passive updates. Existing samples
remain visible with their original age. Suggested Settings text: “Allow real Claude
inference requests to check quota (about 1,440/day at 60 seconds; consumes quota and
may incur charges).”

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
overwrite existing data. Authenticated requests return `200 {"ok": true}` — the hook script
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


## Credential persistence and lifecycle

Rotated Codex and Antigravity OAuth credentials are stored in private files
`oauth-codex.json` and `oauth-antigravity.json` beside `config.json`, using the
repo's existing file-based credential approach (also used by Codex auth.json).
Writes use unique 0600 temporary files, fsync, and atomic rename. Refreshes are
serialized per provider; persistence failures are surfaced and retried. A fingerprint
of the source CLI credentials prevents a saved rotation from overriding a new CLI
login. These files are never returned through the config API.

Config saves serialize the complete read/merge/write/publish/reschedule transaction
with a server mutex. Each disk save uses its own temporary file.

The daemon is independent of the menu-bar app: quitting the app or disabling app
launch-at-login leaves collection running. The daemon's RunAtLoad and KeepAlive
are intentional. `./install.sh --app-login-off` uses `launchctl unload -w` for the
app LaunchAgent; `--app-login-on` uses `load -w`. These persist across login/reboot.
The Settings toggle must use the same `-w` operations. Explicitly stop the daemon
with `./install.sh --daemon-stop` (unload -w); restart/re-enable it using
`--daemon-start` (load -w). A normal reinstall reloads agents without overriding
persisted disabled preferences.

Hook installation preserves unrelated settings, skips equivalent statusLine
configurations, and backs up a replaced configuration as a complete settings file
with a `.bak.<timestamp>` suffix before atomically publishing the new settings.

## P2 API additions (exact UI contract)

### Provider health fields

Every Provider in `GET /status` and `POST /refresh` includes these additional fields:

```jsonc
{
  "credentialSource": "keychain" | "oauth" | "api-key" | "env" | "unknown",
  "effectiveAccount": string | null,
  "lastSuccessAt": int64 | null,
  "lastFailureAt": int64 | null,
  "lastError": string | null
}
```

`credentialSource` is a string describing the most recently discovered credential
source, initially `"unknown"`. Current collectors report `"keychain"` for Claude,
Antigravity, and Codex Keychain credentials, or `"oauth"` for Codex auth.json.
Codex app-server and passive injection do not expose their credential source;
without a credential-backed discovery it stays `"unknown"`. `"api-key"` and `"env"`
are reserved source values. `effectiveAccount` is the discovered Codex account ID
or Antigravity credential email when available; otherwise null. Status reads never
perform credential discovery or network calls.

`lastSuccessAt` and `lastFailureAt` are nullable int64 Unix seconds measured at
completion of synchronous scheduled polls, refreshes, and route tests across both
routes. Empty quota results count as failed polls. Skipped polls, push-only tests,
and passive ingest do not update these fields. `lastError` is the most recent
failed poll's message, redacted using `redact.go`; it remains available after a
subsequent success. All three fields are initially null, live in memory, and reset
on daemon restart. They are independent of the existing route-specific
`last_error` object and the bounded `/errors` ring, which remain unchanged.

### Config fields and pause/resume

`GET /config` and successful `PUT /config` return the full existing Config plus:

```jsonc
{
  "staleAfterSeconds": int64,
  "collectionPaused": boolean
}
```

Defaults are `"staleAfterSeconds":600` and `"collectionPaused":false`, including
when loading older config files that omit these fields. PUT accepts either field
independently; omission or null preserves its current value. Both settings persist
across daemon restarts. `staleAfterSeconds` must be a positive int64 integer in PUT;
zero, negative, fractional, or wrong-type values return HTTP 400. Each provider's
route freshness cutoff is `max(staleAfterSeconds, 2 * keychain_poll_interval_sec)`
seconds, inclusive at the boundary, for both routes. The existing newest-stale
sample fallback remains in effect when no enabled route is fresh.

Pause request (requires `X-Auth-Token`):

```http
PUT /config
```
```json
{"collectionPaused":true}
```

Resume request (requires `X-Auth-Token`):

```http
PUT /config
```
```json
{"collectionPaused":false}
```

Freshness update request (requires `X-Auth-Token`):

```http
PUT /config
```
```json
{"staleAfterSeconds":900}
```

Each successful request returns HTTP 200 with the full Config, including the two
fields above and all existing provider settings. While paused, scheduled polling,
manual refresh, and synchronous route tests make no network, credential, or
app-server calls. Pause waits for already-running polls to finish before returning;
existing per-poll timeouts still apply. Resume immediately schedules enabled
providers again. `POST /refresh` returns stored status while paused.
`POST /test-route` returns HTTP 200 with:

```json
{"ok":false,"provider":"claude","route":"keychain","message":"Collection is paused."}
```

The response echoes the requested provider and route. Passive ingest remains
accepted while paused; stored samples remain visible with their original age.
The daemon process remains running. No `/control/pause` or `/control/resume`
endpoints are added.

### Credential reset

```http
POST /providers/{name}/reset-credentials
X-Auth-Token: <token>
```

`name` is `claude`, `codex`, or `antigravity`. No request body is required; a supplied
body is ignored. The endpoint clears only that provider's daemon credential and
discovery caches, including its daemon-owned persisted OAuth rotation file.
It does not delete or modify OS Keychain items, CLI auth.json, or other user
credentials. The provider's `credentialSource` becomes `"unknown"` and
`effectiveAccount` becomes null until the next credential-backed poll. Samples
and poll-health history remain intact. It does not trigger a poll; the next
scheduled poll, refresh, or route test re-discovers credentials. Reset is allowed
while paused and is idempotent.

HTTP 200 success:

```json
{"ok":true,"provider":"codex"}
```

HTTP 404 unknown provider:

```json
{"ok":false,"provider":"unknown-name","message":"Unknown provider."}
```

HTTP 409 if either provider route is polling or another reset is running:

```json
{"ok":false,"provider":"codex","message":"Provider poll or credential reset already in flight."}
```

HTTP 500 if the daemon OAuth cache cannot be removed:

```json
{"ok":false,"provider":"codex","message":"could not remove daemon OAuth cache"}
```

HTTP 500 if the collector is unavailable:

```json
{"ok":false,"provider":"codex","message":"Collector unavailable."}
```

Every reset response above echoes the requested name in `provider`; `ok` is boolean
and failure `message` is a redacted string. Missing or invalid authentication
returns HTTP 401 before any operation, using the existing response:

```json
{"error":"unauthorized"}
```

## P3 persisted samples and history

Every Provider in `GET /status` and `POST /refresh` includes
`"restoredFromDisk": boolean` (always present, never null). It is true exactly
when the currently displayed `data` came from disk on this daemon startup.
Show this as “Last known — stale since restart”, even if `as_of` is recent.
It is false when data is null or the displayed route has received a new accepted
sample this run. Updating a different route does not clear the stored route's
marker. Restored samples never count as fresh for route preference or push-only
`POST /test-route` diagnostics; they remain eligible for newest-stale fallback.
`as_of` retains the original capture timestamp. Poll-health fields still reset.

Latest samples and history for all provider/route pairs (including disabled
routes) are saved to `samples.json` alongside `config.json`. Each accepted sample
synchronously writes a versioned snapshot using a private 0600 temporary file,
fsync, and atomic rename. Missing caches start empty; invalid/unreadable caches
are logged and ignored without preventing startup. Write failures are logged;
live data remains available and the next accepted update retries the full save.

### `GET /history?provider=claude&route=keychain`

Requires `X-Auth-Token`. Both query parameters are required:

- `provider`: string enum `claude`, `codex`, `antigravity`.
- `route`: string enum `keychain`, `injection`.

HTTP 200, `Content-Type: application/json`:

```json
{"points":[{"at":1767550000,"usedPercent":42.1}]}
```

`points` is an array (empty `[]`, never null, when no retained history exists).
Each point has `at` (int64 Unix seconds, sample request start) and `usedPercent`
(finite JSON number in 0–100). Points are oldest first; multiple updates in one
second can have the same `at`. Values use `used_percent_5h` when available,
otherwise `used_percent_weekly`; reset-only samples produce no point.
Each accepted quota sample with a percentage records a point, even if its value
is unchanged. Rejected older, invalid, and context-only updates record nothing.
At most 200 points per provider/route are retained, and points older than 24 hours
are excluded (the exact 24-hour boundary is included). History survives restarts,
with the same bounds applied on load and query. Reading a disabled route is
allowed; this endpoint never triggers collection. Missing/invalid provider or
route returns HTTP 400 with plain-text `invalid or missing provider/route`.
Missing/invalid authentication returns HTTP 401 as for other protected endpoints.

## P5 Multi-account model and trust-state (supersedes single-Provider status shape)

This section is the authoritative spec for the account model. Backend and Swift
sides build against it in parallel; treat every other endpoint above that
mentions "provider" in `GET /status`, `POST /refresh`, `POST /test-route`,
`GET /history`, and credential reset as **replaced** by the `Account`-keyed
versions below. The raw ingest payload schemas (`POST /ingest/claude`,
`POST /ingest/antigravity`) are unchanged, except each carries an added
`accountId` field described under Ingest below.

### Why: the trust-state field

Reviews found that stale or missing data can render with full confidence (a
missing observation showing as `0%`, stale data keeping a green/live badge).
The fix is a single server-computed `state` enum per account — the daemon
computes it once, the UI only switches on it, and never re-derives freshness
from `as_of`/`restoredFromDisk` itself.

```jsonc
// state derivation, in order:
// - "unknown": data is null, OR age > hardExpirySeconds (age too large to trust as a number)
// - "restored": restoredFromDisk == true (this daemon run hasn't received a fresh sample for this route yet)
// - "fresh":    age <= max(staleAfterSeconds, 2 * keychain_poll_interval_sec)   [existing freshness cutoff]
// - "stale":    freshnessCutoff < age <= hardExpirySeconds
// - "error":    lastError is set AND data is null (no sample to fall back on at all)
//
// hardExpirySeconds = 4 * max(staleAfterSeconds, 2 * keychain_poll_interval_sec)
// When state == "unknown" due to age, the UI must not display `data` as a number —
// render "No recent data" instead, even though the daemon still retains the sample internally.
```

### Account object

```jsonc
Account {
  "id": "acct_ab12cd34",              // stable, generated at creation; never reused after delete
  "provider": "claude" | "codex" | "antigravity",
  "label": "Work",                    // user-editable; auto-created accounts default to "Default"
  "credentialLocation": {
    "kind": "config_dir" | "daemon_token",
    "configDir": "/Users/x/.claude-work" | null   // required when kind=="config_dir"; null for daemon_token
  },
  // Per-account mirror of today's per-provider fields:
  "credentialSource": "keychain" | "oauth" | "api-key" | "env" | "unknown", // discovered kind, distinct from credentialLocation above
  "effectiveAccount": "account identifier or email" | null,
  "lastSuccessAt": int64 | null,
  "lastFailureAt": int64 | null,
  "lastError": "string, secrets redacted" | null,
  "routes_enabled": ["keychain", "injection"],
  "active_route": "keychain" | "injection" | "none",
  "data": { "used_percent_5h": ..., "resets_at_5h": ..., "used_percent_weekly": ..., "resets_at_weekly": ..., "context_window_used_percent": ... } | null,
  "as_of": int64 | null,
  "last_error": { "route": "keychain"|"injection", "message": "...", "at": int64 } | null,
  "restoredFromDisk": boolean,
  "state": "unknown" | "fresh" | "stale" | "restored" | "error"
}
```

`credentialLocation.kind`:
- `"config_dir"` — used for Claude and Codex accounts. The daemon sets
  `CLAUDE_CONFIG_DIR` (Claude) or `CODEX_HOME` (Codex) to `configDir` for every
  collector call and credential lookup for that account. Claude Keychain
  service name for a non-default configDir is
  `"Claude Code-credentials-" + hex(sha256(NFC(configDir)))[:8]`, account `$USER`
  (matches the CLI's own scheme — default/legacy configDir `~/.claude` keeps
  using the unsuffixed `"Claude Code-credentials"` service for backward compat).
  Codex Keychain account is `"cli|" + hex(sha256(canonical(configDir)))[:16]`
  under service `"Codex Auth"` (reuses the existing `codexKeyringAccount` helper
  in `codex_chatgpt.go` — just stop hardcoding `~/.codex` as its input).
- `"daemon_token"` — used for Antigravity accounts (the `agy` CLI itself has no
  profile concept, so a second account's OAuth token is captured once and owned
  entirely by the daemon, not read from the CLI's Keychain item). The daemon
  stores it in its own per-account oauth cache file (extend the existing
  `oauth-antigravity.json` pattern from "Credential persistence and lifecycle"
  above to `oauth-antigravity-<accountId>.json`) and refreshes/polls it directly
  against the same Cloud Code endpoints the default account already uses.

### Migration for existing installs

On first startup after upgrade, for each provider that has any `routes_enabled`
or existing samples under the old single-Provider model, the daemon
auto-creates exactly one Account with `label:"Default"`:
- Claude → `credentialLocation: {kind:"config_dir", configDir: "~/.claude"}` (or
  `$CLAUDE_CONFIG_DIR` if that env var was set for the daemon process).
- Codex → `credentialLocation: {kind:"config_dir", configDir: "~/.codex"}` (or
  `$CODEX_HOME`).
- Antigravity → `credentialLocation: {kind:"daemon_token"}`, and its existing
  Keychain-sourced credential continues to be read as today until the user
  explicitly adds a second Antigravity account (at which point that second
  account's token comes from the new capture flow, while the first/"Default"
  Antigravity account keeps reading the CLI's Keychain item exactly as before —
  it is not migrated into a daemon-owned token file).
Existing `samples.json`/`config.json` provider-keyed data is migrated to be
keyed by this new Default account's generated id; the id is deterministic
(`"acct_" + provider + "_default"`) so migration is idempotent across restarts.

### Endpoints (Account-keyed)

`GET /accounts` — `{"accounts": [{id, provider, label, credentialLocation}]}`,
config only, no live data, requires `X-Auth-Token` (as does `GET /status`).

`POST /accounts` (requires `X-Auth-Token`) — body:
```json
{"provider":"claude","label":"Work","credentialLocation":{"kind":"config_dir","configDir":"/Users/x/.claude-work"}}
```
or, for Antigravity's daemon_token kind:
```json
{"provider":"antigravity","label":"Personal Gmail","credentialLocation":{"kind":"daemon_token"},"oauthBootstrap":{"refreshToken":"...","email":"..."}}
```
Returns HTTP 201 with the created `Account` (data null, state "unknown", until
the first poll). `configDir` must be an absolute path; a `config_dir` account
pointing at a path that has no valid credentials yet is allowed (state stays
"unknown"/"error" until the user logs in with that config dir). Duplicate
`configDir` for the same provider returns HTTP 409.

`PATCH /accounts/{id}` (requires `X-Auth-Token`) — body `{"label":"New label"}`,
rename only; `credentialLocation` is immutable after creation (delete and
recreate to change it). Returns the updated `Account`.

`DELETE /accounts/{id}` (requires `X-Auth-Token`) — removes the account, its
samples/history, and any daemon-owned oauth cache file for it. Returns
`{"ok":true}`. Never deletes OS Keychain items or CLI credential files. 404 if
the id doesn't exist.

`GET /status` and `POST /refresh` — now return `{"accounts": [Account, ...]}`,
ordered by provider (claude, codex, antigravity) then by account creation
order within each provider. `POST /refresh` accepts an optional body
`{"accountId":"acct_..."}` to refresh just one account; omitted body refreshes
all.

`POST /test-route` — body adds a required `"accountId"` field alongside the
existing `provider`/`route` (provider is still included for clarity/validation
but `accountId` is authoritative; a mismatch returns HTTP 400).

`POST /accounts/{id}/reset-credentials` (requires `X-Auth-Token`) — replaces
`POST /providers/{name}/reset-credentials`; same semantics (clears daemon
credential/discovery cache and daemon-owned oauth file for that account only),
scoped to one account instead of a whole provider.

`GET /history?accountId=acct_...&route=keychain` — replaces the
`provider=`+`route=` query form; same response shape
(`{"points":[{"at":...,"usedPercent":...}]}`).

### Ingest (unchanged transport, added routing)

`POST /ingest/claude` and `POST /ingest/antigravity` payloads are unchanged.
Routing an inbound push to the right account: since the statusLine hook has no
concept of "which account," the daemon routes an inbound push to whichever
`config_dir`-kind account's configDir matches the `CLAUDE_CONFIG_DIR` (or
`CODEX_HOME`, n/a for ingest today) the hook process itself was invoked under —
the hook script must forward its own `CLAUDE_CONFIG_DIR` env value (or empty
string for the default) as a new `"configDir"` top-level field alongside the
existing raw payload. A push whose `configDir` doesn't match any known account
is recorded as an `ErrorEntry` (route "injection") and dropped, rather than
guessed onto the Default account.

Antigravity accounts are `daemon_token`, not `config_dir`, so this doesn't
apply to them: the `agy` CLI has no profile concept the hook process could
report, so `POST /ingest/antigravity` payloads instead carry a top-level
`"accountId"` field. The hook script has no way to know a non-default
account's id, so it always forwards an empty string; the daemon treats an
empty (or missing) `accountId` as the default Antigravity account
(`"acct_antigravity_default"`) and otherwise matches it directly against a
known account's `id`. A push whose `accountId` doesn't match any known
Antigravity account is recorded as an `ErrorEntry` (route "injection") and
dropped, same as the `config_dir` case above.
