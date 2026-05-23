#!/usr/bin/env bash
# Prepare a bootable guest for openorb Stage 1:
#   1. convert the Ubuntu cloud image (qcow2) to raw (VZ needs raw)
#   2. grow it so there's room for Docker
#   3. build a cloud-init NoCloud seed image (CIDATA) that installs Docker + socat
#
# Prereqs: qemu-img (brew install qemu), hdiutil (built in).
set -euo pipefail
cd "$(dirname "$0")"

SRC="${SRC:-images/noble-arm64.img}"     # downloaded qcow2 cloud image
DISK="${DISK:-images/disk.img}"           # raw boot disk we produce
SEED="${SEED:-images/seed.img}"           # cloud-init CIDATA image
SIZE="${SIZE:-12G}"

[ -f "$SRC" ] || { echo "missing $SRC — download the Ubuntu arm64 cloud image first"; exit 1; }

echo "==> build openorb-guest (Go, linux/arm64) into the share"
mkdir -p share
( cd guest-agent && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOFLAGS=-mod=mod \
    go build -ldflags="-s -w" -o ../share/openorb-guest . )

echo "==> convert qcow2 → raw"
qemu-img convert -f qcow2 -O raw "$SRC" "$DISK"

echo "==> grow raw disk to $SIZE"
qemu-img resize -f raw "$DISK" "$SIZE"

echo "==> build cloud-init seed (CIDATA)"
rm -f "$SEED"
hdiutil makehybrid -iso -joliet \
  -default-volume-name CIDATA \
  -o "$SEED" cloud-init
# makehybrid appends .iso → normalise the name
[ -f "${SEED}.iso" ] && mv -f "${SEED}.iso" "$SEED"

echo "==> done"
ls -lh "$DISK" "$SEED"
