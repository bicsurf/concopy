cask "concopy" do
  version "1.2.2"
  sha256 "3ac8c21f7719e4b9331341b0029607516569e122b3a9c4cbba80df7429ed107b"

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
