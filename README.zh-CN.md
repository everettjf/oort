<div align="center">

# 🛰️ openorb

**用 Swift + Go 实现的、轻量级 OrbStack 风格 macOS Docker & Linux 运行时**

在 Apple `Virtualization.framework` 上启动一台轻量 Linux 虚拟机，把容器引擎、文件共享、
x86 翻译和端口映射「投影」到 macOS —— 不依赖 Docker Desktop。

<br/>

[![平台](https://img.shields.io/badge/平台-macOS%2013%2B%20·%20Apple%20Silicon-black)](#-环境要求)
[![语言](https://img.shields.io/badge/语言-Swift%20%2B%20Go-orange)](#-项目结构)
[![协议](https://img.shields.io/badge/协议-MIT-blue)](./LICENSE)

[English](./README.md) | **简体中文**

[快速开始](#-快速开始) · [它是什么](#-它是什么) · [架构](#-架构一览) · [文档](#-文档) · [路线图](#-路线图)

</div>

---

## ✨ 它是什么

`openorb` 是一个**能跑起来的** OrbStack 精简复刻 —— 一个研究「OrbStack 为什么又快又轻」并亲手实现核心机制的项目。

一条命令启动，原生 `docker` CLI 直接可用：

```console
$ orb start
starting openorb VM…
waiting for Docker...... ready.
export DOCKER_HOST=unix:///Users/you/.openorb/docker.sock

$ docker run --rm hello-world
Hello from Docker!

$ docker run -p 8080:80 nginx     # 然后在 macOS 上 curl localhost:8080 直接通
$ docker run --platform linux/amd64 alpine uname -m     # x86_64（Rosetta 翻译）
$ orb exec 'uname -a'             # 直接在客户机里执行命令
```

### 已实现并**真机验证**的能力

| 能力 | 说明 | 状态 |
|---|---|:---:|
| 🐳 **Docker over vsock** | VZ 启动 Linux VM，dockerd 经 virtio-vsock 投影到 macOS unix socket | ✅ |
| 🌐 **容器联网** | dockerd 管理 iptables NAT —— `docker build`（`RUN apk/npm/pip…`）和运行时出网都正常 | ✅ |
| 📁 **文件共享** | Mac 家目录以相同路径镜像进客户机，`docker -v $PWD:/app` 直接可用 | ✅ |
| 🧬 **Rosetta x86 翻译** | `linux/amd64` 镜像经 Rosetta 运行，远快于 QEMU | ✅ |
| 🔌 **端口自动转发** | 容器发布端口自动出现在 macOS `localhost`（事件驱动） | ✅ |
| 🧭 **跟随 Mac DNS** | 客户机/容器用 Mac 的 DNS 解析器——内网/VPN 域名可解析 | ✅ |
| 🛰️ **`orb` CLI** | 生命周期、`orb exec`、docker 透传、`orb autostart` 开机自启 | ✅ |
| 💾 **zram 压缩交换** | 已接入（需内核含 zram 模块，详见文档） | ⚠️ |

> 全部在 **macOS 26.3 / Apple Silicon** 上对接本项目自己的守护进程验证通过。

---

## 🚀 快速开始

```bash
# 依赖：Swift 工具链、Go 1.21+、qemu-img（brew install qemu）

# 1. 拉取 Ubuntu 24.04 arm64 云镜像（一次性）
mkdir -p images
curl -fL -o images/noble-arm64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img

# 2. 构建启动盘 + cloud-init seed + 编译客户机 agent
./orb build-image

# 3. 启动（等待 Docker 就绪，自动打印 DOCKER_HOST）
./orb start

# 4. 使用
export DOCKER_HOST=unix://$HOME/.openorb/docker.sock
docker run --rm hello-world
orb status
orb stop
```

更详细的步骤见 **[docs/快速开始.md](./docs/quickstart.zh-CN.md)**。

---

## 🧭 架构一览

```
   ┌─ macOS ───────────────────────────────────┐        ┌─ Linux VM（Virtualization.framework）─┐
   │  docker CLI / orb                          │        │  openorb-guest（Go，编译二进制）：     │
   │     │ DOCKER_HOST=unix://~/.openorb/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec（orb exec）       │
   │  openorb（Swift）                           │◀──────▶│    vsock 2377 → tcp 端口转发           │
   │   ├─ VZ 虚拟机控制                          │        │  dockerd（静态）+ containerd          │
   │   ├─ DockerSocketProxy（unix ⇄ vsock 2375） │        │  VirtioFS：/mnt/mac、/mnt/rosetta     │
   │   ├─ PortForwarder（127.0.0.1:P ⇄ 2377）    │        │  Rosetta binfmt_misc（x86-64）        │
   │   └─ VirtioFS / Rosetta / NAT 设备           │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

客户机是一台 stock Ubuntu 24.04 云镜像，首次启动**无需 apt**完成配置（静态 Docker 引擎 +
编译好的 `openorb-guest` agent，经 VirtioFS 共享盘投递）。

> 想深入了解「OrbStack 怎么做到的、我们怎么复刻」？看 **[orbstack-research.md](./orbstack-research.md)** 深度调研报告，
> 以及 **[docs/架构与原理.md](./docs/architecture.zh-CN.md)**。

---

## 📚 文档

| 文档 | 内容 |
|---|---|
| [快速开始](./docs/quickstart.zh-CN.md) | 安装、首次运行、常用操作 |
| [架构与原理](./docs/architecture.zh-CN.md) | VZ / vsock / VirtioFS / Rosetta / 端口转发 / Go agent 的实现原理 |
| [命令参考](./docs/cli-reference.zh-CN.md) | `orb` 全部子命令 + `openorb run` 全部参数 |
| [常见问题](./docs/faq.zh-CN.md) | FAQ 与排错（DNS、zram、provisioning、与 Docker Desktop 共存等） |
| [深度调研报告](./orbstack-research.md) | OrbStack 实现原理 + 复刻路线（项目缘起） |

---

## 💻 环境要求

- Apple Silicon Mac，**macOS 13+**（开发于 26.3）
- Swift 工具链（`swift --version`）
- Go 1.21+（编译客户机 agent）
- `qemu-img`（`brew install qemu`，用于转换云镜像）

---

## 🗂 项目结构

```
openorb/
├── Sources/openorb/         Swift：VM 编排 + socket 代理 + 端口转发
│   ├── VMConfig.swift        构建 VZVirtualMachineConfiguration（各类设备）
│   ├── VMManager.swift       VM 生命周期（绑定 VZ 串行队列）
│   ├── DockerSocketProxy.swift  host unix socket ⇄ guest vsock 隧道
│   ├── PortForwarder.swift   监视 Docker，转发发布端口到 localhost
│   └── Config.swift / main.swift
├── guest-agent/main.go      客户机 agent（docker 桥 + exec + tcp 转发，编译为 linux/arm64）
├── cloud-init/              无 apt 的首次启动配置
├── orb                      命令行入口
├── make-image.sh            构建启动盘 + seed + 交叉编译 agent
└── orbstack-research.md     深度调研报告
```

---

## ⚠️ 已知限制

- **bind mount 小文件速度**：VirtioFS 对大量小文件比本地盘慢约 21×（如挂源码跑 `npm install`）。VZ 不暴露缓存调优，真正的修复需自研 VirtioFS/DAX 层（阶段五）。变通：热点目录用命名卷。
- **VPN**：DNS *解析*已跟随 Mac，但 VPN *流量*路由需自研用户态网络栈（后续）。
- **zram**：stock Ubuntu 云内核不含 `zram` 模块，该服务会优雅跳过。OrbStack 自编译内核内置了它 —— 这是阶段五的事。
- **动态内存**：已挂载 VirtIO 气球设备，但「按需增长/回收」的主动 ballooning 尚未接入。
- **单 VM**：单一共享内核 VM（类 WSL2 / OrbStack），多「机器」是后续功能。
- 与 Docker Desktop 共存时注意 `DOCKER_HOST`/`docker context`，详见[常见问题](./docs/faq.zh-CN.md)。

---

## 🛣 路线图

阶段一～四已完成（见上表）。下一步是 OrbStack 真正的护城河：

- 🔧 **自编译 Linux 内核**：内置 zram、虚拟化调优
- ⚡ **VirtioFS 缓存层**：把 bind mount 做到接近原生速度（OrbStack 的核心 IP）
- 🧠 **主动内存 ballooning** + **自研用户态网络栈**（跟随 macOS VPN/DNS）
- 🖥️ **多台命名 Linux 机器** + **SwiftUI GUI**

详见[调研报告 §4](./orbstack-research.md)，以及可借力的开源项目（Lima、gvisor-tap-vsock、virtiofsd、Apple `containerization`）。

---

## 🙏 致谢与说明

本项目是**学习与研究性质**的 OrbStack 精简复刻，站在巨人的肩膀上：Apple `Virtualization.framework`、
Docker、Ubuntu cloud image。OrbStack 是闭源商业产品，本项目与其无任何关联。

## 📄 许可证

[MIT](./LICENSE) © 2026 everettjf
