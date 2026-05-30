#!/usr/bin/env bash
# Build, codesign with the virtualization entitlement (required — VZ refuses to
# run otherwise), then launch. All extra args are forwarded to the binary.
#
#   ./run.sh run --disk ./images/ubuntu.img --cpus 4 --memory 4
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-debug}"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/oort"
echo "==> codesign (ad-hoc) with $PWD/oort.entitlements"
codesign --force --sign - --entitlements ./oort.entitlements "$BIN"

echo "==> launch: $BIN $*"
exec "$BIN" "$@"
