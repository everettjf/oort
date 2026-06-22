#!/usr/bin/env python3
"""oort-mcp — a zero-dependency MCP server that turns oort machines into
disposable, forkable sandboxes for AI coding agents.

This is oort's "beyond OrbStack" bet made concrete: an agent (Claude, Cursor,
…) gets first-class tools to spin up an isolated Linux environment, run commands
in it, **snapshot** it before a risky step, **fork** it to explore alternatives
in parallel, **restore** it when something breaks, and **destroy** it when done —
all on the shared-kernel VM, with no per-call VM boot. OrbStack exposes none of
this; here it's the natural API on top of `oort machine` time-travel.

Transport: MCP stdio (newline-delimited JSON-RPC 2.0). No third-party deps — it
just shells out to the sibling `oort` CLI, so it works wherever oort does.

Wire it into a client by launching `oort mcp` (which execs this file). Example
Claude Code config:

    claude mcp add oort -- /path/to/oort/oort mcp

Env:
    OORB    path to the oort CLI (default: the sibling ./oort of this file)
"""
import base64
import json
import os
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor


def _shq(s):
    """POSIX single-quote a string so it survives the guest's `sh -c`."""
    return "'" + str(s).replace("'", "'\\''") + "'"

HERE = os.path.dirname(os.path.abspath(__file__))
OORB = os.environ.get("OORB", os.path.join(HERE, "..", "oort"))
PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "oort", "version": "0.3.0"}

# Per-call wall-clock budget for a sandbox command (builds, installs can be
# slow). This is now enforced end-to-end: it's handed to the guest agent as the
# exec timeout, so it's a real cap rather than an advertised-but-ignored one.
EXEC_TIMEOUT = 600


def _oort_full(args, timeout=120, env=None):
    """Run `oort <args...>` and return (returncode, combined_output)."""
    e = {**os.environ, **env} if env else None
    try:
        p = subprocess.run(
            [OORB, *args],
            capture_output=True, text=True, timeout=timeout, env=e,
        )
    except subprocess.TimeoutExpired:
        return 124, f"oort {' '.join(args)} timed out after {timeout}s"
    except FileNotFoundError:
        return 127, f"oort CLI not found at {OORB} (set $OORB)"
    out = (p.stdout or "") + (p.stderr or "")
    return p.returncode, out.strip()


def _oort(args, timeout=120):
    """Run `oort <args...>` and return (ok, combined_output)."""
    code, out = _oort_full(args, timeout)
    return code == 0, out


def _ensure_vm():
    """Make sure the VM is up. `oort start` is idempotent (fast no-op if running,
    waits for Docker otherwise), so agents never have to manage VM lifecycle."""
    return _oort(["start"], timeout=360)


# --- tool implementations -------------------------------------------------
# Each returns a plain string; the dispatcher wraps it as MCP text content.

def tool_create_sandbox(name, distro="ubuntu", ttl=None, profile="sandbox", network=None):
    ok, out = _ensure_vm()
    if not ok:
        return f"failed to start the oort VM:\n{out}"
    # Agents run untrusted code here, so default to the capped 'sandbox' profile
    # (memory/cpu/pids limits + a private network: egress works, but it can't
    # reach your other sandboxes/containers). Override with profile/network.
    args = ["machine", "create", name, distro, "--profile", profile]
    if network:
        args += ["--network", network]
    if ttl:
        # TTL (seconds) lets `gc` reap a sandbox an agent forgot to destroy.
        args += ["--ttl", str(int(ttl))]
    ok, out = _oort(args, timeout=180)
    return out or ("created" if ok else "create failed")


def tool_gc(older_than=None, purge=False):
    args = ["machine", "gc"]
    if older_than:
        args += ["--older-than", str(int(older_than))]
    if purge:
        args += ["--purge"]
    ok, out = _oort(args, timeout=180)
    return out or ("gc done" if ok else "gc failed")


def tool_exec(name, command, cwd=None, env=None):
    # The quoting-correct `machine exec` path: `sh -c <command>` runs the whole
    # shell line INSIDE the sandbox (redirections/pipes/$VAR included). The
    # command's real exit status is surfaced so the agent can branch on it
    # instead of guessing from output. EXEC_TIMEOUT is enforced in the guest;
    # give the subprocess a little headroom so the guest's clean timeout message
    # wins the race over a blunt subprocess kill.
    prefix = ""
    if env:
        prefix += "".join(f"export {k}={_shq(v)}; " for k, v in env.items())
    if cwd:
        prefix += f"cd {_shq(cwd)} && "
    code, out = _oort_full(
        ["machine", "exec", name, "sh", "-c", prefix + command],
        timeout=EXEC_TIMEOUT + 30,
        env={"OORT_EXEC_TIMEOUT": str(EXEC_TIMEOUT)},
    )
    body = out if out != "" else "(no output)"
    return body if code == 0 else f"{body}\n\n[exit status {code}]"


def tool_write_file(name, path, content):
    # Ship the bytes base64-encoded through the reliable exec path (no docker cp
    # over the hijacked stream), decoding inside the sandbox.
    b = base64.b64encode(content.encode()).decode()
    cmd = (f"mkdir -p \"$(dirname {_shq(path)})\" && "
           f"printf %s {_shq(b)} | base64 -d > {_shq(path)} && "
           f"echo wrote {_shq(path)}")
    code, out = _oort_full(["machine", "exec", name, "sh", "-c", cmd], timeout=120)
    return out if code == 0 else f"{out}\n[exit status {code}]"


def tool_read_file(name, path):
    code, out = _oort_full(["machine", "exec", name, "sh", "-c", f"base64 {_shq(path)}"], timeout=120)
    if code != 0:
        return f"{out}\n[exit status {code}]"
    try:
        return base64.b64decode(out).decode("utf-8", "replace")
    except Exception as e:
        return f"error decoding file: {e}"


def tool_fork_many(source, names):
    if isinstance(names, str):
        names = [names]
    names = [n for n in (names or []) if n]
    if not names:
        return "fork_many: provide at least one target name"
    # One CLI call → the source is committed ONCE and every fork runs from that
    # shared base image (cheap, parallel-friendly).
    ok, out = _oort(["machine", "fork", source, *names], timeout=600)
    return out or ("forked" if ok else "fork failed")


def tool_pause(name):
    ok, out = _oort(["machine", "pause", name], timeout=60)
    return out or ("paused" if ok else "pause failed")


def tool_unpause(name):
    ok, out = _oort(["machine", "unpause", name], timeout=60)
    return out or ("unpaused" if ok else "unpause failed")


def tool_snapshot(name, tag=None):
    args = ["machine", "snapshot", name] + ([tag] if tag else [])
    ok, out = _oort(args, timeout=120)
    return out or ("snapshotted" if ok else "snapshot failed")


def tool_restore(name, tag=None):
    args = ["machine", "restore", name] + ([tag] if tag else [])
    ok, out = _oort(args, timeout=120)
    return out or ("restored" if ok else "restore failed")


def tool_fork(source, name):
    ok, out = _oort(["machine", "fork", source, name], timeout=180)
    return out or ("forked" if ok else "fork failed")


def tool_list_sandboxes():
    ok, out = _oort(["machine", "list"], timeout=30)
    return out or "(no sandboxes)"


def tool_snapshots(name):
    ok, out = _oort(["machine", "snapshots", name], timeout=30)
    return out or "(no snapshots)"


def tool_destroy(name, purge=False):
    args = ["machine", "delete", name] + (["--purge"] if purge else [])
    ok, out = _oort(args, timeout=60)
    return out or ("destroyed" if ok else "destroy failed")


def tool_suspend_vm():
    # Freeze the WHOLE VM (every sandbox, mid-process) to disk; resume_vm (or
    # any next oort start) brings it all back in ~1s exactly where it was.
    ok, out = _oort(["suspend"], timeout=120)
    return out or ("suspended" if ok else "suspend failed")


def tool_resume_vm():
    ok, out = _oort(["start"], timeout=300)
    return out or ("resumed" if ok else "resume failed")


# --- tool registry (name -> (schema, handler)) ----------------------------

TOOLS = [
    {
        "name": "create_sandbox",
        "description": "Create an isolated Linux sandbox (a named oort machine on the shared-kernel VM). Starts the VM if needed. Use this to get a clean environment before running untrusted or experimental commands. Defaults to the capped 'sandbox' profile (resource limits + a private network with egress but no reach to your other sandboxes).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name (e.g. 'scratch', 'build-test')."},
                "distro": {"type": "string", "description": "Base image / distro. Default 'ubuntu'. Try 'alpine' for a tiny fast sandbox.", "default": "ubuntu"},
                "profile": {"type": "string", "enum": ["sandbox", "locked", "open"], "description": "Isolation profile. 'sandbox' (default): 2g/2cpu/512pids + private network (egress, peer-isolated). 'locked': 1g/1cpu/256pids + NO network (pure compute). 'open': no caps, shared network (only for trusted code).", "default": "sandbox"},
                "network": {"type": "string", "enum": ["default", "none", "isolated"], "description": "Override the profile's network: 'isolated' (private bridge, egress ok), 'none' (no network), 'default' (shared bridge, reaches peers)."},
                "ttl": {"type": "integer", "description": "Optional time-to-live in seconds. After this, 'gc' will reap the sandbox — use it so a forgotten or abandoned sandbox cleans itself up."},
            },
            "required": ["name"],
        },
        "handler": lambda a: tool_create_sandbox(a["name"], a.get("distro", "ubuntu"), a.get("ttl"), a.get("profile", "sandbox"), a.get("network")),
    },
    {
        "name": "exec",
        "description": "Run a shell command INSIDE a sandbox and return its combined output. The command is a full shell line (pipes, redirections, $VARs all evaluate in the sandbox). On failure the exit status is appended so you can branch on it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "command": {"type": "string", "description": "Shell command to run inside the sandbox."},
                "cwd": {"type": "string", "description": "Working directory to run the command in (the command fails if it doesn't exist)."},
                "env": {"type": "object", "description": "Extra environment variables to set, as a flat object of string values.", "additionalProperties": {"type": "string"}},
            },
            "required": ["name", "command"],
        },
        "handler": lambda a: tool_exec(a["name"], a["command"], a.get("cwd"), a.get("env")),
    },
    {
        "name": "snapshot",
        "description": "Checkpoint a sandbox's whole filesystem to a tagged, content-addressed image. Take one before a risky change so you can roll back with restore.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "tag": {"type": "string", "description": "Snapshot tag. Defaults to a timestamp."},
            },
            "required": ["name"],
        },
        "handler": lambda a: tool_snapshot(a["name"], a.get("tag")),
    },
    {
        "name": "restore",
        "description": "Roll a sandbox back to a snapshot (newest if no tag given). Replaces the live state — snapshot first if you want to keep it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "tag": {"type": "string", "description": "Snapshot tag to restore. Defaults to the newest snapshot."},
            },
            "required": ["name"],
        },
        "handler": lambda a: tool_restore(a["name"], a.get("tag")),
    },
    {
        "name": "fork",
        "description": "Instantly branch a fully-set-up sandbox into a new one (copy-on-write image layers, no re-provisioning). Use this to explore alternative approaches in parallel from a common starting point.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "source": {"type": "string", "description": "Sandbox to fork from."},
                "name": {"type": "string", "description": "Name for the new forked sandbox."},
            },
            "required": ["source", "name"],
        },
        "handler": lambda a: tool_fork(a["source"], a["name"]),
    },
    {
        "name": "fork_many",
        "description": "Fork a sandbox into SEVERAL new ones at once — the source is committed only once and every fork shares that base (cheap). Ideal for fanning an agent out to explore N approaches in parallel from one starting point.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "source": {"type": "string", "description": "Sandbox to fork from."},
                "names": {"type": "array", "items": {"type": "string"}, "description": "Names for the new forked sandboxes."},
            },
            "required": ["source", "names"],
        },
        "handler": lambda a: tool_fork_many(a["source"], a["names"]),
    },
    {
        "name": "write_file",
        "description": "Write text content to a file inside a sandbox (creates parent dirs). Use this instead of echo/heredoc — it handles any content safely.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "path": {"type": "string", "description": "Absolute path of the file to write inside the sandbox."},
                "content": {"type": "string", "description": "File content."},
            },
            "required": ["name", "path", "content"],
        },
        "handler": lambda a: tool_write_file(a["name"], a["path"], a["content"]),
    },
    {
        "name": "read_file",
        "description": "Read a file from inside a sandbox and return its content as text.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "path": {"type": "string", "description": "Absolute path of the file to read inside the sandbox."},
            },
            "required": ["name", "path"],
        },
        "handler": lambda a: tool_read_file(a["name"], a["path"]),
    },
    {
        "name": "list_sandboxes",
        "description": "List all sandboxes (name, base image, status).",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": lambda a: tool_list_sandboxes(),
    },
    {
        "name": "list_snapshots",
        "description": "List a sandbox's snapshots (tag, age, size).",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Sandbox name."}},
            "required": ["name"],
        },
        "handler": lambda a: tool_snapshots(a["name"]),
    },
    {
        "name": "destroy",
        "description": "Delete a sandbox. By default its snapshots are kept (so you can recreate+restore); set purge=true to also drop them.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "purge": {"type": "boolean", "description": "Also delete the sandbox's snapshots.", "default": False},
            },
            "required": ["name"],
        },
        "handler": lambda a: tool_destroy(a["name"], bool(a.get("purge", False))),
    },
    {
        "name": "gc",
        "description": "Reap leaked sandboxes: those past their TTL, and (with older_than) any sandbox older than that many seconds. Snapshots are kept unless purge=true. Call this to clean up after a session so abandoned forks don't pile up.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "older_than": {"type": "integer", "description": "Also reap any sandbox created more than this many seconds ago."},
                "purge": {"type": "boolean", "description": "Also delete the reaped sandboxes' snapshots.", "default": False},
            },
        },
        "handler": lambda a: tool_gc(a.get("older_than"), bool(a.get("purge", False))),
    },
    {
        "name": "pause",
        "description": "Freeze a single sandbox in place (docker pause) — its processes stop using CPU but stay in memory. Cheaper and finer-grained than suspend_vm; use it to park an idle sandbox without touching the others.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Sandbox name."}},
            "required": ["name"],
        },
        "handler": lambda a: tool_pause(a["name"]),
    },
    {
        "name": "unpause",
        "description": "Resume a paused sandbox — its processes continue exactly where they froze.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Sandbox name."}},
            "required": ["name"],
        },
        "handler": lambda a: tool_unpause(a["name"]),
    },
    {
        "name": "suspend_vm",
        "description": "Freeze the WHOLE oort VM (all sandboxes, mid-process) to disk in ~1-2s. "
                       "Use between agent sessions or before risky host work; resume_vm brings "
                       "everything back exactly where it was, running processes included.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": lambda a: tool_suspend_vm(),
    },
    {
        "name": "resume_vm",
        "description": "Resume a suspended oort VM (~1s) — every sandbox continues exactly "
                       "where it was. Safe to call when the VM is already running.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": lambda a: tool_resume_vm(),
    },
]

TOOL_BY_NAME = {t["name"]: t for t in TOOLS}


# --- JSON-RPC / MCP plumbing ----------------------------------------------

def _result(id_, result):
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def _error(id_, code, message):
    return {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}}


def handle(msg):
    """Handle one JSON-RPC request; return a response dict, or None for a
    notification (which gets no reply)."""
    method = msg.get("method")
    id_ = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        # Echo back the client's protocol version when offered, for compatibility.
        version = params.get("protocolVersion", PROTOCOL_VERSION)
        return _result(id_, {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        })

    if method == "notifications/initialized" or method == "initialized":
        return None  # notification

    if method == "ping":
        return _result(id_, {})

    if method == "tools/list":
        tools = [{"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]} for t in TOOLS]
        return _result(id_, {"tools": tools})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        tool = TOOL_BY_NAME.get(name)
        if not tool:
            return _error(id_, -32602, f"unknown tool: {name}")
        try:
            text = tool["handler"](args)
        except KeyError as e:
            return _error(id_, -32602, f"missing required argument: {e}")
        except Exception as e:  # surface tool errors as tool results, not crashes
            return _result(id_, {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True})
        return _result(id_, {"content": [{"type": "text", "text": text}]})

    if id_ is not None:
        return _error(id_, -32601, f"method not found: {method}")
    return None


_write_lock = threading.Lock()


def _emit(out, resp):
    # Workers write concurrently; serialize so JSON-RPC frames never interleave.
    with _write_lock:
        out.write(json.dumps(resp) + "\n")
        out.flush()


def _serve(out, msg):
    try:
        resp = handle(msg)
    except Exception as e:  # a worker must never die silently
        resp = _error(msg.get("id"), -32603, f"internal error: {e}")
    if resp is not None:
        _emit(out, resp)


def main():
    out = sys.stdout
    # tools/call shells out to the oort CLI (create/fork/snapshot can each take
    # seconds), so run those on a pool — an agent that forks N sandboxes at once
    # gets real parallelism instead of one-at-a-time serialization. The cheap
    # handshake methods (initialize / ping / tools/list) are handled inline so
    # the startup ordering stays simple and deterministic.
    with ThreadPoolExecutor(max_workers=16) as pool:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("method") == "tools/call":
                pool.submit(_serve, out, msg)
            else:
                resp = handle(msg)
                if resp is not None:
                    _emit(out, resp)


if __name__ == "__main__":
    main()
