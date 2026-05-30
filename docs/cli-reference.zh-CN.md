# 命令参考

[English](./cli-reference.md) | **简体中文**

包含 `oort` 命令行的全部子命令，以及底层引擎 `oort run` 的全部参数。

## `oort` —— 命令行入口

`oort` 是对 `oort run` 的轻量封装，固化了常用的启动参数并提供生命周期/执行/透传等便捷命令。

| 命令 | 说明 |
|---|---|
| `oort start` | 启动 VM（Docker + 文件共享 + Rosetta + 端口转发），等待 Docker 就绪并打印 `DOCKER_HOST` |
| `oort stop` | 干净关闭 VM |
| `oort restart` | 先 stop 再 start |
| `oort status` | 显示 VM 与 Docker 状态 |
| `oort exec <命令...>` | 在客户机里执行一条命令（经 vsock agent） |
| `oort shell` | 简易交互式客户机 shell（逐行执行） |
| `oort docker <参数...>` | 以 oort 守护进程为目标运行 `docker` |
| `oort env` | 打印 `export DOCKER_HOST=...`，可 `eval "$(oort env)"` |
| `oort logs` | tail 客户机控制台日志 |
| `oort build-image` | （重新）构建启动盘 + cloud-init seed + 编译客户机 agent |
| `oort help` | 显示帮助 |

### 示例

```bash
./oort build-image
./oort start
eval "$(./oort env)"

docker run --rm hello-world
oort docker ps
oort exec 'free -m'
oort status
oort stop
```

### 环境变量

`oort` 支持用环境变量覆盖默认路径：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `OORT_DISK` | `./images/disk.img` | 启动盘路径 |
| `OORT_SEED` | `./images/seed.img` | cloud-init seed 路径 |
| `OORT_SHARE` | `./share` | 共享给客户机（tag `mac`）的目录 |

宿主侧状态都放在 `~/.oort/`：

| 文件 | 用途 |
|---|---|
| `~/.oort/docker.sock` | 投影的 Docker socket（`DOCKER_HOST` 指向它） |
| `~/.oort/agent.sock` | exec agent（`oort exec` 用，转发到 vsock 2376） |
| `~/.oort/console.log` | 客户机控制台日志 |
| `~/.oort/vm.pid` / `vm.log` | VM 进程 PID / 日志 |

---

## `oort run` —— 底层引擎

`oort` 最终调用的就是它。直接用 `oort run` 可获得完全控制（先 `swift build -c release` 并 codesign，或用 `./run.sh`）。

```
oort run --disk <path> [选项]
```

### 引导

| 参数 | 说明 |
|---|---|
| `--disk <path>` | 可引导的 raw 磁盘镜像（必填） |
| `--seed <path>` | 额外的只读盘，如 cloud-init CIDATA 镜像 |
| `--nvram <path>` | EFI 变量存储路径（默认 `<disk>.nvram`） |
| `--kernel <path>` | 直引导内核镜像（改用 `VZLinuxBootLoader`，关闭 EFI） |
| `--initrd <path>` | 直引导的 initramfs（可选） |
| `--cmdline <字符串>` | 内核命令行（默认 `console=hvc0 root=/dev/vda rw`） |

### 资源

| 参数 | 说明 |
|---|---|
| `--cpus <n>` | vCPU 数量（默认 4） |
| `--memory <GiB>` | 内存（GiB，默认 4） |

### 文件共享（VirtioFS）

| 参数 | 说明 |
|---|---|
| `--mount <hostdir>[:tag][:ro]` | 把主机目录以 VirtioFS 共享进客户机（可重复）。第一个的默认 tag 是 `mac`，客户机挂在 `/mnt/<tag>`。加 `:ro` 只读 |
| `--rosetta` | 共享 Rosetta，使 x86-64 镜像可经翻译运行（必要时自动安装 Rosetta） |

### Docker 投影 / 转发

| 参数 | 说明 |
|---|---|
| `--socket <path>` | 宿主 Docker unix socket（默认 `~/.oort/docker.sock`） |
| `--vsock-port <n>` | 客户机提供 dockerd 的 vsock 端口（默认 2375） |
| `--forward <sock>:<port>` | 额外的 host-socket ⇄ guest-vsock-port 转发（可重复，如把 agent 暴露到 `~/.oort/agent.sock:2376`） |
| `--no-port-forward` | 关闭「容器端口自动转发到 localhost」 |

### 其它

| 参数 | 说明 |
|---|---|
| `--no-console` | 不把客户机串口接到 stdio |
| `--console-log <path>` | 把客户机控制台写入文件（无头调试） |
| `-h`, `--help` | 显示帮助 |

### 等价示例

`oort start` 大致等价于：

```bash
oort run \
  --disk images/disk.img --seed images/seed.img \
  --mount "$PWD/share:mac" --rosetta \
  --forward "$HOME/.oort/agent.sock:2376" \
  --no-console --console-log "$HOME/.oort/console.log" \
  --socket "$HOME/.oort/docker.sock"
```

---

## 客户机 vsock 端口

`oort-guest`（Go agent）在客户机内监听：

| vsock 端口 | 服务 |
|---|---|
| 2375 | Docker 桥（→ `/run/docker.sock`） |
| 2376 | exec（`oort exec` / `oort shell`） |
| 2377 | TCP 端口转发（端口转发用） |

宿主只能通过 oort 进程拥有的 `VZVirtioSocketDevice` 访问这些端口，因此都经 `--forward` 或内置代理暴露。
