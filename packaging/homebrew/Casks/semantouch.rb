# frozen_string_literal: true

# Homebrew cask template for the canonical immutable Semantouch.app ZIP.
# Canonical template path: packaging/homebrew/semantouch.rb.in
# Placeholders are substituted by .github/workflows/homebrew.yml at publish time:
#   @VERSION@  - package version (no leading v); strict semver only
#   @SHA256@   - SHA-256 of Semantouch-vVERSION-macos-universal2.zip
#
# The cask installs the whole signed app bundle only. It never mutates nested
# Mach-Os or re-signs the app.
cask "semantouch" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/watzon/semantouch/releases/download/v#{version}/Semantouch-v#{version}-macos-universal2.zip"
  name "Semantouch"
  desc "Native macOS computer-use MCP server (signed Semantouch.app host + stdio relay)"
  homepage "https://github.com/watzon/semantouch"

  depends_on macos: ">= :sonoma"

  app "Semantouch.app"

  # Public stdio relay path inside the installed app.
  binary "#{appdir}/Semantouch.app/Contents/MacOS/semantouch", target: "semantouch"

  zap trash: [
    "~/Library/Preferences/tech.watzon.semantouch.plist",
    "~/Library/Caches/tech.watzon.semantouch",
  ]
end
