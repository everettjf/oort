<div align="center">

# 🛰️ Oort

**A lightweight, OrbStack-style Docker & Linux runtime for macOS — in Swift + Go.**

Boots a lightweight Linux VM with Apple's `Virtualization.framework`, then projects the
container engine, file sharing, x86 translation and port mapping onto macOS — no Docker Desktop.

*Named for the **Oort cloud** — the vast shell of countless small icy bodies at the
edge of our solar system. Here it's the many lightweight machines and sandboxes that
orbit one shared kernel.*

<br/>

[![Website](https://img.shields.io/badge/website-everettjf.github.io%2Foort-3ee0c5)](https://everettjf.github.io/oort/)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20·%20Apple%20Silicon-black)](#-requirements)
[![Language](https://img.shields.io/badge/built%20with-Swift%20%2B%20Go-orange)](#-project-layout)
[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

**English** | [简体中文](./README.zh-CN.md)

🌐 **[Website &amp; tutorial → everettjf.github.io/oort](https://everettjf.github.io/oort/)**

[Quick start](#-quick-start) · [What it is](#-what-it-is) · [Architecture](#-architecture) · [Docs](#-documentation) · [Roadmap](#-roadmap)

</div>

---

## ✨ What it is

`oort` is a **working**, slimmed-down OrbStack clone — a project that studies *why OrbStack is
fast and light* and reimplements the core mechanisms by hand.

> **Oort vs Docker?** They're at different layers. **Docker** is the container engine — but
> containers need a Linux kernel, which macOS doesn't have. **Oort** is the substrate that gives
> Docker that kernel: it boots a lightweight Linux VM and projects `dockerd` (plus ports, files,
> DNS, x86 translation) back onto macOS, so the stock `docker` CLI just works. Oort doesn't
> replace Docker — it carries it. Compare it to **Docker Desktop / OrbStack / Colima**, not to
> Docker itself. ([more →](./docs/faq.md#concepts))

One command to start, then the stock `docker` CLI just works:

```console
$ oort start
starting oort VM…
waiting for Docker...... ready.
export DOCKER_HOST=unix:///Users/you/.oort/docker.sock

$ docker run --rm hello-world
Hello from Docker!

$ docker run -p 8080:80 nginx     # then `curl localhost:8080` on macOS just works
$ docker run --platform linux/amd64 alpine uname -m     # x86_64 (via Rosetta)
$ oort exec 'uname -a'             # run a command inside the guest
```

### What works today, **verified on real hardware**

| Capability | What it does | Status |
|---|---|:---:|
| 🐳 **Docker over vsock** | VZ boots a Linux VM; dockerd is projected onto a macOS Unix socket via virtio-vsock | ✅ |
| 🌐 **Container networking** | dockerd manages iptables NAT — `docker build` (`RUN apk/npm/pip…`) and runtime egress work | ✅ |
| 📁 **File sharing** | Your Mac home is mirrored into the guest at the same path, so `docker -v $PWD:/app` just works | ✅ |
| 🧬 **Rosetta x86** | `linux/amd64` images run via Rosetta — far faster than QEMU | ✅ |
| 🔌 **Port forwarding** | Container-published ports appear automatically on macOS `localhost` (event-driven) | ✅ |
| 🪪 **`*.oort.local` domains** | `curl http://web.oort.local` reaches container "web" by name — any port, no `-p` (`oort domains enable`) | ✅ |
| 🧭 **Follows Mac DNS** | Guest/containers use the Mac's DNS resolvers — internal/VPN domains resolve | ✅ |
| 🛰️ **`oort` CLI** | Lifecycle, `oort exec`, docker passthrough, `oort autostart` at login | ✅ |
| 🌱 **Machine time-travel** | `snapshot` / `restore` / **`fork`** a whole Linux machine (git-for-environments — *OrbStack can't*) | ✅ |
| 🖥️ **Native SwiftUI app** | Windowed control panel (dashboard, containers, images, volumes, machines, settings) + menu bar — `oort gui` | ✅ |
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
./oort build-image

# 3. Start (waits until Docker is ready, prints DOCKER_HOST)
./oort start

# 4. Use it
export DOCKER_HOST=unix://$HOME/.oort/docker.sock
docker run --rm hello-world
oort status
oort stop
```

See **[docs/quickstart.md](./docs/quickstart.md)** for the detailed walkthrough.

---

## 🧭 Architecture

```
   ┌─ macOS (host) ─────────────────────────────┐        ┌─ Linux VM (Virtualization.framework) ─┐
   │  docker CLI / oort                          │        │  oort-guest (Go binary):           │
   │     │ DOCKER_HOST=unix://~/.oort/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec (oort exec)       │
   │  oort (Swift)                            │◀──────▶│    vsock 2377 → tcp port-forward      │
   │   ├─ VZ VM control                          │        │  dockerd (static) + containerd        │
   │   ├─ DockerSocketProxy (unix ⇄ vsock 2375)  │        │  VirtioFS: /mnt/mac, /mnt/rosetta     │
   │   ├─ PortForwarder (127.0.0.1:P ⇄ 2377)     │        │  Rosetta binfmt_misc (x86-64)         │
   │   └─ VirtioFS / Rosetta / NAT devices        │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

The guest is a stock Ubuntu 24.04 cloud image, provisioned **without apt** on first boot
(static Docker engine + the compiled `oort-guest` agent, staged on the VirtioFS share).

> Curious how OrbStack does it and how we cloned it? Read the deep-dive
> **[orbstack-research.md](./orbstack-research.md)** and **[docs/architecture.md](./docs/architecture.md)**.

---

## 📚 Documentation

| Doc | Contents |
|---|---|
| [Quick start](./docs/quickstart.md) · [中文](./docs/quickstart.zh-CN.md) | Install, first run, everyday use |
| [Beyond OrbStack](./docs/beyond-orbstack.md) · [中文](./docs/beyond-orbstack.zh-CN.md) | Hands-on: machine time-travel, env-as-code, AI-agent sandboxes |
| [Architecture](./docs/architecture.md) · [中文](./docs/architecture.zh-CN.md) | How VZ / vsock / VirtioFS / Rosetta / port-forward / the Go agent work |
| [CLI reference](./docs/cli-reference.md) · [中文](./docs/cli-reference.zh-CN.md) | Every `oort` subcommand + all `oort run` flags |
| [FAQ](./docs/faq.md) · [中文](./docs/faq.zh-CN.md) | Troubleshooting (DNS, zram, provisioning, coexisting with Docker Desktop) |
| [Roadmap](./docs/roadmap.md) · [中文](./docs/roadmap.zh-CN.md) | What's done and what's next |
| [Custom kernel](./kernel/README.md) | Direct-kernel boot + `oort build-kernel` (monolithic, zram built in) |
| [Dev filesystem](./docs/dev-filesystem.md) | Fast bind-mounted projects: the VirtioFS gap + `oort fastvol` |
| [Packaging](./docs/packaging.md) | Build `oort.app` / `.dmg`, signing + notarization |
| [Changelog](./CHANGELOG.md) | Per-version changes (latest: v0.1.0) |
| [Plan](./docs/plan.md) · [中文](./docs/plan.zh-CN.md) | Step-by-step plan to catch up to OrbStack |
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
oort/
├── Sources/oort/         Swift: VM orchestration + socket proxy + port forwarding
│   ├── VMConfig.swift        builds the VZVirtualMachineConfiguration (all devices)
│   ├── VMManager.swift       VM lifecycle (pinned to the VZ serial queue)
│   ├── DockerSocketProxy.swift  host Unix socket ⇄ guest vsock tunnel
│   ├── PortForwarder.swift   watches Docker, forwards published ports to localhost
│   └── Config.swift / main.swift
├── guest-agent/main.go      guest agent (docker bridge + exec + tcp-forward; linux/arm64)
├── cloud-init/              apt-free first-boot provisioning
├── oort                      the command-line front-end
├── make-image.sh            build disk + seed + cross-compile the agent
└── orbstack-research.md     deep-dive research report
```

---

## ⚠️ Known limitations

- **Bind-mount metadata speed**: VirtioFS per-file ops are 8–35× slower than the guest disk
  (`rm -rf`, scans, watchers) — though a real `npm install` is only ~1.2× slower. Fix today:
  **`oort fastvol`** keeps hot dirs (`node_modules`…) on the guest disk. See
  [dev-filesystem](./docs/dev-filesystem.md). (Matching OrbStack's virtiofs needs a custom VMM.)
- **VPN traffic**: shipped via the opt-in gvproxy netstack (`OORT_NET=gvproxy`); DNS already follows the Mac.
- **zram**: the stock Ubuntu cloud kernel ships without the `zram` module, so that service
  no-ops. OrbStack builds a custom kernel with it baked in — that's a Stage 5 item.
- **`*.oort.local` reachability**: the names resolve via the engine's built-in DNS, but reaching
  the IPs needs the container route (`oort domains enable`, sudo) — and the route follows the
  guest IP, so a VM restart may need `oort domains route` (oort start reminds you). VZ NAT only.
- **Single VM**: one shared-kernel VM (like WSL2 / OrbStack); multi-"machine" support is future.
- Coexisting with Docker Desktop: mind `DOCKER_HOST` / `docker context` (see the [FAQ](./docs/faq.md)).

---

## 🛣 Roadmap

**Beyond OrbStack** — rather than only chasing OrbStack's moat, oort is opening
a category it ignores: the dev environment as a versionable, forkable git-object
(**machine time-travel**, shipped) and a local sandbox substrate for AI coding
agents (**`oort mcp`** — an MCP `create/exec/snapshot/fork/destroy` layer, shipped;
see [`mcp/`](./mcp/README.md)), plus **env-as-code** (`oort up` from an
`oort.yaml`). See [roadmap → Beyond OrbStack](./docs/roadmap.md).

Stages 1–4 are done (see the table above). The catch-up items remain OrbStack's real moat:

- ✅ **Custom Linux kernel + direct-kernel boot** — shipped (`oort build-kernel`): monolithic,
  no initramfs, zram built in; EFI fallback. See [`kernel/`](./kernel/README.md).
- ⚡ **VirtioFS caching layer** for near-native bind-mount speed (OrbStack's core IP)
- 🧠 **Active memory ballooning**
- ✅ **User-space netstack** — shipped (opt-in: `OORT_NET=gvproxy`): guest traffic flows
  through macOS's stack via gvproxy, following the Mac's routes/VPN and DNS.
- ✅ **Native SwiftUI app** — shipped (`oort gui`): dashboard, containers, images, volumes,
  machines (snapshot/restore/fork), settings + menu-bar item.

See [research report §4](./orbstack-research.md) for the full picture and the open-source pieces
to borrow (Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`).

---

## 🙏 Acknowledgements

This is a **learning / research** clone of OrbStack, standing on the shoulders of Apple's
`Virtualization.framework`, Docker, and the Ubuntu cloud image. OrbStack is a closed-source
commercial product; this project is unaffiliated with it.

## 📄 License

[MIT](./LICENSE) © 2026 everettjf
