# AI Usage Widget

A lightweight macOS menu bar app showing live 5-hour and weekly usage limits
(and reset times) for Claude Code, Codex, and Antigravity — read from the same
already-authenticated CLIs you have installed, no separate login or API keys.

## How it works

The app itself never talks to Anthropic/OpenAI/Google. It only reads a small
local cache file (`~/Library/Application Support/AIUsageWidget/usage.json`)
that three independent collector scripts keep updated:

- **Claude Code** (`Scripts/claude-statusline-hook.py`): registered as Claude
  Code's `statusLine` hook. Claude Code invokes it with usage data on stdin
  every time it renders its status line during an active session — free,
  no extra API calls, no reverse engineering (this is a documented,
  supported integration point).
- **Antigravity** (`Scripts/antigravity-statusline-hook.py`): same mechanism
  (Antigravity's CLI also has a `statusLine` hook slot), but its payload
  schema wasn't confirmed during initial research. The script dumps the raw
  payload to `antigravity-statusline-debug.json` on first run and best-effort
  guesses at usage/reset fields by key-name matching. If usage doesn't show
  up for Antigravity, inspect that debug file and tighten the field mapping
  in the script.
- **Codex**: has no equivalent free push hook, so
  `Scripts/codex-usage-poll.py` runs a minimal `codex exec` turn every 15
  minutes (via a LaunchAgent) purely to capture the `codex.rate_limits` event
  that rides along on every response. This does cost a small amount of the
  usage it's measuring — increase `StartInterval` in
  `LaunchAgents/com.aiusagewidget.codexpoll.plist.template` if that matters
  to you.

## Install

```
./install.sh
```

This builds the release binary, copies it plus the collector scripts to
`~/Library/Application Support/AIUsageWidget/bin`, adds the `statusLine` hook
to `~/.claude/settings.json` and `~/.gemini/antigravity-cli/settings.json`
(merged in, existing settings preserved), and installs two LaunchAgents so
the app and the Codex poller start automatically at login.

Safe to re-run.

## Uninstall

```
launchctl unload ~/Library/LaunchAgents/com.aiusagewidget.app.plist
launchctl unload ~/Library/LaunchAgents/com.aiusagewidget.codexpoll.plist
rm ~/Library/LaunchAgents/com.aiusagewidget.*.plist
rm -rf ~/Library/Application\ Support/AIUsageWidget
```

Then remove the `"statusLine"` key from `~/.claude/settings.json` and
`~/.gemini/antigravity-cli/settings.json` if you don't use it for anything
else.

## Status / next steps

- macOS menu bar app: working (SwiftUI popover, per-provider progress bars,
  reset countdowns, manual refresh).
- Claude Code usage: confirmed schema, wired up.
- Codex usage: confirmed schema, wired up, polling-based.
- Antigravity usage: hook wired up, exact field names unconfirmed — needs a
  live payload capture to finish.
- iOS/iPhone widget: not started. Would reuse the same `usage.json` schema
  via an App Group container synced from the Mac (e.g. iCloud Key-Value
  store or a small sync helper), since a phone can't read the Mac's local
  CLI state directly.
