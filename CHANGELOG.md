# Changelog

All notable changes to Oort. Dates are YYYY-MM-DD.

## Unreleased

- **Instant resume — `oort suspend`.** Freezes the whole VM (RAM + devices) to
  `~/.oort/vmstate.bin` via VZ save/restore (macOS 14+); the next `oort start`
  resumes in **~1.2s** (cold boot: ~4.4s; OrbStack: ~1–2s cold) with running
  containers, shells and sockets intact, and re-steps the guest clock. The state
  is one-shot (deleted on restore) and auto-discarded when the disk image changes
  underneath it; any restore failure falls back to a cold boot. Required persisting
  the `VZGenericMachineIdentifier` next to the disk — a fresh random identity made
  restore fail with VZ's opaque "invalid argument". `oort status` now shows
  "suspended"; e2e covers state-survival across suspend/resume and resume speed.
- **`*.oort.local` domains** — OrbStack's beloved `*.orb.local`, for oort. The engine
  now runs a tiny DNS responder on `127.0.0.1:5354` (UDP; `--dns-port`, `0` disables)
  answering for containers (`web.oort.local`), machines (`dev.oort.local`), and compose
  services (`api.myproj.oort.local`) straight from the live Docker state. New
  `oort domains enable|route|disable|status`: `enable` (sudo, one-time) writes a
  domain-scoped `/etc/resolver/oort.local` and adds the container route, after which
  **any** container port is reachable by name — no `-p` publishing. The route follows
  the guest IP across restarts; `oort start` reminds, `oort domains route` refreshes.
  VZ NAT mode only. Verified e2e (container / machine / compose-label names, NXDOMAIN,
  AAAA, case-insensitive; new e2e section).
- **Fix: vsock dead on current noble cloud images (silent total failure).** On newer
  noble kernels (seen on 6.8.0-117) the guest no longer autoloads
  `vmw_vsock_virtio_transport` on golden-image boots: the agent listened on a
  transportless vsock core and every host connect got RST — `oort start` timed out with
  Docker "unreachable" while everything inside the guest looked healthy. Provisioning
  now installs `/etc/modules-load.d/oort-vsock.conf` so the transport loads explicitly
  at every boot. (Root-caused live: modprobe'ing the transport instantly restored the
  projected socket.)

## v0.1.0 — 2026-05-30

First public release.

Oort runs fast, lightweight Linux machines and sandboxes on macOS — many on one
shared kernel, like the Oort cloud's countless small bodies. It pairs a Docker-ready
VM with machine time-travel, AI-agent sandboxes, and env-as-code (`oort.yaml`).

Highlights:

- **`oort` CLI** — `start`, `machine`, `snapshot`, `fastvol`, `doctor`, `gui`, and more.
- **Native SwiftUI app** — package as `oort.app` / `.dmg`.
- **Fast boot** — direct-kernel boot with a self-compiled, stripped kernel.
- **User-space network stack** — gvproxy (opt-in).
- **Fast bind-mounted projects** — `oort fastvol` keeps hot dirs on the guest disk.
- **State** lives under `~/.oort`; environment configured via `OORT_*` vars.
