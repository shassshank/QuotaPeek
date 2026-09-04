# AI Usage Widget

A lightweight macOS menu bar app showing live 5-hour and weekly usage limits
(and reset times) for Claude Code, Codex, and Antigravity.

## Architecture

Two pieces:

- **`Backend/` — `aiusaged`**, a small Go daemon that owns everything:
  credential access, provider polling, config, and error state. It listens
  on `127.0.0.1:47831` (loopback only — nothing here ever leaves the Mac) and
  serves a small HTTP API described in full in `API_CONTRACT.md`.
- **`Sources/AIUsageWidget/` — the menu bar app**, a thin Swift/SwiftUI shell
  (status bar icon, popover, Settings window). It never touches Keychain or
  any provider API directly — it only talks to the daemon over that local
  API.

Each provider can be collected two ways, selectable per-provider in the
app's Settings window (gear icon in the popover):

- **Keychain** — the daemon reads the OAuth credential the provider's own
  CLI already stored in the macOS Keychain, and polls that provider's API
  directly on a timer. This is how Claude and Antigravity work by default.
- **Injection** — the provider's own CLI pushes live usage data to the
  daemon in real time, via its documented `statusLine` hook (Claude Code and
  Antigravity both support one; the hook script piggybacks on it — see
  `Scripts/claude-statusline-hook.py` / `Scripts/antigravity-statusline-hook.py`).
  Codex has no such hook, so its "Injection" route is instead a free local
  JSON-RPC call (`account/rateLimits/read` via a freshly spawned
  `codex app-server`) that the daemon runs itself on a timer — no OAuth
  involved either way.

If both routes are enabled for a provider, the daemon prefers the freshest
Injection sample and automatically falls back to the last Keychain poll once
Injection data goes stale (e.g. Claude Code hasn't rendered a status line
recently) — this is real fallback, not an either/or choice.

The daemon never silently drops a failure: every collector error is recorded
with the redacted message (tokens/secrets/full response bodies are always
stripped or truncated before anything is stored) and surfaced in the app's
Settings → Diagnostics tab.

## Install

```
./install.sh
```

This builds the Go daemon and the Swift app, installs both plus the two
statusLine hook scripts to `~/Library/Application Support/AIUsageWidget/bin`,
installs LaunchAgents so the daemon and the app start at login, and merges a
`statusLine` entry into `~/.claude/settings.json` and
`~/.gemini/antigravity-cli/settings.json` (existing settings preserved) so
the Injection route works out of the box.

The first time the daemon runs, macOS will show its own permission dialog
asking whether it may read the "Claude Code-credentials" and "gemini"
Keychain items — choose "Always Allow" so it doesn't ask again.

Safe to re-run.

## Uninstall

```
launchctl unload ~/Library/LaunchAgents/com.aiusagewidget.app.plist
launchctl unload ~/Library/LaunchAgents/com.aiusagewidget.daemon.plist
rm ~/Library/LaunchAgents/com.aiusagewidget.*.plist
rm -rf ~/Library/Application\ Support/AIUsageWidget
```

Then remove the `"statusLine"` key from `~/.claude/settings.json` and
`~/.gemini/antigravity-cli/settings.json` if you don't use it for anything
else.

## Development

- `Backend/README.md` — how to build/run/test the daemon standalone.
- `API_CONTRACT.md` — the HTTP API contract between the daemon and the app;
  the single source of truth for every endpoint and field name.
- `swift build` builds the menu bar app; `go build ./...` (from `Backend/`)
  builds the daemon. Running the daemon standalone (`go run .` from
  `Backend/`) is the fastest way to iterate on the app's UI against real
  data without a full `swift build -c release` + reinstall cycle.
