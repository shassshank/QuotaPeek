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

### Antigravity Keychain-polling OAuth credentials

Refreshing an Antigravity Keychain-stored token requires Antigravity's own
installed-app Google OAuth client id/secret (not a QuotaPeek secret, and not
a per-user credential — every copy of the Antigravity app ships the same
pair, embedded in its compiled binary). Rather than QuotaPeek shipping or
maintaining a copy of that pair itself, the daemon reads it directly out of
the user's own locally installed Antigravity CLI (`~/.local/bin/agy`, or
`agy` on `PATH`) the first time it's needed
(`Backend/antigravity_oauth_discovery.go`), and caches the working pair at
`~/Library/Application Support/QuotaPeek/antigravity-oauth-cache.json`
(0600) so it doesn't rescan the ~180MB binary on every poll. If every cached
pair ever stops working — e.g. Google/Antigravity rotates the credential —
the daemon automatically rescans the local binary for the current one and
retries. If `agy` isn't installed locally, Antigravity Keychain polling
reports itself unavailable and the daemon falls back cleanly; Antigravity's
Injection route (its statusLine hook) is unaffected either way.

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
