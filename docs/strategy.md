# Strategy: where oort should aim

[**English**](./strategy.md) | 简体中文 (todo)

This is the *why* behind the [roadmap](./roadmap.md). The roadmap lists features;
this lists the bet.

## The fork in the road

oort started as a learning clone of OrbStack and reached ~80% of its experience.
That raises the real question: **do we keep chasing OrbStack, or own something it
ignores?**

Two directions, and they pull apart:

### Direction A — be a better OrbStack (don't)

OrbStack's lightness is not one trick; it's *years of full-stack vertical
integration* — a custom kernel, a hand-tuned VirtioFS caching layer, a bespoke
user-space netstack, dynamic memory. See [`orbstack-research.md`](../orbstack-research.md).

The hard truth about competing here:

- **The filesystem moat is structurally closed to us.** OrbStack's 2–5× bind-mount
  speedup comes from a custom *host-side* VirtioFS server. `Virtualization.framework`
  does not let third parties supply one. We can't match it — we can only route
  around it (which `oort fastvol` already does).
- **The netstack moat is a multi-person-year build** for VPN/DNS/bridge parity
  that mostly matters to *daily-driver* users — exactly the users least likely to
  switch from a polished commercial product.
- **Boot/memory parity** needs the custom-kernel + dynamic-memory grind we've
  started, with diminishing returns past "good enough."

Verdict: **demote Direction A to "good enough, never chase parity."** Keep the
catch-up features working; stop pouring incremental effort into closing the last
20% of OrbStack's own moat. It's the lowest-ROI fight on the board.

### Direction B — be the thing OrbStack isn't (do)

OrbStack treats a dev environment as a hand-configured **pet**: no snapshot, no
fork, no branch, no rollback, zero AI-agent integration. oort already treats it as
a **versionable, forkable, disposable git-object** and exposes that over MCP.

> **The bet: become the local sandbox substrate for AI coding agents.**

This is the one direction oort can *win*, because the requirements line up with
oort's structural advantages (open-source, MIT, scriptable) and against OrbStack's
nature (closed, productized, daily-driver-focused). And the timing is the whole
point: parallel coding agents are exploding in 2026, and they need exactly what
oort already has primitives for —

- **fork** a fully-set-up environment N ways and run agents in parallel,
- **snapshot** before a risky step and **restore** on failure,
- **instant resume** so a frozen environment costs nothing between sessions,
- all driven by an **MCP** surface, not a human at a GUI.

Docker Desktop, Lima/Colima, and OrbStack have none of this and aren't structurally
inclined to build it.

## What winning Direction B requires

The primitives exist; the depth doesn't yet. Three things stand between "demo" and
"can't-live-without":

1. **Agent-grade exec & I/O.** Exit codes, streamed output, stdout/stderr split,
   file in/out, working dir / env / user. An agent that can't read an exit code is
   flying blind. *(Today: exit codes are discarded, output is buffered & combined,
   the guest caps every command at 110s.)*

2. **Isolation, answered honestly.** The sandbox runs **untrusted, agent-written
   code**. "Shared-kernel containers are not a hardware boundary" is a disqualifier
   for that use case unless we offer a real answer: resource caps and network
   policy by default, and an *optional* strong-isolation tier (gVisor `runsc`, or a
   per-sandbox microVM in the spirit of `apple/containerization`). The pitch becomes
   **"lightweight by default, hardware-isolated on demand."**

3. **Parallelism & lifecycle that actually hold up.** Forking 10 sandboxes in
   parallel must be genuinely concurrent (the MCP server is single-threaded today),
   and sandboxes must not leak — ownership labels, TTLs, and a reaper, so an agent
   that crashes mid-run doesn't strand state.

The concrete, file-level plan for all three is in
[`agent-sandbox-plan.md`](./agent-sandbox-plan.md).

## Trust: the cross-cutting requirement

For *anyone but the author* to rely on oort, "verified on my one machine" has to
become "verified in the open." A public CI e2e matrix and a recorded canonical
agent workflow (one agent forks three sandboxes, tries three approaches in
parallel, keeps the winner) are worth more than any feature on the list — they're
what turns a research clone into something a team adopts.

## In one line

Stop trying to out-OrbStack OrbStack. Make oort the substrate parallel AI agents
run on — disposable, forkable, instantly-resumable, and isolated on demand — and
make that claim verifiable in public.
