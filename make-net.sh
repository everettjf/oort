#!/usr/bin/env bash
# Fetch the gvproxy (gvisor-tap-vsock) user-space netstack binary into bin/, used
# by `OORT_NET=gvproxy oort start`. Pinned to a known-good release; override
# with GVPROXY_VERSION. Downloaded, not vendored (it's a 24MB universal binary).
set -euo pipefail
cd "$(dirname "$0")"
VER="${GVPROXY_VERSION:-v0.8.9}"
URL="https://github.com/containers/gvisor-tap-vsock/releases/download/$VER/gvproxy-darwin"
mkdir -p bin
echo "==> fetching gvproxy $VER"
curl -fSL -o bin/gvproxy "$URL"
chmod +x bin/gvproxy
echo "==> $(bin/gvproxy -version 2>/dev/null | head -1 || echo "gvproxy installed")"
echo "done — use it with:  OORT_NET=gvproxy ./oort start"
