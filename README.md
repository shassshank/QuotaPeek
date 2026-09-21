# QuotaPeek

[![Release](https://img.shields.io/github/v/release/shassshank/QuotaPeek)](https://github.com/shassshank/QuotaPeek/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight macOS menu bar app showing live 5-hour and weekly usage limits
(and reset times) for Claude Code, Codex, and Antigravity — reading each
provider's own credentials locally, nothing ever leaves your Mac.

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

Either way installs the menu bar app plus its background daemon, sets both
to start at login, and wires up the statusLine hooks Claude Code and
Antigravity use to push live usage data. Safe to re-run.

The first time the daemon runs, macOS will ask whether it may read the
"Claude Code-credentials" and "gemini" Keychain items — choose "Always
Allow" so it doesn't ask again.

## Uninstall

```
brew uninstall --cask quotapeek
```

Or, if installed via the curl script:

```
~/Library/Application\ Support/QuotaPeek/bin/uninstall.sh
```

## More

For architecture details, manual/source installation, and building the
daemon and app yourself, see [INSTALL.md](INSTALL.md).

- `API_CONTRACT.md` — the HTTP API contract between the daemon and the app.
- `Backend/README.md` — how to build/run/test the daemon standalone.
