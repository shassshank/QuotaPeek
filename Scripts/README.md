# Scripts

Build, install, and distribution scripts for QuotaPeek.

## Distribution Channels

### 1. Homebrew Cask (recommended for most users)

```bash
brew tap shassshank/quotapeek
brew install --cask quotapeek

# Uninstall (removes the app and its LaunchAgent; keeps config and logs):
brew uninstall --cask quotapeek

# Full removal (also removes config, logs, and statusLine hooks):
brew uninstall --zap --cask quotapeek
```

### 2. Curl-based installer (no local toolchain needed)

```bash
curl -fsSL https://raw.githubusercontent.com/shassshank/QuotaPeek/master/install.sh | bash
```

Downloads a prebuilt release tarball instead of building anything locally.
Pin a version with `-s -- --version vX.Y.Z`. The tarball's SHA256 is
verified against the `SHA256SUMS` file published alongside each release
before extraction; installation aborts if it's missing or doesn't match.

### 3. DMG install

Download `QuotaPeek-X.Y.Z.dmg` from the GitHub Releases page, open it, then
double-click **Install QuotaPeek.command** — it installs the app, the
statusLine hooks and the login item in one step (the same file-placement
logic as the curl installer, just run against the files already bundled in
the DMG instead of a download). Dragging `QuotaPeek.app` to `/Applications`
also works, but then Claude Code and Antigravity have no hook to report
through; Codex works either way.

> **Note:** Since the app and installer are ad-hoc signed (not notarized),
> the first launch of a browser-downloaded `.dmg`'s contents requires:
> right-click the item → **Open** → click **Open** in the dialog. This only
> needs to be done once per item. The curl installer and Homebrew cask do
> **not** have this issue.

### 4. Build from source (`install.sh`)

Requires a local Swift toolchain:

```bash
./install.sh
```

`install.sh` is the single installer for both of these paths — run from a
source checkout it builds locally; piped via curl (or with `--remote`) it
downloads the prebuilt release tarball instead. See the header comment in
`install.sh` for how it decides which mode to use.

## Script Reference

| Script | Purpose |
|--------|---------|
| `build-app-bundle.sh` | Assembles the app and the widget extension into a `.app` bundle and ad-hoc codesigns |
| `build-dmg.sh` | Creates a `.dmg` disk image from the `.app` bundle |
| `run-with-log-rotation.sh` | LaunchAgent log rotation wrapper (rotates at 5 MB) |
| `uninstall.sh` | Complete uninstaller (LaunchAgent + app files + statusLine hooks) |
| `claude-statusline-hook.py` | StatusLine hook script for Claude Code |
| `antigravity-statusline-hook.py` | StatusLine hook script for Antigravity |
| `quotapeek_hook.py` | Module both hooks share: sends readings to the app, reads `snapshot.json` |
| `measure.sh` | Memory and hook-latency measurement of an installed build |
