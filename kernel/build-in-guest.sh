#!/bin/bash
# build-in-guest.sh — build a custom minimal monolithic arm64 kernel INSIDE the
# oort guest (per the plan: native build avoids macOS cross-compile pain).
#
# Produces an uncompressed arch/arm64/boot/Image with everything oort +
# Docker need built in (=y) and no modules — so VZ can direct-kernel-boot it with
# NO initramfs (root=/dev/vda1). Copies the Image to the VirtioFS share
# (/mnt/mac → the host's ./share) as kernel-Image-custom.
#
# Run it detached (it takes ~20-40 min):
#   systemd-run --unit=oort-kbuild --collect /bin/bash /mnt/mac/build-in-guest.sh
# Watch: tail -f /root/kbuild.log ; done marker: /root/kbuild-done (or -fail).
set -uo pipefail
exec >/root/kbuild.log 2>&1
rm -f /root/kbuild-done /root/kbuild-fail
echo "=== START $(date -u) ==="
export DEBIAN_FRONTEND=noninteractive
fail() { echo "FAIL: $*"; touch /root/kbuild-fail; exit 1; }

VER="${KVER:-6.6.52}"

echo "--- apt build deps ---"
apt-get update -o Acquire::http::Timeout=30 || fail "apt update"
apt-get install -y --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev xz-utils wget ca-certificates kmod cpio || fail "apt install"

cd /root || fail "cd /root"
if [ ! -d "linux-$VER" ]; then
  echo "--- download linux-$VER ---"
  wget -q --timeout=120 "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz" || fail "download"
  tar xf "linux-$VER.tar.xz" || fail "untar"
fi
cd "linux-$VER" || fail "cd linux-$VER"

echo "--- base: arm64 defconfig ---"
make defconfig || fail "defconfig"

# Disable loadable-module support: this is a monolithic kernel with no initramfs,
# so there's nothing to load modules anyway. Crucially, it also collapses every
# tristate to y/n — eliminating the =m state that `make olddefconfig` was demoting
# our --enable'd options back to (a module symbol `select`ing e.g. BRIDGE forced
# it to =m, so it could never be built in). With MODULES off, --enable means =y.
./scripts/config --disable MODULES

echo "--- enable oort/Docker/virtio options (built-in) ---"
# Everything Docker + oort need, forced =y so the kernel is monolithic and
# needs no initramfs. defconfig already sets many; re-enabling is harmless, and
# olddefconfig drops anything not valid for this version.
ENABLE="
VIRTIO VIRTIO_PCI VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE VIRTIO_BALLOON VIRTIO_INPUT HW_RANDOM_VIRTIO
VSOCKETS VIRTIO_VSOCKETS
FUSE_FS VIRTIO_FS
DAX FS_DAX FUSE_DAX ZONE_DEVICE
EXT4_FS OVERLAY_FS TMPFS DEVTMPFS DEVTMPFS_MOUNT
ZRAM ZSMALLOC
BINFMT_MISC BINFMT_ELF
BRIDGE VETH TUN VLAN_8021Q
NAMESPACES UTS_NS IPC_NS USER_NS PID_NS NET_NS
CGROUPS CGROUP_PIDS CGROUP_BPF MEMCG CGROUP_SCHED CFS_BANDWIDTH BLK_CGROUP CGROUP_DEVICE CGROUP_FREEZER CGROUP_CPUACCT CPUSETS
NETFILTER NF_CONNTRACK NF_NAT NETFILTER_XTABLES NF_DEFRAG_IPV4 NF_DEFRAG_IPV6
NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MARK NETFILTER_XT_NAT
IP_NF_IPTABLES IP_NF_FILTER IP_NF_NAT IP_NF_TARGET_MASQUERADE IP_NF_MANGLE NF_NAT_MASQUERADE
IP6_NF_IPTABLES NF_CONNTRACK_NETLINK NETLINK_DIAG PACKET BRIDGE_NETFILTER
NETFILTER_NETLINK NF_TABLES NF_TABLES_INET NF_TABLES_IPV4 NF_TABLES_IPV6 NF_TABLES_NETDEV NF_TABLES_BRIDGE
NFT_CT NFT_NAT NFT_MASQ NFT_REDIR NFT_REJECT NFT_REJECT_INET NFT_COMPAT NFT_CHAIN_NAT NFT_LIMIT NFT_LOG NFT_FIB_INET
BPF BPF_SYSCALL
SECCOMP SECCOMP_FILTER POSIX_MQUEUE KEYS
EXT4_FS_POSIX_ACL EXT4_FS_SECURITY
VXLAN
"
# Apply twice with olddefconfig between: some tristate symbols default to =m and
# only stick at =y once their deps are also set, so a single pass can leave them
# =m (fatal for a monolithic, initramfs-less kernel — modules never load: this is
# why an earlier build left BRIDGE/ZRAM as =m and Docker failed to make docker0).
# Disable drivers that auto-create a network interface at boot — with MODULES off,
# defconfig's =m drivers become =y (built in), and DUMMY's dummy0 then sorts before
# enp0s1 and steals cloud-init's primary-NIC detection (→ no DHCP, no egress).
# Strip whole subsystems a VZ guest never has (it's virtio-only): no GPU/display,
# sound, USB, wireless/BT, media, MMC/MTD, RAID/IB, HID, hardware sensors/watchdog/
# thermal/cpufreq, real-NIC vendor drivers, ATA/NVME (disk is virtio-blk), and
# filesystems we don't use. Smaller Image + far less udev coldplug → faster boot.
# (DUMMY must go — its dummy0 steals cloud-init's primary-NIC pick → no egress.)
DISABLE="DUMMY
DRM FB SOUND SND USB_SUPPORT
WLAN WIRELESS WLAN_VENDOR_ATH CFG80211 MAC80211 BT RFKILL
MEDIA_SUPPORT MMC MTD INFINIBAND MD
HID_SUPPORT HWMON THERMAL CPU_FREQ WATCHDOG IIO PWM REGULATOR POWER_SUPPLY
ATA NVME_CORE SCSI_LOWLEVEL
NET_VENDOR_INTEL NET_VENDOR_BROADCOM NET_VENDOR_REALTEK NET_VENDOR_MELLANOX
NET_VENDOR_MICROSOFT NET_VENDOR_AMAZON NET_VENDOR_GOOGLE NET_VENDOR_AQUANTIA
BTRFS_FS XFS_FS F2FS_FS GFS2_FS JFS_FS REISERFS_FS NILFS2_FS NTFS3_FS OCFS2_FS
NFS_FS NFSD CIFS CEPH_FS
SOUND_PRIME DRM_NOUVEAU"
apply() {
  for o in $ENABLE;  do ./scripts/config --enable  "$o"; done
  for o in $DISABLE; do ./scripts/config --disable "$o"; done
}
apply; make olddefconfig || fail "olddefconfig"
apply; make olddefconfig || fail "olddefconfig"
# Hard gate: fail the BUILD (with the offending names) if any must-be-builtin
# option isn't =y — so a missing driver is caught here, not at docker boot.
MISS=""
for o in VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE VIRTIO_VSOCKETS VIRTIO_FS FUSE_FS \
         EXT4_FS OVERLAY_FS BINFMT_MISC ZRAM ZSMALLOC \
         BRIDGE VETH NF_TABLES NFT_COMPAT NFT_NAT NF_NAT NF_CONNTRACK \
         IP_NF_IPTABLES IP_NF_NAT NETFILTER_XT_MATCH_ADDRTYPE; do
  grep -q "^CONFIG_$o=y" .config || MISS="$MISS $o"
done
[ -n "$MISS" ] && fail "critical options not built-in (=y):$MISS"
echo "all critical options confirmed =y"

echo "--- moby check-config (informational) ---"
if wget -q --timeout=30 -O /root/check-config.sh \
     https://raw.githubusercontent.com/moby/moby/master/contrib/check-config.sh; then
  CONFIG=/root/linux-$VER/.config bash /root/check-config.sh || true
else
  echo "(check-config download skipped)"
fi

echo "--- build Image (j=$(nproc)) — the long part ---"
make -j"$(nproc)" Image || fail "make Image"

ls -l arch/arm64/boot/Image
cp arch/arm64/boot/Image /mnt/mac/kernel-Image-custom || fail "copy to share"
sync
echo "=== DONE $(date -u) — Image at /mnt/mac/kernel-Image-custom ==="
touch /root/kbuild-done
