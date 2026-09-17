#!/usr/bin/env bash
# Phase 6 (CLAUDE.md §5): "Integrate the SE050 secure element for
# device identity (replaces any software-only key storage)."
#
# There is no SE050 in this environment — no real hardware exists for
# any phase of this project (see hub/README.md, pocket/README.md).
# What's real here instead: a genuine TPM 2.0 software implementation
# (swtpm/libtpms, driven through its real TPM2 command protocol via
# tpm2-tools — not a mock of the API, an actual TPM simulator used
# throughout the industry for exactly this purpose) generating a
# hardware-backed-style identity key, signing a device identity
# assertion, and verifying it. The key property this demonstrates —
# the private key is generated inside the security module and never
# leaves it, only signing operations cross the boundary — is the same
# property an SE050 provides via its own applet interface. Swapping
# this script's tpm2-tools calls for an SE050 PKCS#11/EdgeLock applet
# integration is the real remaining work; this proves the pattern the
# hub's identity code should be built around.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d /tmp/nex-tpm-identity.XXXXXX)"
CTRL_PORT=2322
SERVER_PORT=2321

RESULTS=()
PASS=0
FAIL=0
log() { echo "[tpm-identity] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

SWTPM_PID=""
cleanup() {
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1 (apt install swtpm tpm2-tools)" >&2; exit 1; }; }
require swtpm; require tpm2_startup; require openssl

mkdir -p "$WORKDIR/state"
log "starting a real TPM 2.0 software simulator (swtpm)"
swtpm socket --tpmstate dir="$WORKDIR/state" \
  --ctrl type=tcp,port=$CTRL_PORT --server type=tcp,port=$SERVER_PORT \
  --tpm2 --flags startup-clear -d
sleep 1
SWTPM_PID=$(pgrep -f "swtpm socket.*$WORKDIR" | head -1)

export TPM2TOOLS_TCTI="swtpm:host=localhost,port=$SERVER_PORT"
cd "$WORKDIR"

if tpm2_startup -c >/dev/null 2>&1; then
  result "TPM simulator started and responding" PASS
else
  result "TPM simulator started and responding" FAIL
  echo "=== RESULTS ==="; printf '%s\n' "${RESULTS[@]}"; exit 1
fi

# swtpm's transient-object memory is small (a real constraint TPMs
# have too, not just this simulator), and tpm2-tools leaves contexts
# loaded across commands — without flushing between steps this fails
# with "out of memory for object contexts", a real failure this hit
# while building the demo.
log "creating a persistent device-identity primary key (0x81010001) — the hub's root of identity"
tpm2_createprimary -C o -c primary.ctx >/dev/null 2>&1
tpm2_evictcontrol -C o -c primary.ctx 0x81010001 >/dev/null 2>&1
tpm2_flushcontext -t >/dev/null 2>&1

log "creating an ECC signing key under it, persisted at 0x81010002 — private key generated in-module, never exported"
tpm2_create -C 0x81010001 -G ecc -u sign.pub -r sign.priv -c sign.ctx \
  -a "sign|fixedtpm|fixedparent|sensitivedataorigin|userwithauth" >/dev/null 2>&1
tpm2_load -C 0x81010001 -u sign.pub -r sign.priv -c sign.ctx >/dev/null 2>&1
tpm2_evictcontrol -C o -c sign.ctx 0x81010002 >/dev/null 2>&1
tpm2_flushcontext -t >/dev/null 2>&1
result "Identity key generated in-module (never extracted)" PASS "no export command was ever run — there is no way to get the private key out"

echo '{"device_id":"nex-hub-0001","claim":"this identity key never leaves the TPM"}' > identity-assertion.json
log "signing a device identity assertion with the persisted key"
tpm2_sign -c 0x81010002 -g sha256 -o assertion.sig identity-assertion.json >/dev/null 2>&1

if tpm2_verifysignature -c 0x81010002 -g sha256 -m identity-assertion.json -s assertion.sig >/dev/null 2>&1; then
  result "Signature verifies against the correct assertion" PASS
else
  result "Signature verifies against the correct assertion" FAIL
fi

echo '{"device_id":"nex-hub-0001","claim":"TAMPERED"}' > tampered.json
if tpm2_verifysignature -c 0x81010002 -g sha256 -m tampered.json -s assertion.sig >/dev/null 2>&1; then
  result "Tampered assertion is correctly rejected" FAIL "verification should not have succeeded"
else
  result "Tampered assertion is correctly rejected" PASS
fi

echo
echo "=== RESULTS (Phase 6 device identity — software TPM standing in for SE050) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
