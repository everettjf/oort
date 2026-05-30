# Changelog

All notable changes to Oort. Dates are YYYY-MM-DD.

## v0.1.0 — 2026-05-30

First public release.

Oort runs fast, lightweight Linux machines and sandboxes on macOS — many on one
shared kernel, like the Oort cloud's countless small bodies. It pairs a Docker-ready
VM with machine time-travel, AI-agent sandboxes, and env-as-code (`oort.yaml`).

Highlights:

- **`oort` CLI** — `start`, `machine`, `snapshot`, `fastvol`, `doctor`, `gui`, and more.
- **Native SwiftUI app** — package as `oort.app` / `.dmg`.
- **Fast boot** — direct-kernel boot with a self-compiled, stripped kernel.
- **User-space network stack** — gvproxy (opt-in).
- **Fast bind-mounted projects** — `oort fastvol` keeps hot dirs on the guest disk.
- **State** lives under `~/.oort`; environment configured via `OORT_*` vars.
