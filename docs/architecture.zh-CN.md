# 架构与原理

[English](./architecture.md) | **简体中文**

openorb 的目标是用最少的自研代码，复刻 OrbStack「Docker 跑在轻量 Linux VM 里、却像本地一样无缝」的核心体验。本文讲清楚每一层是怎么实现的。

> 想了解 OrbStack 本身的实现原理与完整复刻路线，见仓库根目录的 **[orbstack-research.md](../orbstack-research.md)** 深度调研报告。

## 总览

```
   ┌─ macOS（宿主）────────────────────────────┐        ┌─ Linux VM（Virtualization.framework）─┐
   │  docker CLI / orb                          │        │  openorb-guest（Go 编译二进制）：      │
   │     │ DOCKER_HOST=unix://~/.openorb/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec                   │
   │  openorb（Swift 主程序）                    │◀──────▶│    vsock 2377 → tcp 端口转发           │
   │   ├─ VZ 虚拟机控制                          │        │  dockerd（静态）+ containerd + runc   │
   │   ├─ DockerSocketProxy                      │        │  VirtioFS：/mnt/mac、/mnt/rosetta     │
   │   ├─ PortForwarder                          │        │  Rosetta（binfmt_misc，x86-64）        │
   │   └─ VirtioFS / Rosetta / NAT 设备           │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

核心思想和 OrbStack / WSL2 一致：**一台共享内核的轻量 Linux VM**，把里面的服务通过 virtio-vsock「投影」到 macOS，让原生工具零改动可用。

## 1. 虚拟化层：Apple Virtualization.framework

`Sources/openorb/VMConfig.swift` 用 VZ 构建一台 VM：

- **引导**：`VZEFIBootLoader` + NVRAM，直接 EFI 启动 Ubuntu 云镜像（也支持 `VZLinuxBootLoader` 直引导内核）。
- **磁盘**：`VZVirtioBlockDeviceConfiguration`（启动盘）+ 只读 seed 盘（cloud-init CIDATA）。
- **网络**：`VZVirtioNetworkDeviceConfiguration` + `VZNATNetworkDeviceAttachment`（NAT 出网）。
- **vsock**：`VZVirtioSocketDeviceConfiguration` —— host↔guest 的零网络开销通道，是整套「投影」的载体。
- **其它**：熵源、内存气球、串口控制台。

VZ 直接走 Apple Silicon 的硬件虚拟化，CPU 几乎零损耗，启动 1–2 秒。运行时需要 `com.apple.security.virtualization` entitlement，所以二进制要 codesign（`run.sh` / `orb` 自动处理）。

`VMManager.swift` 负责生命周期：**所有 VZ 调用必须在同一条串行队列上**（VZ 的硬性要求），因此用 `VZVirtualMachine(configuration:queue:)` 创建，并把 start/connect 都派发到这条队列。

## 2. Docker over vsock

容器引擎跑在 VM 里（静态 `dockerd`），它的 unix socket `/run/docker.sock` 经两段桥接投影到 macOS：

```
docker CLI → ~/.openorb/docker.sock  →  [vsock 2375]  →  openorb-guest  →  /run/docker.sock → dockerd
            （DockerSocketProxy，宿主）   （virtio-vsock）   （客户机 Go agent）
```

- **宿主侧 `DockerSocketProxy.swift`**：监听一个 AF_UNIX socket；每来一个连接，就在 VZ 队列上 `connect(toPort: 2375)` 拿到一条 vsock 连接，然后双向 splice 两个 fd。
- **客户机侧 `openorb-guest`**：vsock 2375 上 accept，dial `/run/docker.sock`，splice。

> **一个踩过的坑**：早期 splice 用「半关闭」（一端 EOF 就 `shutdown(SHUT_WR)`），但 Docker API 默认 HTTP keep-alive，对端不发 EOF，导致另一方向的 relay 永久阻塞、连接与 vsock fd 泄漏，最终耗尽设备、代理「假死」。修复：**任一方向结束就 `shutdown(SHUT_RDWR)` 双向唤醒**，保证连接必然回收。见 `DockerSocketProxy.swift` 的 `bridge/relay`。

## 3. 客户机 agent：为什么用 Go

`guest-agent/main.go` 编译成一个静态 linux/arm64 二进制，同时服务三个 vsock 端口：

| 端口 | 作用 |
|---|---|
| 2375 | Docker 桥（→ `/run/docker.sock`） |
| 2376 | exec：读 HTTP body 当 shell 命令执行，回传输出（`orb exec` 的后端） |
| 2377 | TCP 转发：读目标端口，dial 客户机 `127.0.0.1:port` 并 splice（端口转发用） |

> **另一个踩过的坑**：最初这些服务是 Python 写的，但在内存压力/持续负载下会被 OOM 杀掉或卡死（甚至 `ls` 偶发 SIGILL）。换成**编译型 Go 二进制**后稳如磐石——连续 8 个容器 + 负载后 socket 与 agent 依旧在线。OrbStack 用 C/Go/Rust 自研服务，也是同样的道理。`OOMScoreAdjust` 进一步保证它在压力下存活。

## 4. 文件共享：VirtioFS

`VMConfig.swift` 为每个 `--mount` 加一个 `VZVirtioFileSystemDeviceConfiguration`，用 tag 标识（默认第一个 tag 为 `mac`）。客户机用 `mount -t virtiofs mac /mnt/mac` 挂载，并写进 `/etc/fstab`。

这就是 OrbStack `/mnt/mac`（macOS 文件在客户机里）的同款机制。容器通过 `-v /mnt/mac:/...` 即可双向读写主机文件。

> 注意：本项目目前是「基础版」VirtioFS，未做 OrbStack 那层自研缓存/批处理优化（那是阶段五、也是 OrbStack 性能护城河所在）。

**实测（见 `bench.sh`）：** 顺序吞吐尚可（写约为客户机本地盘的 68%，缓存读更快），但**小文件/元数据操作慢约 21×**（3000 个文件：约 720ms vs 本地约 34ms）——每次创建都是一次 FUSE 往返。这正是 `npm install` / `git status` 慢的根源。我们验证过缓存模式**在客户机侧无法调优**（`mount -o cache=always` 被拒绝——VZ 控制主机侧且不暴露该选项），所以唯一的真正修复是自研 VirtioFS 层 / DAX（阶段五）。**当前变通：** 把热点目录（如 `node_modules`、构建产物）放进 Docker 命名卷，而非 bind mount。

## 5. x86-64 翻译：Rosetta

`--rosetta` 时：

1. 宿主侧用 `VZLinuxRosettaDirectoryShare` 把 Rosetta 以 VirtioFS（tag `rosetta`）共享进客户机（不存在则触发安装）。
2. 客户机把它挂到 `/mnt/rosetta`，并用 `binfmt_misc` 注册 x86-64 ELF 处理器，解释器指向 `/mnt/rosetta/rosetta`，带 **`F` 标志**（注册时即打开解释器 fd，因此在容器的 mount namespace 里也生效）。

于是 `docker run --platform linux/amd64 ...` 的 x86 二进制由 Rosetta 翻译执行，远快于 QEMU 用户态模拟。

> binfmt 的 magic/mask 只匹配 x86-64（`e_machine=0x3e`），不会误伤 arm64 二进制。

## 6. 端口转发到 localhost

`PortForwarder.swift`：

1. 每 2 秒查一次 Docker API（`GET /containers/json`，经投影的 docker socket）；
2. 收集所有发布的 TCP 端口；
3. 为每个端口 P 在 macOS `127.0.0.1:P` 起监听；
4. 每个连接经 vsock 2377 隧道到客户机 agent，agent 在客户机内 dial `127.0.0.1:P` 并 splice。

效果：`docker run -p 8080:80` 后，macOS 上 `curl localhost:8080` 直接命中容器——OrbStack 的同款体验。`--no-port-forward` 可关闭。

> 小细节：查询 Docker API 用 HTTP/1.0 + `Connection: close`，并给 socket 设了 recv 超时，避免 dockerd keep-alive 导致「读到 EOF」永久阻塞。

## 7. 首次配置：无 apt

`cloud-init/user-data` 刻意**不依赖 apt**（发行版镜像源时快时慢，且 OrbStack 本身也自带 Docker 工具而非 apt 安装）：

- 静态 Docker 引擎：优先用共享盘上预放的 tarball（宿主下载，可靠），否则从 Docker CDN 走 IPv4 下载；
- 客户机 agent：从共享盘安装编译好的 `openorb-guest`；
- DNS：禁用 IPv6 + 写死 `1.1.1.1`，规避「IPv6-only 解析 / IPv4-only 出网」导致的下载卡死；
- 挂载 `mac`/`rosetta` 共享、注册 Rosetta binfmt、（可选）zram。

## 8. 内存

已挂载 VirtIO 内存气球设备；zram 压缩交换通过客户机服务接入（**但 stock Ubuntu 云内核不含 zram 模块**，会优雅跳过——OrbStack 自编译内核内置了它）。主动 ballooning（按需增长/回收）是后续工作。

## 与 OrbStack 的差距（即路线图）

| 维度 | 本项目 | OrbStack |
|---|---|---|
| 虚拟化 | VZ ✅ | VZ + 自研编排 |
| Docker over vsock | ✅ | ✅ |
| VirtioFS | 基础版 ✅ | + 自研缓存层（2–5x） |
| Rosetta | ✅ | ✅ |
| 端口转发 | ✅ | ✅ + 跟随 VPN/DNS |
| 内核 | stock 云内核 | 自编译（zram 等内置） |
| 内存 | 气球设备 | 动态分配 + zram |
| 多机 / GUI | 暂无 | 有 |

详见 [orbstack-research.md](../orbstack-research.md)。
