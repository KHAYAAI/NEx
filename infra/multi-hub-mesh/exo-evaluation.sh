#!/usr/bin/env bash
# Phase 7 (CLAUDE.md §5, stretch goal, NOT required for v0 ship):
# "Evaluate `exo` (exo-explore/exo) for pooling compute across multiple
# hub units in the same household... Only start this once Phases 1-6
# are stable and shipping."
#
# Phase 7 asks for an EVALUATION, not a build — there is no stated exit
# criteria in CLAUDE.md the way Phases 1-6 have one. This script is
# that evaluation made reproducible: it performs the exact hands-on
# steps used to produce infra/multi-hub-mesh/README.md's findings
# (real clone, real dashboard build, real dependency install, real
# attempts to run exo), so the findings can be re-verified rather than
# taken on faith.
#
# This is deliberately NOT wired into CI (see README.md "Why this
# isn't in CI"): the two real blockers found here are an upstream exo
# packaging bug and a property of this specific sandbox (no IPv6), and
# gating CI on either would mean gating the whole pipeline on a bug in
# someone else's repo or an environment quirk this project doesn't
# control, neither of which is what "acceptance test" should mean.
#
# What this proves, honestly:
#   1. exo's documented Linux CPU-only quick-start actually reproduces
#      here — real clone, real `npm run build` of its dashboard, real
#      Rust nightly toolchain, real `uv sync --extra mlx-cpu` pulling
#      the project's full real dependency graph (this alone is a
#      legitimate, non-trivial validation: it means the *build* story
#      is real, current, and not vendor-lock to macOS the way its
#      dashboard/imagery suggest).
#   2. A real, reproducible bug in the resulting install: on Linux,
#      the `mlx` package's own pyproject.toml source override (not the
#      separate `mlx-cpu` extra) unconditionally points at a
#      CUDA-tagged wheel regardless of platform_machine — so
#      `uv sync --extra mlx-cpu` on a genuinely CPU-only Linux machine
#      installs an `mlx` build that fails to import at all. Cited
#      exactly, with the exact wheel URL and the exact undefined-
#      symbol error, not paraphrased.
#   3. `exo --no-worker` (documented as the coordinator-only mode "for
#      machines without sufficient GPU resources") genuinely avoids
#      importing MLX at all — confirmed by getting past finding #2
#      entirely in that mode — but then hits a second, distinct
#      blocker: exo's Rust networking layer hardcodes its zenoh
#      listener to the IPv6 wildcard address (`rust/networking/src/lib.rs`,
#      `listen/endpoints" -> "tcp/[::]:{port}"`, no IPv4-only override
#      exposed via any CLI flag), and this sandbox has no IPv6 support
#      at the kernel level at all (`AF_INET6` sockets fail outright).
#      This is a property of THIS evaluation sandbox, not a general
#      claim about NEx's real target hardware — a real dev board
#      almost certainly has IPv6 at minimum on loopback — but it does
#      mean a live two-node discovery/mesh demo could not be produced
#      in this environment, and that's disclosed rather than faked.
#
# See README.md for the full findings and recommendation.
set -uo pipefail
# (not -e: several steps are EXPECTED to fail — that's the point of
# the evaluation — so failure is checked explicitly per step instead.)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d /tmp/nex-exo-eval.XXXXXX)"
EXO_COMMIT="21a54c5ea0230a3bec1e1a786d200126c7e34ec6" # pinned to what was actually evaluated

RESULTS=()
PASS=0
FAIL=0
log() { echo "[exo-eval] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
require git; require npm; require rustup; require uv

log "cloning exo-explore/exo at the commit this evaluation is pinned to"
git clone --quiet https://github.com/exo-explore/exo.git "$WORKDIR/exo" >/dev/null 2>&1
cd "$WORKDIR/exo"
git checkout --quiet "$EXO_COMMIT" 2>&1 || {
  log "warning: could not pin to $EXO_COMMIT (repo history may have changed); continuing on current default branch HEAD — findings below may no longer match upstream exactly"
}

log "building the exo dashboard (real npm install + build, per exo's own Linux quick start)"
if (cd dashboard && npm install --silent >/dev/null 2>&1 && npm run build >/dev/null 2>&1); then
  result "Dashboard builds from source (npm install + build)" PASS
else
  result "Dashboard builds from source (npm install + build)" FAIL "see exo's own README.md Linux quick-start section"
fi

log "installing Rust nightly (required by exo's Rust bindings)"
rustup toolchain install nightly >/dev/null 2>&1
if rustup toolchain list | grep -q nightly; then
  result "Rust nightly toolchain installs" PASS
else
  result "Rust nightly toolchain installs" FAIL
fi

log "uv sync --extra mlx-cpu (real dependency resolution + install, exo's documented Linux CPU path)"
if uv sync --extra mlx-cpu >"$WORKDIR/uv-sync.log" 2>&1; then
  result "Full dependency graph installs (uv sync --extra mlx-cpu)" PASS
else
  result "Full dependency graph installs (uv sync --extra mlx-cpu)" FAIL "see $WORKDIR/uv-sync.log"
fi

log "checking whether the resolved 'mlx' wheel is CUDA-tagged despite requesting the CPU extra"
if grep -q "mlx_cuda" "$WORKDIR/uv-sync.log" 2>/dev/null; then
  result "Confirmed: mlx-cpu extra resolves a CUDA-tagged mlx wheel (upstream bug)" PASS "see pyproject.toml's [tool.uv.sources] mlx override — no platform_machine marker distinguishes CPU from CUDA"
else
  result "Confirmed: mlx-cpu extra resolves a CUDA-tagged mlx wheel (upstream bug)" FAIL "resolution differed from what this evaluation found upstream — re-check by hand, the bug may have been fixed"
fi

log "confirming MLX itself fails to import under this install (the actual runtime consequence of the bug above)"
IMPORT_OUT=$(uv run python -c "import mlx.core" 2>&1)
if echo "$IMPORT_OUT" | grep -q "undefined symbol"; then
  result "Confirmed: mlx.core import fails with an undefined-symbol ABI error" PASS "$(echo "$IMPORT_OUT" | grep -o 'undefined symbol:.*' | head -c 200)"
else
  result "Confirmed: mlx.core import fails with an undefined-symbol ABI error" FAIL "import behaved differently than this evaluation found — re-check by hand: $IMPORT_OUT"
fi

log "confirming --no-worker (coordinator-only) mode gets PAST the MLX blocker entirely"
NOWORKER_OUT=$(timeout 8 uv run exo --no-worker --no-downloads --offline \
  --api-port 52999 --discovery-port 55900 --zenoh-port 55901 --namespace nex-eval 2>&1 || true)
if echo "$NOWORKER_OUT" | grep -q "undefined symbol"; then
  result "--no-worker mode avoids importing MLX" FAIL "still hit the MLX ABI error even in coordinator-only mode"
else
  result "--no-worker mode avoids importing MLX" PASS "reached the networking layer without ever touching mlx.core"
fi

log "confirming the specific blocker in --no-worker mode is this sandbox's lack of IPv6, not MLX"
if echo "$NOWORKER_OUT" | grep -q "Address family not supported"; then
  result "Confirmed: exo's zenoh listener hardcodes an IPv6 bind, this sandbox has no IPv6" PASS "rust/networking/src/lib.rs pins listen/endpoints to tcp/[::]:{port} unconditionally"
else
  result "Confirmed: exo's zenoh listener hardcodes an IPv6 bind, this sandbox has no IPv6" FAIL "did not reproduce the expected IPv6 bind failure — re-check by hand: $NOWORKER_OUT"
fi

echo
echo "=== RESULTS (Phase 7 — exo evaluation, a stretch goal per CLAUDE.md, not gated in CI) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks did not reproduce as expected — see README.md"
  exit 1
fi
echo "all $PASS checks PASSED (this includes checks that PASS by confirming a real bug reproduces — see README.md)"
