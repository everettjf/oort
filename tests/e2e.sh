#!/usr/bin/env bash
# oort end-to-end test suite (Phase 0.2).
#
# Exercises the whole stack on a real VM and fails red on any regression — the
# guard against "unverified commits". Runs guest-side via `oort exec` where it
# can (reliable, avoids the Docker Desktop CLI) and from macOS for the bits that
# must work host-side (port forwarding, DNS following, the k8s API).
#
#   make verify            # fresh golden image, full run
#   FRESH=0 ./tests/e2e.sh # reuse the current disk (faster, skips build-image)
#   SKIP_K8S=1 ...         # skip the (slow) Kubernetes check
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ORB="$HERE/oort"
FRESH="${FRESH:-1}"
PASS=0; FAIL=0; FAILED=()

ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$2"); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1)" "$3"; fi; }
gx()   { "$ORB" exec "$@" 2>/dev/null; }                 # run in guest
# docker in guest. %q-quote each argv (like `oort machine exec` does): the agent
# re-parses the request body via /bin/sh -c, which otherwise flattens quoting —
# `gdock run ... sh -c 'wget …'` would run the wget on the GUEST, not in the
# container (and the guest no longer ships wget, so those probes went dark).
gdock(){ local q; printf -v q '%q ' docker "$@"; "$ORB" exec "$q" 2>/dev/null; }

echo "════════ oort e2e ════════"

if [ "$FRESH" = 1 ]; then
  echo "==> build-image (fresh golden)"
  pkill -9 -f "oort run" 2>/dev/null || true; rm -f "$HOME/.oort/vm.pid"
  "$ORB" build-image >/dev/null 2>&1 || { echo "build-image FAILED"; exit 1; }
fi

echo "==> start"
"$ORB" start >/dev/null 2>&1
SOCK="$HOME/.oort/docker.sock"
# Confirm Docker is actually reachable AND stable: probe /version (not just
# _ping) a few times over ~30s, since the daemon can answer once and then still
# be settling right after a reuse boot.
up=n; for _ in $(seq 1 15); do
  curl -s --max-time 4 --unix-socket "$SOCK" http://localhost/version 2>/dev/null | grep -q ApiVersion && { up=y; break; }
  sleep 2
done
[ "$up" = y ] || { echo "VM/Docker did not come up — aborting"; "$ORB" stop >/dev/null 2>&1; exit 1; }
ok "VM up, Docker reachable"

# Container networking (the docker0 NAT path + DNS) takes a few seconds to settle
# after a fresh boot — longer than the daemon itself. Warm it up before the
# network-dependent checks so they test the steady state, not the boot race.
printf "   warming container network"
gdock pull --platform linux/arm64 alpine >/dev/null 2>&1
# Gate on OUTPUT, not exit code: the guest agent always answers HTTP 200, so the
# exit status of an `oort exec` never reflects the inner command. Poll until a
# container can actually reach the internet (or give up after ~60s).
for _ in $(seq 1 30); do
  [ "$(gdock run --rm --platform linux/arm64 alpine sh -c 'wget -T12 -qO- https://example.com >/dev/null 2>&1 && echo ok')" = ok ] && break
  printf "."; sleep 2
done
echo

echo "── core ──────────────────────────────────────"
# Pin --platform on every native run: the Rosetta test below pulls the amd64
# alpine, which would otherwise repoint the alpine:latest tag and silently make
# later containers run under emulation. The guest agent merges stderr into the
# response, so pre-pull quietly first and read only the command's last line.
gdock pull --platform linux/arm64 alpine >/dev/null 2>&1
check "$(gdock run --rm --platform linux/arm64 alpine echo hi | tail -1)" "hi" "docker run"

echo "── M1/M2/M3 (efficiency) ─────────────────────"
# zram (best-effort: may not be present if the module install was capped)
if gx 'swapon --show=NAME --noheadings 2>/dev/null' | grep -q zram; then ok "zram swap active"; else echo "  SKIP zram (module not present)"; fi
# ballooning: target log appears in vm.log
grep -q "balloon target" "$HOME/.oort/vm.log" 2>/dev/null && ok "memory ballooning active" || echo "  SKIP ballooning (no target logged yet)"

echo "── M2-net (egress) + DNS ─────────────────────"
# Probe egress with HTTPS to a stable host (http://1.1.1.1 answers with a 301
# redirect, which makes busybox wget exit non-zero — a false negative). Resolve
# against an explicit server so the check is independent of DNS-follow timing.
check "$(gdock run --rm --platform linux/arm64 alpine sh -c 'wget -T12 -qO- https://example.com >/dev/null 2>&1 && echo y || echo n')" "y" "container egress"
check "$(gdock run --rm --platform linux/arm64 alpine sh -c 'nslookup example.com 1.1.1.1 >/dev/null 2>&1 && echo y || echo n')" "y" "container DNS resolve"

echo "── VirtioFS + Rosetta ────────────────────────"
echo "oort-e2e-$(date +%s)" > "$HERE/share/.e2e"
check "$(gdock run --rm --platform linux/arm64 -v /mnt/mac:/m alpine cat /m/.e2e | grep -c oort-e2e)" "1" "VirtioFS bind read"
rm -f "$HERE/share/.e2e"
gdock pull --platform linux/amd64 alpine >/dev/null 2>&1
check "$(gdock run --rm --platform linux/amd64 alpine uname -m)" "x86_64" "Rosetta amd64"
# The amd64 pull repointed alpine:latest; restore arm64 as the default so
# `machine create` (which takes no --platform) runs a native rootfs.
gdock pull --platform linux/arm64 alpine >/dev/null 2>&1

echo "── M3-stage port forwarding ──────────────────"
# busybox:latest, not alpine: alpine ≥3.20 dropped httpd from its busybox
# (moved to busybox-extras), so the alpine httpd one-liner dies instantly and
# the port never publishes — a false negative on the forwarder.
gdock rm -f e2eweb >/dev/null 2>&1
gdock run -d --name e2eweb -p 18080:80 --platform linux/arm64 busybox:latest sh -c 'mkdir -p /w; echo PFOK>/w/i; exec httpd -f -p 80 -h /w' >/dev/null 2>&1
# Wait for the container to actually reach "running" before probing (a busy host
# can take a few seconds to start it), then poll the forwarded port.
for _ in $(seq 1 10); do [ "$(gdock inspect -f '{{.State.Status}}' e2eweb 2>/dev/null)" = running ] && break; sleep 1; done
r=""; for _ in $(seq 1 8); do r=$(curl -s --max-time 3 http://127.0.0.1:18080/i 2>/dev/null); [ -n "$r" ] && break; sleep 2; done
check "$r" "PFOK" "port forward → localhost"
gdock rm -f e2eweb >/dev/null 2>&1

echo "── M7 *.oort.local domains ───────────────────"
# The engine's DNS responder (127.0.0.1:5354) — testable without sudo or the
# /etc/resolver file by querying it directly. Reachability (route) is covered
# by `oort domains enable`, which needs sudo and stays manual.
# busybox is baked into the golden, so this works even on a bad-egress boot.
gdock rm -f e2edns >/dev/null 2>&1
gdock run -d --name e2edns --platform linux/arm64 busybox:latest sleep 300 >/dev/null 2>&1
for _ in $(seq 1 10); do [ "$(gdock inspect -f '{{.State.Status}}' e2edns 2>/dev/null)" = running ] && break; sleep 1; done
cip=$(gdock inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' e2edns 2>/dev/null)
# Retry until dig matches: the responder caches the container table for ~2s.
r=""; for _ in $(seq 1 8); do r=$(dig +short +time=2 +tries=1 @127.0.0.1 -p 5354 e2edns.oort.local 2>/dev/null); [ -n "$r" ] && [ "$r" = "$cip" ] && break; sleep 1; done
check "$r" "$cip" "container name → bridge IP (DNS responder)"
check "$(dig +short +time=2 +tries=1 @127.0.0.1 -p 5354 nosuch.oort.local 2>/dev/null | wc -l | tr -d ' ')" "0" "unknown name → NXDOMAIN"
"$ORB" machine create e2edm busybox:latest >/dev/null 2>&1
for _ in $(seq 1 10); do [ "$(gdock inspect -f '{{.State.Status}}' ovm-e2edm 2>/dev/null)" = running ] && break; sleep 1; done
mip=$(gdock inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ovm-e2edm 2>/dev/null)
r2=""; for _ in $(seq 1 8); do r2=$(dig +short +time=2 +tries=1 @127.0.0.1 -p 5354 e2edm.oort.local 2>/dev/null); [ -n "$r2" ] && [ "$r2" = "$mip" ] && break; sleep 1; done
check "$r2" "$mip" "machine name (prefix-stripped) resolves"
"$ORB" machine delete e2edm >/dev/null 2>&1
gdock rm -f e2edns >/dev/null 2>&1

echo "── M5 DNS-following ──────────────────────────"
gx 'grep -q nameserver /etc/resolv.conf && echo y || echo n' | grep -q y && ok "guest resolv.conf populated" || bad "guest resolv.conf" "dns-follow"

echo "── M7 machines ───────────────────────────────"
"$ORB" machine create e2ebox alpine >/dev/null 2>&1
check "$("$ORB" machine exec e2ebox cat /etc/os-release 2>/dev/null | grep -c '^ID=alpine')" "1" "machine create+exec"
# exec quoting: a redirection must evaluate INSIDE the machine, not on the guest
# host (the bug fixed in 724d73f). Write+read in separate execs to prove persistence.
"$ORB" machine exec e2ebox sh -c 'echo q > /quote-test' >/dev/null 2>&1
check "$("$ORB" machine exec e2ebox cat /quote-test 2>/dev/null | tail -1)" "q" "machine exec quoting (redirection in-container)"
"$ORB" machine delete e2ebox >/dev/null 2>&1

echo "── time-travel (snapshot/restore/fork) ───────"
"$ORB" machine create ttbox alpine >/dev/null 2>&1
"$ORB" machine exec ttbox touch /MARK >/dev/null 2>&1
"$ORB" machine snapshot ttbox base >/dev/null 2>&1
"$ORB" machine exec ttbox rm -f /MARK >/dev/null 2>&1
check "$("$ORB" machine exec ttbox sh -c 'test -e /MARK && echo present || echo gone' 2>/dev/null | tail -1)" "gone" "snapshot taken; live state mutated"
"$ORB" machine restore ttbox base >/dev/null 2>&1
check "$("$ORB" machine exec ttbox sh -c 'test -e /MARK && echo present || echo gone' 2>/dev/null | tail -1)" "present" "restore rolls back to snapshot"
"$ORB" machine fork ttbox ttfork >/dev/null 2>&1
check "$("$ORB" machine exec ttfork sh -c 'test -e /MARK && echo y || echo n' 2>/dev/null | tail -1)" "y" "fork inherits the source state"
"$ORB" machine delete ttbox --purge >/dev/null 2>&1
"$ORB" machine delete ttfork --purge >/dev/null 2>&1

echo "── env-as-code (oort up/down) ────────────────"
cat > "$HERE/.e2e-env.yaml" <<YAML
machines:
  e2eup:
    distro: alpine
    setup:
      - touch /provisioned
YAML
"$ORB" up "$HERE/.e2e-env.yaml" >/dev/null 2>&1
check "$("$ORB" machine exec e2eup sh -c 'test -e /provisioned && echo y || echo n' 2>/dev/null | tail -1)" "y" "oort up creates machine + runs setup"
"$ORB" down "$HERE/.e2e-env.yaml" --purge >/dev/null 2>&1
check "$("$ORB" machine list 2>/dev/null | grep -c '^e2eup ')" "0" "oort down removes the machine"
rm -f "$HERE/.e2e-env.yaml"

echo "── MCP server (AI-agent sandboxes) ───────────"
# Handshake + tools/list over stdio (no VM mutation); the tool surface is the
# contract agents depend on. The underlying machine ops are covered above.
mcp_out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$ORB" mcp 2>/dev/null)
check "$(printf '%s' "$mcp_out" | grep -c '"create_sandbox"')" "1" "MCP initialize + tools/list"

if [ "${SKIP_K8S:-0}" != 1 ]; then
  echo "── M6 Kubernetes ─────────────────────────────"
  if command -v kubectl >/dev/null 2>&1; then
    "$ORB" k8s enable >/dev/null 2>&1
    # /version is auth-gated on k3s, so a bare curl returns 401. Use the written
    # kubeconfig and wait for the node to report Ready (k3s needs a moment).
    kc="$HOME/.oort/kube/config"
    r=n; for _ in $(seq 1 40); do
      KUBECONFIG="$kc" kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready' && { r=y; break; }
      sleep 2
    done
    check "$r" "y" "k3s node Ready (kubectl)"
  else
    echo "  SKIP k8s (kubectl not installed on host)"
  fi
fi

echo "── liveness watchdog ─────────────────────────"
# Under load dockerd can WEDGE — alive (so Restart=always never fires) but
# unresponsive. The watchdog should restart it on sustained failure. Simulate the
# wedge with kill -STOP (which Restart=always can't catch) and require recovery.
check "$(gx 'systemctl is-active oort-watchdog.timer' | tail -1)" "active" "watchdog timer active"
gx 'kill -STOP $(pidof dockerd | tr " " "\n" | head -1)' >/dev/null 2>&1
gx 'systemctl start oort-watchdog.service' >/dev/null 2>&1   # the timer fires this same unit
r=n; for _ in $(seq 1 15); do
  [ "$(gx 'docker info >/dev/null 2>&1 && echo ok' | tail -1)" = ok ] && { r=y; break; }
  sleep 2
done
check "$r" "y" "watchdog auto-recovers a wedged dockerd"

echo "── M8 suspend/resume ─────────────────────────"
# Freeze the VM mid-flight with a counting container, resume, and require BOTH
# that the container kept its in-memory state (a cold boot would have left it
# stopped — no restart policy) AND that the resume was actually fast.
gdock rm -f e2esus >/dev/null 2>&1
gdock run -d --name e2esus --platform linux/arm64 busybox:latest sh -c 'i=0; while :; do i=$((i+1)); echo $i > /c; sleep 1; done' >/dev/null 2>&1
sleep 3
pre=$(gdock exec e2esus cat /c 2>/dev/null | tr -dc 0-9)
"$ORB" suspend >/dev/null 2>&1
check "$([ -s "$HOME/.oort/vmstate.bin" ] && echo y || echo n)" "y" "suspend saved a state file"
t0=$(date +%s)
"$ORB" start >/dev/null 2>&1
dt=$(( $(date +%s) - t0 ))
sleep 2
post=$(gdock exec e2esus cat /c 2>/dev/null | tr -dc 0-9)
check "$([ -n "$pre" ] && [ -n "$post" ] && [ "$post" -gt "$pre" ] && echo y || echo n)" "y" "container survived suspend/resume with state (pre=$pre post=$post)"
check "$([ "$dt" -le 3 ] && echo y || echo n)" "y" "resume is fast (${dt}s ≤ 3s)"
gdock rm -f e2esus >/dev/null 2>&1

echo "── restart on a mutated disk ─────────────────"
# The top Phase-0 reliability bug: a clean cold boot works, but restarting after
# the disk has been written (the create/destroy + k3s churn above) used to fail —
# a force-killed shutdown corrupted the image so dockerd/the agent never came back.
# The durable-stop fix (guest agent sync+poweroff, no force-kill) should make this
# stop→start cycle green every time. We time the stop to confirm it didn't hit the
# 30s force-kill fallback, then require Docker to come back on the restarted disk.
t0=$(date +%s)
"$ORB" stop >/dev/null 2>&1
check "$([ $(( $(date +%s) - t0 )) -lt 28 ] && echo y || echo n)" "y" "stop powered off cleanly (no force-kill)"
"$ORB" start >/dev/null 2>&1
up=n; for _ in $(seq 1 20); do
  curl -s --max-time 4 --unix-socket "$SOCK" http://localhost/version 2>/dev/null | grep -q ApiVersion && { up=y; break; }
  sleep 2
done
check "$up" "y" "Docker reachable after restart-on-mutated-disk"

echo "==> stop"
"$ORB" stop >/dev/null 2>&1

echo "════════ result: $PASS passed, $FAIL failed ════════"
[ "$FAIL" = 0 ] || { printf "failed: %s\n" "${FAILED[*]}"; exit 1; }
echo "ALL GREEN ✅"
