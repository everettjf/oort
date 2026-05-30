# Quick Start

[**English**](./quickstart.md) | [简体中文](./quickstart.zh-CN.md)

This gets you from zero to running: install deps → build the image → start → use it.

## 1. Requirements

- Apple Silicon Mac, **macOS 13 or later** (verified on 26.3)
- [Swift toolchain](https://www.swift.org/install/) (bundled with Xcode / Command Line Tools)
- [Go](https://go.dev/dl/) 1.21+ (to cross-compile the guest agent)
- `qemu-img` (to convert the cloud image):

```bash
brew install qemu
```

Check your environment:

```bash
swift --version
go version
qemu-img --version
```

## 2. Get the guest image (one-time)

The guest is based on the Ubuntu 24.04 ARM64 cloud image:

```bash
cd oort            # repo root
mkdir -p images
curl -fL -o images/noble-arm64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img
```

> ~600 MB. `images/` is in `.gitignore`, so it never enters the repo.

## 3. Build the disk + seed + agent

```bash
./oort build-image
```

This (see `make-image.sh`):

1. cross-compiles the guest agent (`oort-guest`, linux/arm64) into the `share/` dir;
2. converts the cloud image qcow2 → raw (VZ needs raw) and grows it to 12 GB;
3. builds a cloud-init NoCloud seed (volume label `CIDATA`) with `hdiutil`.

Afterwards you'll have `images/disk.img` and `images/seed.img`.

## 4. Start

```bash
./oort start
```

First boot provisions itself **without apt** (installs the static Docker engine, starts the
guest agent, mounts the shares, registers Rosetta). `oort start` waits until Docker is ready,
then prints `DOCKER_HOST`.

> First provisioning is usually tens of seconds (depends on the Docker CDN). Reusing the same
> disk afterwards boots in a couple of seconds.

## 5. Use Docker

Point the stock `docker` CLI at oort's daemon:

```bash
export DOCKER_HOST=unix://$HOME/.oort/docker.sock
docker run --rm hello-world
docker ps
```

Or use the built-in passthrough (no `DOCKER_HOST` needed):

```bash
oort docker run --rm hello-world
```

Print the env to add to your shell:

```bash
oort env            # prints: export DOCKER_HOST=unix://...
eval "$(oort env)"
```

## 6. File sharing

The repo's `share/` directory is mounted into the guest at `/mnt/mac` via VirtioFS. Mount it
in a container to read/write host files:

```bash
echo hello > share/note.txt
oort docker run --rm -v /mnt/mac:/m alpine cat /m/note.txt   # prints hello
```

> Note: `/mnt/mac` in `-v /mnt/mac:/m` is a path **inside the guest** (the VirtioFS mountpoint),
> not a macOS path.

## 7. Run x86 images (Rosetta)

```bash
oort docker run --rm --platform linux/amd64 alpine uname -m   # prints x86_64
```

## 8. Port forwarding

A container's published ports appear automatically on the macOS `localhost`:

```bash
oort docker run -d -p 8080:80 nginx
curl http://localhost:8080/        # just works
```

## 9. Run commands in the guest

```bash
oort exec 'uname -a'
oort exec 'systemctl status docker --no-pager | head'
oort shell                # simple line-at-a-time shell
```

## 10. Status / stop

```bash
oort status               # VM and Docker status
oort logs                 # tail the guest console log
oort stop                 # clean shutdown
```

## One-liner

```bash
./oort build-image && ./oort start && eval "$(./oort env)"
docker run --rm hello-world
./oort stop
```

Hit a snag? See the **[FAQ](./faq.md)**; for internals see **[Architecture](./architecture.md)**.
