# Plan: catching up to OrbStack

[**English**](./plan.md) | [简体中文](./plan.zh-CN.md)

A step-by-step plan to close the gap to OrbStack on **both speed and experience**. Each
milestone is independently shippable, has a measurable parity target, and says how we verify it.
We do them roughly in order; speed/efficiency basics first, then experience, then the hard
filesystem moat last.

> Baseline numbers come from `bench.sh`. Re-run it after each milestone to track progress.

## Status (M1–M8)

| | Milestone | Status |
|---|---|---|
| M1 | Golden image / instant restart | ✅ verified |
| M2 | zram (kernel-tier efficiency) | ✅ verified |
| M3 | Active memory ballooning | ✅ verified |
| M4 | Dev filesystem guidance | ✅ done (docs) |
| M5 | Networking | ✅ v0.3.7 — user-space netstack (gvproxy, opt-in `OORT_NET=gvproxy`): traffic+DNS follow the Mac/VPN. Per-IP-from-host + domains pending |
| M6 | Kubernetes (k3s) | ✅ verified — `kubectl get nodes` → Ready in the e2e suite |
| M7 | Multiple machines | ✅ verified — `machine create`+`exec` green in the e2e suite |
| M8 | Native SwiftUI GUI | ✅ v0.3.6 — full windowed app (dashboard/containers/images/volumes/machines/settings) + menu bar; dashboard visually verified |
| M9 | Native-speed filesystem | ⛔ not started (the hard moat) |

## Phase 0 hardening — what the verification push found & fixed

A long verification push turned the suite from chaos into a reliable 9/12 and
root-caused the real reliability bugs (all fixed, see git log):

1. **Binary signing** — `oort` only codesigned the VZ binary when it *built* it;
   any rebuild left it unsigned → VZ refused to boot (`VZErrorDomain Code=2`).
   This was the core "VM won't boot" cause. Now `bin()` always re-signs.
2. **Bash 3.2 array crash** — `oort start` aborted on stock macOS bash whenever
   k8s wasn't enabled (empty array under `set -u`). Fixed with the 3.2-safe
   expansion.
3. **`machine exec`** — ran `docker exec` over the host socket, which loses
   hijacked-stream output; now routed through the guest agent.
4. **Guest agent hangs** — the exec port could wedge under load (un-timed-out
   commands leaking fds + a busy-loop on accept errors). Added per-command
   timeouts, concurrency caps, accept backoff, and a raised fd limit.
5. **The big one — memory ballooning** (`MemoryManager`): it squeezed the VM to
   `used+384MiB`, clamping a 4GB guest to ~730MiB when idle, so a container
   burst OOM-killed dockerd and the agent. *This was the "degrades under load"
   instability.* Fixed with a 2GB floor, proportional headroom, and hysteresis
   (deflate fast, reclaim slow). Verified: a 30-container churn that used to
   kill the agent in ~5 runs now survives all 30.

**Known residual:** fresh-boot non-determinism — docker/the agent occasionally
take >5min to come up, or container egress is slow for ~60s, on some boots. It's
**not reproducible on demand** (most boots are fine) and worsened over
consecutive boots while host load stayed low, pointing at VZ/host-side
degradation after hours of heavy create/destroy cycling rather than a logic bug.
Re-verify from a fresh host state (reboot).

**Sharper repro (2026-05-26 run):** a **cold boot from the golden image is fast
and reliable** — `oort start` was ready in ~8.8 s and `docker run`, VirtioFS,
Rosetta, machines, zram, ballooning and DNS-follow all passed. The failures
cluster on **booting/restarting a *mutated* `disk.img`** (after heavy cycling, or
the `k8s enable` stop→start on a freshly-k3s-written disk): the guest kernel comes
up (vsock RSTs the connection) but **dockerd + the guest agent never start**, so
graceful stop can't ACPI-poweroff and falls back to force-kill. Separately, on one
golden boot **container egress failed while dockerd's own image *pull* succeeded**
— i.e. the guest host has internet but the docker0 NAT/MASQUERADE path for
containers didn't come up, which also blocks port-forward and k3s CNI. Net: cold
golden boots are trustworthy today; **the unsolved Phase-0 work is reliable
restart-on-a-written-disk + deterministic docker0 NAT bring-up.** `oort reset`
(restore golden) is the reliable recovery.

**Durability fixes since:**
6. **Disk-level lock** (the named next fix) — the engine now takes an exclusive
   `flock` on the disk image before boot (`DiskLock`), so two VMs can never write
   the same image at once (the concurrent-writer ext4 corruption that broke later
   boots). Auto-released by the kernel on exit, so a crash leaves no stale lock.
7. **`oort start` fails fast** — if the engine exits early (locked disk, VZ boot
   refusal, …) the wrapper now detects the dead process and prints the real error
   from `vm.log` immediately, instead of polling for 5 minutes and reporting a
   generic timeout.
8. **Durable stop — the restart-on-a-mutated-disk fix (2026-05-27, verified).**
   Root cause was a doom loop: ACPI graceful stop stalled when dockerd/systemd
   were busy → host timed out and `kill -9`'d the VM mid-write → corrupted the
   ext4 image → next boot's dockerd + agent never started → stop force-killed
   again. Broken at the source: the guest agent now serves a **vsock shutdown
   port (2378)** that `sync`s the fs and does a graceful `systemctl poweroff`
   with a **sysrq `s`/`u`/`o` fallback** (sync, remount-ro, power off — needs
   neither systemd nor acpid). `VMManager.requestStop` prefers that path and only
   falls back to ACPI if the agent is unreachable. cloud-init persists
   `kernel.sysrq=1` and bakes `fsck.repair=yes` into GRUB so a disk left dirty by
   any earlier crash self-heals on boot. `tests/e2e.sh` now has a
   **restart-on-a-mutated-disk** case (stop <28 s = no force-kill, then Docker
   must come back on the restarted disk) — green; a healthy stop now powers off
   in ~1 s via the agent.

9. **Provisioning reliability (2026-05-27).** `oort build-image` was failing on
   the provisioning boot (kernel at the login prompt, dockerd + agent dead). Two
   bugs: (a) the `dhcp6: false` sed line was an unquoted YAML scalar containing
   `": "`, so cloud-init couldn't parse user-data and skipped ALL provisioning;
   (b) `update-grub` (os-prober can hang) sat in `runcmd` *before* the docker/agent
   enables, so a hang left them unstarted. Fix: quote the scalar, move the two
   next-boot-only tweaks (dhcp6 sed, update-grub) after the enables, cap
   update-grub with `timeout 60`. Verified: build-image succeeds and 24/24 boot
   cycles came up with Docker reachable.

10. **Container-egress self-heal (2026-05-27, mitigated — not root-caused).** On
    rare, **time-clustered** boots a container can't reach the internet/DNS while
    the guest *host* still can. Deep diag (40+ boots): on a bad boot the route is
    up, `ip_forward=1`, dockerd's nat/MASQUERADE + FORWARD rules are all present,
    the container can ping its gateway — yet multi-hop egress is dead and the
    MASQUERADE counter stays 0, i.e. **rules present but not translating**. Not
    reproducible on demand (saw 24 good vs 6 bad, bad ones in ~10-min clusters), so
    no pinpointed root cause. Mitigation: `oort-docker-net-heal.service` (boot
    oneshot) probes container egress with a baked-in busybox (ICMP→1.1.1.1, no DNS)
    and, only if the container path is down while the host is up, restarts dockerd
    once to rebuild the nft ruleset, then re-probes. Verified harmless on 13 good
    boots (0 restarts). Also shipped `dhcp6: false` + a route-wait `ExecStartPre`
    on docker.service (hardening, but they did NOT prevent the bad cluster).

11. **Liveness watchdog (2026-05-28, mechanism verified).** Under load,
    dockerd/containerd can **wedge** — the process stays alive (so systemd's
    `Restart=always` never fires) but stops answering: the guest agent's vsock
    docker bridge (2375) resets and `docker info` hangs. Reproduced this session
    on the first image pull and on back-to-back `oort up` creates (containerd
    "connection refused", then the exec agent went unresponsive too; recovered
    only by host stop→start). Fix: `oort-watchdog.timer` (every ~30s) runs
    `oort-watchdog.sh`, which restarts docker (rebuilds dockerd+containerd) and
    bounces the guest agent **only** on a *sustained* `docker info` failure — a
    busy daemon mid-build/pull still answers `docker info`, so live work is never
    killed. Verified live by freezing dockerd with `kill -STOP` (a wedge
    `Restart=always` can't catch): healthy → watchdog is a no-op; frozen → the
    timer-driven watchdog detected it and auto-recovered docker + the host socket
    in ~39s with zero manual intervention (journal logged the detect+restart).
    *Caveat:* baked into cloud-init but a fresh-golden end-to-end run needs an
    `oort build-image` rebuild. Open refinement: it triggers on dockerd liveness;
    an agent-only wedge (agent stuck while dockerd is fine) would need an agent
    health endpoint to catch directly.

**Remaining Phase-0 open question — root-cause the egress heisenbug.** The
self-heal recovers the symptom, but the true cause of "dockerd's NAT rules are
present but don't translate" (and why it time-clusters) is unknown, and the
restart-docker recovery wasn't observed end-to-end on a live bad boot. Next:
catch the heal firing (`journalctl -u oort-docker-net-heal` → "restarting
dockerd") and confirm it recovers; investigate a host-side (VZ NAT) trigger.

**New evidence (2026-05-29, during the v0.3.0 e2e run).** Caught a sustained bad
cluster live. Sharper findings:
- **net-heal is boot-only and misses post-boot degradation.** On a bad-cluster
  boot, net-heal logged `container egress OK` at ~3s, then egress broke *later*
  (the e2e suite's container checks failed minutes after boot). Because net-heal
  is a boot oneshot, it never re-checked. **✅ FIXED in v0.3.1:**
  `oort-egress-heal.timer` re-probes container TCP/DNS egress periodically
  (only when containers run) and restarts docker to rebuild NAT after a sustained
  failure while the host is online. Verified deterministically (flush MASQUERADE →
  healer restarts docker → NAT rebuilt → egress recovers), which also **confirmed
  the long-open question**: a docker restart *does* rebuild the NAT and recover
  container egress.
- **Signature reconfirmed precisely:** in the bad window, container *ICMP* to
  1.1.1.1 succeeded while container *TCP/DNS/HTTPS* (`wget https://…`) failed —
  so a ping-only probe is a false positive. Any heal/probe MUST test TCP+DNS, not
  ICMP (net-heal already does; ad-hoc checks must too).
- **Agent-only wedge observed under load in the bad window:** hammering containers
  while egress was broken left the *guest agent itself* unresponsive (vsock 2376
  dead) while dockerd was up. **✅ FIXED in v0.3.2:** the agent writes a heartbeat
  (`/run/oort-agent-heartbeat`) every ~10s while healthy; the in-guest watchdog
  restarts **just the agent** when it goes stale (>60s). Chosen over a host-side
  restarter because the agent IS the host's control channel (restarting a fully-
  wedged agent from the host hits a chicken-and-egg — only a VM restart would
  work, which is disruptive). Host-side visibility is provided by `oort doctor`
  instead. Verified live (froze the agent → auto-recovered hands-off, no VM
  restart). NOTE: this caught the build-image bug below.
- **build-image force-kill → corrupted golden (FIXED v0.3.2).** The ld.so/libc
  assertions seen on some boots were a corrupted golden: build-image's stop
  force-killed the VM while the background zram apt-install kept it busy past the
  graceful window. Now build-image quiesces (stops zram, syncs) before stop.
- Whether `systemctl restart docker` reliably clears a bad *TCP*-egress window
  still wasn't cleanly captured (the agent wedged mid-test); the periodic-heal
  follow-up should log before/after TCP probes to settle it.

## Reassessment — the real gap to OrbStack

Building M1–M8 changed the picture. The biggest gap is **no longer a single missing
feature** — it's that the **foundation isn't rock-solid yet**, and a chunk of work is
**written but not proven**:

- **Reliability:** the build effort repeatedly hit VM boot / first-boot-provision timeouts,
  force-kills that corrupted the disk, and stuck build processes holding SwiftPM/Go locks that
  cascaded into hangs. OrbStack just-works; oort still sometimes won't boot. This is the
  most painful practical gap.
- **Unverified work:** `oort route` (M5), k3s (M6), machines (M7) are code-complete but never
  ran end-to-end — and M7 shipped with a real bug that only surfaced when a stale verification
  task finally completed. *Code that hasn't run doesn't count.*
- **Maturity:** the GUI (M8) is a menu-bar stub; there's no packaging/distribution; the
  filesystem moat (M9) is untouched.

The gaps fall into three buckets:

**A. Foundation (stability & trust) — the current top blocker**
1. Boot/provision reliability: `oort start` must *always* come up, shutdown must never corrupt
   the disk, no lock cascades.
2. Prove the written work: real end-to-end green for M5 route, M6 k3s, M7 machines (+ fix bugs).
3. An automated e2e test suite (start→docker→mount→rosetta→port→k8s→machine→stop), CI-gated, so
   "unverified commits" can't happen again.

**B. Performance (truly *fast*)**
4. Custom minimal kernel + direct boot → cold start ~8 s down to ~1–2 s (OrbStack-level).
5. **M9 filesystem moat** — own virtiofs caching/DAX (likely a custom VMM on
   `Hypervisor.framework`). Small-file from ~21× toward native. The only research-hard piece.

**C. Product (truly *nice*)**
6. Full GUI (containers/images/volumes/logs/machines/k8s/settings), not a menu-bar stub.
7. Networking depth: VPN *traffic* routing (gvproxy), container-by-IP, `*.oort.local` domains.
8. Packaging: signed + notarized `.app`, dmg / brew cask, Sparkle auto-update.

## Path forward — Phase 0 → 1 → 2

> Reordered from the original M-sequence: **harden the foundation first**, then performance,
> then product. Continuing to pile on features before Phase 0 just builds on sand.

**Phase 0 — Foundation hardening (do first)**
- 0.1 Root-cause and fix boot/provision reliability (EFI delay? cloud-init apt stalls? lock
  contention?); target a stable <10 s start; graceful-only shutdown; `oort start` self-heals.
- 0.2 `make verify` end-to-end suite + CI; red on any failure.
- 0.3 Verify & harden M5 route / M6 k3s / M7 machines to real green.

**Phase 1 — Performance**
- 1.1 Custom compiled minimal kernel + direct boot → ~1–2 s start.
- 1.2 (the moat) M9 self-built virtiofs caching/DAX → near-native files. Hardest, most expensive, last.

**Phase 2 — Product**
- 2.1 Full SwiftUI app (multi-panel).
- 2.2 gvproxy netstack (VPN traffic + container IPs + domains).
- 2.3 Signed/notarized `.app` + brew cask + auto-update.

**Bottom line:** matching OrbStack's *speed* ≈ Phase 1.2 (research-hard, months, likely a custom
VMM). Matching its *reliability and polish* ≈ Phase 0 + Phase 2 (large but ordinary engineering).
**Do Phase 0 next** — not M9.

## Parity scorecard

| Dimension | OrbStack | oort now | Target milestone |
|---|---|---|---|
| CPU virt / Rosetta | ✅ | ✅ at parity | — |
| Docker / ports / egress / DNS resolve | ✅ | ✅ | — |
| Cold start | ~1–2 s | ~30–60 s first / ~3–6 s reuse | **M1, M2** |
| Memory footprint | dynamic + zram | fixed, no zram | **M3** |
| Bind-mount small files | ~native | ~21× slower | **M4** (mitigate), **M9** (match) |
| VPN traffic / container IPs | ✅ | DNS only | **M5** |
| Kubernetes | one-click | none | **M6** |
| Multiple machines | ✅ | single VM | **M7** |
| GUI | native app | CLI only | **M8** |

---

## M1 — Instant restart (golden image)
- **Goal:** `oort start` on an already-provisioned disk in **≤ 3 s**; provisioning never reruns.
- **Tasks:** make `oort build-image` produce a fully-provisioned "golden" disk (boot once, let
  cloud-init finish, snapshot); `oort start` reuses it read-fast; keep a pristine copy so resets are cheap.
- **Verify:** `time oort start` ≤ 3 s; `docker run hello-world` immediately after.
- **Effort:** 🟢 small · **Risk:** low · **Deps:** none.

## M2 — Fast boot + custom kernel — ✅ SHIPPED (v0.3.3)
- **Done:** `oort start` direct-kernel-boots via `VZLinuxBootLoader` (EFI fallback kept);
  `oort build-kernel` builds a monolithic arm64 kernel in the guest (all `=y`, MODULES
  off → no initramfs, zram built in) via `kernel/build-in-guest.sh`. Verified e2e
  (boot/vsock/virtiofs/Rosetta/Docker/egress). Hard lessons baked into the build:
  MODULES=n is required so `--enable` reliably means `=y` (a module `select` kept
  demoting BRIDGE/ZRAM to `=m`); `CONFIG_DUMMY` must be off (its `dummy0` hijacks
  cloud-init's NIC detection → no egress); `flash-kernel` neutered so apt works.
  **v0.3.4:** stripped the driver set to minimal (virtio-only — Image 74→41 MB) and
  masked the boot cruft (~2 s networkd-wait-online, snapd, cloud-init re-runs,
  apport/udisks2/e2scrub/rsyslog/polkit/lvm2/multipathd) + dropped docker's
  network-online dep. **v0.3.5** then optimized the dockerd-ready path (pre-started
  containerd so dockerd skips managed-containerd ~1 s; parallel agent; 0.2 s
  route-wait). `oort start`→Docker: **~4.5 s stock / ~2.8 s custom** (was ~7–9 s).
  **Remaining toward ~1–2 s:** the floor is now VZ boot + kernel init (~2 s to agent)
  + dockerd's own ~1 s startup — closing the last second needs a faster
  dockerd-ready path or deeper VMM work. Below is the original plan.
- **Goal:** cold boot toward OrbStack's ~1–2 s; a kernel we control.
- **Tasks:** build a kernel **inside the guest** (native arm64 — no macOS cross-compile pain),
  monolithic (virtio-blk/net/fs, vsock, ext4, overlay, **zram** all `=y`); boot it via VZ
  **direct-kernel-boot** (`--kernel`, already supported) instead of EFI; strip unused drivers.
- **Verify:** `uname -r` shows the custom kernel; boot time measured in `bench.sh`; VM still
  passes the full Docker/VirtioFS/Rosetta/port-forward suite.
- **Effort:** 🟡 medium · **Risk:** medium (getting a bootable `.config` may take a few tries) · **Deps:** none.
- **Unlocks:** zram builtin (M3), tuning, faster boot.

## M3 — Memory efficiency (zram + ballooning)
- **Goal:** low idle footprint; reclaim memory on demand like OrbStack.
- **Tasks:** enable **zram** swap (builtin from M2); add an **active ballooning** loop on the host
  that reads guest memory pressure and adjusts the VZ balloon target; optional **KSM** for
  cross-container page dedup.
- **Verify:** idle RSS drops materially; many small containers run without hogging RAM.
- **Effort:** 🟡 medium · **Risk:** medium · **Deps:** M2 (for zram).

## M4 — Dev filesystem, pragmatic
- **Goal:** make mounted-source dev usable now (without the full M9 rewrite).
- **Tasks:** an `oort` helper + docs for the named-volume workflow (keep `node_modules`/build dirs
  on the guest's own disk); investigate any guest-side caching knob; **add small-file + real
  workload (`npm install`) cases to `bench.sh`**.
- **Verify:** documented workflow gets `npm install` close to native; bench shows the win.
- **Effort:** 🟢 small–medium · **Risk:** low · **Deps:** none.

## M5 — Seamless networking (user-space netstack)
- **Goal:** VPN **traffic** routing, container/machine reachability by IP, optional domain names.
- **Tasks:** integrate a user-space netstack (e.g. **gvisor-tap-vsock / gvproxy**) so guest
  traffic flows through macOS (following VPN routes), with a unified bridge.
- **Verify:** a container reaches a VPN-only host; ping a container IP from macOS.
- **Effort:** 🔴 large · **Risk:** medium · **Deps:** none (DNS resolution already follows the Mac).

## M6 — Kubernetes
- **Goal:** one command to a working cluster.
- **Tasks:** run **k3s** in the guest; project the kube API (vsock tcp-forward → `localhost:6443`);
  write/merge a kubeconfig; `oort k8s enable/disable`.
- **Verify:** `kubectl get nodes` and a sample deployment from macOS.
- **Effort:** 🟡 medium · **Risk:** low–medium · **Deps:** M5 nice-to-have (service networking).

## M7 — Multiple Linux machines
- **Goal:** OrbStack-style named, multi-distro machines on the shared kernel.
- **Tasks:** manage multiple rootfs images; `oort machine create/list/delete/exec`; per-machine
  mounts/networking; one SSH/exec multiplexer.
- **Verify:** create an Ubuntu and an Alpine machine, exec into each, files isolated.
- **Effort:** 🔴 large · **Risk:** medium · **Deps:** M2 (shared custom kernel helps).

## M8 — GUI
- **Goal:** a native app experience, not just CLI.
- **Tasks:** a **SwiftUI** app wrapping the engine — status/menu-bar, containers, machines, logs,
  settings, start/stop; bundle the `oort` engine + guest agent.
- **Verify:** install the `.app`, manage everything from the UI.
- **Effort:** 🔴 large · **Risk:** low (engineering, not research) · **Deps:** M6/M7 for full surface.

## M9 — The moat: native-speed filesystem
- **Measured (2026-05-30, stock kernel, VZ virtiofs `/mnt/mac` vs guest ext4):**

  | op | VirtioFS | guest fs | ratio |
  |---|---|---|---|
  | seq write 512MB | 559 MB/s | 845 MB/s | 0.66× (fine) |
  | seq read (cold) | 3.5 GB/s | 2.0 GB/s | faster (host cache) |
  | create 3000 files | 633ms | 33ms | ~19× |
  | scan `find` 8000 | 16ms | 2ms | ~8× |
  | `tar` 8000 | 319ms | 9ms | ~35× |
  | `rm -rf` 8000 | 983ms | 37ms | ~27× |
  | **`npm install` 2111 files (warm cache)** | **1351ms** | **1120ms** | **~1.2×** |

  **Reframing the gap:** pure per-file metadata ops (create/scan/tar/`rm -rf`) are
  8–35× slower on virtiofs — real and large. BUT the canonical "dev pain" workload,
  `npm install`, is only **~1.2×** slower, because npm's own resolve/extract/JS work
  dominates, not raw file creation. So the practical pain concentrates in
  `rm -rf node_modules` (~27×), bulk reads/`tar` (~35×), `git status`-style scans
  (~8×), and file-watchers doing many stats — NOT the install itself. The headline
  "~21×" overstates everyday impact; the named-volume workaround (M4: keep
  `node_modules`/build output on the guest disk) removes exactly these hot-path ops.
- **Goal:** match OrbStack's ~75–95% native bind-mount speed (vs ~21× slower today).
- **Tasks:** the hard part — VZ's stock VirtioFS exposes no cache/DAX tuning, so we need our own
  **virtiofs server with caching/batching (+ DAX if possible)**. That likely means dropping VZ's
  high-level API for a **custom VMM on `Hypervisor.framework`** (so we control the device models).
  This is the deepest, most expensive piece — OrbStack's real moat.
- **Verify:** `bench.sh` small-file within ~2× of local disk; `npm install` on a bind mount near native.
- **Effort:** 🔴🔴 very large (research-hard, multi-month) · **Risk:** high · **Deps:** ideally after M1–M8.

---

## Milestone vs phase

The M1–M9 detail above is the original feature breakdown (M1–M8 now built; see Status). The
**Phase 0 → 1 → 2** plan is what we actually execute next, after the reassessment: Phase 0 turns
the built-but-shaky foundation into something trustworthy, then Phase 1 (incl. M9) chases real
speed, then Phase 2 the product surface. See the [research report](../orbstack-research.md) for
the OrbStack deep dive.
