# AI Usage Widget Daemon

Go backend for the macOS menu bar app. It serves the API in `../API_CONTRACT.md`
on loopback only:

```sh
go build ./...
go run .
```

The daemon listens on `127.0.0.1:47831` and persists config at:

```text
~/Library/Application Support/AIUsageWidget/config.json
```

There are no flags or required environment variables. Claude and Antigravity
keychain collectors read existing macOS Keychain entries via `/usr/bin/security`.
Codex usage is polled by spawning `~/.local/bin/codex app-server`, falling back
to `codex` on `PATH`. Credential reads are cached in memory (TTL-based,
invalidated on expiry or an auth failure) so a normal poll cycle doesn't
re-hit the Keychain or respawn `codex app-server` every tick.

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
