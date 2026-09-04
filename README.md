# AI Usage Widget

A lightweight macOS menu bar app showing live 5-hour and weekly usage limits
(and reset times) for Claude Code, Codex, and Antigravity — read from the same
already-authenticated CLIs you have installed, no separate login or API keys.

**The app never edits any other tool's config or settings file.** Everything
it needs comes either from a credential the CLI already stored in the macOS
Keychain (with macOS's own per-app access prompt) or from a protocol the CLI
already exposes for other processes to talk to.

## How it works

The app writes to its own local cache file
(`~/Library/Application Support/AIUsageWidget/usage.json`) and the menu bar
UI just reads that. Three independent collectors keep it updated:

- **Claude Code** (`Sources/AIUsageWidget/ClaudeUsageCollector.swift`, runs
  in-process): reads Claude Code's OAuth token from the Keychain (service
  `"Claude Code-credentials"` — macOS prompts once per app to allow this,
  "Always Allow" persists it), then makes one minimal (`max_tokens: 1`)
  authenticated request to `https://api.anthropic.com/v1/messages`. The
  response headers carry the same numbers Claude Code's own status line
  shows: `anthropic-ratelimit-unified-5h-utilization` /
  `-5h-reset` / `-7d-utilization` / `-7d-reset` (utilization is a 0–1
  fraction used, reset is a unix timestamp). Polled every 5 minutes.
- **Codex** (`Scripts/codex-usage-poll.py`): has a proper JSON-RPC method,
  `account/rateLimits/read`, over its app-server protocol. The script spawns
  a fresh, short-lived `codex app-server` process (stdio transport, not the
  persistent daemon's control socket — that speaks a different, admin-only
  protocol), sends `initialize` then `account/rateLimits/read`, and gets an
  instant answer at **no token/usage cost**. Polled every 2 minutes via a
  LaunchAgent (`StartInterval` in
  `LaunchAgents/com.aiusagewidget.codexpoll.plist.template`).
- **Antigravity**: not wired up yet. Antigravity's OAuth token lives in the
  Keychain too (service `"gemini"`, account `"antigravity"`, base64-encoded
  Google-style token), but which Google/Gemini API endpoint exposes quota
  from that token hasn't been determined yet.

## Install

```
./install.sh
```

This builds the release binary, copies it plus the Codex collector script to
`~/Library/Application Support/AIUsageWidget/bin`, and installs two
LaunchAgents so the app and the Codex poller start automatically at login.

The first time the app runs, macOS will show its own permission dialog
asking whether AIUsageWidget may read the "Claude Code-credentials" Keychain
item — choose "Always Allow" so it doesn't ask again.

Safe to re-run.

## Uninstall

```
launchctl unload ~/Library/LaunchAgents/com.aiusagewidget.app.plist
launchctl unload ~/Library/LaunchAgents/com.aiusagewidget.codexpoll.plist
rm ~/Library/LaunchAgents/com.aiusagewidget.*.plist
rm -rf ~/Library/Application\ Support/AIUsageWidget
```

Nothing else needs cleaning up — no other tool's files were ever touched.

## Status / next steps

- macOS menu bar app: working (SwiftUI popover, per-provider progress bars,
  reset countdowns, manual refresh).
- Claude Code usage: confirmed real header schema, wired up in-app
  (Keychain read + direct Anthropic API call). Verified against a real
  account (200 response, correct headers) — needs a full end-to-end run of
  the built app to confirm the menu bar UI renders it correctly.
- Codex usage: confirmed schema and protocol, wired up, free on-demand
  polling every 2 minutes via `codex app-server` JSON-RPC.
- Antigravity usage: not started. Need to identify which Google/Gemini API
  endpoint, called with the Keychain-stored `ya29...` access token, returns
  quota/rate-limit data.
- iOS/iPhone widget: not started. Would reuse the same `usage.json` schema
  via an App Group container synced from the Mac (e.g. iCloud Key-Value
  store or a small sync helper), since a phone can't read the Mac's local
  CLI state directly.
