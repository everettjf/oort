# FAQ / Troubleshooting

[**English**](./faq.md) | [简体中文](./faq.zh-CN.md)

## Install & build

### `swift build` errors about PCH / module cache path
Usually the `.build/` cache points at an old path (e.g. the directory was moved). Rebuild clean:

```bash
rm -rf .build && swift build -c release
```

### `orb start` fails with an entitlement / virtualization error
VZ requires the `com.apple.security.virtualization` entitlement. `orb` and `run.sh` ad-hoc sign
automatically; if you build by hand, remember:

```bash
codesign --force --sign - --entitlements ./openorb.entitlements \
  "$(swift build -c release --show-bin-path)/openorb"
```

### `qemu-img: command not found`
```bash
brew install qemu
```

### Go missing / guest agent didn't compile
`./orb build-image` cross-compiles `share/openorb-guest`. Needs Go 1.21+:

```bash
go version
```

## Boot & provisioning

### `orb start` keeps "waiting for Docker" then times out
First boot installs the static Docker engine online. Causes & checks:

- **Slow network**: the Docker CDN/mirror is slow. `orb logs` shows guest progress; or pre-stage
  the docker tarball on the host into `share/docker-27.3.1.tgz` (cloud-init prefers it).
- **DNS issues**: cloud-init disables IPv6 and hardcodes `1.1.1.1`. If your network blocks
  1.1.1.1, change the resolver in `cloud-init/user-data`.
- To re-provision cleanly: `./orb build-image` (resets the disk; cloud-init reruns).

### Startup is slow / it reinstalls Docker every time
`orb build-image` resets the disk and re-provisions. **`orb start` alone (without build-image)
reuses the provisioned disk** and boots in seconds. Day to day:

```bash
./orb start        # reuses the existing images/disk.img
```

### I can't see kernel boot logs
VZ's serial is virtio-console (`hvc0`), while the Ubuntu kernel logs to `ttyS0/ttyAMA0` by
default — so `console.log` only shows the login prompt, not early kernel logs. To observe
provisioning, use `orb exec` to inspect guest state, or read cloud-init output in
`~/.openorb/console.log`.

## Using Docker

### `docker` hits Docker Desktop instead of openorb
`DOCKER_HOST` isn't set. Two ways:

```bash
export DOCKER_HOST=unix://$HOME/.openorb/docker.sock   # or eval "$(orb env)"
# or use passthrough directly:
orb docker ps
```

### `-v /mnt/mac:/x` says "path not shared / File Sharing"
That's the **Docker Desktop CLI**'s client-side check (it treats `/mnt/mac` as a macOS path).
Make sure `DOCKER_HOST` points at openorb; `orb docker ...` avoids it. Note `/mnt/mac` is a path
*inside the guest*.

### Bind mounts can't see files
Check: ① openorb was started with `--mount` (`orb start` shares `./share` → `/mnt/mac` by
default); ② the file is actually in the shared dir; ③ the container mounts `/mnt/mac` (the guest
path), not a macOS path.

```bash
orb exec 'mount | grep virtiofs; ls -la /mnt/mac'
```

### `--platform linux/amd64` says "exec format error"
The Rosetta binfmt isn't registered. Make sure you started with `--rosetta`, and check:

```bash
orb exec 'cat /proc/sys/fs/binfmt_misc/rosetta'   # should show enabled + interpreter /mnt/rosetta/rosetta
```

### `curl localhost:<port>` doesn't connect
Port forwarding polls Docker every 2s, so wait a moment after publishing. Check:

```bash
orb logs            # should show "forwarding 127.0.0.1:<port> → guest:<port>"
orb docker ps       # confirm the port is published (0.0.0.0:8080->80/tcp)
```
If you used `--no-port-forward`, no forwarding happens.

## Features & limits

### zram isn't active
The stock Ubuntu cloud kernel **lacks the `zram` module** (it lives in `linux-modules-extra`),
so the zram service no-ops. This is exactly the value of OrbStack's custom kernel. To enable it:
use a kernel that has the module, or install `linux-modules-extra-$(uname -r)` (needs apt).

### Memory usage / dynamic memory
The VirtIO balloon device is attached, but active ballooning (grow/reclaim on demand) isn't
wired yet. Use `--memory` to cap it.

### Can containers reach the internet?
dockerd currently starts with `--iptables=false` (to avoid an iptables package dependency), so
container-to-internet NAT isn't fully wired — local runs/builds and image pulls (dockerd uses
the host network) all work. Full container egress is future work.

## Cleanup / reset

```bash
orb stop
rm -f images/disk.img images/disk.img.nvram images/seed.img   # delete the provisioned disk
./orb build-image                                             # rebuild
```

Host-side sockets / logs live in `~/.openorb/` and are safe to delete (after the VM stops).

---

Still stuck? See [Architecture](./architecture.md) for the internals, or open an issue.
