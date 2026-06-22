# Plan: make the AI-agent sandbox layer deep

[**English**](./agent-sandbox-plan.md) | 简体中文 (todo)

This is the concrete, file-level work behind [Direction B](./strategy.md). It turns
the current MCP layer (a thin shell-out over `oort machine`) into something an agent
can actually rely on for parallel, untrusted, long-running work.

Each item cites the exact change site. Ordered by ROI within each tier.

## Status (v0.5.0 — Agent sandbox layer v1)

**Shipped:** 1.1 exit codes · 1.2 timeout · 1.4 file I/O · 1.5 exec cwd/env ·
2.1 resource caps · 2.2 network policy (+ fork/restore isolation inheritance) ·
3.1 concurrent MCP server · 3.2 cheap parallel fork · 3.3 pause/unpause ·
3.4 labels/TTL/gc (+ fork-base pruning).

**Next milestone:** 2.3 strong isolation (gVisor `runsc`) — needs provisioning +
on-VM verification · 1.3 streamed output — needs guest-agent + protocol work ·
3.5 robust snapshot resolution/retention · Tier 4 (public CI, demo). 2.4
read-only rootfs is low-priority.

---

## How the sandbox layer works today (so the gaps are concrete)

- A **machine** is a docker container `ovm-<name>` running an idle `sleep` loop,
  `--restart unless-stopped` — `_machine_run` (`oort:704`).
- **snapshot** = `docker commit` → `oort-machine/<name>:<tag>` (`oort:726`).
- **fork** = `docker commit` the source, then run a new container from it (`oort:751`).
- **restore** = `docker rm -f` + re-run from the snapshot image (`oort:740`).
- **exec** = POST the shell line to the guest agent, which runs it via
  `/bin/sh -c` and returns combined output (`oort:768` → `guest-agent/main.go:336`).
- The **MCP server** shells out to the `oort` CLI for every tool
  (`mcp/oort-mcp.py`), reading stdin one line at a time (`oort-mcp.py:294`).

Every machine lands on the **default docker bridge**, with **no resource caps**, on
the **shared kernel**. That's fine for the author; it's the gap for untrusted agent
code.

---

## Tier 1 — agent-grade exec & I/O (cheap, unblocks everything)

### 1.1 Surface exit codes  ★ critical
**Today:** `out, _ := c.CombinedOutput()` (`guest-agent/main.go:345`) throws the
exit code away. The agent only ever sees "exec failed" — it can't branch on
success/failure.
**Change:**
- `guest-agent/main.go:336-351` — capture the `*exec.ExitError`, derive the exit
  code, and return it. Add an `X-Oort-Exit: <code>` response header (keeps the body
  pure output).
- `oort:407` `cmd_exec` / `oort:768` `machine exec` — read the header, propagate as
  the process exit status.
- `oort-mcp.py:70` `tool_exec` — return a structured result, e.g. prefix
  `exit=<n>\n` or (better) a JSON content block `{exit_code, output}`.

### 1.2 Fix the timeout mismatch  ★ critical
**Today:** `execTimeout = 110 * time.Second` (`guest-agent/main.go:53`) silently
kills any command over 110s — but `EXEC_TIMEOUT = 600` (`oort-mcp.py:35`) advertises
600s. Builds and installs hit the floor and die.
**Change:** make the per-exec timeout caller-supplied (header `X-Oort-Timeout`, or a
long-running mode), defaulting high for sandbox work. Keep a concurrency cap
(`execSem`, `guest-agent/main.go:58`) but stop hard-killing long legitimate work.

### 1.3 Streamed output + stdout/stderr split
**Today:** `CombinedOutput()` buffers until the command finishes and merges the two
streams. An agent watching a 5-minute build sees nothing until it ends.
**Change:** add a streaming exec endpoint (chunked response over the vsock conn,
`guest-agent/main.go` exec handler) and keep separate stdout/stderr. Expose as a new
MCP tool `exec_stream` or an `stream=true` arg on `exec`.

### 1.4 File in/out
**Today:** the only way to get a file into/out of a sandbox is shell heredocs through
`exec` — fragile for binaries and large files.
**Change:** new `oort machine cp <name> <src> <dst>` (`cmd_machine`, `oort:716`) over
`docker cp` via the agent; new MCP tools `write_file(name, path, content)` /
`read_file(name, path)` in `oort-mcp.py`.

### 1.5 exec context: cwd / env / user
**Change:** add `-w`, `-e`, `-u` passthrough in `machine exec` (`oort:768`) →
`docker exec` flags; add `cwd`/`env`/`user` args to the MCP `exec` tool.

---

## Tier 2 — isolation, answered honestly (the make-or-break)

The sandbox runs untrusted agent code. This tier is what lets us say so out loud.

### 2.1 Resource caps by default  ★
**Today:** `_machine_run` (`oort:704`) sets no limits — one runaway sandbox can
starve the whole VM (and every other agent's sandbox).
**Change:** add `--memory`, `--cpus`, `--pids-limit` to `_machine_run`, driven by an
isolation profile (below). Sensible defaults; overridable per sandbox.

### 2.2 Network policy / egress control  ★
**Today:** every machine sits on the shared default bridge — full egress, and
machines can reach each other.
**Change:** per-sandbox network selection in `_machine_run` — `--network none`, or a
dedicated isolated bridge per agent run, or an egress allowlist. Surface as a
`network` arg on `create_sandbox`.

### 2.3 Strong-isolation tier (optional)  ★ the differentiator
**The pitch becomes "lightweight by default, hardware-isolated on demand."**
**Change:** an isolation profile on `create_sandbox` —
- `shared` (today): fast shared-kernel container.
- `gvisor`: run under `runsc` — add `--runtime=runsc` in `_machine_run`; install
  gVisor in `make-image.sh` provisioning and register the runtime in the guest's
  docker config.
- `microvm` (stretch): a per-sandbox lightweight VM in the spirit of
  `apple/containerization` — strongest boundary, heaviest cost.

Thread the profile from `oort-mcp.py:62` `tool_create_sandbox` → `oort machine
create` (new flag) → `_machine_run`.

### 2.4 read-only rootfs + tmpfs option
**Change:** `--read-only` + `--tmpfs /tmp` in `_machine_run` for throwaway exec
sandboxes that shouldn't persist anything.

---

## Tier 3 — parallelism & lifecycle (the core value)

### 3.1 Make the MCP server concurrent  ★
**Today:** `main()` (`oort-mcp.py:294`) reads stdin line by line and handles one
request at a time — so "fork 10 sandboxes in parallel" serializes. (The guest agent
was already moved Python→Go for exactly this kind of load; the MCP server has the
same exposure.)
**Change:** dispatch each `tools/call` on its own thread/worker and write responses
as they complete. If contention bites, rewrite the server in Go alongside the guest
agent.

### 3.2 Cheap parallel fork  ★
**Today:** `fork` (`oort:751`) `docker commit`s the source on *every* call — N forks
= N full commits of the same source.
**Change:** commit the source **once** to a base image, then fan out N CoW
containers from it. Add `fork_many(source, names[])` to the MCP layer; have
`cmd_machine fork` reuse an existing snapshot tag when present instead of
re-committing.

### 3.3 Per-sandbox pause/resume
**Today:** only whole-VM `suspend_vm`/`resume_vm` exist (`oort-mcp.py:110-119`).
**Change:** add `pause(name)`/`unpause(name)` over `docker pause`/`unpause` — freeze
one idle sandbox without touching the others. Near-free, and a natural fit with the
instant-resume story.

### 3.4 Lifecycle hygiene — labels, TTL, reaper  ★
**Today:** nothing tags or expires sandboxes; an agent that crashes mid-run strands
containers and snapshot images forever.
**Change:**
- `_machine_run` (`oort:704`) — stamp `--label oort.agent=1 --label
  oort.created=<ts> --label oort.ttl=<secs>`.
- new `oort machine gc [--idle <dur>]` in `cmd_machine` (`oort:716`) — reap expired /
  idle agent sandboxes and their dangling snapshots.
- MCP: `destroy_all(owner?)` and an opt-in reaper so a session cleans up after
  itself.

### 3.5 Robust snapshot resolution + GC
**Today:** `_machine_latest_snap` (`oort:711`) picks "newest" by **string-sorting
`CreatedAt`** — locale/format-fragile. Snapshots also accumulate with no GC.
**Change:** sort by docker's real created timestamp (or an `oort.seq` label); add
snapshot retention (keep last N / age out) to `machine delete --purge` and `gc`.

---

## Tier 4 — make the bet verifiable (trust)

Per [strategy.md](./strategy.md), this is worth more than any single feature.

- **Public CI e2e matrix** — today `tests/e2e.sh` runs only on the author's hardware
  (VZ can't nest). Get as much as possible into CI; publish results.
- **Canonical agent-workflow demo** — a recorded, reproducible run: one agent forks
  three sandboxes, tries three approaches in parallel, snapshots the winner, destroys
  the rest. This is the single most convincing artifact for adoption.
- **MCP conformance test** — exercise every tool over real stdio JSON-RPC, including
  parallel calls (locks in Tier 3.1).

---

## Suggested sequencing

1. **Tier 1.1 + 1.2** first — tiny diffs, immediately make exec trustworthy.
2. **Tier 3.1 + 3.4** — concurrency + lifecycle, so parallel agent use stops leaking.
3. **Tier 2.1 + 2.2** — default caps + network policy (cheap, real safety).
4. **Tier 2.3 (gvisor)** — the headline differentiator; provisioning work.
5. **Tier 4 demo** — in parallel throughout; it's the proof.
