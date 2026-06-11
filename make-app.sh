#!/usr/bin/env bash
# Bundle the SwiftUI GUI into a proper oort.app so it runs as a real windowed
# Mac app (a bare executable with a WindowGroup doesn't reliably attach to the
# window server). Output: build/oort.app.
#
# Signing: ad-hoc by default; set CODESIGN_IDENTITY="Developer ID Application: …"
# for a distributable signature (then notarize — see docs/packaging.md).
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"

swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)/oort-gui"
APP="build/oort.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/oort-gui"

# Bake OORT_HOME (this repo) into the bundle so the GUI finds the `oort` CLI +
# engine even when the .app is dragged to /Applications. LaunchServices passes
# LSEnvironment to the process on Finder/`open` launch.
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
  <key>CFBundleVersion</key><string>0.3.0</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>LSEnvironment</key><dict><key>OORT_HOME</key><string>$REPO</string></dict>
</dict>
</plist>
PLIST

IDENTITY="${CODESIGN_IDENTITY:--}"   # '-' = ad-hoc
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "built $APP (ad-hoc signed — local use; for distribution set CODESIGN_IDENTITY + notarize)"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "built $APP (signed: $IDENTITY — notarize with: xcrun notarytool submit, then xcrun stapler staple)"
fi
