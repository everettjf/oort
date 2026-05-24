# CLI Reference

[**English**](./cli-reference.md) | [简体中文](./cli-reference.zh-CN.md)

Every `orb` subcommand, plus all flags of the underlying engine `openorb run`.

## `orb` — the front-end

`orb` is a thin wrapper around `openorb run` that codifies common launch flags and adds
lifecycle / exec / passthrough conveniences.

| Command | Description |
|---|---|
| `orb start` | Boot the VM (Docker + file sharing + Rosetta + port forwarding); wait until Docker is ready and print `DOCKER_HOST` |
| `orb stop` | Cleanly shut the VM down |
| `orb restart` | stop then start |
| `orb status` | Show VM and Docker status |
| `orb exec <cmd...>` | Run a command in the guest (via the vsock agent) |
| `orb shell` | Simple line-at-a-time guest shell |
| `orb docker <args...>` | Run `docker` against the openorb daemon |
| `orb env` | Print `export DOCKER_HOST=...`; use `eval "$(orb env)"` |
| `orb logs` | Tail the guest console log |
| `orb build-image` | (Re)build the boot disk + cloud-init seed + cross-compile the agent |
| `orb help` | Show help |

### Examples

```bash
./orb build-image
./orb start
eval "$(./orb env)"

docker run --rm hello-world
orb docker ps
orb exec 'free -m'
orb status
orb stop
```

### Environment variables

`orb` lets you override default paths:

| Variable | Default | Meaning |
|---|---|---|
| `OPENORB_DISK` | `./images/disk.img` | boot disk path |
| `OPENORB_SEED` | `./images/seed.img` | cloud-init seed path |
| `OPENORB_SHARE` | `./share` | directory shared into the guest (tag `mac`) |

Host-side state lives under `~/.openorb/`:

| File | Purpose |
|---|---|
| `~/.openorb/docker.sock` | projected Docker socket (`DOCKER_HOST` points here) |
| `~/.openorb/agent.sock` | exec agent (used by `orb exec`, forwarded to vsock 2376) |
| `~/.openorb/console.log` | guest console log |
| `~/.openorb/vm.pid` / `vm.log` | VM process PID / log |

---

## `openorb run` — the engine

This is what `orb` ultimately invokes. Use it directly for full control (first
`swift build -c release` and codesign, or use `./run.sh`).

```
openorb run --disk <path> [options]
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
| `--socket <path>` | Host Docker Unix socket (default `~/.openorb/docker.sock`) |
| `--vsock-port <n>` | Guest vsock port serving dockerd (default 2375) |
| `--forward <sock>:<port>` | Extra host-socket ⇄ guest-vsock-port forward (repeatable, e.g. expose the agent at `~/.openorb/agent.sock:2376`) |
| `--no-port-forward` | Disable auto-forwarding container ports to localhost |

### Misc

| Flag | Description |
|---|---|
| `--no-console` | Don't attach the guest serial to stdio |
| `--console-log <path>` | Write the guest console to a file (headless) |
| `-h`, `--help` | Show help |

### Equivalent

`orb start` is roughly equivalent to:

```bash
openorb run \
  --disk images/disk.img --seed images/seed.img \
  --mount "$PWD/share:mac" --rosetta \
  --forward "$HOME/.openorb/agent.sock:2376" \
  --no-console --console-log "$HOME/.openorb/console.log" \
  --socket "$HOME/.openorb/docker.sock"
```

---

## Guest vsock ports

`openorb-guest` (the Go agent) listens inside the guest on:

| vsock port | Service |
|---|---|
| 2375 | Docker bridge (→ `/run/docker.sock`) |
| 2376 | exec (`orb exec` / `orb shell`) |
| 2377 | TCP port forwarding |

The host can only reach these through the `VZVirtioSocketDevice` owned by the openorb process,
so they're exposed via `--forward` or the built-in proxy.
