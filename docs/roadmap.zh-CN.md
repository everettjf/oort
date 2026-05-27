# 路线图

[English](./roadmap.md) | [**简体中文**](./roadmap.zh-CN.md)

openorb 现在到哪了、接下来往哪走。本项目是 OrbStack 的学习/研究性复刻——目标是复刻核心体验，并一步步缩小与 OrbStack 的差距。

> 如何逐项补齐,见**[分阶段计划](./plan.zh-CN.md)**。

## ✅ 已完成

**阶段一～四**（可用的核心）：
- 用 `Virtualization.framework` 启动轻量 Linux VM。
- 把容器引擎经 `virtio-vsock` 投影到 macOS unix socket。
- VirtioFS 文件共享；Rosetta x86-64；容器端口转发；`oorb` CLI。
- 编译型 Go 客户机 agent（docker 桥 + exec + tcp 转发），无 apt 的首次配置。

**加固（v0.1.0 之后）：**
- **容器联网** —— dockerd 管理 iptables NAT；`docker build` 与运行时出网都正常。
- **可靠性** —— 优雅关机、固定网卡 MAC 让复用盘重启保持联网、`/version` 就绪判定、`oorb autostart` 开机自启。
- **家目录镜像** —— Mac 家目录以相同路径挂进客户机，任意项目 `docker -v $PWD:/app` 可用。
- **跟随 Mac DNS** —— 容器内可解析内网 / VPN 域名。
- **事件驱动端口转发** + `bench.sh` 性能基线。

→ openorb 现在已能在常见工作流上替代 Docker Desktop：`docker build`、Compose、开发用 bind mount、内网 DNS、稳定重启。

## 🔜 接下来（尚未开始）

大致按价值排序。以下都是较大的多步工程。

### 性能 —— OrbStack 真正的护城河
- **自编译 Linux 内核**（交叉编译，和 OrbStack 一样）。解锁 `zram`、VirtioFS **DAX**、KSM 与各种调优。是最大的使能项——下面好几项都依赖它。
- **VirtioFS 缓存层**，针对小文件/元数据操作。实测目前比本地盘慢约 21×（`npm install` 之痛）；VZ 不暴露缓存调优，所以需要自研 FUSE/DAX 路径。*OrbStack 标志性的 2–5× 优势就在这。*

### 网络
- **用户态网络栈**（如 gvisor-tap-vsock），实现完整的 VPN **流量**路由（DNS 解析已跟随 Mac）、统一 bridge、按 IP 互达。

### 资源效率
- **主动内存 ballooning** —— 按需增长/回收客户机内存（气球设备已挂载）。
- **zram** 压缩交换（依赖自编译内核带该模块）。

### 功能
- **Kubernetes** —— guest 装 k3s + 投影 kube API + kubeconfig（剩余项里最自包含、最易做的一步）。
- **多台 Linux 机器** —— 命名、多发行版环境（OrbStack 的 "machines"）。
- **GUI** —— 原生 SwiftUI 应用（状态、容器、机器、设置）。

## 📝 当前已知限制

- bind mount 小文件速度（见上面「性能」）。
- VPN 流量路由尚未接线（DNS 已跟随 Mac）。
- zram 在 stock 内核上空转（无模块）。
- 单一共享内核 VM；无 GUI。

详见[调研报告](../orbstack-research.md) §4 的深入分析，以及可借力的开源项目（Lima、gvisor-tap-vsock、virtiofsd、Apple `containerization`）。
