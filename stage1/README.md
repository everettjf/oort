<div align="center">

# 🛰️ openorb

**A tiny, working OrbStack-style Docker & Linux runtime for macOS — in Swift + Go.**

Boots a lightweight Linux VM with Apple's `Virtualization.framework`, projects the
Docker engine onto a macOS Unix socket over `virtio-vsock`, shares files via VirtioFS,
runs x86-64 images through Rosetta, and forwards container ports to `localhost` —
driven by an `orb` CLI. No Docker Desktop.

</div>

---

## What works today (v0.1.0)

| Stage | Feature | Status |
|------:|---------|--------|
| 1 | Boot a Linux VM (VZ) and project the Docker socket over vsock | ✅ verified |
| 2 | VirtioFS file sharing (`/mnt/mac`) + Rosetta x86-64 | ✅ verified |
| 3 | Auto-forward container ports to macOS `localhost` | ✅ verified |
| 4 | `orb` CLI (start/stop/exec/docker), zram swap | ✅ verified¹ |

All verified on **macOS 26.3, Apple Silicon**, talking to the project's own daemon:

```text
orb start                       → Docker up (27.3.1 linux/arm64)
docker run --rm hello-world     → "Hello from Docker!"
docker run -v /mnt/mac:/m …     → reads/writes macOS files (VirtioFS, both ways)
docker run --platform linux/amd64 alpine uname -m  → x86_64   (Rosetta)
docker run -p 8088:80 …  →  curl localhost:8088    → reaches the container
orb exec 'uname -a'             → runs inside the guest
```

¹ zram needs a kernel with the `zram` module; the stock Ubuntu cloud kernel lacks it,
so that service no-ops (see *Known limitations*).

---

## Architecture

```
   ┌─ macOS ───────────────────────────────────┐        ┌─ Linux VM (Virtualization.framework) ─┐
   │  docker CLI / orb                          │        │  openorb-guest (Go):                  │
   │     │ DOCKER_HOST=unix://~/.openorb/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec (orb exec)       │
   │  openorb (Swift)                            │◀──────▶│    vsock 2377 → tcp forward           │
   │   ├─ VZ VM control                          │        │  dockerd (static) + containerd        │
   │   ├─ DockerSocketProxy  (unix ⇄ vsock 2375) │        │  VirtioFS: /mnt/mac, /mnt/rosetta     │
   │   ├─ PortForwarder      (127.0.0.1:P ⇄ 2377)│        │  Rosetta binfmt_misc (x86-64)         │
   │   └─ VirtioFS / Rosetta / NAT devices        │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

The guest is a stock Ubuntu 24.04 cloud image, provisioned **apt-free** on first boot
(static Docker engine + the compiled `openorb-guest` agent, staged on the VirtioFS share).
See [`../orbstack-research.md`](../orbstack-research.md) for the deep dive this is based on.

## Requirements

- Apple Silicon Mac, **macOS 13+** (developed on 26.3)
- Swift toolchain, Go 1.21+ (`go` — for the guest agent), `qemu-img` (`brew install qemu`)

## Quick start

```bash
cd stage1

# one-time: fetch the Ubuntu arm64 cloud image
mkdir -p images
curl -fL -o images/noble-arm64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img

./orb build-image     # raw disk + cloud-init seed + compiled guest agent
./orb start           # boot; waits until Docker is ready, prints DOCKER_HOST

export DOCKER_HOST=unix://$HOME/.openorb/docker.sock
docker run --rm hello-world
# …or: orb docker run --rm hello-world

orb status            # VM + Docker status
orb exec 'uname -a'   # run a command in the guest
orb stop
```

## `orb` commands

```
orb start | stop | restart        VM lifecycle
orb status                        VM / Docker status
orb exec <cmd...>                 run a command in the guest (vsock agent)
orb shell                         line-at-a-time guest shell
orb docker <args...>              docker against the openorb daemon
orb env                           print `export DOCKER_HOST=…`
orb logs                          tail the guest console
orb build-image                   (re)build disk + seed + guest agent
```

## `openorb run` flags (the engine `orb` drives)

```
--disk <path> --seed <path>       boot disk + cloud-init seed
--mount <hostdir>[:tag][:ro]      VirtioFS share (default tag: mac → /mnt/mac)
--rosetta                         share Rosetta for x86-64 translation
--forward <sock>:<port>           extra host-socket ⇄ guest-vsock-port
--no-port-forward                 disable localhost port forwarding
--cpus <n> --memory <GiB>         resources
--console-log <path>              guest console to a file (headless)
```

## Project layout

| Path | Role |
|------|------|
| `Sources/openorb/VMConfig.swift` | builds the `VZVirtualMachineConfiguration` (block/net/vsock/fs/rosetta) |
| `Sources/openorb/VMManager.swift` | VM lifecycle on the VZ serial queue |
| `Sources/openorb/DockerSocketProxy.swift` | host Unix socket ⇄ guest vsock tunnel |
| `Sources/openorb/PortForwarder.swift` | watch Docker, forward published ports to localhost |
| `Sources/openorb/Config.swift` / `main.swift` | CLI parsing / entry point |
| `guest-agent/main.go` | compiled guest agent: docker bridge + exec + tcp-forward |
| `cloud-init/` | apt-free first-boot provisioning |
| `orb` | the command-line front-end |
| `make-image.sh` | build disk + seed + cross-compile the guest agent |

## Known limitations

- **zram**: the stock Ubuntu cloud kernel ships without the `zram` module, so the swap
  service no-ops. OrbStack ships a custom kernel with it built in — that's a Stage 5 item.
- **Dynamic memory**: the VirtIO balloon device is attached, but active ballooning
  (grow/reclaim on demand) isn't wired yet.
- **Provisioning**: first boot installs Docker (~seconds when the CDN/mirror is fast).
  Reusing a provisioned disk boots in a couple of seconds.
- **Single VM**: one shared-kernel VM (like WSL2 / OrbStack); multi-"machine" support is future.

## Roadmap (Stage 5+)

- Custom Linux kernel (zram built-in, tuning) — the last big lever OrbStack pulls
- VirtioFS caching layer for native-speed bind mounts (OrbStack's real moat)
- Active memory ballooning; user-space netstack that follows macOS VPN/DNS
- Multiple named Linux machines; SwiftUI GUI

See [research report §4](../orbstack-research.md) for the full picture and which open-source
pieces (Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`) to borrow next.
