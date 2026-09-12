# Homebrew Cask definition for QuotaPeek.
#
# This file is intended to live in a separate tap repository:
#   homebrew-quotapeek/Casks/quotapeek.rb
#
# Users would install via:
#   brew tap shassshank/quotapeek
#   brew install --cask quotapeek
#
# This provides a free, familiar distribution + uninstall story via:
#   brew uninstall --cask quotapeek
cask "quotapeek" do
  version "1.0.0"
  # Must replace :no_check with the real pinned SHA256 before publishing to any tap.
  # Once the checksums workflow publishes a release, download its tarball and run:
  #   shasum -a 256 quotapeek-macos.tar.gz
  # Use that digest (also in SHA256SUMS) for the version and URL below.
  sha256 :no_check

  url "https://github.com/shassshank/QuotaPeek/releases/download/v#{version}/quotapeek-macos.tar.gz"
  name "QuotaPeek"
  desc "macOS menu bar widget showing AI coding assistant usage and quotas"
  homepage "https://github.com/shassshank/QuotaPeek"

  # The tarball is not a .app directly — it contains the app plus supporting
  # files. The `app` stanza installs QuotaPeek.app into /Applications
  # (matching install.sh's behavior), and a postflight sets up the daemon,
  # hooks, and LaunchAgents.
  app "QuotaPeek.app"

  postflight do
    bin_dir = "#{Dir.home}/Library/Application Support/QuotaPeek/bin"
    staged = staged_path.to_s

    # Copy daemon and supporting scripts
    FileUtils.mkdir_p(bin_dir)
    %w[
      quotapeekd
      claude-statusline-hook.py
      antigravity-statusline-hook.py
      run-with-log-rotation.sh
      uninstall.sh
    ].each do |f|
      src = File.join(staged, f)
      FileUtils.cp(src, bin_dir) if File.exist?(src)
    end

    # Make scripts executable
    Dir.glob(File.join(bin_dir, "*.py")).each { |f| FileUtils.chmod(0o755, f) }
    Dir.glob(File.join(bin_dir, "*.sh")).each { |f| FileUtils.chmod(0o755, f) }
    FileUtils.chmod(0o755, File.join(bin_dir, "quotapeekd")) if File.exist?(File.join(bin_dir, "quotapeekd"))

    # Install LaunchAgent plists from templates
    la_dir = "#{Dir.home}/Library/LaunchAgents"
    FileUtils.mkdir_p(la_dir)
    python3 = `which python3`.strip
    python3 = "/usr/bin/python3" if python3.empty?
    app_support = "#{Dir.home}/Library/Application Support/QuotaPeek"
    app_bundle = "/Applications/QuotaPeek.app"

    %w[com.quotapeek.daemon com.quotapeek.app].each do |label|
      template = File.join(staged, "#{label}.plist.template")
      next unless File.exist?(template)

      content = File.read(template)
        .gsub("__BIN_DIR__", bin_dir)
        .gsub("__HOME__", Dir.home)
        .gsub("__APP_SUPPORT__", app_support)
        .gsub("__APP_BUNDLE__", app_bundle)
      dest = File.join(la_dir, "#{label}.plist")
      system_command "/usr/bin/true", args: [] # ensure previous is unloaded
      system_command "launchctl", args: ["unload", dest], must_succeed: false if File.exist?(dest)
      File.write(dest, content)
      system_command "launchctl", args: ["load", "-w", dest]
    end

    # Register statusLine hooks (Injection route)
    merge_script = <<~'PY'
      import datetime, json, os, shutil, sys, tempfile

      path, command = sys.argv[1], sys.argv[2]
      interval = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

      os.makedirs(os.path.dirname(path), exist_ok=True)
      if not os.path.exists(path) or os.path.getsize(path) == 0:
          data = {}
      else:
          try:
              with open(path) as f:
                  data = json.load(f)
          except (json.JSONDecodeError, OSError):
              data = {}

      desired = {"type": "command", "command": command, "enabled": True}
      if interval:
          desired["refreshInterval"] = int(interval)

      existing = data.get("statusLine")
      if isinstance(existing, dict) and all(existing.get(k) == v for k, v in desired.items()):
          sys.exit(0)

      is_ours = (
          isinstance(existing, dict)
          and existing.get("type") == "command"
          and isinstance(existing.get("command", ""), str)
          and "QuotaPeek" in existing.get("command", "")
      )

      if "statusLine" in data and not is_ours:
          backup = path + ".bak." + datetime.datetime.now().strftime("%Y%m%dT%H%M%S%f")
          shutil.copy2(path, backup)

      data["statusLine"] = desired
      fd, tmp = tempfile.mkstemp(prefix=".settings-", dir=os.path.dirname(path))
      try:
          with os.fdopen(fd, "w") as f:
              json.dump(data, f, indent=2)
              f.write("\n")
              f.flush()
              os.fsync(f.fileno())
          os.replace(tmp, path)
      finally:
          if os.path.exists(tmp):
              os.unlink(tmp)
    PY

    claude_detected = which("claude") ||
                      system_command("/bin/zsh", args: ["-l", "-c", "command -v claude"], must_succeed: false).success? ||
                      File.exist?("#{Dir.home}/.local/bin/claude") ||
                      File.exist?("/opt/homebrew/bin/claude") ||
                      File.exist?("/usr/local/bin/claude")
    if claude_detected
      claude_settings = "#{Dir.home}/.claude/settings.json"
      claude_hook = "\"#{python3}\" \"#{bin_dir}/claude-statusline-hook.py\""
      system_command python3, args: ["-c", merge_script, claude_settings, claude_hook, "3"], must_succeed: false
    end

    antigravity_detected = system_command("security", args: ["find-generic-password", "-s", "gemini", "-a", "antigravity"], must_succeed: false).success?
    if antigravity_detected
      ag_settings = "#{Dir.home}/.gemini/antigravity-cli/settings.json"
      ag_hook = "\"#{python3}\" \"#{bin_dir}/antigravity-statusline-hook.py\""
      system_command python3, args: ["-c", merge_script, ag_settings, ag_hook], must_succeed: false
    end
  end

  uninstall launchctl: [
              "com.quotapeek.daemon",
              "com.quotapeek.app",
            ],
            delete:    [
              "#{Dir.home}/Library/LaunchAgents/com.quotapeek.daemon.plist",
              "#{Dir.home}/Library/LaunchAgents/com.quotapeek.app.plist",
            ]

  zap script: {
        executable: "/bin/bash",
        args:       [
          "-c",
          <<~'BASH',
            python3 - "$HOME/.claude/settings.json" "$HOME/.gemini/antigravity-cli/settings.json" <<'PY'
import glob, json, os, sys, tempfile

for path in sys.argv[1:]:
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        continue
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        continue

    existing = data.get("statusLine")
    if existing is None:
        continue

    is_ours = (
        isinstance(existing, dict)
        and existing.get("type") == "command"
        and isinstance(existing.get("command", ""), str)
        and "QuotaPeek" in existing.get("command", "")
    )
    if not is_ours:
        continue

    backups = sorted(glob.glob(path + ".bak.*"))
    restored = False
    if backups:
        latest_backup = backups[-1]
        try:
            with open(latest_backup) as bf:
                backup_data = json.load(bf)
            backup_sl = backup_data.get("statusLine")
            if backup_sl is not None:
                data["statusLine"] = backup_sl
                restored = True
            else:
                del data["statusLine"]
                restored = True
        except (json.JSONDecodeError, OSError):
            pass

    if not restored:
        del data["statusLine"]

    try:
        fd, tmp = tempfile.mkstemp(prefix=".settings-", dir=os.path.dirname(path))
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
PY
          BASH
        ],
        must_succeed: false,
      },
      trash:  "#{Dir.home}/Library/Application Support/QuotaPeek"
end
