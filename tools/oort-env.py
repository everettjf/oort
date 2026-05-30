#!/usr/bin/env python3
"""oort-env — parse an `oort.yaml` (or `.json`) env-as-code file and emit a
flat, tab-delimited plan that the `oort` shell front-end executes. Stdlib only
(no PyYAML dependency), so it runs anywhere oort does.

Usage:
    oort-env.py up   <file>   # emit the bring-up plan
    oort-env.py down <file>   # emit machine names to tear down

Supported file schema (declare dev environments as machines):

    # oort.yaml
    machines:
      web:
        distro: ubuntu          # base image, default 'ubuntu'
        setup:                  # commands run once, in order, on first `up`
          - apt-get update -y
          - apt-get install -y git curl
      cache:
        distro: alpine

JSON with the same structure also works (handy when you can't rely on the YAML
subset): {"machines": {"web": {"distro": "ubuntu", "setup": ["..."]}}}

Emitted plan (tab-delimited), consumed by `oort up`:
    C<TAB>name<TAB>distro          # create machine
    S<TAB>name<TAB>command         # setup command (only run when freshly created)
"""
import json
import re
import sys


def _unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v


def parse(text):
    """Return {name: {"distro": str, "setup": [str, ...]}} from YAML-subset or JSON."""
    s = text.strip()
    if s.startswith("{"):
        doc = json.loads(s)
        machines = {}
        for name, spec in (doc.get("machines") or {}).items():
            spec = spec or {}
            machines[name] = {
                "distro": str(spec.get("distro", "ubuntu")),
                "setup": [str(c) for c in (spec.get("setup") or [])],
            }
        return machines

    # Minimal, predictable YAML subset: a top-level `machines:` mapping; each
    # machine is a key with optional `distro:` scalar and `setup:` list. Keys
    # `distro`/`setup` are reserved, so a machine can't be named either.
    machines = {}
    section = None
    cur = None
    in_setup = False
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        stripped = raw.strip()
        if stripped == "machines:":
            section = "machines"
            continue
        if section != "machines":
            continue
        if stripped.startswith("- "):
            if cur is not None and in_setup:
                machines[cur]["setup"].append(_unquote(stripped[2:]))
            continue
        m = re.match(r"^([^:]+):\s*(.*)$", stripped)
        if not m:
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        if key == "distro":
            if cur is not None:
                machines[cur]["distro"] = _unquote(val) or "ubuntu"
            in_setup = False
        elif key == "setup":
            in_setup = True
        else:
            cur = key
            machines.setdefault(cur, {"distro": "ubuntu", "setup": []})
            in_setup = False
    return machines


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("up", "down"):
        sys.stderr.write("usage: oort-env.py up|down <file>\n")
        return 2
    mode, path = sys.argv[1], sys.argv[2]
    try:
        with open(path) as f:
            machines = parse(f.read())
    except FileNotFoundError:
        sys.stderr.write(f"no env file: {path}\n")
        return 1
    except Exception as e:
        sys.stderr.write(f"failed to parse {path}: {e}\n")
        return 1

    if not machines:
        sys.stderr.write(f"{path}: no machines declared\n")
        return 1

    if mode == "down":
        for name in machines:
            print(name)
        return 0

    # up: create each machine, then its setup commands (in declared order).
    for name, spec in machines.items():
        print(f"C\t{name}\t{spec['distro']}")
        for cmd in spec["setup"]:
            # Tabs/newlines in a command would corrupt the plan; reject loudly.
            if "\t" in cmd or "\n" in cmd:
                sys.stderr.write(f"{name}: setup command may not contain tabs/newlines\n")
                return 1
            print(f"S\t{name}\t{cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
