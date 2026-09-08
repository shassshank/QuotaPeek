# Homebrew Cask definition for AIUsageWidget.
#
# This file is intended to live in a separate tap repository:
#   homebrew-aiusagewidget/Casks/aiusagewidget.rb
#
# Users would install via:
#   brew tap <owner>/aiusagewidget
#   brew install --cask aiusagewidget
#
# This provides a free, familiar distribution + uninstall story via:
#   brew uninstall --cask aiusagewidget
cask "aiusagewidget" do
  version "1.0.0"
  sha256 :no_check  # TODO: pin SHA256 once first release is published

  url "https://github.com/<owner>/AIUsageWidget/releases/download/v#{version}/aiusagewidget-macos.tar.gz"
  name "AI Usage Widget"
  desc "macOS menu bar widget showing AI coding assistant usage and quotas"
  homepage "https://github.com/<owner>/AIUsageWidget"

  # The tarball is not a .app directly — it contains the app plus supporting
  # files.  We use an artifact block to place the .app and a postflight to
  # set up the daemon, hooks, and LaunchAgents.
  artifact "AIUsageWidget.app", target: "#{Dir.home}/Library/Application Support/AIUsageWidget/bin/AIUsageWidget.app"

  postflight do
    bin_dir = "#{Dir.home}/Library/Application Support/AIUsageWidget/bin"
    staged = staged_path.to_s

    # Copy daemon and supporting scripts
    FileUtils.mkdir_p(bin_dir)
    %w[
      aiusaged
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
    FileUtils.chmod(0o755, File.join(bin_dir, "aiusaged")) if File.exist?(File.join(bin_dir, "aiusaged"))

    # Install LaunchAgent plists from templates
    la_dir = "#{Dir.home}/Library/LaunchAgents"
    FileUtils.mkdir_p(la_dir)
    python3 = `which python3`.strip
    app_support = "#{Dir.home}/Library/Application Support/AIUsageWidget"

    %w[com.aiusagewidget.daemon com.aiusagewidget.app].each do |label|
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
              "com.aiusagewidget.daemon",
              "com.aiusagewidget.app",
            ],
            delete:    [
              "#{Dir.home}/Library/LaunchAgents/com.aiusagewidget.daemon.plist",
              "#{Dir.home}/Library/LaunchAgents/com.aiusagewidget.app.plist",
            ]

  zap trash: "#{Dir.home}/Library/Application Support/AIUsageWidget"
end
