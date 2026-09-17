#!/usr/bin/env bash
# Phase 6 (CLAUDE.md §5): "Isolate the modem/NPU firmware blobs behind
# their documented boundary; write the isolation test that proves the
# rest of the system functions with the modem physically switched off."
#
# There is no real modem or NPU hardware anywhere in this project's
# development environment (the same "no real hardware" constraint
# documented throughout — hub/README.md, pocket/README.md, D3 in
# docs/DECISIONS.md) so there is no real firmware blob to isolate and
# no real kill-switch GPIO to flip. What "the modem physically switched
# off" actually asks the system to prove — that the rest of the stack
# keeps functioning with zero WAN access — is exactly what three
# earlier, already-real, already-CI-wired tests independently proved
# for their own phases:
#
#   - AT-2-2 (hub/scripts/hub-stack-demo.sh)   — hub survives no-WAN
#   - AT-4-1 (pocket/scripts/pocket-demo.sh)   — phone survives no-WAN
#   - AT-5-1 (infra/zero-internet/run-week.sh) — both together, a full
#                                                  week, egress-instrumented
#
# All three use a real Linux network namespace with no WAN route (not
# a mocked/simulated disconnect), which is the honest software
# equivalent of "modem physically switched off": from the process's
# point of view there is no path to a WAN interface at all, same as if
# the radio were unpowered. Writing a fourth, separate no-WAN test here
# would just be a weaker rebuild of tests that already exist and
# already pass — so this script's job is to run all three as one
# gated check and document the boundary they collectively prove,
# rather than duplicate their infrastructure.
#
# What this does NOT prove: that the isolation boundary holds against a
# COMPROMISED modem/NPU firmware blob actively trying to exfiltrate
# data (e.g. a baseband exploit reaching into host memory) — that's a
# hardware/firmware security property no software test in this
# environment can demonstrate, and docs/THREAT-MODEL.md says so
# explicitly rather than overclaiming it (see "Supply-chain / firmware
# compromise" in that file). What's proven here is the weaker,
# software-observable half: the system's own functional correctness in
# the total absence of a WAN path, which is the necessary precondition
# for a physical kill switch to be meaningful at all — a kill switch
# that made the hub or phone crash or hang would be worse than no kill
# switch, since a panicked user is more likely to just turn it back on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

RESULTS=()
PASS=0
FAIL=0
log() { echo "[modem-isolation] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

if [ "$(id -u)" -ne 0 ]; then
  echo "this script needs root (the underlying scripts create network namespaces)" >&2
  exit 1
fi

run_gate() {
  local id="$1" desc="$2" script="$3"
  log "$id: running $desc ($script)"
  if "$REPO_ROOT/$script" >"/tmp/nex-modem-isolation-$id.log" 2>&1; then
    result "$id ($desc) passes with no WAN route available" PASS
  else
    result "$id ($desc) passes with no WAN route available" FAIL "see /tmp/nex-modem-isolation-$id.log"
  fi
}

run_gate "AT-2-2" "hub survives with zero WAN access"   "hub/scripts/hub-stack-demo.sh"
run_gate "AT-4-1" "phone survives with zero WAN access" "pocket/scripts/pocket-demo.sh"
run_gate "AT-5-1" "hub+phone together, egress-instrumented, a full simulated week" "infra/zero-internet/run-week.sh"

echo
echo "=== RESULTS (Phase 6 modem/NPU isolation — proven via the existing no-WAN suite) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
