#!/usr/bin/env bash
# Prepare a bootable guest for oort Stage 1:
#   1. convert the Ubuntu cloud image (qcow2) to raw (VZ needs raw)
#   2. grow it so there's room for Docker
#   3. build a cloud-init NoCloud seed image (CIDATA) that installs Docker + socat
#
# Prereqs: qemu-img (brew install qemu), hdiutil (built in).
# All paths are overridable so the bundled oort.app can run this with its data
# under ~/.oort (SRC/DISK/SEED/SHARE).
set -euo pipefail
cd "$(dirname "$0")"

SRC="${SRC:-images/noble-arm64.img}"     # downloaded qcow2 cloud image
DISK="${DISK:-images/disk.img}"           # raw boot disk we produce
SEED="${SEED:-images/seed.img}"           # cloud-init CIDATA image
SHARE="${SHARE:-share}"                   # staging dir mounted into the guest
SIZE="${SIZE:-12G}"

[ -f "$SRC" ] || { echo "missing $SRC — download the Ubuntu arm64 cloud image first"; exit 1; }

mkdir -p "$SHARE" "$(dirname "$DISK")"
# Build the guest agent when a Go toolchain is around (repo checkout); the
# bundled app ships a prebuilt share/oort-guest instead.
if command -v go >/dev/null 2>&1 && [ -d guest-agent ]; then
  echo "==> build oort-guest (Go, linux/arm64) into the share"
  ( cd guest-agent && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOFLAGS=-mod=mod \
      go build -ldflags="-s -w" -o "$SHARE/oort-guest" . )
elif [ -f "$SHARE/oort-guest" ]; then
  echo "==> using prebuilt oort-guest from the share"
else
  echo "no Go toolchain and no prebuilt $SHARE/oort-guest — cannot continue"; exit 1
fi

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
