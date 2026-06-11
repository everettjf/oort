# CLI Reference

[**English**](./cli-reference.md) | [简体中文](./cli-reference.zh-CN.md)

Every `oort` subcommand, plus all flags of the underlying engine `oort run`.

## `oort` — the front-end

`oort` is a thin wrapper around `oort run` that codifies common launch flags and adds
lifecycle / exec / passthrough conveniences.

| Command | Description |
|---|---|
| `oort start` | Boot the VM (Docker + file sharing + Rosetta + port forwarding); wait until Docker is ready and print `DOCKER_HOST`. If a suspended state exists, **resumes it in ~1s** with containers still running |
| `oort suspend` | Freeze the whole VM (RAM + devices) to `~/.oort/vmstate.bin` and exit; the next `oort start` resumes instantly. The guest clock is re-stepped on resume. Note: macOS withholds the state's decryption key while the screen is locked — a locked-session start falls back to a cold boot |
| `oort stop` | Cleanly shut the VM down |
| `oort restart` | stop then start |
| `oort status` | Show VM and Docker status |
| `oort exec <cmd...>` | Run a command in the guest (via the vsock agent) |
| `oort shell` | Simple line-at-a-time guest shell |
| `oort docker <args...>` | Run `docker` against the oort daemon |
| `oort env` | Print `export DOCKER_HOST=...`; use `eval "$(oort env)"` — usually unnecessary: `oort start` registers a **`oort` docker context** and selects it when the current one is `default` or dead, so the stock `docker` CLI just works (`oort stop` restores the previous context; note an exported `DOCKER_HOST` always overrides contexts) |
| `oort logs` | Tail the guest console log |
| `oort build-image` | (Re)build the boot disk + cloud-init seed + cross-compile the agent |
| `oort reset` | Restore the disk from the golden snapshot |
| `oort net install\|uninstall\|status` | One-time root helper (sudo once): after it, routes and `*.oort.local` apply automatically — no sudo ever again |
| `oort route enable\|disable` | Reach containers by their docker0 IP from macOS (sudo-free with the net helper) |
| `oort domains enable\|route\|disable` | `*.oort.local` names for containers/machines/compose services (sudo, see below) |
| `oort k8s enable\|disable` | Run Kubernetes (k3s) in the guest. With `oort domains`, Services resolve as `<svc>.k8s.oort.local` / `<svc>.<ns>.k8s.oort.local` (ClusterIPs routed via the net helper) |
| `oort debug <container> [cmd...]` | Toolbox shell into ANY container, even distroless: busybox joins the target's pid+net namespaces; target rootfs at `/proc/1/root` |
| `oort https enable\|disable` | Trusted `https://web.oort.local` for any container: local CA (trusted once, sudo), TLS terminated in-guest with per-name certs, forwarded to the container's :80. Needs `oort domains` |
| `oort ssh [setup\|machine [cmd...]]` | `setup` writes a `Host oort` block (guest sshd on a stable `localhost:2222`) — then `ssh oort` and **VS Code Remote-SSH** just work; `oort ssh <machine>` shells into a machine. Key re-injected on every start |
| `oort disk [reclaim [--prune]]` | Show disk usage / return freed guest space to macOS right now (TRIM → APFS hole-punch; `--prune` clears unused docker data first). A daily in-guest timer also runs it |
| `oort fs [open\|mount\|umount]` | The guest's and every machine's filesystem in Finder at `~/Oort` (`guest/`, `machines/<name>/`) — in-agent NFS export, mounted with **no sudo**; read-write both ways. Auto-remounted across restarts/resume, auto-unmounted on stop/suspend |
| `mac <cmd…>` *(inside the guest)* | Run a command **on the Mac** from any guest shell — output and exit code come back (`mac open https://…`, `mac pbpaste`, `mac say done`). Runs as your Mac user via your login shell; disable with `--no-mac-exec` |
| `oort machine ...` | Manage named Linux machines (see below) |
| `oort up [file]` | Bring up machines declared in `oort.yaml`/`.json` (env-as-code); runs each machine's one-time `setup` |
| `oort down [file]` | Tear those machines down (`--purge` also drops their snapshots) |
| `oort mcp` | Run the MCP server (stdio): oort sandboxes as tools for AI agents — see [`mcp/`](../mcp/README.md) |
| `oort gui` | Launch the native menu-bar app |
| `oort help` | Show help |

### `oort machine` — named Linux machines + time-travel

Machines are persistent, multi-distro environments you shell into (OrbStack's
"machines"), backed by long-lived containers on the shared guest kernel. Because
a machine is just a container, its whole filesystem is a content-addressed image
— so oort can **snapshot, roll back and fork** an environment, which OrbStack
cannot. "git for dev environments."

| Command | Description |
|---|---|
| `oort machine create <name> [distro]` | Create a machine (default distro `ubuntu`) |
| `oort machine list` | List machines |
| `oort machine shell <name>` | Interactive shell into a machine |
| `oort machine exec <name> <cmd...>` | Run a command in a machine |
| `oort machine delete <name> [--purge]` | Delete the machine; `--purge` also drops its snapshots |
| `oort machine snapshot <name> [tag]` | Commit the machine's live state to a tagged image (tag defaults to a timestamp) |
| `oort machine snapshots <name>` | List a machine's snapshots |
| `oort machine restore <name> [tag]` | Roll a machine back to a snapshot (newest if no tag) |
| `oort machine fork <src> <newname>` | **Instantly branch** a fully-set-up machine into a new one (CoW, no re-provisioning) |

```bash
oort machine create devbox ubuntu
oort machine exec devbox apt-get install -y …      # configure it
oort machine snapshot devbox clean-baseline        # checkpoint
# … experiment, maybe break things …
oort machine restore devbox clean-baseline         # roll back
oort machine fork devbox feature-x                 # branch into a parallel env
```

### `oort domains` — `*.oort.local` names (OrbStack's `*.orb.local`)

The engine runs a tiny DNS responder on `127.0.0.1:5354` (UDP; `OORT_DNS_PORT` /
`--dns-port` to change, `0` disables). It answers from the live Docker state:

| Name | Resolves to |
|---|---|
| `<container>.oort.local` | that container's bridge IP |
| `<machine>.oort.local` | the machine's container (`ovm-` prefix stripped) |
| `<service>.<project>.oort.local` | a compose service's container |

`oort domains enable` (sudo, one-time) writes `/etc/resolver/oort.local` so macOS
sends only `*.oort.local` queries there, and adds the `172.17.0.0/16 → guest`
route — after that, **any** container port is reachable by name, no `-p` needed:

```bash
oort domains enable
docker run -d --name web nginx
curl http://web.oort.local            # no published port required
```

The route follows the guest IP, which can change across VM restarts. With the
**net helper** installed (`oort net install`, one sudo, ever), `oort start`
refreshes it automatically; without it, `oort start` prints a reminder and
`oort domains route` refreshes it (sudo). The helper is a tiny root LaunchDaemon
that watches `~/.oort/net-request` and applies exactly two validated operations
(the 172.17/16 route + the resolver file) — see `tools/oort-nethelper.sh`.
`oort domains` alone shows status; `disable` removes the resolver file + route.
Note: requires the default VZ NAT networking (not `OORT_NET=gvproxy`).

### Examples

```bash
./oort build-image
./oort start
eval "$(./oort env)"

docker run --rm hello-world
oort docker ps
oort exec 'free -m'
oort status
oort stop
```

### Environment variables

`oort` lets you override default paths:

| Variable | Default | Meaning |
|---|---|---|
| `OORT_DISK` | `./images/disk.img` | boot disk path |
| `OORT_SEED` | `./images/seed.img` | cloud-init seed path |
| `OORT_SHARE` | `./share` | directory shared into the guest (tag `mac`) |

Host-side state lives under `~/.oort/`:

| File | Purpose |
|---|---|
| `~/.oort/docker.sock` | projected Docker socket (`DOCKER_HOST` points here) |
| `~/.oort/agent.sock` | exec agent (used by `oort exec`, forwarded to vsock 2376) |
| `~/.oort/console.log` | guest console log |
| `~/.oort/vm.pid` / `vm.log` | VM process PID / log |

---

## `oort run` — the engine

This is what `oort` ultimately invokes. Use it directly for full control (first
`swift build -c release` and codesign, or use `./run.sh`).

```
oort run --disk <path> [options]
```

### Boot

| Flag | Description |
|---|---|
| `--disk <path>` | Bootable raw disk image (required) |
| `--seed <path>` | Extra read-only disk, e.g. a cloud-init CIDATA image |
| `--nvram <path>` | EFI variable store path (default `<disk>.nvram`) |
| `--kernel <path>` | Direct-kernel boot image (switches to `VZLinuxBootLoader`, disables EFI) |
| `--initrd <path>` | initramfs for direct-kernel boot (optional) |
| `--cmdline <string>` | Kernel command line (default `console=hvc0 root=/dev/vda rw`) |

### Resources

| Flag | Description |
|---|---|
| `--cpus <n>` | vCPU count (default 4) |
| `--memory <GiB>` | Memory in GiB (default 4) |

### File sharing (VirtioFS)

| Flag | Description |
|---|---|
| `--mount <hostdir>[:tag][:ro]` | Share a host dir into the guest via VirtioFS (repeatable). First one's default tag is `mac`; the guest mounts at `/mnt/<tag>`. Add `:ro` for read-only |
| `--rosetta` | Share Rosetta so x86-64 images run via translation (installs Rosetta on demand) |

### Docker projection / forwarding

| Flag | Description |
|---|---|
| `--socket <path>` | Host Docker Unix socket (default `~/.oort/docker.sock`) |
| `--vsock-port <n>` | Guest vsock port serving dockerd (default 2375) |
| `--forward <sock>:<port>` | Extra host-socket ⇄ guest-vsock-port forward (repeatable, e.g. expose the agent at `~/.oort/agent.sock:2376`) |
| `--no-port-forward` | Disable auto-forwarding container ports to localhost |

### Misc

| Flag | Description |
|---|---|
| `--no-console` | Don't attach the guest serial to stdio |
| `--console-log <path>` | Write the guest console to a file (headless) |
| `-h`, `--help` | Show help |

### Equivalent

`oort start` is roughly equivalent to:

```bash
oort run \
  --disk images/disk.img --seed images/seed.img \
  --mount "$PWD/share:mac" --rosetta \
  --forward "$HOME/.oort/agent.sock:2376" \
  --no-console --console-log "$HOME/.oort/console.log" \
  --socket "$HOME/.oort/docker.sock"
```

---

## Guest vsock ports

`oort-guest` (the Go agent) listens inside the guest on:

| vsock port | Service |
|---|---|
| 2375 | Docker bridge (→ `/run/docker.sock`) |
| 2376 | exec (`oort exec` / `oort shell`) |
| 2377 | TCP port forwarding |

The host can only reach these through the `VZVirtioSocketDevice` owned by the oort process,
so they're exposed via `--forward` or the built-in proxy.
