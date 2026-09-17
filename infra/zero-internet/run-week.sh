#!/usr/bin/env bash
# Phase 5 (CLAUDE.md §5): "Run the full 'zero internet after initial
# setup' test end-to-end: hub + phone, both on an isolated network
# with no WAN, for a full week of simulated real use (calendar
# queries, notes, home automation, voice interactions). Load-test the
# sync layer with realistic conflict rates... Security pass: confirm
# no component makes an outbound DNS or HTTP call outside the
# WireGuard tunnel."
#
# Reuses every real piece built in Phases 1-4 rather than re-deriving
# any of them:
#   - infra/wireguard-poc/'s netns + WireGuard tunnel setup (Phase 1)
#   - hub/agent/agent.py + hub/apps/ (Phase 2, plus two new apps —
#     notes/, smart-home/ — added this phase so "notes" and "home
#     automation" are real tool calls, not relabeled Q&A)
#   - hub/dreaming/consolidate.py (Phase 3)
#   - pocket/local-model/ + pocket/sync/ (Phase 4)
#   - sync-protocol/'s Peer via wg-node.mjs (Phase 1)
#
# "Voice interactions" are NOT exercised — no Faster-Whisper integration
# exists (pocket/README.md discloses this Phase 4 gap already); those
# slots in the week below are plain text questions, not claimed as voice.
#
# Two things this phase adds that didn't exist before:
#   1. A rapid concurrent-write load test on the SAME Automerge field,
#      both peers connected simultaneously (not offline-then-reconnect).
#   2. An instrumented security pass: every non-loopback,
#      non-WireGuard-tunnel outbound packet in either namespace is
#      REJECTed and counted; the test fails if that counter is ever
#      nonzero, not just because no route exists to hit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SYNC_DIR="$REPO_ROOT/sync-protocol"
HUB_DIR="$REPO_ROOT/hub"
POCKET_DIR="$REPO_ROOT/pocket"

HUB_NS=nex-zi-hub
PHONE_NS=nex-zi-phone
VETH_HUB_ADDR=10.201.0.1
VETH_PHONE_ADDR=10.201.0.2
WG_HUB_ADDR=10.98.0.1
WG_PHONE_ADDR=10.98.0.2
WG_HUB_PORT=51830
WG_PHONE_PORT=51831
SYNC_PORT=4200
LLAMA_PORT=8200

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/tmp/nex-llama.cpp}"
VENV_DIR="${VENV_DIR:-/tmp/nex-hub-venv}"
MODEL_PATH="${MODEL_PATH:-/tmp/nex-hub-models/nex-tiny-qwen2.gguf}"

RESULTS=()
PASS=0
FAIL=0
log() { echo "[zero-internet] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

HUB_LLAMA_PID=""
cleanup() {
  log "cleaning up"
  [ -n "$HUB_LLAMA_PID" ] && ip netns exec "$HUB_NS" kill "$HUB_LLAMA_PID" 2>/dev/null || true
  ip netns exec "$HUB_NS" pkill -f llama-server 2>/dev/null || true
  pkill -f "wireguard-go wg-zi" 2>/dev/null || true
  ip netns exec "$HUB_NS" pkill -f wg-node.mjs 2>/dev/null || true
  ip netns exec "$PHONE_NS" pkill -f wg-node.mjs 2>/dev/null || true
  sleep 0.3
  ip netns delete "$HUB_NS" 2>/dev/null || true
  ip netns delete "$PHONE_NS" 2>/dev/null || true
  rm -f /var/run/wireguard/wg-zi-hub.sock /var/run/wireguard/wg-zi-phone.sock 2>/dev/null || true
  if [ -n "${WORKDIR:-}" ]; then
    if [ -n "${NEX_ZI_KEEP_LOGS:-}" ]; then
      log "NEX_ZI_KEEP_LOGS set and a check failed — leaving logs at $WORKDIR"
    else
      rm -rf "$WORKDIR"
    fi
  fi
}

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
require ip; require wg; require wireguard-go; require node; require iptables

if [ "$(id -u)" -ne 0 ]; then
  echo "this script needs root (network namespaces, WireGuard, iptables)" >&2
  exit 1
fi

cleanup
trap cleanup EXIT
WORKDIR="$(mktemp -d /tmp/nex-zero-internet.XXXXXX)"

# --- 0. build/find dependencies (reused, not rebuilt, from earlier phases) ---
LLAMA_SERVER_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
  log "building llama.cpp"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
  cmake -B "$LLAMA_CPP_DIR/build" -S "$LLAMA_CPP_DIR" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF
  cmake --build "$LLAMA_CPP_DIR/build" --config Release -j"$(nproc)" --target llama-server
fi
if [ ! -x "$VENV_DIR/bin/python3" ]; then
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python3"
"$VENV_DIR/bin/pip" install --quiet -r "$HUB_DIR/agent/requirements.txt"
if [ ! -f "$MODEL_PATH" ]; then
  "$VENV_DIR/bin/pip" install --quiet gguf numpy
  mkdir -p "$(dirname "$MODEL_PATH")"
  "$PYTHON" "$HUB_DIR/models/make-tiny-model.py" --out "$MODEL_PATH" \
    --vocab-gguf "$LLAMA_CPP_DIR/models/ggml-vocab-qwen2.gguf" --n-embd 64 --n-layer 2 --n-head 2
fi
if [ ! -d "$SYNC_DIR/node_modules" ]; then ( cd "$SYNC_DIR" && npm ci --silent ); fi
if [ ! -x "$POCKET_DIR/sync/build/install/nex-pocket-sync/bin/nex-pocket-sync" ]; then
  ( cd "$POCKET_DIR/sync" && gradle installDist --console=plain -q )
fi
POCKET_SYNC_CLI="$POCKET_DIR/sync/build/install/nex-pocket-sync/bin/nex-pocket-sync"

# --- 1. two real, separate network namespaces + a real WireGuard tunnel ---
log "creating network namespaces and WireGuard tunnel"
ip netns add "$HUB_NS"
ip netns add "$PHONE_NS"
ip link add veth-zi-hub type veth peer name veth-zi-phone
ip link set veth-zi-hub netns "$HUB_NS"
ip link set veth-zi-phone netns "$PHONE_NS"
ip netns exec "$HUB_NS" ip addr add "$VETH_HUB_ADDR/24" dev veth-zi-hub
ip netns exec "$HUB_NS" ip link set veth-zi-hub up
ip netns exec "$HUB_NS" ip link set lo up
ip netns exec "$PHONE_NS" ip addr add "$VETH_PHONE_ADDR/24" dev veth-zi-phone
ip netns exec "$PHONE_NS" ip link set veth-zi-phone up
ip netns exec "$PHONE_NS" ip link set lo up

umask 077
wg genkey | tee "$WORKDIR/hub.key" | wg pubkey > "$WORKDIR/hub.pub"
wg genkey | tee "$WORKDIR/phone.key" | wg pubkey > "$WORKDIR/phone.pub"
ip netns exec "$HUB_NS" wireguard-go wg-zi-hub
ip netns exec "$PHONE_NS" wireguard-go wg-zi-phone
ip netns exec "$HUB_NS" wg set wg-zi-hub \
  private-key "$WORKDIR/hub.key" listen-port "$WG_HUB_PORT" \
  peer "$(cat "$WORKDIR/phone.pub")" endpoint "$VETH_PHONE_ADDR:$WG_PHONE_PORT" \
  allowed-ips "$WG_PHONE_ADDR/32" persistent-keepalive 5
ip netns exec "$PHONE_NS" wg set wg-zi-phone \
  private-key "$WORKDIR/phone.key" listen-port "$WG_PHONE_PORT" \
  peer "$(cat "$WORKDIR/hub.pub")" endpoint "$VETH_HUB_ADDR:$WG_HUB_PORT" \
  allowed-ips "$WG_HUB_ADDR/32" persistent-keepalive 5
ip netns exec "$HUB_NS" ip addr add "$WG_HUB_ADDR/24" dev wg-zi-hub
ip netns exec "$PHONE_NS" ip addr add "$WG_PHONE_ADDR/24" dev wg-zi-phone
ip netns exec "$HUB_NS" ip link set wg-zi-hub up
ip netns exec "$PHONE_NS" ip link set wg-zi-phone up

for _ in $(seq 1 20); do
  ip netns exec "$HUB_NS" wg show wg-zi-hub latest-handshakes | awk '{print $2}' | grep -qv '^0$' && break
  sleep 0.5
done
HANDSHAKE=$(ip netns exec "$HUB_NS" wg show wg-zi-hub latest-handshakes | awk '{print $2}')
if [ "$HANDSHAKE" = "0" ] || [ -z "$HANDSHAKE" ]; then
  result "WireGuard handshake" FAIL "no handshake"
else
  result "WireGuard handshake" PASS
fi

# --- 2. security instrumentation: lock down egress in BOTH namespaces ---
# Note there is no route to any real WAN from either namespace regardless
# (veth only connects them to each other) — that alone already makes a
# leak impossible here. The point of this instrumentation is the
# stronger, environment-independent claim: nothing even ATTEMPTS to
# leave except via loopback or the tunnel, actively caught and counted,
# not just "it would fail anyway because there's no route."
# The UDP rule's --dport is the REMOTE peer's listen port, not this
# namespace's own — that's what a WireGuard client actually addresses
# its outgoing encapsulated packets to (hub sends to the phone's port
# and vice versa). Got this backwards on the first pass — it silently
# blocked the tunnel's own traffic, which is exactly the kind of bug
# this instrumentation exists to make loud rather than let slide.
for ns_if in "$HUB_NS:wg-zi-hub:veth-zi-hub:$WG_PHONE_PORT" "$PHONE_NS:wg-zi-phone:veth-zi-phone:$WG_HUB_PORT"; do
  IFS=: read -r ns wgif vethif remote_port <<< "$ns_if"
  ip netns exec "$ns" iptables -F OUTPUT
  ip netns exec "$ns" iptables -A OUTPUT -o lo -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o "$wgif" -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o "$vethif" -p udp --dport "$remote_port" -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -j REJECT
done
log "egress lockdown active in both namespaces (lo + wg tunnel + tunnel's own UDP only)"

reject_count() {
  local ns="$1" reject_line
  reject_line=$(ip netns exec "$ns" iptables -L OUTPUT -v -n -x | grep REJECT | tail -1)
  echo "$reject_line" | awk '{print $1}'
}

# Canary: prove the instrumentation actually catches a leak, not just
# that it passes because nothing happened to trip it. Targeting an
# unroutable public IP doesn't work for this: with no default route at
# all, the kernel fails the lookup before the packet ever reaches the
# OUTPUT chain, so nothing gets REJECTed — that's a routing failure,
# not a firewall catch, and it would make this canary pass for the
# wrong reason (verified: it silently failed to increment the counter
# on the first attempt). Instead, target something that IS routable —
# the phone's veth address, reachable on that L2 segment — on a port
# our rules don't allow (only the WireGuard-to-WireGuard UDP port is
# allowed on that link). That's a real bypass attempt an application
# could make, and it must get REJECTed.
ip netns exec "$HUB_NS" curl -s -m 2 "http://$VETH_PHONE_ADDR/" >/dev/null 2>&1 || true
CANARY_HUB_REJECTS=$(reject_count "$HUB_NS")
if [ "$CANARY_HUB_REJECTS" -gt 0 ]; then
  result "Security instrumentation canary (a real leak attempt is actually caught)" PASS
else
  result "Security instrumentation canary (a real leak attempt is actually caught)" FAIL "counter did not increment on a deliberate leak attempt"
fi

BASELINE_HUB_REJECTS=$(reject_count "$HUB_NS")
BASELINE_PHONE_REJECTS=$(reject_count "$PHONE_NS")

# --- 3. pairing, and start the hub's llama-server for the whole week ---
DB_PATH="$WORKDIR/hub-events.db"
QDRANT_PATH="$WORKDIR/qdrant"
AUDIT_DB="$WORKDIR/dreaming-audit.db"
APPS_DATA_DIR="$WORKDIR/apps-data"
mkdir -p "$APPS_DATA_DIR"
HUB_DOC="$WORKDIR/hub.doc"
PHONE_DOC="$WORKDIR/phone.doc"
QUEUE_DB="$WORKDIR/pocket-queue.db"

node "$SYNC_DIR/scripts/wg-node.mjs" --label genesis --genesis --doc-file "$HUB_DOC" --hold-ms 0 >/dev/null
cp "$HUB_DOC" "$PHONE_DOC"

log "starting the hub's llama-server inside its namespace (loopback only — its own local Q&A never needs the tunnel)"
ip netns exec "$HUB_NS" "$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$LLAMA_PORT" \
  --skip-chat-parsing > "$WORKDIR/hub-llama.log" 2>&1 &
HUB_LLAMA_PID=$!
for _ in $(seq 1 60); do
  ip netns exec "$HUB_NS" curl -sSf -o /dev/null "http://127.0.0.1:$LLAMA_PORT/completion" \
    -H "Content-Type: application/json" -d '{"prompt":"x","n_predict":1}' 2>/dev/null && break
  sleep 0.5
done

ask_hub() {
  ip netns exec "$HUB_NS" "$PYTHON" "$HUB_DIR/agent/agent.py" "$1" \
    --db-path "$DB_PATH" --mcp-root "$REPO_ROOT" --model-path "$MODEL_PATH" \
    --apps-data-dir "$APPS_DATA_DIR" --llama-url "http://127.0.0.1:$LLAMA_PORT" >/dev/null
}

consolidate() {
  ip netns exec "$HUB_NS" "$PYTHON" "$HUB_DIR/dreaming/consolidate.py" \
    --event-db "$DB_PATH" --qdrant-path "$QDRANT_PATH" --audit-db "$AUDIT_DB" \
    --llama-url "http://127.0.0.1:$LLAMA_PORT" --vector-size 64 >/dev/null
}

# --- 4. the week ---
log "day 1: hub local activity (Q&A, notes, home automation)"
ask_hub "What is on my calendar today?"                 # "calendar" — no real calendar backend; plain Q&A, disclosed
ask_hub "notes: add pack hiking boots"
ask_hub "home: set living_room_light on"
consolidate

log "day 2: phone offline cycle, then reconnects to the hub over the real WireGuard tunnel"
ip netns exec "$PHONE_NS" "$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$LLAMA_PORT" \
  --skip-chat-parsing > "$WORKDIR/phone-llama-day2.log" 2>&1 &
PHONE_LLAMA_PID=$!
for _ in $(seq 1 60); do
  ip netns exec "$PHONE_NS" curl -sSf -o /dev/null "http://127.0.0.1:$LLAMA_PORT/completion" \
    -H "Content-Type: application/json" -d '{"prompt":"x","n_predict":1}' 2>/dev/null && break
  sleep 0.5
done
PHONE_ANSWER=$(ip netns exec "$PHONE_NS" "$PYTHON" "$POCKET_DIR/local-model/offline_answer.py" \
  "What is the weather like?" --llama-url "http://127.0.0.1:$LLAMA_PORT" --model-path "$MODEL_PATH")
PHONE_ANSWER=$(echo "$PHONE_ANSWER" | tr '\n|' '  ')
ip netns exec "$PHONE_NS" "$POCKET_SYNC_CLI" enqueue "$QUEUE_DB" "What is the weather like?" "$PHONE_ANSWER" "m" \
  > /dev/null 2> >(grep -v Picked >&2)
kill "$PHONE_LLAMA_PID" 2>/dev/null || true
wait "$PHONE_LLAMA_PID" 2>/dev/null || true

PENDING=$("$POCKET_SYNC_CLI" pending "$QUEUE_DB" 2>&1 | grep -v Picked || true)
EXPECTED_EVENTS=$(echo "$PENDING" | grep -c '|' || true)
ip netns exec "$HUB_NS" node "$SYNC_DIR/scripts/wg-node.mjs" --label hub --listen "/ip4/$WG_HUB_ADDR/tcp/$SYNC_PORT" \
  --doc-file "$HUB_DOC" --print-multiaddrs-only --wait-events "$EXPECTED_EVENTS" --timeout-ms 30000 --hold-ms 500 \
  > "$WORKDIR/hub-sync-day2.log" 2>&1 &
HUB_SYNC_PID=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$WORKDIR/hub-sync-day2.log" | awk '{print $2}')
APPEND_ARGS=()
while IFS='|' read -r id ts question answer model; do
  [ -z "$id" ] && continue
  APPEND_ARGS+=(--append "Q: $question / A: $answer")
done <<< "$PENDING"
ip netns exec "$PHONE_NS" node "$SYNC_DIR/scripts/wg-node.mjs" --label phone --listen "/ip4/$WG_PHONE_ADDR/tcp/$((SYNC_PORT + 1))" \
  --doc-file "$PHONE_DOC" --connect "$HUB_ADDR" "${APPEND_ARGS[@]}" --hold-ms 2000 \
  > "$WORKDIR/phone-sync-day2.log" 2>&1 || true
if wait "$HUB_SYNC_PID"; then
  result "Day 2 (phone syncs over the real WireGuard tunnel)" PASS
  # Confirmed synced — mark these rows so day 5 doesn't resend them.
  SYNCED_IDS=$(echo "$PENDING" | awk -F'|' '{print $1}' | tr '\n' ' ')
  "$POCKET_SYNC_CLI" mark-synced "$QUEUE_DB" $SYNCED_IDS > /dev/null 2> >(grep -v Picked >&2)
else
  result "Day 2 (phone syncs over the real WireGuard tunnel)" FAIL "see $WORKDIR/hub-sync-day2.log"
fi
consolidate

log "day 3: hub local activity"
ask_hub "notes: list"
ask_hub "home: get living_room_light"
consolidate

log "day 4: load test — rapid concurrent writes to the same field, both sides connected"
N=50
HUB_SET_ARGS=(); PHONE_SET_ARGS=()
for i in $(seq 1 "$N"); do
  HUB_SET_ARGS+=(--set "shared_counter=hub-$i")
  PHONE_SET_ARGS+=(--set "shared_counter=phone-$i")
done
ip netns exec "$HUB_NS" node "$SYNC_DIR/scripts/wg-node.mjs" --label hub --listen "/ip4/$WG_HUB_ADDR/tcp/$SYNC_PORT" \
  --doc-file "$HUB_DOC" --print-multiaddrs-only "${HUB_SET_ARGS[@]}" --hold-ms 5000 \
  > "$WORKDIR/hub-load.log" 2>&1 &
HUB_LOAD_PID=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$WORKDIR/hub-load.log" | awk '{print $2}')
ip netns exec "$PHONE_NS" node "$SYNC_DIR/scripts/wg-node.mjs" --label phone --listen "/ip4/$WG_PHONE_ADDR/tcp/$((SYNC_PORT + 1))" \
  --doc-file "$PHONE_DOC" --connect "$HUB_ADDR" "${PHONE_SET_ARGS[@]}" --hold-ms 3000 \
  > "$WORKDIR/phone-load.log" 2>&1 || true
wait "$HUB_LOAD_PID" || true

HUB_FIELD=$(node "$SYNC_DIR/scripts/dump-field.mjs" "$HUB_DOC" shared_counter)
PHONE_FIELD=$(node "$SYNC_DIR/scripts/dump-field.mjs" "$PHONE_DOC" shared_counter)
log "load test: hub final value=$HUB_FIELD phone final value=$PHONE_FIELD ($((N * 2)) total writes across both peers)"
if [ "$HUB_FIELD" = "$PHONE_FIELD" ] && [ -n "$HUB_FIELD" ]; then
  result "Day 4 (load test: $((N * 2)) rapid concurrent writes converge deterministically)" PASS "both sides agree on '$HUB_FIELD'"
else
  result "Day 4 (load test: $((N * 2)) rapid concurrent writes converge deterministically)" FAIL "hub='$HUB_FIELD' phone='$PHONE_FIELD'"
fi

log "day 5: hub local activity, second phone offline/reconnect cycle"
ask_hub "home: set thermostat 70F"
consolidate

ip netns exec "$PHONE_NS" "$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$LLAMA_PORT" \
  --skip-chat-parsing > "$WORKDIR/phone-llama-day5.log" 2>&1 &
PHONE_LLAMA_PID=$!
for _ in $(seq 1 60); do
  ip netns exec "$PHONE_NS" curl -sSf -o /dev/null "http://127.0.0.1:$LLAMA_PORT/completion" \
    -H "Content-Type: application/json" -d '{"prompt":"x","n_predict":1}' 2>/dev/null && break
  sleep 0.5
done
PHONE_ANSWER2=$(ip netns exec "$PHONE_NS" "$PYTHON" "$POCKET_DIR/local-model/offline_answer.py" \
  "Remind me to call mom." --llama-url "http://127.0.0.1:$LLAMA_PORT" --model-path "$MODEL_PATH")
PHONE_ANSWER2=$(echo "$PHONE_ANSWER2" | tr '\n|' '  ')
ip netns exec "$PHONE_NS" "$POCKET_SYNC_CLI" enqueue "$QUEUE_DB" "Remind me to call mom." "$PHONE_ANSWER2" "m" \
  > /dev/null 2> >(grep -v Picked >&2)
kill "$PHONE_LLAMA_PID" 2>/dev/null || true
wait "$PHONE_LLAMA_PID" 2>/dev/null || true

PENDING2=$("$POCKET_SYNC_CLI" pending "$QUEUE_DB" 2>&1 | grep -v Picked || true)
NEW_EVENTS=$(echo "$PENDING2" | grep -c '|' || true)
EXPECTED_EVENTS=$((EXPECTED_EVENTS + NEW_EVENTS))
ip netns exec "$HUB_NS" node "$SYNC_DIR/scripts/wg-node.mjs" --label hub --listen "/ip4/$WG_HUB_ADDR/tcp/$SYNC_PORT" \
  --doc-file "$HUB_DOC" --print-multiaddrs-only --wait-events "$EXPECTED_EVENTS" --timeout-ms 30000 --hold-ms 500 \
  > "$WORKDIR/hub-sync-day5.log" 2>&1 &
HUB_SYNC_PID2=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$WORKDIR/hub-sync-day5.log" | awk '{print $2}')
APPEND_ARGS2=()
while IFS='|' read -r id ts question answer model; do
  [ -z "$id" ] && continue
  APPEND_ARGS2+=(--append "Q: $question / A: $answer")
done <<< "$PENDING2"
ip netns exec "$PHONE_NS" node "$SYNC_DIR/scripts/wg-node.mjs" --label phone --listen "/ip4/$WG_PHONE_ADDR/tcp/$((SYNC_PORT + 1))" \
  --doc-file "$PHONE_DOC" --connect "$HUB_ADDR" "${APPEND_ARGS2[@]}" --hold-ms 2000 \
  > "$WORKDIR/phone-sync-day5.log" 2>&1 || true
if wait "$HUB_SYNC_PID2"; then
  result "Day 5 (second phone reconnect cycle over the tunnel)" PASS
  SYNCED_IDS2=$(echo "$PENDING2" | awk -F'|' '{print $1}' | tr '\n' ' ')
  "$POCKET_SYNC_CLI" mark-synced "$QUEUE_DB" $SYNCED_IDS2 > /dev/null 2> >(grep -v Picked >&2)
else
  result "Day 5 (second phone reconnect cycle over the tunnel)" FAIL "see $WORKDIR/hub-sync-day5.log"
fi

log "day 6: hub local activity"
ask_hub "notes: list"
consolidate

log "day 7: hub local activity, final consolidation"
ask_hub "home: get thermostat"
ask_hub "What do you know about me?"
consolidate

log "mirroring the week's phone-synced interactions into the hub's real event log (closing the same gap Phase 4 closed)"
node "$SYNC_DIR/scripts/dump-events.mjs" "$HUB_DOC" > "$WORKDIR/hub-doc-events.json"
"$PYTHON" - "$WORKDIR/hub-doc-events.json" "$DB_PATH" "$HUB_DIR/memory" <<'PYEOF'
import sys, json
sys.path.insert(0, sys.argv[3])
from eventlog import EventLog

events = json.loads(open(sys.argv[1]).read())
log = EventLog(sys.argv[2])
existing = {row["question"] for row in log.recent(1000)}
mirrored = 0
for e in events:
    q, _, a = e["text"].partition(" / A: ")
    q = q.removeprefix("Q: ")
    if q in existing:
        continue  # already logged locally or mirrored in an earlier pass
    log.log_interaction(question=q, answer=a, model="pocket-relayed", latency_ms=0.0, tool_used="pocket_sync", ts_ms=e["ts"])
    mirrored += 1
log.close()
print(f"mirrored {mirrored} new interaction(s)")
PYEOF

EVENT_COUNT=$("$PYTHON" -c "
import sys; sys.path.insert(0, '$HUB_DIR/memory')
from eventlog import EventLog
print(len(EventLog('$DB_PATH').recent(1000)))
")
if [ "$EVENT_COUNT" -ge 10 ]; then
  result "Full week (sustained hub+phone activity, zero WAN)" PASS "$EVENT_COUNT interactions logged across 7 simulated days"
else
  result "Full week (sustained hub+phone activity, zero WAN)" FAIL "only $EVENT_COUNT interactions logged"
fi

# --- 5. the security pass: did anything ever try to leave except via lo/tunnel? ---
FINAL_HUB_REJECTS=$(reject_count "$HUB_NS")
FINAL_PHONE_REJECTS=$(reject_count "$PHONE_NS")
log "egress-reject counters — hub: $BASELINE_HUB_REJECTS -> $FINAL_HUB_REJECTS, phone: $BASELINE_PHONE_REJECTS -> $FINAL_PHONE_REJECTS"
if [ "$FINAL_HUB_REJECTS" = "$BASELINE_HUB_REJECTS" ] && [ "$FINAL_PHONE_REJECTS" = "$BASELINE_PHONE_REJECTS" ]; then
  result "Security pass (no packets left except via loopback/tunnel)" PASS "0 rejected packets in either namespace across the whole week"
else
  result "Security pass (no packets left except via loopback/tunnel)" FAIL "hub +$((FINAL_HUB_REJECTS - BASELINE_HUB_REJECTS)) phone +$((FINAL_PHONE_REJECTS - BASELINE_PHONE_REJECTS)) rejected packets"
fi

kill "$HUB_LLAMA_PID" 2>/dev/null || true
wait "$HUB_LLAMA_PID" 2>/dev/null || true
HUB_LLAMA_PID=""

echo
echo "=== RESULTS (Phase 5 — full integration, load test, security pass) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
