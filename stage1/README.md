<div align="center">

# 🛰️ openorb — Stage 1

**A tiny OrbStack-style runtime in ~600 lines of Swift.**

Boot a Linux VM with Apple's `Virtualization.framework`, then make the **stock `docker` CLI on macOS** talk to the Docker engine *inside* the VM — over a `virtio-vsock` tunnel, no TCP, no Docker Desktop.

</div>

---

## What it does

```
   ┌─ macOS ──────────────────────────────────┐        ┌─ Linux VM (Virtualization.framework) ─┐
   │                                           │        │                                       │
   │  docker CLI                               │        │   socat ──► /run/docker.sock          │
   │     │ DOCKER_HOST=unix://~/.openorb/...   │        │     ▲              │                  │
   │     ▼                                     │ vsock  │     │              ▼                  │
   │  ~/.openorb/docker.sock ──► openorb ──────┼────────┼─► VSOCK-LISTEN   dockerd              │
   │                          (DockerSocketProxy)        │      :2375                            │
   └───────────────────────────────────────────┘        └───────────────────────────────────────┘
```

This is the same backbone OrbStack / Lima / Colima use, distilled to its essence so every moving part is visible. See the [research report](../orbstack-research.md) for the full picture and roadmap.

### ✔ Verified end-to-end on a real machine (macOS 26.3, Apple Silicon)

```text
$ export DOCKER_HOST=unix://~/.openorb/docker.sock
$ docker version
  Server: Docker 29.1.3 | API 1.52 | linux/arm64      ← running inside the VM
$ docker run --rm hello-world
  Hello from Docker!                                   ← pulled from Docker Hub, ran an arm64 container
```

The full path was exercised: macOS `docker` CLI → `~/.openorb/docker.sock` → `openorb` (Swift, VZ) → **vsock** → guest `socat` → `dockerd` → container.

> ⏱️ **First boot provisions itself** (cloud-init installs Docker + socat).
> On a fresh image this takes a couple of minutes; later boots are instant.

---

## Requirements

- Apple Silicon Mac, **macOS 13+** (tested on 26.3)
- Swift toolchain — `swift --version`
- `qemu-img` to convert the cloud image — `brew install qemu`

---

## Quick start

```bash
cd stage1

# 1. Get an Ubuntu arm64 cloud image (~600 MB)
mkdir -p images
curl -fL -o images/noble-arm64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img

# 2. Build the boot disk (raw) + cloud-init seed that installs Docker
./make-image.sh

# 3. Boot the VM and project the Docker socket
./run.sh run --disk images/disk.img --seed images/seed.img

# 4. In another terminal — point Docker at the projected socket
export DOCKER_HOST="unix://$HOME/.openorb/docker.sock"
docker version      # may take a few minutes on the very first boot
docker run --rm hello-world
```

`run.sh` builds, **codesigns the binary with the `com.apple.security.virtualization` entitlement** (VZ refuses to launch without it), then starts the VM. Press **Ctrl-C** for a clean guest shutdown.

> 💡 The very first `docker` call waits for cloud-init to finish installing Docker.
> Watch progress with: `tail -f images/console.log`

---

## How it works

1. **`make-image.sh`** converts the qcow2 cloud image to **raw** (VZ needs raw), grows it to 12 GB, and builds a **cloud-init NoCloud seed** (`CIDATA`) from [`cloud-init/`](cloud-init/). On first boot cloud-init reads the seed and installs `docker.io` + `socat`, then enables a unit that does:
   ```
   socat VSOCK-LISTEN:2375,fork,reuseaddr UNIX-CONNECT:/run/docker.sock
   ```
2. **`openorb` (Swift)** builds a `VZVirtualMachineConfiguration` — virtio block (boot disk + seed), virtio-net (NAT), **virtio-vsock**, entropy, balloon, console — and starts the VM on the queue VZ requires.
3. **`DockerSocketProxy`** listens on a macOS `AF_UNIX` socket. For each client it opens a host→guest **vsock** connection to port `2375` and splices the two file descriptors. Result: the unmodified `docker` CLI thinks it's talking to a local daemon.

---

## Usage reference

```
openorb run --disk <path> [options]

  --disk <path>            Bootable raw disk image (required)
  --seed <path>            Extra read-only disk (cloud-init CIDATA image)
  --nvram <path>           EFI variable store (default: <disk>.nvram)
  --kernel/--initrd/--cmdline   Direct kernel boot instead of EFI

  --cpus <n>               vCPU count (default: 4)
  --memory <GiB>           Memory in GiB (default: 4)

  --vsock-port <n>         Guest vsock port serving dockerd (default: 2375)
  --socket <path>          Host Unix socket (default: ~/.openorb/docker.sock)

  --no-console             Don't attach the guest console to stdio
  --console-log <path>     Write the guest console to a file (headless)
```

---

## Project layout

| Path | Role |
|------|------|
| `Sources/openorb/Config.swift` | CLI flag parsing (zero dependencies) |
| `Sources/openorb/VMConfig.swift` | builds the `VZVirtualMachineConfiguration` |
| `Sources/openorb/VMManager.swift` | VM lifecycle, pinned to the VZ serial queue |
| `Sources/openorb/DockerSocketProxy.swift` | `AF_UNIX` ⇄ vsock fd splice |
| `Sources/openorb/main.swift` | entry point, SIGINT handling, run loop |
| `openorb.entitlements` | the one entitlement VZ needs |
| `make-image.sh` | qcow2→raw + resize + build cloud-init seed |
| `cloud-init/` | NoCloud `user-data` / `meta-data` (installs Docker + socat) |
| `guest/` | the vsock→docker.sock systemd unit (also baked by cloud-init) |
| `run.sh` | build + codesign + launch |

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker` hangs on first boot | cloud-init is still installing Docker. Wait a couple of minutes. |
| Provisioning stalls for many minutes | The VZ NAT resolver may return IPv6-only mirror addresses while the guest is IPv4-only, so `apt` times out. We force IPv4 in `cloud-init/user-data` (`Acquire::ForceIPv4`) — keep that if you regenerate the seed. |
| “VM failed to start … entitlement” | run via `./run.sh` (it codesigns with the virtualization entitlement). |
| `connection refused` on the socket | the VM exited — check `images/console.log`. |
| Want a guest shell | console login is `ubuntu` / `openorb` (set in `cloud-init/user-data`). |

---

## What this stage deliberately leaves out

The fast, magical parts of OrbStack are **not** here yet — that's the point of staging:

- **VirtioFS bind mounts** + the caching layer that makes them fast *(OrbStack's real moat)*
- **Custom user-space netstack** (port auto-forward, follow macOS VPN/DNS)
- **Rosetta** x86 emulation (`VZLinuxRosettaDirectoryShare`)
- **Dynamic memory** / zram, multi-machine namespacing, native GUI

See [research report §4](../orbstack-research.md) for the roadmap and which open-source pieces (Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`) to borrow next.
