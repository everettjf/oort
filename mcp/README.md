# oort MCP — Linux sandboxes for AI agents

`oort-mcp.py` is a zero-dependency [MCP](https://modelcontextprotocol.io)
server that gives AI coding agents (Claude, Cursor, …) first-class tools to use
oort machines as **disposable, forkable sandboxes**.

This is oort's "beyond OrbStack" bet made concrete. OrbStack treats
environments as hand-configured pets; here an agent can spin up a clean Linux
environment, run commands in it, **snapshot** before a risky step, **fork** to
explore alternatives in parallel, **restore** when something breaks, and
**destroy** when done — all on the shared-kernel VM, no per-call VM boot.

## Tools

| Tool | What it does |
|---|---|
| `create_sandbox(name, distro?)` | Create an isolated sandbox (starts the VM if needed). `distro` default `ubuntu`; `alpine` for a tiny fast one. |
| `exec(name, command)` | Run a shell command **inside** the sandbox; returns combined output. Pipes / redirections / `$VAR` evaluate in the sandbox. |
| `snapshot(name, tag?)` | Checkpoint the sandbox filesystem to a tagged image (tag defaults to a timestamp). |
| `restore(name, tag?)` | Roll the sandbox back to a snapshot (newest if no tag). |
| `fork(source, name)` | Instantly branch a set-up sandbox into a new one (CoW, no re-provisioning). |
| `list_sandboxes()` | List sandboxes. |
| `list_snapshots(name)` | List a sandbox's snapshots. |
| `destroy(name, purge?)` | Delete a sandbox; `purge` also drops its snapshots. |

## Wire it into a client

The server speaks MCP over stdio. Launch it with `oort mcp` (which execs this
file). For Claude Code:

```bash
claude mcp add oort -- /absolute/path/to/oort/oort mcp
```

Or point any MCP client at the command `oort mcp` (cwd anywhere; the launcher
resolves the repo). Env var `OORB` overrides the path to the `oort` CLI.

## Why this is safe-ish and useful for agents

- **Disposable**: a sandbox is a container on the shared kernel — cheap to make
  and destroy, so an agent can use one per task and throw it away.
- **Snapshot-on-risk**: checkpoint before `rm -rf`, a migration, a big install;
  `restore` if it goes wrong.
- **Fork-to-explore**: branch a configured environment and try N approaches in
  parallel without contaminating the baseline.

> Isolation note: these are shared-kernel containers, not per-VM boundaries — fine
> for routine agent work, not a substitute for hardware isolation against truly
> hostile code.

## Try it

```bash
# from the repo root, with the VM buildable:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./oort mcp
```
