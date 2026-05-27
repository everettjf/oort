# 快速开始

[English](./quickstart.md) | **简体中文**

本文带你从零跑起来 openorb：装依赖 → 构建镜像 → 启动 → 使用。

## 1. 环境要求

- Apple Silicon Mac（M 系列），**macOS 13 或更高**（开发验证于 26.3）
- [Swift 工具链](https://www.swift.org/install/)（Xcode 或 Command Line Tools 自带）
- [Go](https://go.dev/dl/) 1.21+（用于交叉编译客户机 agent）
- `qemu-img`（转换云镜像）：

```bash
brew install qemu
```

确认环境：

```bash
swift --version
go version
qemu-img --version
```

## 2. 获取客户机镜像（一次性）

openorb 客户机基于 Ubuntu 24.04 ARM64 云镜像：

```bash
cd openorb            # 仓库根目录
mkdir -p images
curl -fL -o images/noble-arm64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img
```

> 镜像约 600 MB。`images/` 已在 `.gitignore` 中，不会进仓库。

## 3. 构建启动盘 + seed + agent

```bash
./oorb build-image
```

这一步会（见 `make-image.sh`）：

1. 用 Go 交叉编译客户机 agent（`openorb-guest`，linux/arm64）到共享目录 `share/`；
2. 把云镜像 qcow2 转成 raw（VZ 需要 raw）并扩容到 12 GB；
3. 用 `hdiutil` 生成 cloud-init NoCloud seed（卷标 `CIDATA`）。

完成后 `images/` 下会有 `disk.img` 和 `seed.img`。

## 4. 启动

```bash
./oorb start
```

首次启动会**无需 apt**自动完成配置（安装静态 Docker 引擎、启动客户机 agent、挂载共享、注册 Rosetta）。
`oorb start` 会一直等到 Docker 就绪，然后打印 `DOCKER_HOST`。

> 首次配置通常几十秒（取决于 Docker CDN 速度）。之后复用同一块盘启动只需几秒。

## 5. 使用 Docker

让原生 `docker` CLI 指向 openorb 的守护进程：

```bash
export DOCKER_HOST=unix://$HOME/.openorb/docker.sock
docker run --rm hello-world
docker ps
```

或者用内置透传，省去设置 `DOCKER_HOST`：

```bash
oorb docker run --rm hello-world
```

打印 env 方便加到 shell 配置：

```bash
oorb env        # 输出： export DOCKER_HOST=unix://...
eval "$(oorb env)"
```

## 6. 文件共享

仓库的 `share/` 目录默认以 VirtioFS 挂到客户机 `/mnt/mac`。容器里挂这个目录即可读写主机文件：

```bash
echo hello > share/note.txt
oorb docker run --rm -v /mnt/mac:/m alpine cat /m/note.txt   # 输出 hello
```

> 注意：`-v /mnt/mac:/m` 里的 `/mnt/mac` 是**客户机内**的路径（VirtioFS 挂载点），不是 macOS 路径。

## 7. 运行 x86 镜像（Rosetta）

```bash
oorb docker run --rm --platform linux/amd64 alpine uname -m   # 输出 x86_64
```

## 8. 端口转发

容器发布的端口自动出现在 macOS 的 `localhost`：

```bash
oorb docker run -d -p 8080:80 nginx
curl http://localhost:8080/        # 直接通
```

## 9. 在客户机里执行命令

```bash
oorb exec 'uname -a'
oorb exec 'systemctl status docker --no-pager | head'
oorb shell                # 简易交互式 shell（逐行）
```

## 10. 查看状态 / 停止

```bash
oorb status               # VM 与 Docker 状态
oorb logs                 # tail 客户机控制台日志
oorb stop                 # 干净关机
```

## 常用一条龙

```bash
./oorb build-image && ./oorb start && eval "$(./oorb env)"
docker run --rm hello-world
./oorb stop
```

遇到问题看 **[常见问题](./faq.zh-CN.md)**；想了解内部原理看 **[架构与原理](./architecture.zh-CN.md)**。
