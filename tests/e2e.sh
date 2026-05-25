#!/usr/bin/env bash
# openorb end-to-end test suite (Phase 0.2).
#
# Exercises the whole stack on a real VM and fails red on any regression — the
# guard against "unverified commits". Runs guest-side via `orb exec` where it
# can (reliable, avoids the Docker Desktop CLI) and from macOS for the bits that
# must work host-side (port forwarding, DNS following, the k8s API).
#
#   make verify            # fresh golden image, full run
#   FRESH=0 ./tests/e2e.sh # reuse the current disk (faster, skips build-image)
#   SKIP_K8S=1 ...         # skip the (slow) Kubernetes check
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ORB="$HERE/orb"
FRESH="${FRESH:-1}"
PASS=0; FAIL=0; FAILED=()

ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$2"); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1)" "$3"; fi; }
gx()   { "$ORB" exec "$@" 2>/dev/null; }                 # run in guest
gdock(){ "$ORB" exec docker "$@" 2>/dev/null; }          # docker in guest

echo "════════ openorb e2e ════════"

if [ "$FRESH" = 1 ]; then
  echo "==> build-image (fresh golden)"
  pkill -9 -f "openorb run" 2>/dev/null || true; rm -f "$HOME/.openorb/vm.pid"
  "$ORB" build-image >/dev/null 2>&1 || { echo "build-image FAILED"; exit 1; }
fi

echo "==> start"
"$ORB" start >/dev/null 2>&1
SOCK="$HOME/.openorb/docker.sock"
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
# exit status of an `orb exec` never reflects the inner command. Poll until a
# container can actually reach the internet (or give up after ~60s).
for _ in $(seq 1 30); do
  [ "$(gdock run --rm --platform linux/arm64 alpine sh -c 'wget -T5 -qO- https://example.com >/dev/null 2>&1 && echo ok')" = ok ] && break
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
grep -q "balloon target" "$HOME/.openorb/vm.log" 2>/dev/null && ok "memory ballooning active" || echo "  SKIP ballooning (no target logged yet)"

echo "── M2-net (egress) + DNS ─────────────────────"
# Probe egress with HTTPS to a stable host (http://1.1.1.1 answers with a 301
# redirect, which makes busybox wget exit non-zero — a false negative). Resolve
# against an explicit server so the check is independent of DNS-follow timing.
check "$(gdock run --rm --platform linux/arm64 alpine sh -c 'wget -T8 -qO- https://example.com >/dev/null 2>&1 && echo y || echo n')" "y" "container egress"
check "$(gdock run --rm --platform linux/arm64 alpine sh -c 'nslookup example.com 1.1.1.1 >/dev/null 2>&1 && echo y || echo n')" "y" "container DNS resolve"

echo "── VirtioFS + Rosetta ────────────────────────"
echo "openorb-e2e-$(date +%s)" > "$HERE/share/.e2e"
check "$(gdock run --rm --platform linux/arm64 -v /mnt/mac:/m alpine cat /m/.e2e | grep -c openorb-e2e)" "1" "VirtioFS bind read"
rm -f "$HERE/share/.e2e"
gdock pull --platform linux/amd64 alpine >/dev/null 2>&1
check "$(gdock run --rm --platform linux/amd64 alpine uname -m)" "x86_64" "Rosetta amd64"
# The amd64 pull repointed alpine:latest; restore arm64 as the default so
# `machine create` (which takes no --platform) runs a native rootfs.
gdock pull --platform linux/arm64 alpine >/dev/null 2>&1

echo "── M3-stage port forwarding ──────────────────"
gdock rm -f e2eweb >/dev/null 2>&1
gdock run -d --name e2eweb -p 18080:80 --platform linux/arm64 alpine sh -c 'mkdir -p /w; echo PFOK>/w/i; exec httpd -f -p 80 -h /w' >/dev/null 2>&1
# Wait for the container to actually reach "running" before probing (a busy host
# can take a few seconds to start it), then poll the forwarded port.
for _ in $(seq 1 10); do [ "$(gdock inspect -f '{{.State.Status}}' e2eweb 2>/dev/null)" = running ] && break; sleep 1; done
r=""; for _ in $(seq 1 8); do r=$(curl -s --max-time 3 http://127.0.0.1:18080/i 2>/dev/null); [ -n "$r" ] && break; sleep 2; done
check "$r" "PFOK" "port forward → localhost"
gdock rm -f e2eweb >/dev/null 2>&1

echo "── M5 DNS-following ──────────────────────────"
gx 'grep -q nameserver /etc/resolv.conf && echo y || echo n' | grep -q y && ok "guest resolv.conf populated" || bad "guest resolv.conf" "dns-follow"

echo "── M7 machines ───────────────────────────────"
"$ORB" machine create e2ebox alpine >/dev/null 2>&1
check "$("$ORB" machine exec e2ebox cat /etc/os-release 2>/dev/null | grep -c '^ID=alpine')" "1" "machine create+exec"
"$ORB" machine delete e2ebox >/dev/null 2>&1

if [ "${SKIP_K8S:-0}" != 1 ]; then
  echo "── M6 Kubernetes ─────────────────────────────"
  if command -v kubectl >/dev/null 2>&1; then
    "$ORB" k8s enable >/dev/null 2>&1
    # /version is auth-gated on k3s, so a bare curl returns 401. Use the written
    # kubeconfig and wait for the node to report Ready (k3s needs a moment).
    kc="$HOME/.openorb/kube/config"
    r=n; for _ in $(seq 1 40); do
      KUBECONFIG="$kc" kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready' && { r=y; break; }
      sleep 2
    done
    check "$r" "y" "k3s node Ready (kubectl)"
  else
    echo "  SKIP k8s (kubectl not installed on host)"
  fi
fi

echo "==> stop"
"$ORB" stop >/dev/null 2>&1

echo "════════ result: $PASS passed, $FAIL failed ════════"
[ "$FAIL" = 0 ] || { printf "failed: %s\n" "${FAILED[*]}"; exit 1; }
echo "ALL GREEN ✅"
