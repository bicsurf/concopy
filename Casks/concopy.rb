cask "concopy" do
  version "1.2.2"
  sha256 "ca2aee3094860d3a6896267f7afc12ddba530cacd2b2ea7c5f9fb1f2b8ad34f0"

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
