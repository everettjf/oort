# Roadmap

[**English**](./roadmap.md) | [简体中文](./roadmap.zh-CN.md)

Where openorb is and where it's going. This is a learning/research clone of OrbStack — the
goal is to reproduce the core experience and close the gap to OrbStack step by step.

> See the **[step-by-step plan](./plan.md)** for how we close each gap below.

## ✅ Done

**Stages 1–4** (the working core):
- Boot a lightweight Linux VM via `Virtualization.framework`.
- Project the Docker engine onto a macOS Unix socket over `virtio-vsock`.
- VirtioFS file sharing; Rosetta x86-64; container port forwarding; the `oorb` CLI.
- Compiled Go guest agent (docker bridge + exec + tcp-forward), apt-free provisioning.

**Hardening (since v0.1.0):**
- **Container networking** — dockerd-managed iptables NAT; `docker build` and runtime egress work.
- **Reliability** — graceful shutdown, a pinned NIC MAC so reused-disk boots keep networking,
  `/version`-gated startup, `oorb autostart` at login.
- **Home mirroring** — the Mac home is mounted at the same path in the guest, so
  `docker -v $PWD:/app` works for any project.
- **Follows the Mac's DNS** — internal / VPN domains resolve inside containers.
- **Event-driven port forwarding** + a `bench.sh` performance baseline.

→ openorb can now stand in for Docker Desktop for the common workflows: `docker build`,
Compose, dev bind-mounts, internal DNS, stable restarts.

## 🔜 Next (not started)

Ordered roughly by value. These are larger, multi-step efforts.

### Performance — OrbStack's real moat
- **Custom Linux kernel** (cross-compiled, like OrbStack's). Unlocks `zram`, VirtioFS **DAX**,
  KSM, and tuning. The single biggest enabler — several items below depend on it.
- **VirtioFS caching layer** for small-file/metadata ops. Measured ~21× slower than local disk
  today (the `npm install` pain); VZ exposes no cache tuning, so this needs a custom
  FUSE/DAX path. *OrbStack's headline 2–5× advantage lives here.*

### Networking
- **User-space netstack** (e.g. gvisor-tap-vsock) for full VPN **traffic** routing
  (DNS resolution already follows the Mac), a unified bridge, and per-IP reachability.

### Resource efficiency
- **Active memory ballooning** — grow/reclaim guest memory on demand (balloon device is attached).
- **zram** compressed swap (depends on the custom kernel having the module).

### Features
- **Kubernetes** — k3s in the guest + a projected kube API + kubeconfig (the most self-contained next step).
- **Multiple Linux machines** — named, multi-distro environments (OrbStack's "machines").
- **GUI** — a native SwiftUI app (status, containers, machines, settings).

## 📝 Known limitations (today)

- Bind-mount small-file speed (see Performance above).
- VPN traffic routing not yet wired (DNS does follow the Mac).
- zram no-ops on the stock kernel (no module).
- Single shared-kernel VM; no GUI.

See the [research report](../orbstack-research.md) §4 for the deep dive and which open-source
pieces to borrow (Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`).
