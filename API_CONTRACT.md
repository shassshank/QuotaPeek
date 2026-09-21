# QuotaPeek daemon API contract

This is the contract between the Go daemon (`Backend/`) and the Swift menu
bar app (`Sources/QuotaPeek/`). Both sides build against it — if you're
adding a field or endpoint, update this file as part of that change, not
after.

## Transport and auth

The daemon listens on `127.0.0.1:47831` only — never `0.0.0.0`, never a unix
socket, so the Swift side can keep using plain `URLSession`. Nothing here
ever leaves localhost, so plain HTTP is fine. All bodies are JSON.

Every endpoint requires an `X-Auth-Token` header. At startup the daemon
writes a random 256-bit token to
`~/Library/Application Support/QuotaPeek/auth-token` (mode 0600); the app
and the statusLine hooks read that file per request, so a daemon restart
doesn't require restarting clients. This is a per-user secret, not an app
identity check — any process running as the same user can read the file.
Missing or wrong tokens return 401 without touching anything.

## Core types

```jsonc
Account {
  "id": "acct_ab12cd34",
  "provider": "claude" | "codex" | "antigravity",
  "label": "Work",                     // user-editable, defaults to "Default"
  "credentialLocation": {
    "kind": "config_dir" | "daemon_token",
    "configDir": "/Users/x/.claude-work" | null   // set when kind == "config_dir"
  },
  "credentialSource": "keychain" | "oauth" | "api-key" | "env" | "unknown",
  "effectiveAccount": "account identifier or email" | null,
  "lastSuccessAt": 1767550000 | null,  // unix seconds
  "lastFailureAt": 1767549000 | null,
  "lastError": "most recent failed poll message, secrets redacted" | null,
  "routes_enabled": ["keychain", "injection"],
  "active_route": "keychain" | "injection" | "none",
  "data": {
    "used_percent_5h": 42.1,
    "resets_at_5h": 1767561600,
    "used_percent_weekly": 18.0,
    "resets_at_weekly": 1768080000,
    "used_percent_5h_third_party": 0.0,       // Antigravity's Claude/GPT 3P quota
    "resets_at_5h_third_party": 1767561600,
    "used_percent_weekly_third_party": 6.0,
    "resets_at_weekly_third_party": 1768400000,
    "context_window_used_percent": 12.4
  } | null,
  "as_of": 1767550000 | null,
  "last_error": { "route": "keychain" | "injection", "message": "...", "at": 1767549000 } | null,
  "restoredFromDisk": boolean,          // true if this daemon run hasn't polled fresh data yet
  "state": "unknown" | "fresh" | "stale" | "restored" | "error"
}
```

`state` is computed server-side, in this order: `unknown` if there's no data
or it's older than `hardExpirySeconds`; `restored` if it came from disk and
hasn't been refreshed this run; `fresh` if it's within the freshness cutoff;
`stale` if it's older than that but still under `hardExpirySeconds`; `error`
if there's a live error and no data to fall back on. `hardExpirySeconds` is
`4 * max(staleAfterSeconds, 2 * keychain_poll_interval_sec)`. The app
switches on `state` rather than inferring freshness itself from `as_of` —
when state is `unknown` because of age, show "No recent data" instead of the
stale number.

`credentialLocation.kind`:
- `config_dir` — Claude and Codex. The daemon sets `CLAUDE_CONFIG_DIR` or
  `CODEX_HOME` to `configDir` for every call made on that account's behalf.
- `daemon_token` — Antigravity. The `agy` CLI has no concept of multiple
  profiles, so a second Antigravity account's OAuth token is captured once
  and owned by the daemon rather than read live from the CLI's Keychain
  entry (see "Antigravity accounts" below).

```jsonc
Config {
  "statusline_show_other_agents": true,
  "staleAfterSeconds": 600,
  "collectionPaused": false,
  "claude_polling_mode": "disabled",   // or "inference"
  "claude":      { "routes_enabled": ["keychain", "injection"], "keychain_poll_interval_sec": 300 },
  "codex":       { "routes_enabled": ["injection"],              "keychain_poll_interval_sec": 300 },
  "antigravity": { "routes_enabled": ["keychain"],                "keychain_poll_interval_sec": 300 }
}
```

A route counts as fresh for up to `max(2 * keychain_poll_interval_sec, staleAfterSeconds)`
seconds; if neither route is fresh, the newest enabled sample is shown
regardless. Injection is preferred over Keychain whenever both have current
data. Each provider entry also accepts an optional `notify_threshold_percent`
(1–100); omit or null to disable notifications for that provider — the
daemon only stores and returns this, the app decides when to actually fire one.

```jsonc
ErrorEntry {
  "provider": "claude" | "codex" | "antigravity",
  "route": "keychain" | "injection",
  "message": "string, secrets redacted",
  "at": 1767549000
}
```

## Endpoints

### `GET /status`
Returns `{ "statusline_show_other_agents": true, "accounts": [Account, ...] }`,
ordered by provider (claude, codex, antigravity) then by creation order.
Doesn't trigger any collection — just returns what's currently stored.

### `POST /refresh`
Forces an immediate poll on every enabled synchronous route. Injection
routes only update from a push, so this doesn't touch them. Optional body
`{"accountId":"acct_..."}` limits it to one account; an empty body refreshes
everything. Blocks until fetches finish (each capped around 10s) and
returns the same shape as `GET /status`.

### `POST /test-route`
Body: `{"provider":"...","accountId":"acct_...","route":"keychain"|"injection"}`.
Runs one specific route's fetch on demand, even if that route is disabled,
and reports the result without touching stored samples on failure — a
failed probe never clobbers what's currently displayed. A successful fetch
does save the fresh sample normally.

Injection routes are push-only, so there's nothing to fetch: `ok` just
reflects whether a push has arrived recently enough to count as fresh.

Both success and failure return HTTP 200:
```json
{"ok":true,"provider":"claude","route":"keychain","accountId":"acct_..."}
```
```json
{"ok":false,"provider":"claude","route":"keychain","accountId":"acct_...","message":"Claude credentials expired, run claude CLI to refresh"}
```

### `GET /config` / `PUT /config`
`PUT` accepts a full or partial config — only the providers you're changing
need to be present, and each one you include replaces its whole entry (so
send `routes_enabled` and `keychain_poll_interval_sec` together with any
`notify_threshold_percent` change). Persists immediately and reschedules
poll timers. Returns the resulting full config.

`claude_polling_mode: "inference"` makes the daemon send a real,
token-consuming Messages API call (`max_tokens: 1`) on a timer just to read
the rate-limit headers back — about 1,440 calls/day at the default 60s
interval, and it may incur charges depending on the plan. It's off by
default; Claude's own statusLine (Injection) gives passive updates for free
whenever Claude Code is actually being used.

Pausing and resuming collection is just `PUT /config` with
`{"collectionPaused": true}` / `false}` — there's no separate
`/control/pause` endpoint. While paused, nothing makes network, credential,
or subprocess calls; `POST /refresh` and `POST /test-route` both report that
collection is paused rather than doing anything.

### `GET /errors?limit=50`
Returns `{ "errors": [ErrorEntry, ...] }`, newest first, capped at `limit`
(default 50, max 200). In-memory ring buffer — doesn't survive a restart.

### `GET /history?accountId=acct_...&route=keychain`
Returns `{"points":[{"at":1767550000,"usedPercent":42.1}]}`, oldest first.
Up to 200 points per account/route, nothing older than 24 hours. Uses the 5h
percentage when available, otherwise weekly.

## Accounts

### `GET /accounts`
`{"accounts": [{id, provider, label, credentialLocation}, ...]}` — config
only, no live data.

### `POST /accounts`
```json
{"provider":"claude","label":"Work","credentialLocation":{"kind":"config_dir","configDir":"/Users/x/.claude-work"}}
```
For Antigravity's `daemon_token` accounts, either let the daemon read the
locally signed-in `agy` CLI's own Keychain entry:
```json
{"provider":"antigravity","label":"Personal Gmail","credentialLocation":{"kind":"daemon_token"},"autoDetect":true}
```
or hand it a refresh token directly (returns 422 if no login was found for
`autoDetect`):
```json
{"provider":"antigravity","label":"Personal Gmail","credentialLocation":{"kind":"daemon_token"},"oauthBootstrap":{"refreshToken":"...","email":"..."}}
```
Returns 201 with the new account (state `unknown` until the first poll). A
duplicate `configDir` for the same provider is a 409; so is a second
Antigravity account with the same email.

### `PATCH /accounts/{id}`
Rename only — `{"label":"New label"}`. Everything else about an account is
fixed at creation; delete and recreate to change it.

### `DELETE /accounts/{id}`
Removes the account, its history, and any daemon-owned credential cache file
for it. Never touches the OS Keychain or a CLI's own credential files.

### `POST /accounts/{id}/reset-credentials`
Clears the daemon's cached credentials and discovery state for that account
only — not Keychain items, not CLI files. The account goes back to
`credentialSource: "unknown"` until the next poll rediscovers it, and this
endpoint doesn't trigger that poll itself.

### `POST /accounts/{id}/reauthenticate`
Antigravity-only, and only for a non-default account (the default account
just re-reads the `agy` CLI's Keychain entry on its own — nothing to
reauthenticate). Body is the same `oauthBootstrap`/`autoDetect` shape as
account creation; swaps in a fresh refresh token for an account that's
fallen out of sync without deleting and recreating it.

## Antigravity accounts

Only one Antigravity login can live in the `agy` CLI's own Keychain entry at
a time, so a second Antigravity account's token has to be captured once and
kept by the daemon itself (`credentialLocation.kind: "daemon_token"`),
stored in its own file next to `config.json`. The default account keeps
reading the CLI's Keychain entry live, the same way it always has.

When a daemon-owned account's cached access token goes stale, the daemon
first just re-reads the Keychain — if `agy` itself refreshed in the
background, that's enough. If that doesn't recover it, the daemon runs the
`agy` CLI with a trivial prompt to make it refresh its own credentials (the
same recovery used for Claude and Codex), then tries again. The daemon never
calls Google's OAuth endpoint on its own behalf during a normal poll — that
only happens as part of an explicit account bootstrap or reauthenticate.

## Ingest

### `POST /ingest/claude`, `POST /ingest/antigravity`
Called by the statusLine hook scripts on every invocation, with that
provider's raw statusLine payload as the body. A successful parse updates
that account's `data`/`as_of` on the Injection route; a failed parse is
logged as an `ErrorEntry` without touching existing data. The hook doesn't
wait on or care about the response.

Since the statusLine hook has no notion of "which account," Claude/Codex
pushes carry a `configDir` field (the hook's own `CLAUDE_CONFIG_DIR`, or
empty for the default) that the daemon matches against a `config_dir`
account. Antigravity pushes carry an `accountId` instead — the hook always
sends it empty (it has no way to know a non-default account's id), so
non-default Antigravity accounts don't currently receive Injection data. A
push that doesn't match any known account is logged and dropped rather than
guessed onto the default one.

Raw payload shapes, for reference:

```jsonc
// Claude Code statusLine (subset actually used)
{
  "rate_limits": {
    "five_hour": { "used_percentage": 42.1, "resets_at": 1767561600 },
    "seven_day": { "used_percentage": 18.0, "resets_at": 1768080000 }
  },
  "context_window": { "used_percentage": 12.4 }
  // rate_limits is absent until the session's first API response, and for
  // API-key (non-subscription) auth — treat that as "no data yet," not an error.
}

// Antigravity statusLine (subset actually used)
{
  "quota": {
    "<window-key>": {
      "remaining_fraction": 0.9378,   // usage = (1 - remaining_fraction) * 100
      "reset_in_seconds": 3600
    }
    // only "gemini-weekly" is confirmed to appear in practice; map it to
    // used_percent_weekly rather than pattern-matching on substrings like "hour".
  },
  "context_window": { "used_percentage": 12.4 }
}
```

## Error messages

Never put a raw OAuth token, API key, or full provider response body into an
error message (`ErrorEntry.message`, `lastError`, etc.) — truncate provider
responses to ~200 characters and strip anything that looks like a secret
first. `"antigravity: token refresh failed (401)"` is the right shape, not a
dump of the response.

## Persistence

Rotated Codex and Antigravity credentials live in their own private files
next to `config.json` (0600, atomic writes). A fingerprint of the source CLI
credential is kept alongside so a fresh CLI login always supersedes a stale
daemon-saved rotation. `samples.json` holds the latest sample and recent
history for every account/route, written the same way.

Quitting the app unloads the daemon's LaunchAgent for the current session
(it comes back at next login). `./install.sh --daemon-stop` /
`--daemon-start` stop or start it persistently; `--app-login-off` /
`--app-login-on` do the same for whether the app itself launches at login.
A normal reinstall reloads both agents without overriding whichever of these
you'd already set.
