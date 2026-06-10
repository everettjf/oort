# Roadmap

[**English**](./roadmap.md) | [简体中文](./roadmap.zh-CN.md)

Where oort is and where it's going. This is a learning/research clone of OrbStack — the
goal is to reproduce the core experience and close the gap to OrbStack step by step.

> See the **[step-by-step plan](./plan.md)** for how we close each gap below.

## ✅ Done

**Stages 1–4** (the working core):
- Boot a lightweight Linux VM via `Virtualization.framework`.
- Project the Docker engine onto a macOS Unix socket over `virtio-vsock`.
- VirtioFS file sharing; Rosetta x86-64; container port forwarding; the `oort` CLI.
- Compiled Go guest agent (docker bridge + exec + tcp-forward), apt-free provisioning.

**Hardening (since v0.1.0):**
- **Container networking** — dockerd-managed iptables NAT; `docker build` and runtime egress work.
- **Reliability** — graceful shutdown, a pinned NIC MAC so reused-disk boots keep networking,
  `/version`-gated startup, `oort autostart` at login.
- **Home mirroring** — the Mac home is mounted at the same path in the guest, so
  `docker -v $PWD:/app` works for any project.
- **Follows the Mac's DNS** — internal / VPN domains resolve inside containers.
- **Event-driven port forwarding** + a `bench.sh` performance baseline.
- **Liveness watchdog** — a periodic in-guest supervisor (`oort-watchdog.timer`)
  that restarts a *wedged* dockerd/containerd (alive but unresponsive — a state
  `Restart=always` can't catch) only on sustained failure, so it never kills a
  busy build. Verified live (frozen dockerd auto-recovers in ~39s).
- **Periodic container-egress self-heal** (`oort-egress-heal.timer`) — catches
  container TCP/DNS egress that degrades *after* boot (which the boot-only net-heal
  misses), restarting docker to rebuild the docker0 NAT only on sustained failure
  while containers are running. Verified deterministically (flush NAT → recover).
- **Guest-agent wedge auto-recovery** — the agent heartbeats while healthy; the
  in-guest watchdog restarts just the agent (no VM restart) if it goes stale, so a
  wedged agent (alive but not serving — fd exhaustion) self-heals. Plus
  **`oort doctor`**, a host-side probe that distinguishes VM / dockerd / agent
  failure modes. Verified live (froze the agent → hands-off recovery).

→ oort can now stand in for Docker Desktop for the common workflows: `docker build`,
Compose, dev bind-mounts, internal DNS, stable restarts.

## 🚀 Beyond OrbStack (differentiation, not catch-up)

Most of the roadmap below is *catch-up* — chasing parity on OrbStack's own turf
(custom kernel, virtiofs moat, netstack). That's the hardest, lowest-ROI fight.
The higher-leverage bet is to own a category OrbStack ignores, using oort's
structural advantage (open-source, scriptable, MIT). Thesis:

> **Don't beat OrbStack on benchmarks — treat the dev environment as a
> versionable, forkable, disposable git-object, and become the local sandbox
> substrate for AI coding agents.** OrbStack treats environments as hand-configured
> *pets*; it has no snapshot / fork / branch / rollback, and zero AI-agent integration.

- ✅ **Machine time-travel (shipped).** Because a machine is just a container, its
  whole filesystem is a content-addressed image. `oort machine snapshot` commits
  live state to a tagged image; `restore` rolls back; **`fork` instantly branches a
  fully-set-up machine into a new one** (CoW image layers — no re-provisioning).
  "git for dev environments" — verified e2e (snapshot→break→restore→fork, marker
  survives across all four). *OrbStack has none of this.*
- ✅ **AI-agent sandbox layer (shipped).** `oort mcp` runs a zero-dep
  [MCP](https://modelcontextprotocol.io) stdio server exposing
  `create_sandbox / exec / snapshot / restore / fork / list / destroy`, so coding
  agents get instant disposable environments, snapshot-on-risk, and
  fork-to-explore-in-parallel — built directly on the time-travel primitives above.
  Verified e2e (a full agent workflow: create→exec→snapshot→break→restore→fork with
  branch isolation→destroy). See [`mcp/`](../mcp/README.md). *OrbStack has nothing
  like this.*
- ✅ **Instant resume (shipped).** `oort suspend` pauses the VM and saves its whole
  state (RAM + devices) via VZ's save/restore; the next `oort start` resumes in
  **~1.2s** — running containers, shells and sockets come back exactly where they
  were, and the guest clock is re-stepped. State is one-shot and discarded if the
  disk image changes underneath it. (Needed a persisted `VZGenericMachineIdentifier`
  — a fresh random identity made restore fail with VZ's opaque "invalid argument".)
  *OrbStack cold-boots; it has nothing like this.*
- ✅ **`oort up` (env-as-code, shipped).** A declarative `oort.yaml` (or `.json`)
  describes machines + one-time `setup` commands; `oort up` reproduces them and
  `oort down` tears them down. Dependency-free parser (stdlib only). Idempotent
  (existing machines skipped). Verified e2e (create + ordered setup in the right
  machine, re-run skips, `down --purge`). See [`oort.example.yaml`](../oort.example.yaml).

> ✅ Fixed along the way: `oort machine exec` used to flatten quoting — redirections/
> pipes/quotes in a complex command got re-parsed on the guest host instead of inside
> the container (`sh -c 'echo x > /f'` wrote `/f` on the guest). The agent runs the
> request body via `/bin/sh -c`, so each argv is now `%q`-quoted on the host and the
> guest's dash reconstructs the exact same argv for `docker exec`. Verified e2e
> (redirection/pipe/`$VAR`/`$(...)` all evaluate in the container, no host leak).

## 🔜 Next (not started)

Ordered roughly by value. These are larger, multi-step efforts.

### Performance — OrbStack's real moat
- ✅ **Custom Linux kernel + direct-kernel boot (shipped, M2).** `oort start` boots via
  VZ's `VZLinuxBootLoader` (skipping EFI+GRUB), and **`oort build-kernel`** builds a
  monolithic arm64 kernel *in the guest* — everything `=y`, no modules, no initramfs,
  **zram built in**. EFI stays the fallback. Verified e2e (boot, vsock, virtiofs,
  Rosetta, Docker, egress). See [`kernel/`](../kernel/README.md). v0.3.4 stripped it
  to a minimal driver set (74→41 MB) and masked the boot cruft (~2 s
  networkd-wait-online + snapd + cloud-init + …) and optimized the dockerd path
  (pre-started containerd, parallel agent, tighter route-wait): `oort start`→Docker
  now **~4.5 s stock / ~2.8 s custom** (was ~7–9 s). Remaining toward OrbStack's
  ~1–2 s: dockerd's own ~1 s init + the VZ/kernel floor; plus KSM and VirtioFS
  **DAX** tuning.
- ~~**VirtioFS caching layer**~~ — benchmarked + reframed (v0.3.9). Per-file metadata
  ops are 8–35× slower on virtiofs, but real `npm install` is only ~1.2× (npm's own
  work dominates). The genuinely slow ops (`rm -rf`, scans, watchers) are removed by
  **`oort fastvol`** (keep hot dirs on the guest disk) — see
  [`docs/dev-filesystem.md`](../docs/dev-filesystem.md). Matching OrbStack's general
  virtiofs speed needs a custom host-side server (VZ disallows) → low ROI; deferred.

### Networking
- ✅ **User-space netstack (shipped, opt-in — v0.3.7).** `OORT_NET=gvproxy oort start`
  attaches the guest NIC to gvproxy via VZ's `VZFileHandleNetworkDeviceAttachment`, so
  guest traffic flows through macOS's stack — following the Mac's routes/VPN and DNS.
  Verified at parity with VZ NAT (e2e 18/22). Remaining: per-IP reachability from the
  host (gvproxy's forwarding API); promote from opt-in once proven against a live VPN.
- ✅ **`*.oort.local` domains (shipped).** OrbStack's beloved `*.orb.local`, for oort:
  the engine runs a tiny DNS responder on `127.0.0.1:5354` answering for containers
  (`web.oort.local`), machines (`dev.oort.local`), and compose services
  (`api.myproj.oort.local`) straight from the live Docker state. `oort domains enable`
  (sudo, one-time) writes a domain-scoped `/etc/resolver/oort.local` and adds the
  container route — then **any** container port is reachable by name, no `-p` publishing.
  VZ NAT mode; the route follows the guest IP (`oort domains route` refreshes it).

### Resource efficiency
- ✅ **Active memory ballooning (shipped).** The engine periodically reads the guest's
  real usage over the vsock agent and sets the balloon target to `used + headroom`
  (deflate fast on load, reclaim slowly when idle) — so the VM's host footprint tracks
  what the guest actually needs, OrbStack-style. Default on; `--no-dynamic-memory` opts out.
- **zram** compressed swap (depends on the custom kernel having the module).

### Features
- ✅ **Kubernetes (shipped).** `oort k8s enable` installs k3s in the guest (one-time),
  projects its API server onto the Mac's `localhost:6443` (static tcp-forward) and
  writes a kubeconfig to `~/.oort/kube/config` — then the stock `kubectl` just works.
- ✅ **Multiple Linux machines (shipped).** `oort machine create/list/shell/exec/delete` —
  named, multi-distro environments on the shared kernel (OrbStack's "machines"), plus
  the snapshot/restore/fork time-travel OrbStack doesn't have (see Beyond OrbStack).
- ✅ **GUI (shipped, v0.3.6)** — a complete native SwiftUI app (`oort gui`): dashboard,
  containers (+ logs), images, volumes, machines (snapshot/restore/fork/shell), settings,
  plus a menu-bar item. Talks to the engine via the Docker socket + the `oort` CLI.

## 📝 Known limitations (today)

- Bind-mount small-file speed (see Performance above).
- VPN traffic routing not yet wired (DNS does follow the Mac).
- zram no-ops on the stock kernel (no module).
- Single shared-kernel VM; no GUI.

See the [research report](../orbstack-research.md) §4 for the deep dive and which open-source
pieces to borrow (Lima, gvisor-tap-vsock, virtiofsd, Apple's `containerization`).
