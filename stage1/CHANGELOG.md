# Changelog

## v0.1.0 — first releasable version

A working, OrbStack-style Docker & Linux runtime for macOS (Apple Silicon),
built on Apple's `Virtualization.framework`. Verified end-to-end on macOS 26.3.

**Stage 1 — Docker over vsock**
- Boot a lightweight Linux VM via `Virtualization.framework` (virtio block/net/vsock/console).
- `DockerSocketProxy`: project the guest Docker engine onto a macOS Unix socket over vsock.
- Verified: `docker run --rm hello-world`.

**Stage 2 — files & x86**
- VirtioFS host-directory sharing (`--mount`, default `/mnt/mac`), bidirectional.
- Rosetta x86-64 translation (`--rosetta`) via a shared Rosetta dir + `binfmt_misc` (F-flag).
- Verified: read/write macOS files from a container; `linux/amd64` container → `x86_64`.

**Stage 3 — networking**
- Generic vsock forwarding (`--forward sock:port`).
- `PortForwarder`: auto-forward container-published ports to macOS `127.0.0.1`.
- Verified: `docker run -p 8088:80` → `curl localhost:8088`.

**Stage 4 — experience**
- `orb` CLI: start/stop/restart/status, `exec`/`shell`, `docker` passthrough, `env`, `logs`, `build-image`.
- zram swap service (no-ops on kernels without the module).

**Engineering**
- Apt-free guest provisioning: static Docker engine staged on the VirtioFS share.
- Replaced fragile Python vsock services with one compiled Go binary (`openorb-guest`)
  serving the docker bridge, exec agent, and tcp-forward — stable under sustained load.
- Hardened the proxy against fd/connection leaks on HTTP keep-alive (full-duplex teardown).

### Known limitations
- zram requires a kernel with the `zram` module (stock Ubuntu cloud kernel lacks it).
- Dynamic memory ballooning not yet active; single shared-kernel VM only.
