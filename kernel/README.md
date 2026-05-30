# Custom kernel (M2)

oort can direct-kernel-boot via VZ's `VZLinuxBootLoader` instead of going
through EFI + GRUB. Two kernels are supported, both with an automatic EFI
fallback (`OORT_BOOT=efi oort start`) so the VM can never end up unbootable.

## Stock direct-boot (default)

`oort build-image` stages the guest's own kernel — decompresses its `Image` and
copies its `initrd` into `images/` — and `oort start` boots them directly. This
skips the firmware/bootloader stage. `root=/dev/vda1`, `console=hvc0`.

## Custom minimal kernel (opt-in) — `oort build-kernel`

`oort build-kernel` builds a **minimal monolithic** arm64 kernel *inside the
guest* (native build — no macOS cross-compile pain) via
[`build-in-guest.sh`](./build-in-guest.sh), then installs it as
`images/kernel-Image` and removes the initrd. Because it's monolithic
(`CONFIG_MODULES` off — everything oort/Docker need is `=y`), it boots with
**no initramfs** straight to `root=/dev/vda1`, is smaller than the stock kernel,
and has **zram built in**.

```bash
oort start          # VM up (stock direct-boot)
oort build-kernel   # ~20-40 min the first time (cached source after)
oort restart        # now booting the custom kernel
oort exec uname -r  # → the custom version (e.g. 6.6.x)
```

### What's in it

`build-in-guest.sh` starts from `arm64 defconfig`, disables loadable modules
(monolithic), **strips whole subsystems a virtio-only VZ guest never has** (GPU/DRM,
sound, USB, wireless/BT, media, MMC/MTD, RAID/IB, HID, hwmon/thermal/cpufreq/
watchdog, real-NIC vendor drivers, ATA/NVME, unused filesystems — Image 74 MB →
41 MB, ~1.5 s less udev coldplug), and force-enables everything the stack needs
**built-in**:

- virtio: blk, net, console, balloon, **vsock**, **virtio-fs** (+ FUSE)
- filesystems: ext4, overlayfs, tmpfs
- **zram** + zsmalloc (compressed swap, no module needed)
- **binfmt_misc** (Rosetta x86-64 translation)
- container networking: bridge, veth, vxlan, **nftables** (`NFT_COMPAT` — Ubuntu's
  iptables-nft backend), legacy iptables, conntrack, NAT/MASQUERADE, br_netfilter
- namespaces, cgroups (+ BPF), seccomp — the full Docker surface

The build **hard-gates** on a list of must-be-builtin options: if any isn't `=y`
it fails *at build time* with the offending names, rather than surfacing later as
a cryptic dockerd error. (`CONFIG_MODULES` off is what makes `--enable` reliably
mean `=y`: with modules on, a module `select` kept demoting symbols like
`BRIDGE`/`ZRAM` back to `=m`.)

### Reverting

- `OORT_BOOT=efi oort start` — boot via EFI once (always works).
- `oort build-image` — re-stage the stock kernel as the direct-boot kernel.

### Notes

- The kernel source (~1.5 GB) lives in the guest's working disk, not the golden;
  `oort reset` clears it. Re-running `build-kernel` reuses the cached source.
- `KVER=<x.y.z> oort exec …` isn't how you pick the version — edit `KVER` at the
  top of `build-in-guest.sh` (default a 6.6 LTS).
