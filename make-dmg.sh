#!/usr/bin/env bash
# Package build/oort.app into a distributable build/oort-<version>.dmg with
# the usual drag-to-Applications layout. Build the .app first (./make-app.sh).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/oort.app"
[ -d "$APP" ] || ./make-app.sh >/dev/null
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="build/oort-$VER.dmg"
STAGE="build/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> creating $DMG"
# Explicit size: hdiutil's auto-sizing under-allocates when the app contains
# APFS clonefiles (the bundled docker tarball) — "No space left on device".
SZ_MB=$(( $(du -sm "$STAGE" | cut -f1) + 64 ))
hdiutil create -volname "Oort $VER" -srcfolder "$STAGE" -ov -format UDZO -size "${SZ_MB}m" -quiet "$DMG"
rm -rf "$STAGE"
echo "done: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "note: unsigned/unnotarized DMGs trip Gatekeeper — see docs/packaging.md."
