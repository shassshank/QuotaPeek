# QuotaPeek

[![Release](https://img.shields.io/github/v/release/shassshank/QuotaPeek)](https://github.com/shassshank/QuotaPeek/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight macOS menu bar app showing live 5-hour and weekly usage limits
(and reset times) for Claude Code, Codex, and Antigravity — reading each
provider's own credentials locally, nothing ever leaves your Mac.

- **Menu bar icon + popover** — click for the full breakdown, gear icon for
  Settings.
- **macOS widgets** — native WidgetKit widgets for the desktop and
  Notification Center, in six styles and three sizes.
- **Desktop panels** — separate from the popover; add any number of small,
  draggable, always-on-screen panels, each in its own style (linear bars,
  circular rings, concentric 5h/weekly rings, per-agent breakdown, or a
  single-agent focus view).
- **Claude Code's own statusline** — once installed, Claude Code's native
  statusline picks up Codex's and Antigravity's usage too (percentage and
  reset time), so all three show up without leaving Claude Code.

## Install

Via Homebrew:

```
brew tap shassshank/quotapeek
brew install --cask quotapeek
```

Or without Homebrew, via curl (downloads a prebuilt release):

```
curl -fsSL https://raw.githubusercontent.com/shassshank/QuotaPeek/main/install.sh | bash
```

Either way installs the menu bar app, sets it to start at login, and wires
up the statusLine hooks Claude Code and Antigravity use to send live usage.
There is no background service. Safe to re-run.

When local data is stale and QuotaPeek is on screen, it may ask the web
using the CLI's own saved login; the first time, macOS asks whether
`security` may read the "Claude Code-credentials" (or Codex) Keychain item.
Choose "Always Allow" so it doesn't ask again, or turn the web fallback off
per provider in Settings → Accounts.

## Uninstall

```
brew uninstall --cask quotapeek
```

Or, if installed via the curl script:

```
~/Library/Application\ Support/QuotaPeek/bin/uninstall.sh
```

## More

For architecture details, manual/source installation, and building the app
yourself, see [INSTALL.md](INSTALL.md).
