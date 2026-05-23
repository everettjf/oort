# openorb — Stage 1 skeleton

A minimal, dependency-free Swift program that does the two core things from the
[research report](../orbstack-research.md) §4.2 阶段一:

1. **Boots a Linux VM** with Apple's `Virtualization.framework` (virtio block /
   net / vsock / console).
2. **Projects the guest Docker socket** onto a macOS Unix socket over
   **virtio-vsock**, so the stock `docker` CLI works against it.

This is the same backbone OrbStack / Lima / Colima use. It is intentionally
small (~5 source files, no external packages) so every moving part is visible.

```
docker CLI ──unix──▶ ~/.openorb/docker.sock ──vsock──▶ [guest] socat ──▶ /run/docker.sock ──▶ dockerd
            (host: DockerSocketProxy)        (VZVirtioSocketDevice)        (guest setup, see below)
```

## Requirements

- Apple Silicon Mac, macOS 13+
- Swift toolchain (`swift --version`)
- A bootable **arm64 Linux raw disk image** with Docker installed (see below)

## 1. Get a guest image

The skeleton needs a disk image to boot. Easiest options:

- **Reuse what Lima/Colima already downloaded** (an Ubuntu cloud image), or
- Download an Ubuntu **arm64** cloud image and convert it to raw:

  ```bash
  mkdir -p images
  # qcow2 → raw (needs qemu-img: brew install qemu)
  qemu-img convert -f qcow2 -O raw ubuntu-24.04-arm64.qcow2 images/ubuntu.img
  # optionally grow it
  truncate -s 20G images/ubuntu.img
  ```

> Cloud images expect cloud-init for first-boot login. For a quick spike, a
> distro image you can already log into (console attached) is simplest. Direct
> kernel boot (`--kernel/--initrd`) is also supported if you have matching
> artifacts.

## 2. Inside the guest: install Docker + the vsock bridge

Boot once (console is attached to your terminal by default), log in, then:

```bash
# Docker engine
curl -fsSL https://get.docker.com | sh

# vsock → docker socket bridge
sudo apt-get install -y socat
sudo cp /path/to/openorb-docker-vsock.service /etc/systemd/system/
sudo systemctl enable --now openorb-docker-vsock.service
```

(`guest/openorb-docker-vsock.service` is included here — copy it into the VM.)

## 3. Run

```bash
./run.sh run --disk ./images/ubuntu.img --cpus 4 --memory 4
```

`run.sh` builds, **codesigns with the `com.apple.security.virtualization`
entitlement** (VZ refuses to launch without it), then starts the VM. Once up:

```bash
export DOCKER_HOST=unix://$HOME/.openorb/docker.sock
docker ps
docker run --rm hello-world
```

Press **Ctrl-C** to request a clean guest shutdown.

## Files

| File | Role |
|------|------|
| `Sources/openorb/Config.swift` | CLI flag parsing |
| `Sources/openorb/VMConfig.swift` | builds the `VZVirtualMachineConfiguration` (all devices) |
| `Sources/openorb/VMManager.swift` | VM lifecycle on the VZ serial queue |
| `Sources/openorb/DockerSocketProxy.swift` | AF_UNIX listener ⇄ vsock fd splice |
| `Sources/openorb/main.swift` | entry point, SIGINT handling, run loop |
| `openorb.entitlements` | the one entitlement VZ needs |
| `guest/openorb-docker-vsock.service` | guest-side socat bridge |

## What this skeleton deliberately leaves out (later stages)

- **VirtioFS bind mounts** + the caching layer that makes them fast (OrbStack's moat)
- **Custom user-space netstack** (port auto-forward, follow macOS VPN/DNS)
- **Rosetta** x86 emulation (`VZLinuxRosettaDirectoryShare`)
- **Dynamic memory** tuning / zram, multi-machine namespacing, GUI

See the research report §4 for the full roadmap and which open-source pieces
(Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`) to borrow next.
