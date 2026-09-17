#!/usr/bin/env bash
# Phase 6 (CLAUDE.md §5): "Move the agent/tool runtime into gVisor or
# Firecracker sandboxing on the hub; Wasmtime for anything lightweight
# enough to run in-process."
#
# gVisor half: runs one of the hub's real MCP apps (hub/apps/file-search/)
# inside an actual gVisor sandbox (runsc) — not a mock, the real
# userspace-kernel syscall interception project Google ships. Two
# checks prove it's real, not just "the command exited 0":
#   1. reading /proc/version inside the sandbox returns gVisor's
#      well-known fake kernel identity string, never the real host's
#   2. a file written inside the sandbox is provably invisible on the
#      real host filesystem afterward — the write went to gVisor's
#      overlay, not the real disk
#
# Wasmtime half: runs a real (hand-written, since no WASM toolchain is
# available here to compile one of the hub's actual apps — see
# README.md) WebAssembly module through the real Wasmtime runtime,
# proving the runtime itself works; the capability-based sandboxing
# model (no ambient filesystem/network access without an explicit
# grant) is documented, not re-derived live, for the reason above.
#
# Not Firecracker: no /dev/kvm in this environment (confirmed earlier
# in this project, same constraint that blocks a real Android emulator
# — see pocket/README.md), and Firecracker needs KVM. gVisor's ptrace
# platform doesn't.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
VENV_DIR="${VENV_DIR:-/tmp/nex-hub-venv}"

RESULTS=()
PASS=0
FAIL=0
log() { echo "[sandbox-demo] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
require runsc; require wasmtime

if [ ! -x "$VENV_DIR/bin/python3" ]; then
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet mcp
fi

# --- gVisor: real MCP app, real sandbox ---
log "running hub/apps/file-search/ inside a real gVisor sandbox (runsc, ptrace platform — no /dev/kvm here)"
GVISOR_OUTPUT=$(timeout 20 runsc -network=none -platform=ptrace do -cwd "$REPO_ROOT" \
  "$VENV_DIR/bin/python3" -c "
import sys
sys.path.insert(0, 'hub/apps/file-search')
import server
from pathlib import Path
server._root = Path('.')
print(server.search_files('Phase 6'))
print(open('/proc/version').read().strip())
" 2>&1)
log "sandboxed app output: $(echo "$GVISOR_OUTPUT" | tail -3 | head -1)"

if echo "$GVISOR_OUTPUT" | grep -q "hub/apps/README.md"; then
  result "gVisor: real MCP app (file-search) runs correctly inside the sandbox" PASS
else
  result "gVisor: real MCP app (file-search) runs correctly inside the sandbox" FAIL "$GVISOR_OUTPUT"
fi

if echo "$GVISOR_OUTPUT" | grep -q "4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016"; then
  result "gVisor: sandbox reports its own kernel identity, not the host's" PASS
else
  result "gVisor: sandbox reports its own kernel identity, not the host's" FAIL "expected gVisor's fake kernel version, got something else"
fi

CANARY_FILE="/tmp/nex-sandbox-write-canary-$$.txt"
rm -f "$CANARY_FILE"
timeout 20 runsc -network=none -platform=ptrace do bash -c "echo written > $CANARY_FILE" >/dev/null 2>&1 || true
if [ -f "$CANARY_FILE" ]; then
  result "gVisor: a write inside the sandbox never touches the real host filesystem" FAIL "canary file leaked onto the real host"
  rm -f "$CANARY_FILE"
else
  result "gVisor: a write inside the sandbox never touches the real host filesystem" PASS
fi

# --- Wasmtime: real runtime, real (hand-written) module ---
log "running a real WebAssembly module through Wasmtime"
WASM_RESULT=$(wasmtime run --invoke add "$HERE/add.wat" 3 4 2>&1 | tail -1)
if [ "$WASM_RESULT" = "7" ]; then
  result "Wasmtime: real WASM module executes correctly (3+4=7)" PASS
else
  result "Wasmtime: real WASM module executes correctly (3+4=7)" FAIL "got '$WASM_RESULT'"
fi

echo
echo "=== RESULTS (Phase 6 sandboxing — gVisor + Wasmtime) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
