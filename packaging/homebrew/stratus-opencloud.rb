# Homebrew cask for the tap repo tensarflow/homebrew-tap (Casks/stratus-opencloud.rb).
# On each release: set version and sha256 (printed by scripts/release.sh).
cask "stratus-opencloud" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/tensarflow/stratus-opencloud/releases/download/v#{version}/Stratus-#{version}.dmg"
  name "Stratus for OpenCloud"
  desc "On-demand Finder access to OpenCloud spaces"
  homepage "https://github.com/tensarflow/stratus-opencloud"

  depends_on macos: ">= :sonoma"

  app "Stratus.app"

  zap trash: [
    "~/Library/Containers/com.arteq.stratus",
    "~/Library/Containers/com.arteq.stratus.FileProvider",
    "~/Library/Group Containers/QBPWS3ADVD.com.arteq.stratus",
  ]
end
