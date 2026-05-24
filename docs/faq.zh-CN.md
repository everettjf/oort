# 常见问题 / 排错

[English](./faq.md) | **简体中文**

## 安装与构建

### `swift build` 报 PCH / module cache 路径错误
通常是 `.build/` 缓存指向了旧路径（比如目录被移动过）。删掉重建：

```bash
rm -rf .build && swift build -c release
```

### `orb start` 报 entitlement / 虚拟化权限错误
VZ 要求二进制带 `com.apple.security.virtualization` entitlement。`orb` 和 `run.sh` 会自动 ad-hoc 签名；若手动构建，记得：

```bash
codesign --force --sign - --entitlements ./openorb.entitlements \
  "$(swift build -c release --show-bin-path)/openorb"
```

### `qemu-img: command not found`
```bash
brew install qemu
```

### Go 未安装 / 客户机 agent 没编译出来
`./orb build-image` 会交叉编译 `share/openorb-guest`。需要 Go 1.21+：

```bash
go version
```

## 启动与配置

### `orb start` 一直 “waiting for Docker” 然后超时
首次启动要在线安装静态 Docker。可能原因与排查：

- **网络慢**：Docker CDN/镜像源慢。`orb logs` 看客户机进度；或先在宿主把 docker 静态包下到 `share/docker-27.3.1.tgz`（cloud-init 会优先用它）。
- **DNS 问题**：cloud-init 已禁用 IPv6 并写死 `1.1.1.1`。若你的网络封锁 1.1.1.1，改 `cloud-init/user-data` 里的 resolver。
- 想重新干净配置：`./orb build-image`（重建盘，cloud-init 会重跑）。

### 启动很慢 / 每次都重装 Docker
`orb build-image` 会重置磁盘并重新配置。**只 `orb start`（不 build-image）会复用已配置的盘**，几秒即起。日常用：

```bash
./orb start        # 复用现有 images/disk.img
```

### 看不到内核启动日志
VZ 的串口是 virtio-console（`hvc0`），而 Ubuntu 内核日志默认走 `ttyS0/ttyAMA0`，所以 `console.log` 里只会看到登录提示，看不到内核早期日志。要观察配置过程，用 `orb exec` 查客户机内部状态，或看 `~/.openorb/console.log` 的 cloud-init 输出。

## Docker 使用

### `docker` 命令跑到了 Docker Desktop，不是 openorb
没设 `DOCKER_HOST`。两种方式：

```bash
export DOCKER_HOST=unix://$HOME/.openorb/docker.sock   # 或 eval "$(orb env)"
# 或直接用透传：
orb docker ps
```

### `-v /mnt/mac:/x` 报 “path not shared / File Sharing”
这是 **Docker Desktop CLI** 的客户端校验在作祟（它把 `/mnt/mac` 当成 macOS 路径）。确保 `DOCKER_HOST` 指向 openorb；用 `orb docker ...` 透传可避免。注意 `/mnt/mac` 是**客户机内**路径。

### 绑定挂载读不到文件
确认：① openorb 启动时带了 `--mount`（`orb start` 默认共享 `./share` → `/mnt/mac`）；② 文件确实在共享目录里；③ 容器里挂的是 `/mnt/mac`（客户机路径），不是 macOS 路径。

```bash
orb exec 'mount | grep virtiofs; ls -la /mnt/mac'
```

### `--platform linux/amd64` 报 exec format error
说明 Rosetta binfmt 没注册。确认启动带了 `--rosetta`，并检查：

```bash
orb exec 'cat /proc/sys/fs/binfmt_misc/rosetta'   # 应显示 enabled + interpreter /mnt/rosetta/rosetta
```

### `curl localhost:<端口>` 不通
端口转发每 2 秒轮询一次 Docker，发布端口后稍等一下。检查：

```bash
orb logs            # 应出现 “forwarding 127.0.0.1:<port> → guest:<port>”
orb docker ps       # 确认端口确实 publish 了（0.0.0.0:8080->80/tcp）
```
若用了 `--no-port-forward` 则不会转发。

## 功能与限制

### zram 没生效
stock Ubuntu 云内核**不含 `zram` 模块**（在 `linux-modules-extra` 里），所以 zram 服务会优雅跳过。这正是 OrbStack 自编译内核的价值之一。要启用：换一个含该模块的内核，或安装 `linux-modules-extra-$(uname -r)`（需 apt）。

### 内存占用 / 动态内存
已挂载 VirtIO 气球设备，但主动 ballooning（按需增长/回收）尚未接入。用 `--memory` 设定上限。

### 容器能上网吗
能。dockerd 自己管理 iptables 的 NAT/MASQUERADE 规则（base 云镜像自带 nft 后端的 iptables），所以容器有出网——`docker build` 里的 `RUN apk add` / `npm install`,以及运行时访问外网都正常。

## 清理 / 重置

```bash
orb stop
rm -f images/disk.img images/disk.img.nvram images/seed.img   # 删掉配置好的盘
./orb build-image                                             # 重新构建
```

宿主侧 socket / 日志在 `~/.openorb/`，可安全删除（VM 停止后）。

---

还有问题？看 [架构与原理](./architecture.zh-CN.md) 了解内部机制，或提 issue。
