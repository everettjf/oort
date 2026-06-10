# 路线图

[English](./roadmap.md) | [**简体中文**](./roadmap.zh-CN.md)

oort 现在到哪了、接下来往哪走。本项目是 OrbStack 的学习/研究性复刻——目标是复刻核心体验，并一步步缩小与 OrbStack 的差距。

> 如何逐项补齐,见**[分阶段计划](./plan.zh-CN.md)**。

## ✅ 已完成

**阶段一～四**（可用的核心）：
- 用 `Virtualization.framework` 启动轻量 Linux VM。
- 把容器引擎经 `virtio-vsock` 投影到 macOS unix socket。
- VirtioFS 文件共享；Rosetta x86-64；容器端口转发；`oort` CLI。
- 编译型 Go 客户机 agent（docker 桥 + exec + tcp 转发），无 apt 的首次配置。

**加固（v0.1.0 之后）：**
- **容器联网** —— dockerd 管理 iptables NAT；`docker build` 与运行时出网都正常。
- **可靠性** —— 优雅关机、固定网卡 MAC 让复用盘重启保持联网、`/version` 就绪判定、`oort autostart` 开机自启。
- **家目录镜像** —— Mac 家目录以相同路径挂进客户机，任意项目 `docker -v $PWD:/app` 可用。
- **跟随 Mac DNS** —— 容器内可解析内网 / VPN 域名。
- **事件驱动端口转发** + `bench.sh` 性能基线。
- **存活看门狗** —— 客户机内周期巡检，dockerd/containerd「活着但失联」时（`Restart=always`
  管不到的状态）按持续失败才重启，不误杀忙碌的构建。已真机验证（冻结 dockerd 约 39s 自愈）。
- **容器出网周期自愈**（`oort-egress-heal.timer`）—— 捕捉启动后才退化的容器 TCP/DNS
  出网，仅在持续失败且有容器运行时重启 docker 重建 NAT。已确定性验证（清空 NAT → 自愈）。
- **agent 卡死自愈** —— agent 健康时维护心跳，客户机看门狗发现心跳过期只重启 agent
  （不重启 VM）；另有宿主侧探针 **`oort doctor`** 区分 VM / dockerd / agent 三类故障。

→ oort 现在已能在常见工作流上替代 Docker Desktop：`docker build`、Compose、开发用 bind mount、内网 DNS、稳定重启。

## 🚀 超越 OrbStack（差异化，而非追赶）

下面大部分路线仍是*追赶*——在 OrbStack 的主场（自编内核、virtiofs 护城河、网络栈）
拼平手，这是最难、回报最低的仗。更高杠杆的打法是吃下 OrbStack 忽略的品类，
用 oort 的结构性优势（开源、可脚本化、MIT）：

> **不在跑分上打 OrbStack——把开发环境变成可版本化、可分叉、可丢弃的
> git 对象，并成为 AI 编码代理的本地沙箱基座。** OrbStack 把环境当手工配置的
> *宠物*：没有 snapshot / fork / 分支 / 回滚，也没有任何 AI 代理集成。

- ✅ **机器时间旅行（已发布）。** 机器本质是容器，整个文件系统就是内容寻址镜像：
  `oort machine snapshot` 把现场提交为带标签的镜像；`restore` 回滚；
  **`fork` 把配置好的机器瞬间分叉成新机器**（CoW 镜像层，无需重新配置）。
  「环境的 git」——已端到端验证。*OrbStack 完全没有。*
- ✅ **AI 代理沙箱层（已发布）。** `oort mcp` 提供零依赖的
  [MCP](https://modelcontextprotocol.io) stdio 服务器，暴露
  `create_sandbox / exec / snapshot / restore / fork / list / destroy`——
  编码代理获得即用即弃环境、冒险前快照、并行分叉探索。见 [`mcp/`](../mcp/README.md)。
  *OrbStack 没有同类能力。*
- ✅ **瞬间恢复（已发布）。** `oort suspend` 暂停 VM 并把完整状态（内存 + 设备）经 VZ 的
  save/restore 存盘；下次 `oort start` **~1.2s** 恢复——运行中的容器、shell、socket 全部
  原地复活，客户机时钟自动校正。状态一次性使用，磁盘镜像变更时自动作废。（需要持久化
  `VZGenericMachineIdentifier`——随机身份会让 restore 报模糊的 "invalid argument"。）
  *OrbStack 只能冷启动，没有同类能力。*
- ✅ **`oort up`（环境即代码，已发布）。** 声明式 `oort.yaml`（或 `.json`）描述机器 +
  一次性 `setup` 命令；`oort up` 复现、`oort down` 拆除。幂等（已存在的机器跳过）。
  见 [`oort.example.yaml`](../oort.example.yaml)。

## 🔜 接下来

大致按价值排序。

### 性能 —— OrbStack 真正的护城河
- ✅ **自编译内核 + 直接内核引导（已发布）。** `oort start` 经 VZ 的 `VZLinuxBootLoader`
  直接引导（跳过 EFI+GRUB）；**`oort build-kernel`** 在客户机内编译单体 arm64 内核
  （全部 `=y`、无模块、无 initramfs、**内置 zram**），EFI 作兜底。v0.3.4 进一步裁剪
  驱动（74→41 MB）并屏蔽启动赘项：`oort start`→Docker 就绪 **stock 约 4.5s / 自编内核约
  2.8s**（原 7–9s）。距 OrbStack 的 1–2s 还差 dockerd 自身约 1s 初始化 + VZ/内核地板。
- ~~**VirtioFS 缓存层**~~ —— 已实测并重新定位：逐文件元数据操作慢 8–35×，但真实
  `npm install` 仅慢约 1.2×。真正慢的操作（`rm -rf`、扫描、watcher）由 **`oort fastvol`**
  （热目录放客户机盘）解决——见 [`docs/dev-filesystem.md`](./dev-filesystem.md)。
  追平 OrbStack 的通用 virtiofs 速度需要自研宿主侧服务（VZ 不允许）→ 低回报，暂缓。

### 网络
- ✅ **用户态网络栈（已发布，可选）。** `OORT_NET=gvproxy oort start` 把客户机网卡接到
  gvproxy（`VZFileHandleNetworkDeviceAttachment`），流量走 macOS 自己的栈——跟随 Mac 的
  路由/VPN 和 DNS。与 VZ NAT 等价性已验证。剩余：宿主按 IP 直达（gvproxy 转发 API）；
  经真实 VPN 验证后转为默认。
- ✅ **`*.oort.local` 域名（已发布）。** OrbStack 广受欢迎的 `*.orb.local`，oort 版：
  引擎在 `127.0.0.1:5354` 内置小型 DNS 服务器，按 Docker 实时状态应答容器
  （`web.oort.local`）、机器（`dev.oort.local`）、compose 服务
  （`api.myproj.oort.local`）。`oort domains enable`（一次性，sudo）写入按域分流的
  `/etc/resolver/oort.local` 并加容器路由——之后容器**任意端口**按名字直达，无需 `-p`。
  仅 VZ NAT 模式；路由跟随客户机 IP（`oort domains route` 刷新）。

### 资源效率
- ✅ **主动内存 ballooning（已发布）。** 引擎周期性地经 vsock agent 读取客户机真实用量，
  把气球目标设为 `用量 + 余量`（负载升高立刻放气、空闲时缓慢回收）——VM 的宿主侧
  内存占用跟随客户机实际所需，OrbStack 式动态内存。默认开启；`--no-dynamic-memory` 关闭。
- **zram** 压缩交换（依赖自编译内核带该模块）。

### 功能
- ✅ **Kubernetes（已发布）。** `oort k8s enable` 在客户机一次性安装 k3s，把 API server
  投影到 Mac 的 `localhost:6443`（静态 tcp 转发）并写出 kubeconfig（`~/.oort/kube/config`）
  ——之后原生 `kubectl` 直接可用。
- ✅ **多台 Linux 机器（已发布）。** `oort machine create/list/shell/exec/delete` ——
  共享内核上的命名多发行版环境（OrbStack 的 "machines"），外加 OrbStack 没有的
  snapshot/restore/fork 时间旅行（见「超越 OrbStack」）。
- ✅ **GUI（已发布）。** 完整的原生 SwiftUI 应用（`oort gui`）：仪表盘、容器（+日志）、
  镜像、卷、机器（快照/回滚/分叉/shell）、设置，外加菜单栏项。

## 📝 当前已知限制

- bind mount 小文件速度（见上面「性能」；`oort fastvol` 可绕过）。
- VPN 流量路由默认未开（DNS 已跟随 Mac）；`OORT_NET=gvproxy` 可选启用。
- zram 在 stock 内核上空转（无模块；`oort build-kernel` 的自编内核已内置）。
- `*.oort.local` 需要容器路由（sudo），且路由跟随客户机 IP，重启后可能需
  `oort domains route` 刷新；仅 VZ NAT 模式。

详见[调研报告](../orbstack-research.md) §4 的深入分析，以及可借力的开源项目（Lima、gvisor-tap-vsock、virtiofsd、Apple `containerization`）。
