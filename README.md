<div align="center">

# 🛰️ openorb

**A lightweight, OrbStack-style Docker & Linux runtime for macOS — in Swift + Go.**

Boots a lightweight Linux VM with Apple's `Virtualization.framework`, then projects the
container engine, file sharing, x86 translation and port mapping onto macOS — no Docker Desktop.

<br/>

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20·%20Apple%20Silicon-black)](#-requirements)
[![Language](https://img.shields.io/badge/built%20with-Swift%20%2B%20Go-orange)](#-project-layout)
[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

**English** | [简体中文](./README.zh-CN.md)

[Quick start](#-quick-start) · [What it is](#-what-it-is) · [Architecture](#-architecture) · [Docs](#-documentation) · [Roadmap](#-roadmap)

</div>

---

## ✨ What it is

`openorb` is a **working**, slimmed-down OrbStack clone — a project that studies *why OrbStack is
fast and light* and reimplements the core mechanisms by hand.

One command to start, then the stock `docker` CLI just works:

```console
$ orb start
starting openorb VM…
waiting for Docker...... ready.
export DOCKER_HOST=unix:///Users/you/.openorb/docker.sock

$ docker run --rm hello-world
Hello from Docker!

$ docker run -p 8080:80 nginx     # then `curl localhost:8080` on macOS just works
$ docker run --platform linux/amd64 alpine uname -m     # x86_64 (via Rosetta)
$ orb exec 'uname -a'             # run a command inside the guest
```

### What works today, **verified on real hardware**

| Capability | What it does | Status |
|---|---|:---:|
| 🐳 **Docker over vsock** | VZ boots a Linux VM; dockerd is projected onto a macOS Unix socket via virtio-vsock | ✅ |
| 🌐 **Container networking** | dockerd manages iptables NAT — `docker build` (`RUN apk/npm/pip…`) and runtime egress work | ✅ |
| 📁 **File sharing** | Your Mac home is mirrored into the guest at the same path, so `docker -v $PWD:/app` just works | ✅ |
| 🧬 **Rosetta x86** | `linux/amd64` images run via Rosetta — far faster than QEMU | ✅ |
| 🔌 **Port forwarding** | Container-published ports appear automatically on macOS `localhost` (event-driven) | ✅ |
| 🧭 **Follows Mac DNS** | Guest/containers use the Mac's DNS resolvers — internal/VPN domains resolve | ✅ |
| 🛰️ **`orb` CLI** | Lifecycle, `orb exec`, docker passthrough, `orb autostart` at login | ✅ |
| 💾 **zram swap** | Wired up (needs a kernel with the zram module — see docs) | ⚠️ |

> All verified on **macOS 26.3 / Apple Silicon**, against the project's own daemon.

---

## 🚀 Quick start

```bash
# Deps: Swift toolchain, Go 1.21+, qemu-img (brew install qemu)

# 1. Fetch the Ubuntu 24.04 arm64 cloud image (one-time)
mkdir -p images
curl -fL -o images/noble-arm64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img

# 2. Build the boot disk + cloud-init seed + compiled guest agent
./orb build-image

# 3. Start (waits until Docker is ready, prints DOCKER_HOST)
./orb start

# 4. Use it
export DOCKER_HOST=unix://$HOME/.openorb/docker.sock
docker run --rm hello-world
orb status
orb stop
```

See **[docs/quickstart.md](./docs/quickstart.md)** for the detailed walkthrough.

---

## 🧭 Architecture

```
   ┌─ macOS (host) ─────────────────────────────┐        ┌─ Linux VM (Virtualization.framework) ─┐
   │  docker CLI / orb                          │        │  openorb-guest (Go binary):           │
   │     │ DOCKER_HOST=unix://~/.openorb/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec (orb exec)       │
   │  openorb (Swift)                            │◀──────▶│    vsock 2377 → tcp port-forward      │
   │   ├─ VZ VM control                          │        │  dockerd (static) + containerd        │
   │   ├─ DockerSocketProxy (unix ⇄ vsock 2375)  │        │  VirtioFS: /mnt/mac, /mnt/rosetta     │
   │   ├─ PortForwarder (127.0.0.1:P ⇄ 2377)     │        │  Rosetta binfmt_misc (x86-64)         │
   │   └─ VirtioFS / Rosetta / NAT devices        │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

The guest is a stock Ubuntu 24.04 cloud image, provisioned **without apt** on first boot
(static Docker engine + the compiled `openorb-guest` agent, staged on the VirtioFS share).

> Curious how OrbStack does it and how we cloned it? Read the deep-dive
> **[orbstack-research.md](./orbstack-research.md)** and **[docs/architecture.md](./docs/architecture.md)**.

---

## 📚 Documentation

| Doc | Contents |
|---|---|
| [Quick start](./docs/quickstart.md) · [中文](./docs/quickstart.zh-CN.md) | Install, first run, everyday use |
| [Architecture](./docs/architecture.md) · [中文](./docs/architecture.zh-CN.md) | How VZ / vsock / VirtioFS / Rosetta / port-forward / the Go agent work |
| [CLI reference](./docs/cli-reference.md) · [中文](./docs/cli-reference.zh-CN.md) | Every `orb` subcommand + all `openorb run` flags |
| [FAQ](./docs/faq.md) · [中文](./docs/faq.zh-CN.md) | Troubleshooting (DNS, zram, provisioning, coexisting with Docker Desktop) |
| [Research report](./orbstack-research.md) | OrbStack internals + clone roadmap (the project's origin) |

---

## 💻 Requirements

- Apple Silicon Mac, **macOS 13+** (developed on 26.3)
- Swift toolchain (`swift --version`)
- Go 1.21+ (to compile the guest agent)
- `qemu-img` (`brew install qemu`, to convert the cloud image)

---

## 🗂 Project layout

```
openorb/
├── Sources/openorb/         Swift: VM orchestration + socket proxy + port forwarding
│   ├── VMConfig.swift        builds the VZVirtualMachineConfiguration (all devices)
│   ├── VMManager.swift       VM lifecycle (pinned to the VZ serial queue)
│   ├── DockerSocketProxy.swift  host Unix socket ⇄ guest vsock tunnel
│   ├── PortForwarder.swift   watches Docker, forwards published ports to localhost
│   └── Config.swift / main.swift
├── guest-agent/main.go      guest agent (docker bridge + exec + tcp-forward; linux/arm64)
├── cloud-init/              apt-free first-boot provisioning
├── orb                      the command-line front-end
├── make-image.sh            build disk + seed + cross-compile the agent
└── orbstack-research.md     deep-dive research report
```

---

## ⚠️ Known limitations

- **Bind-mount small-file speed**: VirtioFS is ~21× slower than local disk for many small files
  (e.g. `npm install` on a mounted source). VZ exposes no cache tuning, so the real fix is a
  custom VirtioFS/DAX layer (Stage 5). Workaround: keep hot dirs in a named volume.
- **VPN**: DNS *resolution* follows the Mac, but VPN *traffic* routing needs a user-space netstack (future).
- **zram**: the stock Ubuntu cloud kernel ships without the `zram` module, so that service
  no-ops. OrbStack builds a custom kernel with it baked in — that's a Stage 5 item.
- **Dynamic memory**: the VirtIO balloon device is attached, but active ballooning isn't wired yet.
- **Single VM**: one shared-kernel VM (like WSL2 / OrbStack); multi-"machine" support is future.
- Coexisting with Docker Desktop: mind `DOCKER_HOST` / `docker context` (see the [FAQ](./docs/faq.md)).

---

## 🛣 Roadmap

Stages 1–4 are done (see the table above). Next is OrbStack's real moat:

- 🔧 **Custom Linux kernel** (zram built in, virtualization tuning)
- ⚡ **VirtioFS caching layer** for near-native bind-mount speed (OrbStack's core IP)
- 🧠 **Active memory ballooning** + **user-space netstack** that follows macOS VPN/DNS
- 🖥️ **Multiple named Linux machines** + a **SwiftUI GUI**

See [research report §4](./orbstack-research.md) for the full picture and the open-source pieces
to borrow (Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`).

---

## 🙏 Acknowledgements

This is a **learning / research** clone of OrbStack, standing on the shoulders of Apple's
`Virtualization.framework`, Docker, and the Ubuntu cloud image. OrbStack is a closed-source
commercial product; this project is unaffiliated with it.

## 📄 License

[MIT](./LICENSE) © 2026 everettjf
