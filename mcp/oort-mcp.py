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
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OORB = os.environ.get("OORB", os.path.join(HERE, "..", "oort"))
PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "oort", "version": "0.3.0"}

# Per-call wall-clock cap. Sandbox commands (builds, installs) can be slow, but
# nothing an agent runs interactively should hang the server forever.
EXEC_TIMEOUT = 600


def _oort(args, timeout=120):
    """Run `oort <args...>` and return (ok, combined_output)."""
    try:
        p = subprocess.run(
            [OORB, *args],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, f"oort {' '.join(args)} timed out after {timeout}s"
    except FileNotFoundError:
        return False, f"oort CLI not found at {OORB} (set $OORB)"
    out = (p.stdout or "") + (p.stderr or "")
    return p.returncode == 0, out.strip()


def _ensure_vm():
    """Make sure the VM is up. `oort start` is idempotent (fast no-op if running,
    waits for Docker otherwise), so agents never have to manage VM lifecycle."""
    return _oort(["start"], timeout=360)


# --- tool implementations -------------------------------------------------
# Each returns a plain string; the dispatcher wraps it as MCP text content.

def tool_create_sandbox(name, distro="ubuntu"):
    ok, out = _ensure_vm()
    if not ok:
        return f"failed to start the oort VM:\n{out}"
    ok, out = _oort(["machine", "create", name, distro], timeout=180)
    return out or ("created" if ok else "create failed")


def tool_exec(name, command):
    # The quoting-correct `machine exec` path: `sh -c <command>` runs the whole
    # shell line INSIDE the sandbox (redirections/pipes/$VAR included).
    ok, out = _oort(["machine", "exec", name, "sh", "-c", command], timeout=EXEC_TIMEOUT)
    return out if out != "" else ("(no output)" if ok else "exec failed")


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
        "description": "Create an isolated Linux sandbox (a named oort machine on the shared-kernel VM). Starts the VM if needed. Use this to get a clean environment before running untrusted or experimental commands.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name (e.g. 'scratch', 'build-test')."},
                "distro": {"type": "string", "description": "Base image / distro. Default 'ubuntu'. Try 'alpine' for a tiny fast sandbox.", "default": "ubuntu"},
            },
            "required": ["name"],
        },
        "handler": lambda a: tool_create_sandbox(a["name"], a.get("distro", "ubuntu")),
    },
    {
        "name": "exec",
        "description": "Run a shell command INSIDE a sandbox and return its combined output. The command is a full shell line (pipes, redirections, $VARs all evaluate in the sandbox).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Sandbox name."},
                "command": {"type": "string", "description": "Shell command to run inside the sandbox."},
            },
            "required": ["name", "command"],
        },
        "handler": lambda a: tool_exec(a["name"], a["command"]),
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


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(msg)
        if resp is not None:
            out.write(json.dumps(resp) + "\n")
            out.flush()


if __name__ == "__main__":
    main()
