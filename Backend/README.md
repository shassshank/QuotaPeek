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
to `codex` on `PATH`.

Useful checks:

```sh
go vet ./...
go test ./...
```
