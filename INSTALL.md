# Installing and building QuotaPeek

This covers manual installation, building from source, and the full
architecture. For the quick version, see [README.md](README.md).

## Architecture

One app, no background service. Every number comes from the agents
themselves:

- **Claude Code and Antigravity** run a `statusLine` hook on every render
  (`Scripts/claude-statusline-hook.py`, `Scripts/antigravity-statusline-hook.py`,
  sharing `Scripts/quotapeek_hook.py`). The hook sends the reading to the app
  as one fire-and-forget datagram on a Unix socket in
  `~/Library/Application Support/QuotaPeek/` and never waits for it. If the
  app isn't running the reading is simply dropped; the agent is unaffected.
- **Codex** writes its rate limits into its own session logs
  (`~/.codex/sessions/**/rollout-*.jsonl`); the app watches them with
  FSEvents.
- **Web fallback** (Claude and Codex): when an account's local data is older
  than 15 minutes and QuotaPeek is on screen, the app asks the provider's
  usage endpoint with the CLI's saved login (read-only through `security`;
  it never refreshes or stores tokens), at most every 10 minutes. Refresh
  Now asks right away. Each provider's live and web sources can be turned
  on or off in Settings → Accounts.

The app keeps only the latest reading per account in memory. It publishes
them to `snapshot.json` (removed when the app quits), which the Claude Code
hook reads to append Codex and Antigravity to Claude Code's own statusline
(turn this off in Settings → General) and the macOS widget reads to render.

Accounts and settings live in `config.json` in the same folder; problems are
written to the unified log (subsystem `com.quotapeek`) and to a small capped
`errors.log`, shown in Settings → Advanced → Recent errors. Secrets are
redacted before anything is written.

Besides the popover, the app drives **desktop panels**
(`DesktopWidgetPanel.swift` / `WidgetPanelView.swift`): small, draggable,
always-visible panels, each with its own account, metric and style. The
**macOS widget** (`Sources/QuotaPeekWidget`, `Sources/QuotaPeekWidgetUI`) is
a WidgetKit extension inside the app bundle with the same styles.

Each provider supports multiple accounts (e.g. two Claude subscriptions in
different config folders), managed in Settings → Accounts. Antigravity's hook
can't tell logins apart, so only one Antigravity account is tracked.

### Upgrading from 1.x

Versions before 2.0 ran a separate Go daemon (`quotapeekd`). The first launch
of 2.x (and `install.sh` or the Homebrew cask) stops it and removes its
LaunchAgent, binary and token caches. `config.json` is kept, so accounts and
settings carry over.

## Install manually

### From source

Requires a Swift toolchain (Xcode 16 or later for the widget).

```
./install.sh
```

### Without cloning, via curl

Downloads a prebuilt release tarball instead of building anything locally:

```
curl -fsSL https://raw.githubusercontent.com/shassshank/QuotaPeek/main/install.sh | bash
```

`install.sh` auto-detects which of these it's doing — building from source
when run next to `Package.swift`, downloading the release otherwise. Pin a
version with `-s -- --version vX.Y.Z`, or force either mode explicitly with
`--local` / `--remote`.

Either way, it installs the app as a normal `.app` bundle in `/Applications`
(falling back to `~/Applications`), installs the statusLine hook scripts to
`~/Library/Application Support/QuotaPeek/bin`, installs a LaunchAgent so the
app starts at login, and merges a `statusLine` entry into
`~/.claude/settings.json` and `~/.gemini/antigravity-cli/settings.json`
(existing settings preserved, backed up if they were someone else's).

Safe to re-run.

## Uninstall

```
~/Library/Application\ Support/QuotaPeek/bin/uninstall.sh
```

This removes the LaunchAgent, deletes the app bundle and support files, and
cleans up the `statusLine` entries it added. See `Scripts/README.md` for what
it does in detail.

## Development

- `swift build` builds the app and the widget; `swift test` runs the tests
  (set `QP_LIVE=1` for the ones that read your real Codex logs and web usage,
  `QP_PREVIEW_DIR=<dir>` to render every widget style to PNGs).
- `python3 -m unittest discover -s Tests/hooks` tests the hook scripts.
- `./install.sh --local` builds a release bundle and installs it.
