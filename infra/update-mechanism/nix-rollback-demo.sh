#!/usr/bin/env bash
# Phase 6 (CLAUDE.md §5): "Stand up the update mechanism per D2 (Nix
# generations, or OSTree/RAUC) and test a rollback from a deliberately
# broken update." Decision D2 (docs/DECISIONS.md) chose Nix generations
# — this tests that real mechanism, not a stand-in: real `nix`,
# installed and exercised in this session (see README.md for the
# install quirks that took solving), building real derivations and
# managing real profile generations via `nix-env --set`, exactly the
# primitive `nixos-rebuild switch --rollback` uses internally.
#
# What this does NOT do: build or switch an actual NixOS system
# (hub/flake.nix declares a nixosModule, not a full nixosConfiguration
# with a bootable system closure, and this environment can't boot one
# anyway — it's a container, not a NixOS host). This operates one
# level down, on the generation/rollback primitive itself, using a
# toy derivation standing in for "the hub's deployed config" — proving
# the mechanism the real system-level rollback depends on, not the
# full boot-time integration. See README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d /tmp/nex-nix-rollback.XXXXXX)"
PROFILE="$WORKDIR/profile/system"

RESULTS=()
PASS=0
FAIL=0
log() { echo "[nix-rollback] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if ! command -v nix >/dev/null && [ -x "$HOME/.nix-profile/bin/nix" ]; then
  export PATH="$HOME/.nix-profile/bin:$PATH"
fi
if ! command -v nix >/dev/null; then
  echo "nix not found. Install with (see README.md for why the group/user steps are needed):" >&2
  echo "  groupadd nixbld && useradd -M -N -g users -G nixbld nixbld1" >&2
  echo "  sh <(curl -sSL https://releases.nixos.org/nix/nix-2.24.9/install) --no-daemon" >&2
  exit 1
fi
export NIX_CONFIG="experimental-features = nix-command flakes"

mkdir -p "$WORKDIR/profile"

cat > "$WORKDIR/v1-good.nix" <<'EOF'
derivation {
  name = "nex-hub-config";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = ["-c" "echo 'hub config v1 -- healthy' > $out"];
}
EOF
cat > "$WORKDIR/v2-broken.nix" <<'EOF'
derivation {
  name = "nex-hub-config";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = ["-c" "echo 'hub config v2 -- STATUS=BROKEN (modem driver misconfigured)' > $out"];
}
EOF
cat > "$WORKDIR/v3-build-fails.nix" <<'EOF'
derivation {
  name = "nex-hub-config";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = ["-c" "echo 'this build fails on purpose' >&2; exit 1"];
}
EOF

log "building generation 1 (a healthy 'hub config')"
V1_PATH=$(nix-build "$WORKDIR/v1-good.nix" --no-out-link 2>&1 | tail -1)
nix-env --profile "$PROFILE" --set "$V1_PATH" >/dev/null 2>&1
if [ "$(cat "$PROFILE")" = "hub config v1 -- healthy" ]; then
  result "Generation 1 deployed" PASS
else
  result "Generation 1 deployed" FAIL "profile content: $(cat "$PROFILE" 2>&1)"
fi

log "building and deploying generation 2 (deliberately broken, but builds fine)"
V2_PATH=$(nix-build "$WORKDIR/v2-broken.nix" --no-out-link 2>&1 | tail -1)
nix-env --profile "$PROFILE" --set "$V2_PATH" >/dev/null 2>&1
if grep -q "STATUS=BROKEN" "$PROFILE"; then
  result "Generation 2 (broken) deployed" PASS
else
  result "Generation 2 (broken) deployed" FAIL "profile content: $(cat "$PROFILE" 2>&1)"
fi

GENERATIONS=$(nix-env --profile "$PROFILE" --list-generations)
log "generations: $(echo "$GENERATIONS" | tr '\n' ';')"
if echo "$GENERATIONS" | grep -qE "^\s*1\s" && echo "$GENERATIONS" | grep -qE "^\s*2\s.*current"; then
  result "Both generations tracked, generation 2 is current" PASS
else
  result "Both generations tracked, generation 2 is current" FAIL "$GENERATIONS"
fi

log "rolling back from the broken generation 2 to generation 1"
nix-env --profile "$PROFILE" --rollback >/dev/null 2>&1
if [ "$(cat "$PROFILE")" = "hub config v1 -- healthy" ]; then
  result "Rollback restores the healthy generation" PASS
else
  result "Rollback restores the healthy generation" FAIL "profile content: $(cat "$PROFILE" 2>&1)"
fi

log "confirming a build that fails outright never reaches (and never corrupts) the profile"
BEFORE="$(cat "$PROFILE")"
set +e
nix-build "$WORKDIR/v3-build-fails.nix" --no-out-link >"$WORKDIR/v3.log" 2>&1
BUILD_EXIT=$?
set -e
AFTER="$(cat "$PROFILE")"
if [ "$BUILD_EXIT" -ne 0 ] && [ "$BEFORE" = "$AFTER" ]; then
  result "A failed build leaves the current generation untouched" PASS
else
  result "A failed build leaves the current generation untouched" FAIL "build_exit=$BUILD_EXIT before='$BEFORE' after='$AFTER'"
fi

echo
echo "=== RESULTS (Phase 6 update mechanism — real Nix generations, per Decision D2) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
