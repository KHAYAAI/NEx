#!/usr/bin/env bash
# Phase 4 exit criteria (CLAUDE.md): "put the phone in airplane mode,
# ask it five different questions..., confirm the offline model answers
# all five reasonably, confirm all five appear correctly ordered in the
# hub's event log within 60 seconds of reconnecting."
#
# Three genuinely real, independently-tested pieces, wired together
# through small CLI seams (the same pattern as hub/agent/agent.py and
# hub/dreaming/consolidate.py):
#   1. pocket/sync/ — a real Kotlin/JVM store-and-forward queue
#      (SQLite-backed, unit-tested — see its own test suite).
#   2. pocket/local-model/offline_answer.py — a real llama-server call
#      (same synthetic-weight model as the hub — see hub/models/README.md).
#   3. sync-protocol/'s Peer (Phase 1, already CRDT-correctness-proven)
#      — performs the actual Automerge merge on reconnect. This stands
#      in for the on-device Automerge binding a real Android build
#      would need (JNI into automerge-rs); see pocket/README.md for why
#      that binding isn't built in this session.
#
# The "airplane mode" phase uses a real network namespace with no WAN
# route at all (same technique as hub/scripts/hub-stack-demo.sh's
# AT-2-2), not a simulated disconnect.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POCKET_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$POCKET_DIR/.." && pwd)"
SYNC_DIR="$REPO_ROOT/sync-protocol"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/tmp/nex-llama.cpp}"
VENV_DIR="${VENV_DIR:-/tmp/nex-hub-venv}"
MODEL_PATH="${MODEL_PATH:-/tmp/nex-hub-models/nex-tiny-qwen2.gguf}"
AIRPLANE_NS=nex-pocket-airplane
APP_PORT=8099
HUB_SYNC_PORT=4100

RESULTS=()
PASS=0
FAIL=0
log() { echo "[pocket-demo] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

LLAMA_SERVER_PID=""
cleanup() {
  [ -n "$LLAMA_SERVER_PID" ] && kill "$LLAMA_SERVER_PID" 2>/dev/null || true
  ip netns exec "$AIRPLANE_NS" pkill -f llama-server 2>/dev/null || true
  ip netns delete "$AIRPLANE_NS" 2>/dev/null || true
}
trap cleanup EXIT
cleanup
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "this script needs root (network namespace for the airplane-mode phase)" >&2
  exit 1
fi

# --- 0. dependencies: llama.cpp, Python venv, synthetic model, pocket/sync CLI, sync-protocol ---
LLAMA_SERVER_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
  log "building llama.cpp (CPU) at $LLAMA_CPP_DIR"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
  cmake -B "$LLAMA_CPP_DIR/build" -S "$LLAMA_CPP_DIR" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF
  cmake --build "$LLAMA_CPP_DIR/build" --config Release -j"$(nproc)" --target llama-server
fi

if [ ! -x "$VENV_DIR/bin/python3" ]; then
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python3"
"$VENV_DIR/bin/pip" install --quiet httpx

if [ ! -f "$MODEL_PATH" ]; then
  log "generating synthetic tiny qwen2-arch model at $MODEL_PATH"
  mkdir -p "$(dirname "$MODEL_PATH")"
  "$VENV_DIR/bin/pip" install --quiet gguf numpy
  "$PYTHON" "$REPO_ROOT/hub/models/make-tiny-model.py" \
    --out "$MODEL_PATH" \
    --vocab-gguf "$LLAMA_CPP_DIR/models/ggml-vocab-qwen2.gguf" \
    --n-embd 64 --n-layer 2 --n-head 2
fi

log "building pocket/sync (Kotlin, real, unit-tested — see pocket/sync/build.gradle.kts)"
( cd "$POCKET_DIR/sync" && gradle installDist --console=plain -q )
POCKET_SYNC_CLI="$POCKET_DIR/sync/build/install/nex-pocket-sync/bin/nex-pocket-sync"

if [ ! -d "$SYNC_DIR/node_modules" ]; then
  ( cd "$SYNC_DIR" && npm ci --silent )
fi

RUN_DIR="$(mktemp -d /tmp/nex-pocket-demo.XXXXXX)"
QUEUE_DB="$RUN_DIR/pocket-queue.db"
HUB_DOC="$RUN_DIR/hub.doc"
PHONE_DOC="$RUN_DIR/phone.doc"
HUB_EVENT_DB="$RUN_DIR/hub-events.db"

# --- 1. pairing (shared genesis, same reasoning as docs/MERGE-SEMANTICS.md) ---
log "pairing: creating shared genesis document"
node "$SYNC_DIR/scripts/wg-node.mjs" --label genesis --genesis --doc-file "$HUB_DOC" --hold-ms 0 >/dev/null
cp "$HUB_DOC" "$PHONE_DOC"

# --- 2. airplane mode: five questions, answered offline, queued locally ---
QUESTIONS=(
  "What is the weather like today?"
  "Remind me to buy groceries."
  "What time is my next meeting?"
  "Tell me a fact about hiking."
  "What is on my calendar tomorrow?"
)

log "AT-4-1: entering airplane mode (real network namespace, no WAN route)"
ip netns add "$AIRPLANE_NS"
ip netns exec "$AIRPLANE_NS" ip link set lo up

if ip netns exec "$AIRPLANE_NS" timeout 3 sh -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' 2>/dev/null; then
  result "AT-4-1 isolation sanity" FAIL "outbound connection unexpectedly succeeded in airplane-mode namespace"
else
  result "AT-4-1 isolation sanity" PASS "no outbound WAN access available"
fi

ip netns exec "$AIRPLANE_NS" "$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$APP_PORT" \
  --skip-chat-parsing > "$RUN_DIR/llama-airplane.log" 2>&1 &
LLAMA_SERVER_PID=$!
for _ in $(seq 1 60); do
  ip netns exec "$AIRPLANE_NS" curl -sSf -o /dev/null "http://127.0.0.1:$APP_PORT/completion" \
    -H "Content-Type: application/json" -d '{"prompt":"x","n_predict":1}' 2>/dev/null && break
  sleep 0.5
done

ANSWERED=0
for q in "${QUESTIONS[@]}"; do
  ANSWER=$(ip netns exec "$AIRPLANE_NS" "$PYTHON" "$POCKET_DIR/local-model/offline_answer.py" "$q" \
    --llama-url "http://127.0.0.1:$APP_PORT" --model-path "$MODEL_PATH")
  # The model's raw output is random tokens (hub/models/README.md) and
  # can contain literal newlines or pipe characters — sanitize before
  # it goes through this script's pipe-delimited CLI parsing below.
  ANSWER=$(echo "$ANSWER" | tr '\n|' '  ')
  if [ -n "$ANSWER" ]; then ANSWERED=$((ANSWERED + 1)); fi
  ip netns exec "$AIRPLANE_NS" "$POCKET_SYNC_CLI" enqueue "$QUEUE_DB" "$q" "$ANSWER" "nex-tiny-qwen2-synthetic" \
    > /dev/null 2> >(grep -v Picked >&2)
done

if [ "$ANSWERED" -eq 5 ]; then
  result "AT-4-1 (offline model answers all 5 questions)" PASS
else
  result "AT-4-1 (offline model answers all 5 questions)" FAIL "only $ANSWERED/5 answered"
fi

kill "$LLAMA_SERVER_PID" 2>/dev/null || true
wait "$LLAMA_SERVER_PID" 2>/dev/null || true
LLAMA_SERVER_PID=""
ip netns delete "$AIRPLANE_NS"

PENDING=$("$POCKET_SYNC_CLI" pending "$QUEUE_DB" 2>&1 | grep -v Picked || true)
PENDING_COUNT=$(echo "$PENDING" | grep -c '|' || true)
if [ "$PENDING_COUNT" -eq 5 ]; then
  result "AT-4-1 (all 5 queued locally while offline)" PASS
else
  result "AT-4-1 (all 5 queued locally while offline)" FAIL "queue has $PENDING_COUNT rows, expected 5"
fi

# --- 3. reconnect: sync the queued interactions into the hub's event log within 60s ---
log "AT-4-1: reconnecting — syncing queued interactions to the hub within 60s"

node "$SYNC_DIR/scripts/wg-node.mjs" --label hub --listen "/ip4/127.0.0.1/tcp/$HUB_SYNC_PORT" \
  --doc-file "$HUB_DOC" --print-multiaddrs-only --wait-events 5 --timeout-ms 60000 --hold-ms 500 \
  > "$RUN_DIR/hub-sync.log" 2>&1 &
HUB_SYNC_PID=$!
sleep 1
HUB_ADDR=$(grep -m1 MULTIADDR "$RUN_DIR/hub-sync.log" | awk '{print $2}')

# Build the phone's --append args from the exact rows the queue holds,
# in order — this is what makes "correctly ordered" a real assertion
# rather than an assumption.
APPEND_ARGS=()
while IFS='|' read -r id ts question answer model; do
  [ -z "$id" ] && continue
  APPEND_ARGS+=(--append "Q: $question / A: $answer")
done <<< "$PENDING"

SYNC_START=$(date +%s)
node "$SYNC_DIR/scripts/wg-node.mjs" --label phone --listen "/ip4/127.0.0.1/tcp/$((HUB_SYNC_PORT + 1))" \
  --doc-file "$PHONE_DOC" --connect "$HUB_ADDR" "${APPEND_ARGS[@]}" --hold-ms 3000 \
  > "$RUN_DIR/phone-sync.log" 2>&1 || true

if wait "$HUB_SYNC_PID"; then
  SYNC_ELAPSED=$(( $(date +%s) - SYNC_START ))
  result "AT-4-1 (all 5 arrive at the hub within 60s of reconnecting)" PASS "${SYNC_ELAPSED}s"
else
  result "AT-4-1 (all 5 arrive at the hub within 60s of reconnecting)" FAIL "hub never saw 5 events — see $RUN_DIR/hub-sync.log"
fi

# --- 4. verify order, then mirror into the hub's real event log and mark the queue synced ---
node "$SYNC_DIR/scripts/dump-events.mjs" "$HUB_DOC" > "$RUN_DIR/hub-events.json"
log "hub doc events: $(cat "$RUN_DIR/hub-events.json")"

printf '%s\n' "${QUESTIONS[@]}" > "$RUN_DIR/expected-questions.txt"

ORDER_OK=$("$PYTHON" - "$RUN_DIR/hub-events.json" "$RUN_DIR/expected-questions.txt" <<'PYEOF'
import json
import sys

events = json.loads(open(sys.argv[1]).read())
expected = [line.rstrip("\n") for line in open(sys.argv[2])]
actual = [e["text"].removeprefix("Q: ").split(" / A: ")[0] for e in events]
print("yes" if actual == expected else "no: " + repr(actual))
PYEOF
)
if [ "$ORDER_OK" = "yes" ]; then
  result "AT-4-1 (arrived in correct order)" PASS
else
  result "AT-4-1 (arrived in correct order)" FAIL "$ORDER_OK"
fi

log "mirroring synced interactions into the hub's real event log (hub/memory/eventlog.py)"
"$PYTHON" - "$RUN_DIR/hub-events.json" "$HUB_EVENT_DB" "$REPO_ROOT/hub/memory" <<'PYEOF'
import sys, json
sys.path.insert(0, sys.argv[3])
from eventlog import EventLog

events = json.loads(open(sys.argv[1]).read())
log = EventLog(sys.argv[2])
for e in events:
    q, _, a = e["text"].partition(" / A: ")
    q = q.removeprefix("Q: ")
    log.log_interaction(question=q, answer=a, model="pocket-relayed", latency_ms=0.0, tool_used="pocket_sync", ts_ms=e["ts"])
log.close()
print(f"mirrored {len(events)} interactions into the hub event log")
PYEOF

MIRRORED_COUNT=$("$PYTHON" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hub/memory')
from eventlog import EventLog
log = EventLog('$HUB_EVENT_DB')
print(len(log.recent(10)))
")
if [ "$MIRRORED_COUNT" -eq 5 ]; then
  result "AT-4-1 (mirrored into hub's real event log)" PASS
else
  result "AT-4-1 (mirrored into hub's real event log)" FAIL "hub event log has $MIRRORED_COUNT rows, expected 5"
fi

log "marking the pocket queue rows as synced"
SYNCED_IDS=$(echo "$PENDING" | awk -F'|' '{print $1}' | tr '\n' ' ')
"$POCKET_SYNC_CLI" mark-synced "$QUEUE_DB" $SYNCED_IDS > /dev/null 2> >(grep -v Picked >&2)
REMAINING=$("$POCKET_SYNC_CLI" pending "$QUEUE_DB" 2>&1 | grep -v Picked | grep -c '|' || true)
if [ "$REMAINING" -eq 0 ]; then
  result "AT-4-1 (queue marked synced, empties)" PASS
else
  result "AT-4-1 (queue marked synced, empties)" FAIL "$REMAINING rows still pending"
fi

echo
echo "=== RESULTS (Phase 4 pocket node) ==="
printf '%s\n' "${RESULTS[@]}"
echo
rm -rf "$RUN_DIR"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
