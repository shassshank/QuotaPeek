# QuotaPeek Daemon

Go backend for the macOS menu bar app. It serves the API in `../API_CONTRACT.md`
on loopback only:

```sh
go build ./...
go run .
```

The daemon listens on `127.0.0.1:47831` and persists config at:

```text
~/Library/Application Support/QuotaPeek/config.json
```

There are no required flags. Claude and Antigravity keychain collectors read
existing macOS Keychain entries via `/usr/bin/security`. Codex usage is
polled by spawning `~/.local/bin/codex app-server`, falling back to `codex`
on `PATH`. Credential reads are cached in memory (TTL-based, invalidated on
expiry or an auth failure) so a normal poll cycle doesn't re-hit the
Keychain or respawn `codex app-server` every tick.

### Antigravity credentials

Day to day, an expired Antigravity access token is recovered without the
daemon touching OAuth at all: it re-reads the `agy` CLI's own Keychain
entry, and if that's still stale, runs `agy -p Hi` to make the CLI itself
refresh and rewrite that entry — the same recovery Claude and Codex use.
The daemon only talks to Google's token endpoint directly as part of an
explicit account bootstrap or reauthenticate (adding a second Antigravity
account, since only one login fits in the CLI's own Keychain entry at a
time).

That direct-refresh path needs Antigravity's own installed-app Google OAuth
client id/secret — not a QuotaPeek secret, and not per-user; every copy of
the Antigravity app ships the same pair, embedded in its compiled binary.
Rather than shipping or maintaining a copy of that pair itself, the daemon
reads it out of the user's own locally installed `agy` binary the first
time it's needed (`Backend/antigravity_oauth_discovery.go`) and caches the
working pair at
`~/Library/Application Support/QuotaPeek/antigravity-oauth-cache.json`
(0600) so it isn't rescanning a ~180MB binary on every use. If Google ever
rotates the credential, the daemon rescans the binary for the current one
and retries automatically. If `agy` isn't installed locally, Antigravity
Keychain polling just reports itself unavailable; the Injection route
(statusLine hook) is unaffected either way.

The daemon shuts down gracefully on SIGINT/SIGTERM: it stops scheduling new
polls immediately, then gives the HTTP server and any in-flight polls up to
10 seconds to finish (so an OAuth token rotation already in progress gets
persisted) before exiting.

Useful checks:

```sh
go vet ./...
go test ./...
go test -race ./...   # concurrency changes should always be raced
```
