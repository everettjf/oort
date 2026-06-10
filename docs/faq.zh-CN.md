# 常见问题 / 排错

[English](./faq.md) | **简体中文**

## 概念

### Oort 和 Docker 是一回事吗？
不是。它们处在**不同层次**——Oort 不替代 Docker，而是**承载并增强**它。

- **Docker** 是容器引擎（`dockerd` + `docker` CLI），负责打包、运行容器；但容器要跑必须有
  **Linux 内核**。macOS 没有 Linux 内核，所以 Docker 在裸 Mac 上根本跑不起来。
- **Oort** 就是给 Docker 提供那个内核的底座：用 Apple 的 `Virtualization.framework` 启动一台
  轻量 Linux VM，在里面跑 `dockerd`，再把引擎、端口、文件、DNS、x86 翻译统统投影回 macOS——
  于是原版 `docker` CLI「直接就能用」。

`oort start` 之后，你敲的命令依然是普通的 `docker run …`。Oort 是底下的运行时 + 适配层，
不是 Docker 的替代品。

> 类比：**Docker** 是应用程序；**Oort** 是让它能在 Mac 上跑起来的运行环境 + 胶水层。

### 那 Oort 到底该和谁比？
不是 Docker，而是其它 **Docker-on-Mac 后端**：**Docker Desktop**、**OrbStack**、**Colima**。
它们和 Oort 同一层（启动 Linux VM、把 Docker 暴露给 Mac）。

| | 角色 |
|---|---|
| **Oort** | 启动轻量 Linux VM，把里面的 `dockerd` 投影到 Mac socket；你照常用原版 `docker` CLI。开源。 |
| **Docker Desktop** | 官方后端——同样是一台 VM，但更重、商用收费。 |
| **OrbStack** | 闭源、商业、快而轻。**Oort 就是它的开源复刻。** |
| **Colima** | 开源，基于 Lima/QEMU；思路相近，管线不同。 |

除了「跑 Docker」，Oort 还做了引擎本身做不到的事——比如**机器级时间旅行**（`snapshot` /
`restore` / `fork` 整台 Linux 机器），这是连 OrbStack 都没有的。见
[Beyond OrbStack](./beyond-orbstack.zh-CN.md)。

## 安装与构建

### `swift build` 报 PCH / module cache 路径错误
通常是 `.build/` 缓存指向了旧路径（比如目录被移动过）。删掉重建：

```bash
rm -rf .build && swift build -c release
```

### `oort start` 报 entitlement / 虚拟化权限错误
VZ 要求二进制带 `com.apple.security.virtualization` entitlement。`oort` 和 `run.sh` 会自动 ad-hoc 签名；若手动构建，记得：

```bash
codesign --force --sign - --entitlements ./oort.entitlements \
  "$(swift build -c release --show-bin-path)/oort"
```

### `qemu-img: command not found`
```bash
brew install qemu
```

### Go 未安装 / 客户机 agent 没编译出来
`./oort build-image` 会交叉编译 `share/oort-guest`。需要 Go 1.21+：

```bash
go version
```

## 启动与配置

### `oort start` 一直 “waiting for Docker” 然后超时
首次启动要在线安装静态 Docker。可能原因与排查：

- **网络慢**：Docker CDN/镜像源慢。`oort logs` 看客户机进度；或先在宿主把 docker 静态包下到 `share/docker-27.3.1.tgz`（cloud-init 会优先用它）。
- **DNS 问题**：cloud-init 已禁用 IPv6 并写死 `1.1.1.1`。若你的网络封锁 1.1.1.1，改 `cloud-init/user-data` 里的 resolver。
- 想重新干净配置：`./oort build-image`（重建盘，cloud-init 会重跑）。

### VM 在跑但 Docker 一直 "unreachable" —— 怎么进客户机排查？
先 `oort doctor`：它能区分 VM / dockerd / agent 三类故障。如果**所有** vsock 端口都被复位
（doctor 显示 Docker 和 Agent 都 down）而 VM 明明启动了，还可以走 SSH 进去——云镜像开了
密码登录（用户 `ubuntu`，密码 `oort`），VZ NAT 会把客户机的 DHCP 租约登记在 Mac 上：

```bash
grep -A2 'name=oort' /var/db/dhcpd_leases   # 找 ip_address=192.168.64.x
ssh ubuntu@192.168.64.x                      # 密码 oort
journalctl -u oort-guest -n 50               # agent 日志
lsmod | grep vsock                           # 传输层加载了吗？
```

实例：较新的 noble 云内核（6.8.0-117）不再自动加载 `vmw_vsock_virtio_transport` ——
agent 在没有传输层的 vsock 核心上"正常"监听，宿主每个连接都收到 RST。现在 provisioning
会写入 `/etc/modules-load.d/oort-vsock.conf` 固定加载；旧黄金镜像遇到同样症状时，客户机里
`sudo modprobe vmw_vsock_virtio_transport` 可立即修复（之后 `oort build-image` 重建）。

### 启动很慢 / 每次都重装 Docker
`oort build-image` 会重置磁盘并重新配置。**只 `oort start`（不 build-image）会复用已配置的盘**，几秒即起。日常用：

```bash
./oort start        # 复用现有 images/disk.img
```

### 看不到内核启动日志
VZ 的串口是 virtio-console（`hvc0`），而 Ubuntu 内核日志默认走 `ttyS0/ttyAMA0`，所以 `console.log` 里只会看到登录提示，看不到内核早期日志。要观察配置过程，用 `oort exec` 查客户机内部状态，或看 `~/.oort/console.log` 的 cloud-init 输出。

## Docker 使用

### `docker` 命令跑到了 Docker Desktop，不是 oort
没设 `DOCKER_HOST`。两种方式：

```bash
export DOCKER_HOST=unix://$HOME/.oort/docker.sock   # 或 eval "$(oort env)"
# 或直接用透传：
oort docker ps
```

### `-v /mnt/mac:/x` 报 “path not shared / File Sharing”
这是 **Docker Desktop CLI** 的客户端校验在作祟（它把 `/mnt/mac` 当成 macOS 路径）。确保 `DOCKER_HOST` 指向 oort；用 `oort docker ...` 透传可避免。注意 `/mnt/mac` 是**客户机内**路径。

### 绑定挂载读不到文件
确认：① oort 启动时带了 `--mount`（`oort start` 默认共享 `./share` → `/mnt/mac`）；② 文件确实在共享目录里；③ 容器里挂的是 `/mnt/mac`（客户机路径），不是 macOS 路径。

```bash
oort exec 'mount | grep virtiofs; ls -la /mnt/mac'
```

### `--platform linux/amd64` 报 exec format error
说明 Rosetta binfmt 没注册。确认启动带了 `--rosetta`，并检查：

```bash
oort exec 'cat /proc/sys/fs/binfmt_misc/rosetta'   # 应显示 enabled + interpreter /mnt/rosetta/rosetta
```

### `curl localhost:<端口>` 不通
端口转发每 2 秒轮询一次 Docker，发布端口后稍等一下。检查：

```bash
oort logs            # 应出现 “forwarding 127.0.0.1:<port> → guest:<port>”
oort docker ps       # 确认端口确实 publish 了（0.0.0.0:8080->80/tcp）
```
若用了 `--no-port-forward` 则不会转发。

## 功能与限制

### zram / 动态内存
两者默认开启。provisioning 会安装 `zram` 内核模块（base 云内核没有），开机即起压缩内存交换；host 侧的气球循环把空闲客户机内存还给 macOS（目标跟随用量，封顶 `--memory`）。气球可用 `--no-dynamic-memory` 关闭。

### 挂源码目录开发很慢
VirtioFS bind mount 有每调用（FUSE）开销——`bench.sh` 显示小文件/元数据操作比客户机本地盘慢不少（这正是自研 VirtioFS/DAX 层要补的差距,见[路线图](./roadmap.zh-CN.md)）。标准缓解方式（和其它 Docker-on-Mac 一样）:把**元数据密集的热点目录放进 Docker 命名卷**,而非 bind mount——比如源码读写挂载,但 `node_modules`/构建产物放卷:

```bash
docker run -v "$PWD:$PWD" -w "$PWD" -v myproj_node_modules:"$PWD/node_modules" node:20 npm install
```

收益与负载相关(对 `npm`/`yarn` 这类元数据频繁的工具有效）；纯顺序读写在 VirtioFS 上已接近原生。

### 容器能上网吗
能。dockerd 自己管理 iptables 的 NAT/MASQUERADE 规则（base 云镜像自带 nft 后端的 iptables），所以容器有出网——`docker build` 里的 `RUN apk add` / `npm install`,以及运行时访问外网都正常。

## 清理 / 重置

```bash
oort stop
rm -f images/disk.img images/disk.img.nvram images/seed.img   # 删掉配置好的盘
./oort build-image                                             # 重新构建
```

宿主侧 socket / 日志在 `~/.oort/`，可安全删除（VM 停止后）。

---

还有问题？看 [架构与原理](./architecture.zh-CN.md) 了解内部机制，或提 issue。
