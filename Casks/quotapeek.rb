# Homebrew Cask definition for QuotaPeek.
#
# This file is intended to live in a separate tap repository:
#   homebrew-quotapeek/Casks/quotapeek.rb
#
# Users would install via:
#   brew tap <owner>/quotapeek
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

  url "https://github.com/<owner>/QuotaPeek/releases/download/v#{version}/quotapeek-macos.tar.gz"
  name "QuotaPeek"
  desc "macOS menu bar widget showing AI coding assistant usage and quotas"
  homepage "https://github.com/<owner>/QuotaPeek"

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
    app_support = "#{Dir.home}/Library/Application Support/QuotaPeek"

    %w[com.quotapeek.daemon com.quotapeek.app].each do |label|
      template = File.join(staged, "#{label}.plist.template")
      next unless File.exist?(template)

      content = File.read(template)
        .gsub("__PYTHON3__", python3)
        .gsub("__BIN_DIR__", bin_dir)
        .gsub("__HOME__", Dir.home)
        .gsub("__APP_SUPPORT__", app_support)
      dest = File.join(la_dir, "#{label}.plist")
      system_command "/usr/bin/true", args: [] # ensure previous is unloaded
      system_command "launchctl", args: ["unload", dest], must_succeed: false if File.exist?(dest)
      File.write(dest, content)
      system_command "launchctl", args: ["load", dest]
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

  zap trash: "#{Dir.home}/Library/Application Support/QuotaPeek"
end
