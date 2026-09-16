#!/usr/bin/env bash
# Phase 1's remaining gap, closed: runs the sync-protocol test matrix
# (AT-1-1, AT-1-2, AT-1-3 — see docs/ACCEPTANCE-TESTS.md and
# docs/MERGE-SEMANTICS.md) across a REAL WireGuard tunnel between two
# genuinely separate Linux network namespaces, instead of loopback.
#
# "Real" here means: two `ip netns` namespaces connected only by a plain
# veth link (standing in for the internet path between a hub and a
# phone), a WireGuard tunnel established over that link with freshly
# generated keypairs and a real handshake, and the sync-protocol Node
# processes bound to the WireGuard overlay addresses so their traffic
# has no way to reach the peer except through the encrypted tunnel.
#
# This still isn't Headscale-mediated discovery or NAT traversal across
# real hardware (see infra/headscale/README.md and
# docs/MERGE-SEMANTICS.md's "What's not yet validated" for what's still
# open) — but it is a real WireGuard tunnel actually carrying the CRDT
# sync protocol, not a stand-in.
#
# Requires: root (or CAP_NET_ADMIN + CAP_NET_RAW), `ip`, `wg`,
# `wireguard-go` (falls back to the kernel module automatically if one
# is present; this script doesn't require it), and `node`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SYNC_DIR="$REPO_ROOT/sync-protocol"
HUB_NS=nex-hub
PHONE_NS=nex-phone
VETH_HUB_ADDR=10.200.0.1
VETH_PHONE_ADDR=10.200.0.2
WG_HUB_ADDR=10.99.0.1
WG_PHONE_ADDR=10.99.0.2
WG_HUB_PORT=51820
WG_PHONE_PORT=51821
APP_PORT=4001

RESULTS=()
PASS=0
FAIL=0

log() { echo "[demo] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

cleanup() {
  log "cleaning up"
  pkill -f "wireguard-go wg-hub" 2>/dev/null || true
  pkill -f "wireguard-go wg-phone" 2>/dev/null || true
  ip netns exec "$HUB_NS" pkill -f wg-node.mjs 2>/dev/null || true
  ip netns exec "$PHONE_NS" pkill -f wg-node.mjs 2>/dev/null || true
  sleep 0.3
  ip netns delete "$HUB_NS" 2>/dev/null || true
  ip netns delete "$PHONE_NS" 2>/dev/null || true
  rm -f /var/run/wireguard/wg-hub.sock /var/run/wireguard/wg-phone.sock 2>/dev/null || true
  if [ -n "${WORKDIR:-}" ]; then
    if [ -n "${NEX_WG_DEMO_KEEP_LOGS:-}" ] && [ "$FAIL" -gt 0 ]; then
      log "NEX_WG_DEMO_KEEP_LOGS set and a check failed — leaving logs at $WORKDIR"
    else
      rm -rf "$WORKDIR"
    fi
  fi
}

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
require ip
require wg
require wireguard-go
require node

if [ "$(id -u)" -ne 0 ]; then
  echo "this script needs root (network namespaces, WireGuard interfaces)" >&2
  exit 1
fi

# --- clean slate (no WORKDIR yet, so cleanup's rm -rf is a no-op) ---
cleanup
trap cleanup EXIT

WORKDIR="$(mktemp -d /tmp/nex-wg-demo.XXXXXX)"

# --- 1. two real, separate network namespaces, linked only by plain veth ---
log "creating network namespaces $HUB_NS / $PHONE_NS"
ip netns add "$HUB_NS"
ip netns add "$PHONE_NS"
ip link add veth-hub type veth peer name veth-phone
ip link set veth-hub netns "$HUB_NS"
ip link set veth-phone netns "$PHONE_NS"
ip netns exec "$HUB_NS" ip addr add "$VETH_HUB_ADDR/24" dev veth-hub
ip netns exec "$HUB_NS" ip link set veth-hub up
ip netns exec "$HUB_NS" ip link set lo up
ip netns exec "$PHONE_NS" ip addr add "$VETH_PHONE_ADDR/24" dev veth-phone
ip netns exec "$PHONE_NS" ip link set veth-phone up
ip netns exec "$PHONE_NS" ip link set lo up

# --- 2. real WireGuard tunnel over that link ---
log "generating WireGuard keypairs"
umask 077
wg genkey | tee "$WORKDIR/hub.key" | wg pubkey > "$WORKDIR/hub.pub"
wg genkey | tee "$WORKDIR/phone.key" | wg pubkey > "$WORKDIR/phone.pub"

log "bringing up wg-hub / wg-phone (userspace wireguard-go, no kernel module required)"
ip netns exec "$HUB_NS" wireguard-go wg-hub
ip netns exec "$PHONE_NS" wireguard-go wg-phone

ip netns exec "$HUB_NS" wg set wg-hub \
  private-key "$WORKDIR/hub.key" listen-port "$WG_HUB_PORT" \
  peer "$(cat "$WORKDIR/phone.pub")" endpoint "$VETH_PHONE_ADDR:$WG_PHONE_PORT" \
  allowed-ips "$WG_PHONE_ADDR/32" persistent-keepalive 5
ip netns exec "$PHONE_NS" wg set wg-phone \
  private-key "$WORKDIR/phone.key" listen-port "$WG_PHONE_PORT" \
  peer "$(cat "$WORKDIR/hub.pub")" endpoint "$VETH_HUB_ADDR:$WG_HUB_PORT" \
  allowed-ips "$WG_HUB_ADDR/32" persistent-keepalive 5

ip netns exec "$HUB_NS" ip addr add "$WG_HUB_ADDR/24" dev wg-hub
ip netns exec "$PHONE_NS" ip addr add "$WG_PHONE_ADDR/24" dev wg-phone
ip netns exec "$HUB_NS" ip link set wg-hub up
ip netns exec "$PHONE_NS" ip link set wg-phone up

log "waiting for WireGuard handshake"
for _ in $(seq 1 20); do
  if ip netns exec "$HUB_NS" wg show wg-hub latest-handshakes | awk '{print $2}' | grep -qv '^0$'; then
    break
  fi
  sleep 0.5
done
HANDSHAKE=$(ip netns exec "$HUB_NS" wg show wg-hub latest-handshakes | awk '{print $2}')
if [ "$HANDSHAKE" = "0" ] || [ -z "$HANDSHAKE" ]; then
  result "WireGuard handshake" FAIL "no handshake after 10s"
  echo "=== RESULTS ==="; printf '%s\n' "${RESULTS[@]}"
  exit 1
fi
result "WireGuard handshake" PASS "real WireGuard tunnel established between two network namespaces"

log "confirming the overlay actually carries traffic (ping over $WG_HUB_ADDR <-> $WG_PHONE_ADDR)"
if ip netns exec "$HUB_NS" ping -c2 -W1 "$WG_PHONE_ADDR" >/dev/null 2>&1; then
  result "WireGuard overlay connectivity" PASS
else
  result "WireGuard overlay connectivity" FAIL "ping over the tunnel failed"
fi

# --- 3. pairing (genesis doc shared once, per docs/MERGE-SEMANTICS.md) ---
# Pairing itself doesn't need the WireGuard overlay address — it's just
# creating and saving the shared starting document, with no networking
# involved. (The libp2p node it starts to do this listens on loopback by
# default and is never dialed.)
log "pairing: creating shared genesis document"
node "$SYNC_DIR/scripts/wg-node.mjs" --label genesis --genesis \
  --doc-file "$WORKDIR/hub.doc" --hold-ms 0
cp "$WORKDIR/hub.doc" "$WORKDIR/phone.doc"

# --- 4. AT-1-1: both nodes online, over the real tunnel ---
log "AT-1-1: hub appends an event, phone (over WireGuard) should receive it"
ip netns exec "$HUB_NS" node "$SYNC_DIR/scripts/wg-node.mjs" \
  --label hub --listen "/ip4/$WG_HUB_ADDR/tcp/$APP_PORT" --doc-file "$WORKDIR/hub.doc" \
  --print-multiaddrs-only --append "hello over a real WireGuard tunnel" --hold-ms 4000 \
  > "$WORKDIR/hub-1.log" 2>&1 &
HUB_PID=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$WORKDIR/hub-1.log" | awk '{print $2}')
if [ -z "$HUB_ADDR" ]; then
  result "AT-1-1" FAIL "hub did not print its multiaddr"
else
  if ip netns exec "$PHONE_NS" node "$SYNC_DIR/scripts/wg-node.mjs" \
    --label phone --listen "/ip4/$WG_PHONE_ADDR/tcp/$APP_PORT" --doc-file "$WORKDIR/phone.doc" \
    --connect "$HUB_ADDR" --wait-events 1 --timeout-ms 10000 > "$WORKDIR/phone-1.log" 2>&1; then
    result "AT-1-1" PASS "event synced over the WireGuard tunnel"
  else
    result "AT-1-1" FAIL "see $WORKDIR/phone-1.log"
  fi
fi
wait "$HUB_PID" 2>/dev/null || true

# --- 5. AT-1-2: phone goes fully offline (process not running at all), ---
#         hub writes more, phone comes back and catches up over the tunnel ---
log "AT-1-2: phone offline (no process running), hub writes 2 more events, phone reconnects"
node "$SYNC_DIR/scripts/wg-node.mjs" --label hub-offline-writes --doc-file "$WORKDIR/hub.doc" \
  --append "written while phone was offline (1)" --append "written while phone was offline (2)" \
  --hold-ms 0 > "$WORKDIR/hub-2-write.log" 2>&1

ip netns exec "$HUB_NS" node "$SYNC_DIR/scripts/wg-node.mjs" \
  --label hub --listen "/ip4/$WG_HUB_ADDR/tcp/$APP_PORT" --doc-file "$WORKDIR/hub.doc" \
  --print-multiaddrs-only --hold-ms 4000 > "$WORKDIR/hub-2.log" 2>&1 &
HUB_PID=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$WORKDIR/hub-2.log" | awk '{print $2}')
if ip netns exec "$PHONE_NS" node "$SYNC_DIR/scripts/wg-node.mjs" \
  --label phone --listen "/ip4/$WG_PHONE_ADDR/tcp/$APP_PORT" --doc-file "$WORKDIR/phone.doc" \
  --connect "$HUB_ADDR" --wait-events 3 --timeout-ms 10000 > "$WORKDIR/phone-2.log" 2>&1; then
  if grep -q "written while phone was offline (1)" "$WORKDIR/phone-2.log" && \
     grep -q "written while phone was offline (2)" "$WORKDIR/phone-2.log"; then
    result "AT-1-2" PASS "both offline-written events arrived over the tunnel on reconnect"
  else
    result "AT-1-2" FAIL "reconnect completed but events missing — see $WORKDIR/phone-2.log"
  fi
else
  result "AT-1-2" FAIL "see $WORKDIR/phone-2.log"
fi
wait "$HUB_PID" 2>/dev/null || true

# --- 6. AT-1-3: both offline, concurrent conflicting write, reconnect over the tunnel ---
log "AT-1-3: both nodes offline, concurrent write to the same field, reconnect"
node "$SYNC_DIR/scripts/wg-node.mjs" --label hub-conflict-write --doc-file "$WORKDIR/hub.doc" \
  --set "mode=A-wins-mode" --hold-ms 0 > "$WORKDIR/hub-3-write.log" 2>&1
node "$SYNC_DIR/scripts/wg-node.mjs" --label phone-conflict-write --doc-file "$WORKDIR/phone.doc" \
  --set "mode=B-wins-mode" --hold-ms 0 > "$WORKDIR/phone-3-write.log" 2>&1

ip netns exec "$HUB_NS" node "$SYNC_DIR/scripts/wg-node.mjs" \
  --label hub --listen "/ip4/$WG_HUB_ADDR/tcp/$APP_PORT" --doc-file "$WORKDIR/hub.doc" \
  --print-multiaddrs-only --hold-ms 4000 > "$WORKDIR/hub-3.log" 2>&1 &
HUB_PID=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$WORKDIR/hub-3.log" | awk '{print $2}')
# No --wait-field here: which value wins the conflict isn't known ahead
# of time (that's the point of the test), so there's nothing correct to
# wait for. Just hold the connection open long enough for the sync
# exchange to finish, then compare both saved docs directly.
ip netns exec "$PHONE_NS" node "$SYNC_DIR/scripts/wg-node.mjs" \
  --label phone --listen "/ip4/$WG_PHONE_ADDR/tcp/$APP_PORT" --doc-file "$WORKDIR/phone.doc" \
  --connect "$HUB_ADDR" --hold-ms 3000 \
  > "$WORKDIR/phone-3.log" 2>&1 || true
wait "$HUB_PID" 2>/dev/null || true

if node "$SYNC_DIR/scripts/verify-convergence.mjs" \
  "$WORKDIR/hub.doc" "$WORKDIR/phone.doc" mode "A-wins-mode,B-wins-mode"; then
  result "AT-1-3" PASS "converged deterministically and losslessly over the real WireGuard tunnel"
else
  result "AT-1-3" FAIL "see output above"
fi

echo
echo "=== RESULTS (real WireGuard tunnel, two network namespaces) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
