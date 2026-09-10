# Scripts

Build, install, and distribution scripts for AIUsageWidget.

## Distribution Channels

### 1. Homebrew Cask (recommended for most users)

```bash
brew tap <owner>/aiusagewidget
brew install --cask aiusagewidget
# Uninstall: brew uninstall --cask aiusagewidget
```

### 2. Curl-based installer (no local toolchain needed)

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/AIUsageWidget/main/install.sh | bash
```

Downloads a prebuilt release tarball instead of building anything locally.
Pin a version with `-s -- --version vX.Y.Z`.

### 3. DMG drag-to-install

Download `AIUsageWidget-X.Y.Z.dmg` from the GitHub Releases page.

> **Note:** Since the app is ad-hoc signed (not notarized), the first launch of
> a browser-downloaded `.dmg` requires: right-click the app → **Open** → click
> **Open** in the dialog.  This only needs to be done once.  The curl installer
> and Homebrew cask do **not** have this issue.

### 4. Build from source (`install.sh`)

Requires local `go` and `swift` toolchains:

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
| `build-app-bundle.sh` | Assembles the Swift binary into a `.app` bundle and ad-hoc codesigns |
| `build-dmg.sh` | Creates a `.dmg` disk image from the `.app` bundle |
| `run-with-log-rotation.sh` | LaunchAgent log rotation wrapper (rotates at 5 MB) |
| `uninstall.sh` | Complete uninstaller (LaunchAgents + app files + statusLine hooks) |
| `claude-statusline-hook.py` | StatusLine hook script for Claude Code |
| `antigravity-statusline-hook.py` | StatusLine hook script for Antigravity |
| `antigravity-quota-probe.swift` | Standalone debug script that queries Antigravity's quota directly from the Keychain credential, bypassing the daemon — for manually diagnosing Antigravity collector issues |
