# Changelog

All notable changes to Oort. Dates are YYYY-MM-DD.

## v0.2.0 — 2026-06-09

The "daily-driver" release: instant resume, container domains with trusted
HTTPS, zero-config docker CLI, sudo-free networking, debug-anything — plus two
deep streaming fixes in the docker projection.

- **Suspend/resume hardening.** The stale-state guard now stamps the disk's
  post-suspend mtime and requires an exact match (the old `-nt` comparison
  raced VZ's final disk flush during the save, discarding good states). Also
  root-caused the opaque restore "permission denied": macOS withholds the
  state file's decryption key while the screen is LOCKED — saves work, but a
  locked-session start falls back to a cold boot (now logged clearly; the e2e
  suspend section auto-skips when locked).
- **HTTPS for `*.oort.local` — `oort https enable`.** Trusted
  `https://web.oort.local` for any container, OrbStack-style: a local CA is
  generated on the Mac and trusted once in the system keychain (the only
  sudo); the guest agent terminates TLS for container-IP:443 (iptables
  REDIRECT → :8443), mints a per-SNI leaf on the fly (so every name level
  works — `api.myproj.oort.local` included), and forwards plain HTTP to the
  container's :80. Verified in-guest: TLS handshake, CA chain validation,
  arbitrary-SNI minting, backend-by-name resolution.
- **`oort debug <container>` — toolbox shell into ANY container** (OrbStack's
  `orb debug`): a busybox toolbox joins the target's pid+net namespaces, so
  distroless/shell-less containers get ps/netstat/wget/vi against the live
  process; the target's root filesystem is at `/proc/1/root`. Run a one-shot
  command (`oort debug web 'cat /proc/1/root/etc/nginx/nginx.conf'`) or get an
  interactive shell.
- **Fix: `docker run`/`exec`/attach output was lost through the projected
  socket** — `docker run --rm alpine echo hi` printed nothing. Both relay ends
  (host proxy and guest agent) tore down the whole connection on the FIRST
  EOF, racing the hijacked attach stream's reply. Both now propagate
  half-closes properly.
- **Fix: one stalled docker client could freeze the whole VM's I/O.** VZ
  delivers every vsock connection through ONE serial device queue that does a
  blocking `writev` into the connection's host fd (verified by sampling the
  Virtualization XPC process mid-wedge). A client that stopped reading — e.g.
  `docker run … | head -1` — filled its socket buffer, blocked that queue, and
  froze docker, the agent and all port forwards until restart. The guest→host
  relay direction is now a poll-based pump that ALWAYS drains the vsock fd,
  buffering up to 32 MiB toward a slow client and killing only that connection
  on overflow. Verified: 5 concurrent vanish-mid-stream clients plus a 50 MB
  flood into a never-reading pipe leave Docker fully responsive. (Also ignore
  SIGPIPE engine-wide — a relay writing to a vanished peer used to kill the
  whole engine.)
- **Sudo-free networking — `oort net install`.** A one-time-installed root
  LaunchDaemon (the privileged-helper pattern OrbStack uses) watches
  `~/.oort/net-request` and applies exactly two strictly-validated operations:
  the 172.17/16 container route and `/etc/resolver/oort.local`. After install,
  `oort start` refreshes the route automatically on every boot and
  `oort domains`/`oort route` never ask for sudo again. Requests are validated
  against fixed patterns (gateway must be 192.168.x.x, port 1024–65535,
  injection-tested); all privileged writes go to fixed root-owned paths.
- **`oort` docker context — the stock docker CLI just works.** `oort start`
  registers/refreshes a `oort` context and auto-selects it when the current
  context is `default` or its engine is dead (e.g. desktop-linux with Docker
  Desktop closed) — never stealing a live one. `oort stop` restores the
  previous context. No more `export DOCKER_HOST` (which still overrides
  contexts when set).
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
