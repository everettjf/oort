# Beyond OrbStack: a hands-on tutorial

[**English**](./beyond-orbstack.md) | [简体中文](./beyond-orbstack.zh-CN.md)

oort does the OrbStack things (Docker, file sharing, Rosetta, ports), but it
also does three things OrbStack **can't**. This tutorial walks through all three,
end to end, with commands you can paste.

The thesis: OrbStack treats a dev environment as a hand-configured *pet*. oort
treats it as a **versionable, forkable, disposable git-object** — and exposes that
to AI coding agents.

| | What | Why it's beyond OrbStack |
|---|---|---|
| 1 | **Machine time-travel** | snapshot / restore / **fork** a whole Linux env |
| 2 | **Env-as-code** | reproduce machines from a committed `oort.yaml` |
| 3 | **AI-agent sandboxes** | an MCP server: agents get disposable, forkable envs |

## Prerequisites

```bash
# from the repo root, one-time:
./oort build-image      # build + provision the golden disk (first run only)
./oort start            # boot the VM; prints DOCKER_HOST when Docker is ready
```

Everything below assumes `oort start` has succeeded. A *machine* is a named Linux
environment on the shared-kernel VM (OrbStack's "machines") — backed by a
long-lived container, which is exactly what makes time-travel possible.

---

## 1. Machine time-travel — git for dev environments

Create a machine and configure it:

```bash
oort machine create devbox ubuntu
oort machine exec devbox apt-get update -y
oort machine exec devbox apt-get install -y git
oort machine shell devbox            # interactive shell, when you want one
```

**Snapshot** a known-good state, then experiment freely:

```bash
oort machine snapshot devbox clean-baseline
oort machine snapshots devbox        # list snapshots (tag / age / size)
```

Broke something? **Roll back** (newest snapshot if you omit the tag):

```bash
oort machine restore devbox clean-baseline
```

**Fork** a fully-set-up machine into a new one — instantly, via copy-on-write
image layers, with no re-provisioning. Great for trying two approaches from a
common starting point:

```bash
oort machine fork devbox experiment
oort machine exec experiment sh -c 'echo "only in this branch" >> /etc/notes'
oort machine exec devbox     cat /etc/notes   # the original is untouched
```

Clean up (snapshots are kept unless you `--purge`):

```bash
oort machine delete experiment --purge
oort machine list
```

> Tip: `oort machine exec <name> <cmd...>` runs `<cmd>` **inside** the machine.
> Pipes, redirections and `$VARs` evaluate in the machine, e.g.
> `oort machine exec devbox sh -c 'echo hi > /f && cat /f'`.

---

## 2. Env-as-code — reproduce an environment from a file

Commit your environment alongside your repo. Create `oort.yaml`:

```yaml
machines:
  web:
    distro: ubuntu
    setup:                       # run once, in order, on first `up`
      - apt-get update -y
      - apt-get install -y --no-install-recommends git curl
  cache:
    distro: alpine
    setup:
      - apk add --no-cache redis
```

Bring it up and tear it down:

```bash
oort up                # creates web + cache, runs each setup once
oort up                # idempotent: existing machines are skipped
oort down              # delete the declared machines
oort down --purge      # …and drop their snapshots too
```

`oort up <file>` / `oort down <file>` take an explicit path; with no argument they
look for `oort.yaml` / `oort.yml` / `oort.json` in the current directory.
JSON with the same shape works too — handy in scripts. See
[`oort.example.yaml`](../oort.example.yaml).

---

## 3. AI-agent sandboxes (MCP)

`oort mcp` runs an [MCP](https://modelcontextprotocol.io) server (stdio) that
gives an AI coding agent first-class tools to use oort machines as
**disposable, forkable sandboxes**: spin up a clean env, run commands, snapshot
before a risky step, fork to explore alternatives, restore on failure, destroy
when done.

Wire it into Claude Code:

```bash
claude mcp add oort -- /absolute/path/to/oort/oort mcp
```

(Any MCP client works — point it at the command `oort mcp`.) The agent then sees
these tools:

| Tool | Use |
|---|---|
| `create_sandbox(name, distro?)` | new sandbox (starts the VM if needed) |
| `exec(name, command)` | run a shell command inside it |
| `snapshot(name, tag?)` / `restore(name, tag?)` | checkpoint / roll back |
| `fork(source, name)` | branch a set-up sandbox |
| `list_sandboxes()` / `list_snapshots(name)` | inspect |
| `destroy(name, purge?)` | delete |

A typical agent workflow (what the tools enable):

> create a `scratch` sandbox → `snapshot` it as `clean` → attempt a risky refactor
> / migration → on failure `restore clean` and try again → on success `fork` it to
> run the test suite in parallel → `destroy` when finished.

Verify the server by hand without an agent:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./oort mcp
```

More detail in [`mcp/README.md`](../mcp/README.md).

> Isolation note: sandboxes are shared-kernel containers — cheap and great for
> routine agent work, but not a hardware-isolation boundary against truly hostile
> code.

---

## Cheatsheet

```bash
# time-travel
oort machine create <name> [distro]
oort machine snapshot <name> [tag]
oort machine restore  <name> [tag]
oort machine fork     <src> <new>
oort machine delete   <name> [--purge]

# env-as-code
oort up   [file]
oort down [file] [--purge]

# AI-agent sandboxes
oort mcp                       # MCP stdio server
claude mcp add oort -- /path/to/oort mcp
```

See the [CLI reference](./cli-reference.md) for every flag, and the
[roadmap](./roadmap.md) for what's next (foundation hardening, a custom kernel).
