# 超越 OrbStack：上手教程

[English](./beyond-orbstack.md) | [**简体中文**](./beyond-orbstack.zh-CN.md)

oort 把 OrbStack 那套都做了（Docker、文件共享、Rosetta、端口转发），但它还做了
三件 OrbStack **做不到**的事。本教程把这三件从头到尾走一遍，命令都可直接复制。

核心理念：OrbStack 把开发环境当成手工配置的「宠物」。oort 把它当成
**可版本化、可 fork、可丢弃的 git 对象**——并把这套能力开放给 AI 编码 agent。

| | 能力 | 为什么是「超越」 |
|---|---|---|
| 1 | **Machine 时间旅行** | 对整个 Linux 环境 snapshot / restore / **fork** |
| 2 | **环境即代码** | 用提交进仓库的 `oort.yaml` 复现机器 |
| 3 | **AI-agent 沙箱** | 一个 MCP server：agent 拿到即开即弃、可 fork 的环境 |

## 前置准备

```bash
# 在仓库根目录，一次性：
./oort build-image      # 构建并 provision golden 磁盘（仅首次）
./oort start            # 启动 VM；Docker 就绪后打印 DOCKER_HOST
```

下面都假设 `oort start` 已成功。**machine** 是共享内核 VM 上的一个命名 Linux 环境
（即 OrbStack 的 "machines"）——底层是一个长期存活的容器，**正是这一点让"时间旅行"
成为可能**。

---

## 1. Machine 时间旅行 —— 给开发环境用的 git

创建一台 machine 并配置它：

```bash
oort machine create devbox ubuntu
oort machine exec devbox apt-get update -y
oort machine exec devbox apt-get install -y git
oort machine shell devbox            # 想要交互式 shell 时用
```

对一个「已知良好」状态打 **snapshot**，然后放心折腾：

```bash
oort machine snapshot devbox clean-baseline
oort machine snapshots devbox        # 列出快照（tag / 时间 / 大小）
```

弄坏了？**回滚**（不写 tag 就回滚到最新快照）：

```bash
oort machine restore devbox clean-baseline
```

把一台配置好的机器**瞬间 fork** 成新的一台——基于写时复制（CoW）镜像层，无需重新
provision。适合从同一起点并行尝试两条路线：

```bash
oort machine fork devbox experiment
oort machine exec experiment sh -c 'echo "只在这个分支里" >> /etc/notes'
oort machine exec devbox     cat /etc/notes   # 原机器完全不受影响
```

清理（不加 `--purge` 时保留快照）：

```bash
oort machine delete experiment --purge
oort machine list
```

> 提示：`oort machine exec <name> <cmd...>` 在机器**内部**执行 `<cmd>`。管道、重定向、
> `$变量` 都在机器内求值，例如
> `oort machine exec devbox sh -c 'echo hi > /f && cat /f'`。

---

## 2. 环境即代码 —— 用一个文件复现环境

把环境和代码一起提交。创建 `oort.yaml`：

```yaml
machines:
  web:
    distro: ubuntu
    setup:                       # 首次 up 时按顺序执行一次
      - apt-get update -y
      - apt-get install -y --no-install-recommends git curl
  cache:
    distro: alpine
    setup:
      - apk add --no-cache redis
```

一键起、一键拆：

```bash
oort up                # 创建 web + cache，各自跑一次 setup
oort up                # 幂等：已存在的机器会被跳过
oort down              # 删除声明的机器
oort down --purge      # ……并一并删除它们的快照
```

`oort up <file>` / `oort down <file>` 可显式指定路径；不带参数时，会在当前目录查找
`oort.yaml` / `oort.yml` / `oort.json`。同结构的 JSON 也支持——写脚本时方便。
参见 [`oort.example.yaml`](../oort.example.yaml)。

---

## 3. AI-agent 沙箱（MCP）

`oort mcp` 启动一个 [MCP](https://modelcontextprotocol.io) server（stdio），给 AI 编码
agent 提供一等公民工具，把 oort 机器当作**即开即弃、可 fork 的沙箱**：开一个干净
环境、跑命令、在危险操作前 snapshot、fork 出去探索别的方案、出错就 restore、用完
destroy。

接入 Claude Code：

```bash
claude mcp add oort -- /绝对路径/到/oort/oort mcp
```

（任何 MCP 客户端都行——把命令指向 `oort mcp` 即可。）agent 会看到这些工具：

| 工具 | 用途 |
|---|---|
| `create_sandbox(name, distro?)` | 新建沙箱（需要时自动启动 VM） |
| `exec(name, command)` | 在沙箱内执行 shell 命令 |
| `snapshot(name, tag?)` / `restore(name, tag?)` | 打快照 / 回滚 |
| `fork(source, name)` | 从一个配置好的沙箱分叉 |
| `list_sandboxes()` / `list_snapshots(name)` | 查看 |
| `destroy(name, purge?)` | 删除 |

一个典型的 agent 工作流（这些工具支撑的）：

> 创建一个 `scratch` 沙箱 → 打快照为 `clean` → 尝试一次有风险的重构/迁移 → 失败就
> `restore clean` 重来 → 成功就 `fork` 一份并行跑测试套件 → 完事 `destroy`。

不接 agent，手动验证 server：

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./oort mcp
```

更多细节见 [`mcp/README.md`](../mcp/README.md)。

> 隔离说明：沙箱是共享内核的容器——便宜、适合日常 agent 工作，但**不是**对抗真正
> 恶意代码的硬件级隔离边界。

---

## 速查表

```bash
# 时间旅行
oort machine create <name> [distro]
oort machine snapshot <name> [tag]
oort machine restore  <name> [tag]
oort machine fork     <src> <new>
oort machine delete   <name> [--purge]

# 环境即代码
oort up   [file]
oort down [file] [--purge]

# AI-agent 沙箱
oort mcp                       # MCP stdio server
claude mcp add oort -- /path/to/oort mcp
```

每个参数的细节见 [CLI 参考](./cli-reference.zh-CN.md)，后续计划（地基加固、自编译内核）
见 [roadmap](./roadmap.zh-CN.md)。
