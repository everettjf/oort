#!/usr/bin/env bash
# bench.sh — a small performance baseline for openorb.
#
# Measures the dimensions that matter most (and where OrbStack's moat is):
#   - VirtioFS throughput (host-backed /mnt/mac) vs the guest's own ext4 disk
#   - VirtioFS small-file overhead (the FUSE per-call weak spot)
#   - Docker run latency
#
# Filesystem tests run directly in the guest via `oorb exec` (Ubuntu's GNU
# coreutils → accurate rates and nanosecond timing, no container-startup noise).
# Requires the VM to be started:  ./oorb start && ./bench.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ORB="$HERE/oorb"
SIZE_MB="${SIZE_MB:-512}"
SMALL_N="${SMALL_N:-3000}"

gx() { "$ORB" exec "$@"; }
rate() { grep -oiE '[0-9.]+ ?[kmg]?b/s' | tail -1 || true; }

echo "==> checking VM…"
"$ORB" status | sed 's/^/    /'
gx "mkdir -p /mnt/mac/.bench /var/tmp/.bench" >/dev/null

echo
echo "════════════════════════════════════════════════════════"
echo " openorb benchmark  (size=${SIZE_MB}MB, small-files=${SMALL_N})"
echo " VirtioFS = host-backed /mnt/mac   ·   baseline = guest ext4 /var/tmp"
echo "════════════════════════════════════════════════════════"

echo
echo "── Sequential write ──────────────────────────────────────"
vfs_w=$(gx "dd if=/dev/zero of=/mnt/mac/.bench/w.bin bs=1M count=$SIZE_MB conv=fsync 2>&1" | rate)
loc_w=$(gx "dd if=/dev/zero of=/var/tmp/.bench/w.bin bs=1M count=$SIZE_MB conv=fsync 2>&1" | rate)
printf "  VirtioFS : %s\n" "${vfs_w:-n/a}"
printf "  guest fs : %s   (baseline)\n" "${loc_w:-n/a}"

echo
echo "── Sequential read (cold cache) ──────────────────────────"
vfs_r=$(gx "sync; echo 3 > /proc/sys/vm/drop_caches; dd if=/mnt/mac/.bench/w.bin of=/dev/null bs=1M 2>&1" | rate)
loc_r=$(gx "sync; echo 3 > /proc/sys/vm/drop_caches; dd if=/var/tmp/.bench/w.bin of=/dev/null bs=1M 2>&1" | rate)
printf "  VirtioFS : %s\n" "${vfs_r:-n/a}"
printf "  guest fs : %s   (baseline)\n" "${loc_r:-n/a}"

echo
echo "── Small files: create $SMALL_N files (VirtioFS per-call cost) ──"
sf() { gx "d=$1; rm -rf \$d; mkdir -p \$d; t=\$(date +%s%N); i=0; while [ \$i -lt $SMALL_N ]; do echo x > \$d/\$i; i=\$((i+1)); done; echo \$(( (\$(date +%s%N) - t) / 1000000 ))ms"; }
vfs_sf=$(sf "/mnt/mac/.bench/sf" | tail -1)
loc_sf=$(sf "/var/tmp/.bench/sf" | tail -1)
printf "  VirtioFS : %s   (FUSE per-call overhead)\n" "${vfs_sf:-n/a}"
printf "  guest fs : %s   (baseline)\n" "${loc_sf:-n/a}"

echo
echo "── Docker run latency (warm, alpine true ×5) ─────────────"
gx "docker image inspect alpine >/dev/null 2>&1 || docker pull alpine >/dev/null 2>&1" >/dev/null
lat=$(gx "t=\$(date +%s%N); for i in 1 2 3 4 5; do docker run --rm alpine true; done; echo \$(( (\$(date +%s%N) - t) / 5000000 ))ms/run" | tail -1)
printf "  %s\n" "${lat:-n/a}"

gx "rm -rf /mnt/mac/.bench /var/tmp/.bench" >/dev/null 2>&1 || true
echo
echo "════════════════════════════════════════════════════════"
echo "Tip: re-run after tuning the VirtioFS cache mode / kernel to compare."
