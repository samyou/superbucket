# Homebrew cask. Put this file in a tap repo as Casks/superbucket.rb
# (e.g. github.com/<you>/homebrew-tap), then: brew install --cask <you>/tap/superbucket
cask "superbucket" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/<you>/superbucket/releases/download/v#{version}/SuperBucket-#{version}.dmg"
  name "SuperBucket"
  desc "Drag-and-drop uploader for Tigris object storage"
  homepage "https://github.com/<you>/superbucket"

  depends_on macos: ">= :sonoma"

  app "SuperBucket.app"

  zap trash: [
    "~/Library/Preferences/com.superbucket.app.plist",
  ]
end
