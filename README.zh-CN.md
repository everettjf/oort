<div align="center">

# 🛰️ Oort

**用 Swift + Go 实现的、轻量级 OrbStack 风格 macOS Docker & Linux 运行时**

在 Apple `Virtualization.framework` 上启动一台轻量 Linux 虚拟机，把容器引擎、文件共享、
x86 翻译和端口映射「投影」到 macOS —— 不依赖 Docker Desktop。

*名字取自**奥尔特云（Oort cloud）**——太阳系边缘那层由无数小冰体组成的巨大云壳。
在这里，它是围绕同一个共享内核运行的无数轻量机器与沙箱。*

<br/>

[![网站](https://img.shields.io/badge/网站-everettjf.github.io%2Foort-3ee0c5)](https://everettjf.github.io/oort/)
[![平台](https://img.shields.io/badge/平台-macOS%2013%2B%20·%20Apple%20Silicon-black)](#-环境要求)
[![语言](https://img.shields.io/badge/语言-Swift%20%2B%20Go-orange)](#-项目结构)
[![协议](https://img.shields.io/badge/协议-MIT-blue)](./LICENSE)

[English](./README.md) | **简体中文**

🌐 **[网站 &amp; 教程 → everettjf.github.io/oort](https://everettjf.github.io/oort/)**

[快速开始](#-快速开始) · [它是什么](#-它是什么) · [架构](#-架构一览) · [文档](#-文档) · [路线图](#-路线图)

</div>

---

## ✨ 它是什么

`oort` 是一个**能跑起来的** OrbStack 精简复刻 —— 一个研究「OrbStack 为什么又快又轻」并亲手实现核心机制的项目。

> **Oort 和 Docker 什么区别?** 它们处在不同层次。**Docker** 是容器引擎——但容器要跑必须有 Linux
> 内核,而 macOS 没有。**Oort** 就是给 Docker 提供内核的底座:启动一台轻量 Linux VM,把 `dockerd`
> (连同端口、文件、DNS、x86 翻译)投影回 macOS,于是原版 `docker` CLI 直接可用。Oort 不替代
> Docker——它承载 Docker。要比就和 **Docker Desktop / OrbStack / Colima** 比,而不是和 Docker 比。
> ([详见 →](./docs/faq.zh-CN.md#概念))

一条命令启动，原生 `docker` CLI 直接可用：

```console
$ oort start
starting oort VM…
waiting for Docker...... ready.
export DOCKER_HOST=unix:///Users/you/.oort/docker.sock

$ docker run --rm hello-world
Hello from Docker!

$ docker run -p 8080:80 nginx     # 然后在 macOS 上 curl localhost:8080 直接通
$ docker run --platform linux/amd64 alpine uname -m     # x86_64（Rosetta 翻译）
$ oort exec 'uname -a'             # 直接在客户机里执行命令
```

### 已实现并**真机验证**的能力

| 能力 | 说明 | 状态 |
|---|---|:---:|
| 🐳 **Docker over vsock** | VZ 启动 Linux VM，dockerd 经 virtio-vsock 投影到 macOS unix socket | ✅ |
| 🌐 **容器联网** | dockerd 管理 iptables NAT —— `docker build`（`RUN apk/npm/pip…`）和运行时出网都正常 | ✅ |
| 📁 **文件共享** | Mac 家目录以相同路径镜像进客户机，`docker -v $PWD:/app` 直接可用 | ✅ |
| 🧬 **Rosetta x86 翻译** | `linux/amd64` 镜像经 Rosetta 运行，远快于 QEMU | ✅ |
| 🔌 **端口自动转发** | 容器发布端口自动出现在 macOS `localhost`（事件驱动） | ✅ |
| 🪪 **`*.oort.local` 域名** | `curl http://web.oort.local` 按名字直达容器「web」——任意端口、无需 `-p`（`oort domains enable`） | ✅ |
| 🧭 **跟随 Mac DNS** | 客户机/容器用 Mac 的 DNS 解析器——内网/VPN 域名可解析 | ✅ |
| 🛰️ **`oort` CLI** | 生命周期、`oort exec`、docker 透传、`oort autostart` 开机自启 | ✅ |
| 🌱 **机器时间旅行** | `snapshot` / `restore` / **`fork`** 整台 Linux 机器（环境的 git——*OrbStack 做不到*） | ✅ |
| ⚡ **瞬间恢复** | `oort suspend` 冻结整台 VM；下次 start **~1.2s 恢复、容器原地存活**（*OrbStack 只能冷启动*） | ✅ |
| 🖥️ **原生 SwiftUI 应用** | 窗口化控制面板（仪表盘、容器、镜像、卷、机器、设置）+ 菜单栏 —— `oort gui` | ✅ |
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
./oort build-image

# 3. 启动（等待 Docker 就绪，自动打印 DOCKER_HOST）
./oort start

# 4. 使用
export DOCKER_HOST=unix://$HOME/.oort/docker.sock
docker run --rm hello-world
oort status
oort stop
```

更详细的步骤见 **[docs/快速开始.md](./docs/quickstart.zh-CN.md)**。

---

## 🧭 架构一览

```
   ┌─ macOS ───────────────────────────────────┐        ┌─ Linux VM（Virtualization.framework）─┐
   │  docker CLI / oort                          │        │  oort-guest（Go，编译二进制）：     │
   │     │ DOCKER_HOST=unix://~/.oort/...     │        │    vsock 2375 → /run/docker.sock      │
   │     ▼                                       │ vsock  │    vsock 2376 → exec（oort exec）       │
   │  oort（Swift）                           │◀──────▶│    vsock 2377 → tcp 端口转发           │
   │   ├─ VZ 虚拟机控制                          │        │  dockerd（静态）+ containerd          │
   │   ├─ DockerSocketProxy（unix ⇄ vsock 2375） │        │  VirtioFS：/mnt/mac、/mnt/rosetta     │
   │   ├─ PortForwarder（127.0.0.1:P ⇄ 2377）    │        │  Rosetta binfmt_misc（x86-64）        │
   │   └─ VirtioFS / Rosetta / NAT 设备           │        └───────────────────────────────────────┘
   └─────────────────────────────────────────────┘
```

客户机是一台 stock Ubuntu 24.04 云镜像，首次启动**无需 apt**完成配置（静态 Docker 引擎 +
编译好的 `oort-guest` agent，经 VirtioFS 共享盘投递）。

> 想深入了解「OrbStack 怎么做到的、我们怎么复刻」？看 **[orbstack-research.md](./orbstack-research.md)** 深度调研报告，
> 以及 **[docs/架构与原理.md](./docs/architecture.zh-CN.md)**。

---

## 📚 文档

| 文档 | 内容 |
|---|---|
| [快速开始](./docs/quickstart.zh-CN.md) | 安装、首次运行、常用操作 |
| [架构与原理](./docs/architecture.zh-CN.md) | VZ / vsock / VirtioFS / Rosetta / 端口转发 / Go agent 的实现原理 |
| [命令参考](./docs/cli-reference.zh-CN.md) | `oort` 全部子命令 + `oort run` 全部参数 |
| [常见问题](./docs/faq.zh-CN.md) | FAQ 与排错（DNS、zram、provisioning、与 Docker Desktop 共存等） |
| [路线图](./docs/roadmap.zh-CN.md) | 已完成 + 接下来要做的 |
| [计划](./docs/plan.zh-CN.md) | 一步步追平 OrbStack 的可执行计划 |
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
oort/
├── Sources/oort/         Swift：VM 编排 + socket 代理 + 端口转发
│   ├── VMConfig.swift        构建 VZVirtualMachineConfiguration（各类设备）
│   ├── VMManager.swift       VM 生命周期（绑定 VZ 串行队列）
│   ├── DockerSocketProxy.swift  host unix socket ⇄ guest vsock 隧道
│   ├── PortForwarder.swift   监视 Docker，转发发布端口到 localhost
│   └── Config.swift / main.swift
├── guest-agent/main.go      客户机 agent（docker 桥 + exec + tcp 转发，编译为 linux/arm64）
├── cloud-init/              无 apt 的首次启动配置
├── oort                      命令行入口
├── make-image.sh            构建启动盘 + seed + 交叉编译 agent
└── orbstack-research.md     深度调研报告
```

---

## ⚠️ 已知限制

- **bind mount 元数据速度**：VirtioFS 逐文件操作比客户机盘慢 8–35×（`rm -rf`、扫描、watcher）
  ——但真实 `npm install` 仅慢约 1.2×。当下的解法：**`oort fastvol`** 把热目录（`node_modules` 等）
  放在客户机盘上，见 [dev-filesystem](./docs/dev-filesystem.md)。
- **VPN 流量**：经可选的 gvproxy 用户态网络栈支持（`OORT_NET=gvproxy`）；DNS 已默认跟随 Mac。
- **zram**：stock Ubuntu 云内核不含 `zram` 模块，该服务会优雅跳过；`oort build-kernel`
  的自编译内核已内置。
- **`*.oort.local` 可达性**：域名经引擎内置 DNS 解析，但到达容器 IP 需要路由
  （`oort domains enable`，sudo）；路由跟随客户机 IP，VM 重启后可能需 `oort domains route`
  刷新（`oort start` 会提醒）。仅 VZ NAT 模式。
- **单 VM**：单一共享内核 VM（类 WSL2 / OrbStack）；「机器」是其上的命名环境（`oort machine`）。
- 与 Docker Desktop 共存时注意 `DOCKER_HOST`/`docker context`，详见[常见问题](./docs/faq.zh-CN.md)。

---

## 🛣 路线图

**超越 OrbStack** —— 与其只追赶 OrbStack 的护城河，oort 选择开辟它忽略的品类：
把开发环境变成可版本化、可分叉的 git 对象（**机器时间旅行**，已发布）、AI 编码代理的
本地沙箱基座（**`oort mcp`**，已发布）、**环境即代码**（`oort up` + `oort.yaml`，已发布）。

追赶项进展（OrbStack 的主场）：

- ✅ **自编译 Linux 内核 + 直接内核引导**（`oort build-kernel`：单体、无 initramfs、内置 zram）
- ✅ **用户态网络栈**（可选 `OORT_NET=gvproxy`：流量跟随 Mac 的路由/VPN 和 DNS）
- ✅ **`*.oort.local` 域名**（`oort domains enable`——OrbStack 的 `*.orb.local`）
- ✅ **主动内存 ballooning**（默认开启，宿主侧占用跟随客户机实际用量）
- ✅ **Kubernetes**（`oort k8s enable`：k3s + 投影 API + kubeconfig）
- ✅ **原生 SwiftUI 应用**（`oort gui`）
- ⚡ 剩余：VirtioFS 通用提速（需自研 VMM，低回报暂缓）、gvproxy 按 IP 直达、KSM/DAX 调优

详见[路线图](./docs/roadmap.zh-CN.md)与[调研报告 §4](./orbstack-research.md)。

详见[调研报告 §4](./orbstack-research.md)，以及可借力的开源项目（Lima、gvisor-tap-vsock、virtiofsd、Apple `containerization`）。

---

## 🙏 致谢与说明

本项目是**学习与研究性质**的 OrbStack 精简复刻，站在巨人的肩膀上：Apple `Virtualization.framework`、
Docker、Ubuntu cloud image。OrbStack 是闭源商业产品，本项目与其无任何关联。

## 📄 许可证

[MIT](./LICENSE) © 2026 everettjf
