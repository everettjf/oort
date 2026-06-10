# FAQ / Troubleshooting

[**English**](./faq.md) | [简体中文](./faq.zh-CN.md)

## Concepts

### Oort vs Docker — aren't they the same thing?
No. They live at **different layers**, and Oort doesn't replace Docker — it *carries and
augments* it.

- **Docker** is the container engine (`dockerd` + the `docker` CLI). It packages and runs
  containers, but containers need a **Linux kernel** to run. macOS has no Linux kernel, so
  Docker can never run on the bare Mac.
- **Oort** is the substrate that gives Docker that kernel: it boots a lightweight Linux VM with
  Apple's `Virtualization.framework`, runs `dockerd` inside it, and projects the engine, ports,
  files, DNS and x86 translation back onto macOS — so the stock `docker` CLI "just works".

After `oort start`, the commands you type are still plain `docker run …`. Oort is the
runtime + adapter layer underneath, not a Docker alternative.

> Analogy: **Docker** is the application; **Oort** is the environment + glue that lets it run on
> a Mac at all.

### So what should I actually compare Oort to?
Not Docker — compare it to the other **Docker-on-Mac backends**: **Docker Desktop**,
**OrbStack**, and **Colima**. They occupy the same layer Oort does (boot a Linux VM, expose
Docker to the Mac).

| | Role |
|---|---|
| **Oort** | Boots a lightweight Linux VM, projects its `dockerd` onto a Mac socket; you keep using the stock `docker` CLI. Open source. |
| **Docker Desktop** | The official backend — also a VM, but heavier and commercially licensed. |
| **OrbStack** | Closed-source, commercial, fast & light. **Oort is an open clone of it.** |
| **Colima** | Open-source Lima/QEMU-based backend; similar idea, different plumbing. |

Beyond just running Docker, Oort adds things the engine itself can't do — e.g. **machine-level
time-travel** (`snapshot` / `restore` / `fork` a whole Linux machine), which even OrbStack
doesn't have. See [Beyond OrbStack](./beyond-orbstack.md).

## Install & build

### `swift build` errors about PCH / module cache path
Usually the `.build/` cache points at an old path (e.g. the directory was moved). Rebuild clean:

```bash
rm -rf .build && swift build -c release
```

### `oort start` fails with an entitlement / virtualization error
VZ requires the `com.apple.security.virtualization` entitlement. `oort` and `run.sh` ad-hoc sign
automatically; if you build by hand, remember:

```bash
codesign --force --sign - --entitlements ./oort.entitlements \
  "$(swift build -c release --show-bin-path)/oort"
```

### `qemu-img: command not found`
```bash
brew install qemu
```

### Go missing / guest agent didn't compile
`./oort build-image` cross-compiles `share/oort-guest`. Needs Go 1.21+:

```bash
go version
```

## Boot & provisioning

### `oort start` keeps "waiting for Docker" then times out
First boot installs the static Docker engine online. Causes & checks:

- **Slow network**: the Docker CDN/mirror is slow. `oort logs` shows guest progress; or pre-stage
  the docker tarball on the host into `share/docker-27.3.1.tgz` (cloud-init prefers it).
- **DNS issues**: cloud-init disables IPv6 and hardcodes `1.1.1.1`. If your network blocks
  1.1.1.1, change the resolver in `cloud-init/user-data`.
- To re-provision cleanly: `./oort build-image` (resets the disk; cloud-init reruns).

### VM runs but Docker stays "unreachable" — how do I see inside the guest?
`oort doctor` first: it tells VM / dockerd / agent apart. If **all** vsock ports reset
(doctor shows Docker *and* Agent down) while the VM is clearly booted, you can still get
in over SSH — the cloud image enables password auth (user `ubuntu`, password `oort`),
and VZ NAT registers the guest's DHCP lease on the Mac:

```bash
grep -A2 'name=oort' /var/db/dhcpd_leases   # find ip_address=192.168.64.x
ssh ubuntu@192.168.64.x                      # password: oort
journalctl -u oort-guest -n 50               # agent logs
lsmod | grep vsock                           # transport loaded?
```

Case study: on newer noble cloud kernels (6.8.0-117) the guest stopped autoloading
`vmw_vsock_virtio_transport` — the agent listened happily on a transportless vsock
core and every host connect got RST. Provisioning now pins the module via
`/etc/modules-load.d/oort-vsock.conf`; if you hit the same signature on an old golden
image, `sudo modprobe vmw_vsock_virtio_transport` inside the guest fixes it live
(then rebuild with `oort build-image`).

### `oort build-image` fails with "Failed to lock byte"
Something still holds the disk image. A force-killed engine (`kill -9`) orphans
its Virtualization XPC child, which keeps a byte-range lock on `disk.img` —
`build-image` now clears holders automatically, but if you hit this elsewhere:
`lsof -t images/disk.img | xargs kill -9`.

### Startup is slow / it reinstalls Docker every time
`oort build-image` resets the disk and re-provisions. **`oort start` alone (without build-image)
reuses the provisioned disk** and boots in seconds. Day to day:

```bash
./oort start        # reuses the existing images/disk.img
```

### I can't see kernel boot logs
VZ's serial is virtio-console (`hvc0`), while the Ubuntu kernel logs to `ttyS0/ttyAMA0` by
default — so `console.log` only shows the login prompt, not early kernel logs. To observe
provisioning, use `oort exec` to inspect guest state, or read cloud-init output in
`~/.oort/console.log`.

## Using Docker

### `docker` hits Docker Desktop instead of oort
`DOCKER_HOST` isn't set. Two ways:

```bash
export DOCKER_HOST=unix://$HOME/.oort/docker.sock   # or eval "$(oort env)"
# or use passthrough directly:
oort docker ps
```

### `-v /mnt/mac:/x` says "path not shared / File Sharing"
That's the **Docker Desktop CLI**'s client-side check (it treats `/mnt/mac` as a macOS path).
Make sure `DOCKER_HOST` points at oort; `oort docker ...` avoids it. Note `/mnt/mac` is a path
*inside the guest*.

### Bind mounts can't see files
Check: ① oort was started with `--mount` (`oort start` shares `./share` → `/mnt/mac` by
default); ② the file is actually in the shared dir; ③ the container mounts `/mnt/mac` (the guest
path), not a macOS path.

```bash
oort exec 'mount | grep virtiofs; ls -la /mnt/mac'
```

### `--platform linux/amd64` says "exec format error"
The Rosetta binfmt isn't registered. Make sure you started with `--rosetta`, and check:

```bash
oort exec 'cat /proc/sys/fs/binfmt_misc/rosetta'   # should show enabled + interpreter /mnt/rosetta/rosetta
```

### `curl localhost:<port>` doesn't connect
Port forwarding polls Docker every 2s, so wait a moment after publishing. Check:

```bash
oort logs            # should show "forwarding 127.0.0.1:<port> → guest:<port>"
oort docker ps       # confirm the port is published (0.0.0.0:8080->80/tcp)
```
If you used `--no-port-forward`, no forwarding happens.

## Features & limits

### zram / dynamic memory
Both are on by default. Provisioning installs the `zram` kernel module (it's not in the base
cloud kernel) so a compressed RAM swap comes up on boot, and a host-side balloon loop returns
idle guest memory to macOS (target tracks usage, capped at `--memory`). Disable the balloon with
`--no-dynamic-memory`.

### Developing on a mounted source dir is slow
VirtioFS bind mounts have a per-call (FUSE) overhead — `bench.sh` shows small-file/metadata ops
much slower than the guest's own disk (this is the gap a custom VirtioFS/DAX layer would close;
see the [roadmap](./roadmap.md)). The standard mitigation, same as other Docker-on-Mac setups:
keep **metadata-heavy hot directories in a Docker named volume** rather than on the bind mount —
e.g. mount your source read-write but put `node_modules` / build output in a volume:

```bash
docker run -v "$PWD:$PWD" -w "$PWD" -v myproj_node_modules:"$PWD/node_modules" node:20 npm install
```

The benefit is workload-dependent (it helps metadata-churny tools like `npm`/`yarn`); plain
sequential read/write over VirtioFS is already close to native.

### Can containers reach the internet?
Yes. dockerd manages its own iptables NAT/MASQUERADE rules (the base cloud image ships
iptables with the nft backend), so containers have outbound network — `docker build` steps
like `RUN apk add` / `npm install`, and runtime egress, all work.

## Cleanup / reset

```bash
oort stop
rm -f images/disk.img images/disk.img.nvram images/seed.img   # delete the provisioned disk
./oort build-image                                             # rebuild
```

Host-side sockets / logs live in `~/.oort/` and are safe to delete (after the VM stops).

---

Still stuck? See [Architecture](./architecture.md) for the internals, or open an issue.
