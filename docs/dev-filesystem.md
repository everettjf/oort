# Dev filesystem: fast bind-mounted projects

oort mirrors your Mac files into the guest over **VirtioFS** (`/mnt/mac`, and
the home mirror), so `docker -v $PWD:/app` just works. Sequential throughput is
fine, but **per-file metadata ops are much slower than the guest's own disk** —
the same FUSE-round-trip weak spot OrbStack built a custom caching layer to beat.
This page is the practical way to stay fast today.

## What's actually slow (measured)

VZ VirtioFS (`/mnt/mac`) vs the guest's own ext4, on this hardware:

| op | VirtioFS | guest fs | ratio |
|---|---|---|---|
| sequential write 512MB | 559 MB/s | 845 MB/s | 0.66× (fine) |
| sequential read | 3.5 GB/s | 2.0 GB/s | faster (host cache) |
| create 3000 files | 633ms | 33ms | ~19× |
| `find` scan 8000 | 16ms | 2ms | ~8× |
| `tar` 8000 files | 319ms | 9ms | ~35× |
| `rm -rf` 8000 files | 983ms | 37ms | ~27× |
| **`npm install` (2111 files, warm cache)** | **1351ms** | **1120ms** | **~1.2×** |

**The nuance that matters:** a real `npm install` is only ~1.2× slower, because
npm's own resolve/extract/JS work dominates — not raw file I/O. The big multipliers
hit the operations that *touch every file*: **`rm -rf node_modules`, bulk reads/
`tar`, `git status`-style scans, and file-watchers** doing thousands of `stat`s.
So that's where to apply the fix.

## The fix: keep hot dirs on the guest disk (`oort fastvol`)

Bind-mount your **source** (so edits sync), but put the **generated hot dirs**
(`node_modules`, `dist`, `target/`, `.next`, …) on a Docker named volume — which
lives on the guest's own fast ext4, not VirtioFS. Those metadata-heavy ops then
run at native speed.

```bash
oort fastvol myapp /app/node_modules
# → fast volume 'oortfast-myapp' ready
#   docker run:  -v "$PWD:/app" -v oortfast-myapp:/app/node_modules -w /app <image> …

docker run --rm -v "$PWD:/app" -v oortfast-myapp:/app/node_modules -w /app \
  node:20 sh -c 'npm install && npm run build'
```

`oort fastvol ls` lists them; `oort fastvol rm <name>` removes one.

### docker compose

```yaml
services:
  app:
    image: node:20
    volumes:
      - .:/app
      - node_modules:/app/node_modules   # ← on the guest disk, fast
    working_dir: /app
volumes:
  node_modules: {}
```

## Other tips

- **Don't bind-mount `.git` of a huge repo** into a watcher/`git status` loop —
  the scan is metadata-bound. Work on a copy on the guest disk, or use a machine
  (`oort machine`) whose filesystem is entirely guest-native.
- Sequential file I/O (large reads/writes, builds that stream) is already near
  native — no workaround needed.

## Why not just make VirtioFS fast? (the moat)

OrbStack's headline 2–5× comes from a **custom host-side VirtioFS server** with
caching/batching + **DAX**. oort uses Apple's `Virtualization.framework`, whose
VirtioFS server is a closed black box — it exposes no cache/DAX tuning (`mount -o
cache=always` is rejected). Matching it would mean replacing VZ with a custom VMM
on `Hypervisor.framework` (research-hard, multi-month). Given the data above —
real workloads like `npm install` are ~1.2×, and the named-volume pattern removes
the genuinely slow ops — that moat is low-ROI for oort today.

> The custom kernel (`oort build-kernel`) does enable guest-side `FUSE_DAX`, so the
> guest is ready if a DAX-capable host server ever exists; under VZ it's inert.
