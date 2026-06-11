#!/usr/bin/env bash
# Bundle oort into a SELF-CONTAINED oort.app (M15): the GUI plus a complete
# oort home (CLI, prebuilt engine + guest agent, cloud-init, make-image) under
# Contents/Resources/oort-home. Installed from the dmg, it needs no repo
# clone: first `oort start` downloads the Ubuntu cloud image and builds the
# golden disk under ~/.oort (qemu-img via `brew install qemu` is the one
# external dependency).
#
# Signing: ad-hoc by default; set CODESIGN_IDENTITY="Developer ID Application: …"
# for a distributable signature (then notarize — see docs/packaging.md).
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"

swift build -c release >/dev/null
BINDIR="$(swift build -c release --show-bin-path)"
APP="build/oort.app"
HOMEDIR="$APP/Contents/Resources/oort-home"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$HOMEDIR/bin" "$HOMEDIR/share"
cp "$BINDIR/oort-gui" "$APP/Contents/MacOS/oort-gui"

# ---- the bundled oort home -------------------------------------------------
cp oort "$HOMEDIR/oort" && chmod +x "$HOMEDIR/oort"
cp "$BINDIR/oort" "$HOMEDIR/bin/oort-engine"
cp -R cloud-init "$HOMEDIR/cloud-init"
cp make-image.sh "$HOMEDIR/make-image.sh"
cp oort.example.yaml "$HOMEDIR/oort.example.yaml" 2>/dev/null || true
mkdir -p "$HOMEDIR/tools" "$HOMEDIR/mcp"
cp tools/oort-nethelper.sh "$HOMEDIR/tools/"
cp mcp/oort-mcp.py "$HOMEDIR/mcp/"
# Prebuilt guest agent (required — the app has no Go toolchain to build it).
if [ ! -f share/oort-guest ]; then
  ( cd guest-agent && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOFLAGS=-mod=mod \
      go build -ldflags="-s -w" -o ../share/oort-guest . )
fi
cp share/oort-guest "$HOMEDIR/share/oort-guest"
# Optional: a pre-staged docker tarball makes first-run provisioning fully
# deterministic (no in-guest CDN download). ~66MB; skip with OORT_APP_SLIM=1.
if [ -f share/docker-27.3.1.tgz ] && [ "${OORT_APP_SLIM:-0}" != 1 ]; then
  cp share/docker-27.3.1.tgz "$HOMEDIR/share/"
fi
touch "$HOMEDIR/.bundled"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Oort</string>
  <key>CFBundleDisplayName</key><string>Oort</string>
  <key>CFBundleIdentifier</key><string>dev.oort.gui</string>
  <key>CFBundleExecutable</key><string>oort-gui</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0.4.0</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# ---- signing (inner binaries first, then the bundle) -----------------------
IDENTITY="${CODESIGN_IDENTITY:--}"   # '-' = ad-hoc
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements oort.entitlements "$HOMEDIR/bin/oort-engine" >/dev/null 2>&1
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "built $APP (self-contained, ad-hoc signed — local use; for distribution set CODESIGN_IDENTITY + notarize)"
else
  codesign --force --options runtime --timestamp \
    --entitlements oort.entitlements --sign "$IDENTITY" "$HOMEDIR/bin/oort-engine"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "built $APP (self-contained, signed: $IDENTITY — notarize with: xcrun notarytool submit, then xcrun stapler staple)"
fi
