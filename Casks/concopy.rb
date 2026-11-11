cask "concopy" do
  version "1.2.1"
  sha256 "e650f3c5f582f1963490a895539df395bc47ce23e10e3301fe8d06b6cd9f764a"

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
