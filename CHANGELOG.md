# Changelog

All notable changes to Oort. Dates are YYYY-MM-DD.

## Unreleased

- **Self-contained `oort.app` — no repo clone needed.** The bundle now ships a
  complete oort home (CLI, prebuilt + pre-entitled engine, prebuilt guest
  agent, cloud-init, make-image, the net helper and MCP server, plus a
  pre-staged Docker tarball for deterministic provisioning; `OORT_APP_SLIM=1`
  omits it). All mutable data lives under `~/.oort` — the bundle is never
  written to (that would break its signature). First `oort start` (or GUI
  launch) downloads the Ubuntu cloud image once and builds the golden disk;
  `qemu-img` (brew install qemu) is the one external dependency. Verified
  end-to-end from a pristine fake `$HOME`: bootstrap → provision →
  direct-kernel boot → `docker run` → clean stop. Repo checkouts keep the
  old layout (`.bundled` marker switches modes).

## v0.3.0 — 2026-06-10

The "lives on your Mac" release: the guest's filesystem in Finder, Mac
commands from Linux shells, ssh/VS Code into the guest, disk space that
returns itself — plus two root-cause fixes (the suspend/resume agent
starvation and the golden-image kernel/module mismatch).

- **`oort ssh` + VS Code Remote-SSH.** The guest's sshd is projected onto a
  stable `localhost:2222` (new `--tcp-forward host:guest` syntax), surviving
  guest-IP changes and gvproxy. `oort ssh setup` injects a dedicated keypair
  (re-injected on every start, so disk rebuilds self-heal) and writes a
  `Host oort` block into `~/.ssh/config` — after that `ssh oort`, `scp`,
  and VS Code's Remote-SSH "oort" just work; `oort ssh <machine> [cmd]`
  shells into a machine. Verified live (ubuntu + root + machine + sftp).
- **`mac` — run Mac commands from inside the guest** (OrbStack's reverse
  direction): `mac open https://…`, `mac pbpaste`, `mac say done` from any
  guest shell — output streams back and the exit code propagates. The engine
  serves a guest-reachable vsock port (VZVirtioSocketListener); the guest
  client is the agent binary in client mode behind a `mac` symlink. Runs as
  your Mac user via your login shell — same trust model as OrbStack's `mac`;
  `--no-mac-exec` disables it.
- **Fix: golden images could bake a kernel that can't load its own modules.**
  The zram step's apt can upgrade kernel+modules to a NEWER REBUILD of the
  same version string (6.8.0-117.X → .Y); staging the direct-boot kernel
  while dpkg was mid-replace baked an old vmlinuz next to new /lib/modules —
  every module load then failed with "Unknown symbol" (this killed
  nf_tables→dockerd outright, and is the real story behind the earlier
  vmw_vsock_virtio_transport failures). build-image now waits for apt/dpkg
  to go completely quiet before reading /boot, and drops a stale
  images/kernel-Image (forcing consistent EFI boot) when it can't.
- **Robustness sweep from running the full fresh-image suite end to end:**
  `build-image` now clears stale disk-image holders first (a force-killed
  engine orphans its VZ XPC child, which keeps a byte lock — "Failed to lock
  byte 101"); `oort suspend` refuses to freeze a VM whose agent is
  mid-restart/dead (the resumed guest would have no control channel); the
  https stage/probe helpers use best-effort curl instead of `cmd_exec`
  (whose internal `exit 1` killed the whole script when the staged command's
  trailing agent restart cut the reply — this broke build-image's
  provisioning boot); e2e waits for the agent to settle after restarts
  instead of sleeping; and provisioning is deterministic when
  `share/docker-27.3.1.tgz` is pre-staged (the in-guest CDN download
  otherwise races the 5-minute start ceiling on slow networks).
- **`~/Oort` in Finder — `oort fs open`.** The guest's and every machine's
  live filesystem, browsable and read-write from macOS (OrbStack's
  `~/OrbStack`): a pure-Go NFSv3 server in the agent exports `guest/` (the
  whole guest) and `machines/<name>/` (each machine's merged rootfs,
  reconciled as machines start/stop) — no guest packages, and the macOS mount
  needs **no sudo** (user mount + noresvport). Auto-remounted across
  restarts/resume, auto-unmounted on stop/suspend so a frozen guest can never
  wedge Finder. Verified: read guest files, write a file from the Mac and
  read it inside the machine.
- **Fix: suspend/resume slowly starved the guest agent (the "empty exec"
  failure).** Every engine restart — above all suspend/resume — left the
  restored guest holding vsock connections whose host peers no longer exist
  and never RST; each stranded two agent goroutines + fds. Enough cycles and
  `oort exec` returned empty (pipe/fork starvation) while ssh/tcp-forwards
  failed — yet the heartbeat (one fd) kept the watchdog happy, so it never
  self-healed. The engine now pings a reset port (2379) on every start and
  the agent drops all previously-bridged connections. Verified: back-to-back
  suspend/resume cycles keep exec+ssh green, reset events logged.
- **Disk space returns to macOS — `oort disk reclaim` + a daily timer.** VZ
  passes guest TRIM through to the raw image as APFS hole-punches, so freed
  guest space literally shrinks the host file. `oort disk reclaim [--prune]`
  does it on demand (verified: 800M of guest churn → exactly 800M returned);
  the in-guest `oort-trim.timer` runs it shortly after boot and daily
  (Ubuntu's stock fstrim.timer is only weekly). `oort disk` shows usage.
- **Fix: container IPs were routable but not reachable.** `oort route`/
  `oort domains` resolved names and routed 172.17/16 to the guest, but
  dockerd's FORWARD policy (DROP) swallowed every unpublished port — only the
  https path worked (its REDIRECT lands in INPUT, not FORWARD). The agent now
  keeps an `enp0s1 → docker0 ACCEPT` in DOCKER-USER (the chain Docker reserves
  for user rules and never flushes), re-asserted periodically. Verified from
  macOS: `curl http://web.oort.local` (unpublished port), trusted
  `https://web.oort.local`, and ping — the full last mile, end to end.

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
