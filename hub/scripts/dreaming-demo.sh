#!/usr/bin/env bash
# Phase 3 exit criteria (CLAUDE.md): "after a week of varied test
# interactions, the hub's answers to 'what do you know about me'
# visibly reflect accumulated facts, and every fact is traceable back
# to the source interaction that produced it." Also verifies the decay
# requirement: facts not reinforced over N days lose priority, but are
# never silently deleted without being logged as pruned.
#
# A real week is simulated rather than waited out: interactions are
# logged with backdated timestamps spread across 7 fake days
# (EventLog.log_interaction's ts_ms override — see hub/memory/eventlog.py),
# and consolidate.py's --now-ms lets the decay clock follow the same
# fake timeline. The pipeline code under test (extraction, embedding,
# storage, reinforcement, decay, audit logging) is exactly what a real
# nightly systemd timer would run — only the clock is fake.
#
# Scenario:
#   - "My name is Alex" and "I like hiking" are mentioned on days 1, 4,
#     and 7 — reinforced, should stay active.
#   - "I live in Cape Town" is mentioned only on day 1 — never
#     reinforced, should be pruned (but not silently — logged) once the
#     decay threshold has passed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_DIR="$(cd "$HERE/.." && pwd)"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/tmp/nex-llama.cpp}"
VENV_DIR="${VENV_DIR:-/tmp/nex-hub-venv}"
MODEL_PATH="${MODEL_PATH:-/tmp/nex-hub-models/nex-tiny-qwen2.gguf}"
APP_PORT=8098
VECTOR_SIZE=64
MAX_AGE_DAYS=3

RESULTS=()
PASS=0
FAIL=0
log() { echo "[dreaming-demo] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

LLAMA_SERVER_PID=""
cleanup() {
  [ -n "$LLAMA_SERVER_PID" ] && kill "$LLAMA_SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

LLAMA_SERVER_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
  log "building llama.cpp (CPU) at $LLAMA_CPP_DIR"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
  cmake -B "$LLAMA_CPP_DIR/build" -S "$LLAMA_CPP_DIR" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF
  cmake --build "$LLAMA_CPP_DIR/build" --config Release -j"$(nproc)" --target llama-server
fi

if [ ! -x "$VENV_DIR/bin/python3" ]; then
  log "creating venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python3"
"$VENV_DIR/bin/pip" install --quiet -r "$HUB_DIR/agent/requirements.txt"

if [ ! -f "$MODEL_PATH" ]; then
  log "generating synthetic tiny qwen2-arch model at $MODEL_PATH"
  mkdir -p "$(dirname "$MODEL_PATH")"
  "$PYTHON" "$HUB_DIR/models/make-tiny-model.py" \
    --out "$MODEL_PATH" \
    --vocab-gguf "$LLAMA_CPP_DIR/models/ggml-vocab-qwen2.gguf" \
    --n-embd "$VECTOR_SIZE" --n-layer 2 --n-head 2
fi

log "starting llama-server (embedding mode) on port $APP_PORT"
"$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$APP_PORT" \
  --embedding --pooling mean > /tmp/nex-dreaming-llama-server.log 2>&1 &
LLAMA_SERVER_PID=$!
for _ in $(seq 1 60); do
  curl -sSf -o /dev/null "http://127.0.0.1:$APP_PORT/embedding" \
    -H "Content-Type: application/json" -d '{"content":"x"}' 2>/dev/null && break
  sleep 0.5
done

RUN_DIR="$(mktemp -d /tmp/nex-dreaming-demo.XXXXXX)"
EVENT_DB="$RUN_DIR/events.db"
QDRANT_PATH="$RUN_DIR/qdrant"
AUDIT_DB="$RUN_DIR/dreaming-audit.db"
LLAMA_URL="http://127.0.0.1:$APP_PORT"

DAY_MS=86400000
DAY1=$(( $(date +%s) * 1000 ))

log "simulating a week: log each day's interactions, then run that day's consolidation — same order a real nightly job would see them in"
for d in 1 2 3 4 5 6 7; do
  NOW_MS=$(( DAY1 + (d - 1) * DAY_MS ))

  case "$d" in
    1)
      "$PYTHON" - "$EVENT_DB" "$NOW_MS" "$HUB_DIR/memory" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[3])
from eventlog import EventLog
log = EventLog(sys.argv[1])
now = int(sys.argv[2])
log.log_interaction(question="My name is Alex.", answer="x", model="m", latency_ms=1.0, ts_ms=now)
log.log_interaction(question="I like hiking.", answer="x", model="m", latency_ms=1.0, ts_ms=now)
log.log_interaction(question="I live in Cape Town.", answer="x", model="m", latency_ms=1.0, ts_ms=now)
log.close()
PYEOF
      ;;
    4|7)
      "$PYTHON" - "$EVENT_DB" "$NOW_MS" "$HUB_DIR/memory" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[3])
from eventlog import EventLog
log = EventLog(sys.argv[1])
now = int(sys.argv[2])
log.log_interaction(question="My name is Alex.", answer="x", model="m", latency_ms=1.0, ts_ms=now)
log.log_interaction(question="I like hiking.", answer="x", model="m", latency_ms=1.0, ts_ms=now)
log.close()
PYEOF
      ;;
  esac

  log "day $d: consolidating"
  "$PYTHON" "$HUB_DIR/dreaming/consolidate.py" \
    --event-db "$EVENT_DB" --qdrant-path "$QDRANT_PATH" --audit-db "$AUDIT_DB" \
    --llama-url "$LLAMA_URL" --vector-size "$VECTOR_SIZE" \
    --max-age-days "$MAX_AGE_DAYS" --now-ms "$NOW_MS"
done

RECALL=$("$PYTHON" "$HUB_DIR/agent/agent.py" "What do you know about me?" \
  --db-path "$EVENT_DB" --qdrant-path "$QDRANT_PATH" --facts-audit-db "$AUDIT_DB" \
  --llama-url "$LLAMA_URL")
echo "$RECALL"

if echo "$RECALL" | grep -q "name: Alex" && echo "$RECALL" | grep -q "likes: hiking"; then
  result "AT-3-1 (reinforced facts stay active, traceable)" PASS
else
  result "AT-3-1 (reinforced facts stay active, traceable)" FAIL "recall answer missing expected facts"
fi

if echo "$RECALL" | grep -q "source interaction(s): #1" && echo "$RECALL" | grep -q "#4" && echo "$RECALL" | grep -q "#6"; then
  result "AT-3-1 (source traceability across all 3 mentions)" PASS
else
  result "AT-3-1 (source traceability across all 3 mentions)" FAIL "expected source ids #1, #4, #6 not all present: $RECALL"
fi

if echo "$RECALL" | grep -qi "Cape Town"; then
  result "AT-3-1 (unreinforced fact pruned, not surfaced)" FAIL "Cape Town should have been pruned by day 7"
else
  result "AT-3-1 (unreinforced fact pruned, not surfaced)" PASS
fi

PRUNE_LOGGED=$("$PYTHON" -c "
import sqlite3
c = sqlite3.connect('$AUDIT_DB')
rows = c.execute(\"select fact_key, fact_value, reason from dreaming_log where action = 'prune' and fact_value = 'Cape Town'\").fetchall()
print(len(rows))
for r in rows: print(r)
")
if [ "$(echo "$PRUNE_LOGGED" | head -1)" != "0" ]; then
  result "AT-3-1 (pruning is logged, not silent)" PASS "$(echo "$PRUNE_LOGGED" | tail -1)"
else
  result "AT-3-1 (pruning is logged, not silent)" FAIL "no prune audit row found for Cape Town"
fi

echo
echo "=== RESULTS (Phase 3 dreaming pipeline) ==="
printf '%s\n' "${RESULTS[@]}"
echo
rm -rf "$RUN_DIR"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
