# Homebrew cask stub for oort's GUI. Publish a notarized DMG as a GitHub
# release asset (see docs/packaging.md), then fill in the version + sha256.
#
# Until oort ships a fully self-contained app (see docs/packaging.md "Path to a
# fully standalone app"), this distributes the GUI front-end; the engine still
# needs a local install. Provided as a template for when that lands.
cask "oort" do
  version "0.1.0"
  sha256 :no_check # replace with the notarized DMG's sha256

  url "https://github.com/everettjf/oort/releases/download/v#{version}/oort-#{version}.dmg"
  name "oort"
  desc "Lightweight, OrbStack-style Docker & Linux runtime for macOS"
  homepage "https://github.com/everettjf/oort"

  depends_on macos: ">= :ventura"
  app "oort.app"
end
