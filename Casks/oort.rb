# Homebrew cask for oort's GUI, published from the v0.1.0 GitHub release
# (a Developer ID-signed, notarized + stapled DMG — see docs/packaging.md).
#
# NOTE: today's .app is a front-end that drives a *local* oort install — it
# bakes OORT_HOME to the repo it was built from, so after `brew install` you
# still need that repo cloned and a golden image built (`oort build-image`).
# A fully self-contained app is on the roadmap (docs/packaging.md).
cask "oort" do
  version "0.1.0"
  sha256 "fbcdfae0b0156750cc340a58d1f0f294c57826ec478931af416dae1cbe54f970"

  url "https://github.com/everettjf/oort/releases/download/v#{version}/oort-#{version}.dmg"
  name "oort"
  desc "Lightweight, OrbStack-style Docker & Linux runtime for macOS"
  homepage "https://github.com/everettjf/oort"

  depends_on macos: ">= :ventura"
  app "oort.app"
end
