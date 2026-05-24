# Architecture

[**English**](./architecture.md) | [简体中文](./architecture.zh-CN.md)

openorb aims to reproduce OrbStack's core experience — "Docker runs in a lightweight Linux VM,
yet feels local and seamless" — with the least amount of custom code. This explains how each
layer is implemented.

> For OrbStack's own internals and the full clone roadmap, see the deep-dive
> **[orbstack-research.md](../orbstack-research.md)** in the repo root.

## Overview

```
   ┌─ macOS (host) ─────────────────────────────┐        ┌─ Linux VM (Virtualization.framework) ─┐
   │  docker CLI / orb                          │        │  openorb-guest (Go binary):           │
   │     │ DOCKER_HOST=unix://~/.openorb/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec                   │
   │  openorb (Swift main program)               │◀──────▶│    vsock 2377 → tcp port-forward      │
   │   ├─ VZ VM control                          │        │  dockerd (static) + containerd + runc │
   │   ├─ DockerSocketProxy                      │        │  VirtioFS: /mnt/mac, /mnt/rosetta     │
   │   ├─ PortForwarder                          │        │  Rosetta (binfmt_misc, x86-64)        │
   │   └─ VirtioFS / Rosetta / NAT devices        │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

The core idea matches OrbStack / WSL2: **one shared-kernel lightweight Linux VM**, with its
services "projected" onto macOS over virtio-vsock so stock tools work unchanged.

## 1. Virtualization: Apple Virtualization.framework

`Sources/openorb/VMConfig.swift` builds a VM with VZ:

- **Boot**: `VZEFIBootLoader` + NVRAM, EFI-booting the Ubuntu cloud image directly
  (`VZLinuxBootLoader` direct-kernel boot is also supported).
- **Disks**: `VZVirtioBlockDeviceConfiguration` (boot disk) + a read-only seed disk (cloud-init CIDATA).
- **Network**: `VZVirtioNetworkDeviceConfiguration` + `VZNATNetworkDeviceAttachment` (NAT egress).
- **vsock**: `VZVirtioSocketDeviceConfiguration` — the zero-network-overhead host↔guest channel
  that carries the whole "projection".
- **Misc**: entropy source, memory balloon, serial console.

VZ uses Apple Silicon's hardware virtualization directly — near-zero CPU overhead, 1–2s boot.
At runtime it needs the `com.apple.security.virtualization` entitlement, so the binary must be
codesigned (`run.sh` / `orb` do this automatically).

`VMManager.swift` owns the lifecycle: **all VZ calls must happen on one serial queue** (a hard
VZ requirement), so the VM is created with `VZVirtualMachine(configuration:queue:)` and start/
connect are dispatched onto it.

## 2. Docker over vsock

The container engine runs inside the VM (static `dockerd`); its Unix socket `/run/docker.sock`
is projected onto macOS in two hops:

```
docker CLI → ~/.openorb/docker.sock  →  [vsock 2375]  →  openorb-guest  →  /run/docker.sock → dockerd
            (DockerSocketProxy, host)    (virtio-vsock)   (guest Go agent)
```

- **Host side `DockerSocketProxy.swift`**: listens on an AF_UNIX socket; for each connection it
  `connect(toPort: 2375)` on the VZ queue to get a vsock connection, then splices the two fds.
- **Guest side `openorb-guest`**: accepts on vsock 2375, dials `/run/docker.sock`, splices.

> **A bug worth remembering**: the splice originally used a half-close (`shutdown(SHUT_WR)` on
> EOF), but the Docker API uses HTTP keep-alive by default — the peer never sends EOF, so the
> other relay blocked forever, leaking the fd and the vsock connection, eventually exhausting
> the device and wedging the proxy. Fix: **when either direction ends, `shutdown(SHUT_RDWR)`
> both** so the other wakes and the connection is reclaimed. See `bridge/relay`.

## 3. The guest agent: why Go

`guest-agent/main.go` compiles to one static linux/arm64 binary serving three vsock ports:

| Port | Role |
|---|---|
| 2375 | Docker bridge (→ `/run/docker.sock`) |
| 2376 | exec: read an HTTP body as a shell command, run it, return output (backend for `orb exec`) |
| 2377 | TCP forward: read a target port, dial guest `127.0.0.1:port`, splice (for port forwarding) |

> **Another bug worth remembering**: these services were first written in Python, but under
> memory pressure / sustained load they got OOM-killed or wedged (even `ls` occasionally hit
> SIGILL). Switching to a **compiled Go binary** made it rock-solid — 8 back-to-back containers
> plus load and both the socket and agent stay up. OrbStack writes its services in C/Go/Rust for
> the same reason. `OOMScoreAdjust` further keeps it alive under pressure.

## 4. File sharing: VirtioFS

For each `--mount`, `VMConfig.swift` adds a `VZVirtioFileSystemDeviceConfiguration` keyed by a
tag (the first defaults to `mac`). The guest mounts it with `mount -t virtiofs mac /mnt/mac` and
records it in `/etc/fstab`.

This is OrbStack's `/mnt/mac` (macOS files inside the guest), same mechanism. Containers read/
write host files through `-v /mnt/mac:/...`.

> Note: this is a "basic" VirtioFS — without OrbStack's custom caching/batching layer (that's
> Stage 5, and OrbStack's performance moat).

## 5. x86-64 translation: Rosetta

With `--rosetta`:

1. The host shares Rosetta into the guest as VirtioFS (tag `rosetta`) via
   `VZLinuxRosettaDirectoryShare` (installing Rosetta on demand if absent).
2. The guest mounts it at `/mnt/rosetta` and registers an x86-64 ELF handler with `binfmt_misc`,
   pointing the interpreter at `/mnt/rosetta/rosetta` with the **`F` flag** (the interpreter fd
   is opened at registration time, so it works inside containers' mount namespaces too).

So `docker run --platform linux/amd64 ...` runs x86 binaries through Rosetta — far faster than
QEMU user-mode emulation.

> The binfmt magic/mask only matches x86-64 (`e_machine=0x3e`); it won't misfire on arm64 binaries.

## 6. Port forwarding to localhost

`PortForwarder.swift`:

1. polls the Docker API every 2s (`GET /containers/json` over the projected docker socket);
2. collects all published TCP ports;
3. opens a `127.0.0.1:P` listener on macOS for each;
4. tunnels each connection over vsock 2377 to the guest agent, which dials `127.0.0.1:P` inside
   the guest and splices.

Result: after `docker run -p 8080:80`, `curl localhost:8080` on macOS hits the container — the
OrbStack experience. Disable with `--no-port-forward`.

> Detail: the API query uses HTTP/1.0 + `Connection: close` and sets a recv timeout on the
> socket, so dockerd keep-alive doesn't make "read until EOF" block forever.

## 7. First-boot provisioning: apt-free

`cloud-init/user-data` deliberately **avoids apt** (distro mirrors are flaky, and OrbStack itself
ships its own Docker tooling rather than apt-installing it):

- Static Docker engine: prefers a tarball staged on the share (host-downloaded, reliable),
  else the Docker CDN over IPv4;
- Guest agent: installs the compiled `openorb-guest` from the share;
- DNS: disables IPv6 + hardcodes `1.1.1.1` to dodge "IPv6-only resolution / IPv4-only egress"
  download stalls;
- mounts the `mac`/`rosetta` shares, registers Rosetta binfmt, (optionally) zram.

## 8. Memory

The VirtIO memory balloon device is attached; zram compressed swap is wired via a guest service
(**but the stock Ubuntu cloud kernel lacks the zram module**, so it no-ops — OrbStack's custom
kernel has it built in). Active ballooning (grow/reclaim on demand) is future work.

## Gap vs OrbStack (i.e. the roadmap)

| Dimension | This project | OrbStack |
|---|---|---|
| Virtualization | VZ ✅ | VZ + custom orchestration |
| Docker over vsock | ✅ | ✅ |
| VirtioFS | basic ✅ | + custom cache layer (2–5×) |
| Rosetta | ✅ | ✅ |
| Port forwarding | ✅ | ✅ + follows VPN/DNS |
| Kernel | stock cloud kernel | custom-built (zram, etc.) |
| Memory | balloon device | dynamic allocation + zram |
| Multi-machine / GUI | none | yes |

See [orbstack-research.md](../orbstack-research.md) and the [CHANGELOG](../CHANGELOG.md).
