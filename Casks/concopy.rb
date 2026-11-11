cask "concopy" do
  version "1.2.0"
  sha256 "b21300c96738e6d3ed1f91dd9e78868aa384bbd17fa7aa1288b731c0fff35d3c"

  url "https://github.com/bicsurf/concopy/releases/download/v#{version}/ConCopy-#{version}.dmg"
  name "ConCopy"
  desc "Clipboard manager nativo per macOS a latenza zero con sync iCloud Drive"
  homepage "https://github.com/bicsurf/concopy"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "ConCopy.app"

  zap trash: [
    "~/Library/Application Support/ConCopy",
    "~/Library/Caches/com.bicsurf.concopy",
    "~/Library/Preferences/com.bicsurf.concopy.plist",
  ]
end
