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
| M5 | Networking | 🟡 partial — DNS-following verified; `orb route` + full netstack pending |
| M6 | Kubernetes (k3s) | 🟢 code-complete — live re-verify pending* |
| M7 | Multiple machines | 🟢 code-complete — live re-verify pending* |
| M8 | Native menu-bar GUI | ✅ builds & launches (UI not visually verified headless) |
| M9 | Native-speed filesystem | ⛔ not started (the hard moat) |

\* M6/M7 are implemented and reuse verified paths, but a clean end-to-end run
couldn't be completed in the build session — the local VZ environment kept
failing to boot a VM reliably. Re-verify on a fresh machine state.

## Parity scorecard

| Dimension | OrbStack | openorb now | Target milestone |
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
- **Goal:** `orb start` on an already-provisioned disk in **≤ 3 s**; provisioning never reruns.
- **Tasks:** make `orb build-image` produce a fully-provisioned "golden" disk (boot once, let
  cloud-init finish, snapshot); `orb start` reuses it read-fast; keep a pristine copy so resets are cheap.
- **Verify:** `time orb start` ≤ 3 s; `docker run hello-world` immediately after.
- **Effort:** 🟢 small · **Risk:** low · **Deps:** none.

## M2 — Fast boot + custom kernel
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
- **Tasks:** an `orb` helper + docs for the named-volume workflow (keep `node_modules`/build dirs
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
  write/merge a kubeconfig; `orb k8s enable/disable`.
- **Verify:** `kubectl get nodes` and a sample deployment from macOS.
- **Effort:** 🟡 medium · **Risk:** low–medium · **Deps:** M5 nice-to-have (service networking).

## M7 — Multiple Linux machines
- **Goal:** OrbStack-style named, multi-distro machines on the shared kernel.
- **Tasks:** manage multiple rootfs images; `orb machine create/list/delete/exec`; per-machine
  mounts/networking; one SSH/exec multiplexer.
- **Verify:** create an Ubuntu and an Alpine machine, exec into each, files isolated.
- **Effort:** 🔴 large · **Risk:** medium · **Deps:** M2 (shared custom kernel helps).

## M8 — GUI
- **Goal:** a native app experience, not just CLI.
- **Tasks:** a **SwiftUI** app wrapping the engine — status/menu-bar, containers, machines, logs,
  settings, start/stop; bundle the `openorb` engine + guest agent.
- **Verify:** install the `.app`, manage everything from the UI.
- **Effort:** 🔴 large · **Risk:** low (engineering, not research) · **Deps:** M6/M7 for full surface.

## M9 — The moat: native-speed filesystem
- **Goal:** match OrbStack's ~75–95% native bind-mount speed (vs ~21× slower today).
- **Tasks:** the hard part — VZ's stock VirtioFS exposes no cache/DAX tuning, so we need our own
  **virtiofs server with caching/batching (+ DAX if possible)**. That likely means dropping VZ's
  high-level API for a **custom VMM on `Hypervisor.framework`** (so we control the device models).
  This is the deepest, most expensive piece — OrbStack's real moat.
- **Verify:** `bench.sh` small-file within ~2× of local disk; `npm install` on a bind mount near native.
- **Effort:** 🔴🔴 very large (research-hard, multi-month) · **Risk:** high · **Deps:** ideally after M1–M8.

---

## Sequencing

1. **M1 → M2 → M3** — speed & efficiency basics (startup, boot, memory). Biggest perceived-speed win for least effort.
2. **M4** — make dev-on-mounts usable in the meantime.
3. **M5 → M6 → M7 → M8** — close the experience gap (networking, k8s, machines, GUI).
4. **M9** — the filesystem moat, last (the only research-hard item).

After M1–M8, openorb *looks and feels* like OrbStack. M9 is what makes it *truly as fast* on the
filesystem. See the [research report](../orbstack-research.md) for the deep dive.
