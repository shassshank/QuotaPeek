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
pair). To keep this out of source control, the daemon reads it from two
optional build-time `-ldflags`, falling back to environment variables:

```sh
go build -ldflags "-X main.antigravityOAuthClientIDs=<id1,id2,...> -X main.antigravityOAuthClientSecrets=<secret1,secret2,...>" .
# or, for `go run .` / local dev:
QUOTAPEEK_ANTIGRAVITY_OAUTH_CLIENT_IDS=<id1,id2,...> \
QUOTAPEEK_ANTIGRAVITY_OAUTH_CLIENT_SECRETS=<secret1,secret2,...> \
go run .
```

Official release builds (via `.github/workflows/release.yml`) inject these
from the repo's `ANTIGRAVITY_OAUTH_CLIENT_IDS` / `ANTIGRAVITY_OAUTH_CLIENT_SECRETS`
Actions secrets, so curl/DMG/Homebrew installs work out of the box. A plain
local source build (`./install.sh` without these set) will report Antigravity
Keychain polling as "not configured" and fall back cleanly — Antigravity's
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
