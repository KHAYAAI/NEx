#!/usr/bin/env bash
# Phase 2 exit criteria (CLAUDE.md): "ask the hub a question over
# SSH/CLI, it answers using the local model, the interaction appears in
# the event log within 1 second, and the process survives a network
# cable pull without crashing." Also exercises the "call at least one
# MCP tool" bring-up requirement.
#
# This also completes the TODO left in .github/workflows/acceptance-tests.yml's
# original AT-0-1 placeholder job: "This job proves the harness only. It
# will be replaced by the real hub-process test... once Phase 2 exists."
# AT-2-2 below is that real test — the actual hub process (llama-server +
# agent + event log), not a generic namespace sanity check.
#
# What it does, in order:
#   1. builds llama.cpp if a server binary isn't already at $LLAMA_SERVER
#   2. sets up a Python venv for the agent (mcp, httpx) if missing
#   3. generates the synthetic tiny model if missing (see hub/models/README.md
#      for why it's synthetic, not a real trained checkpoint)
#   4. AT-2-1: starts llama-server, asks a plain question and a
#      "search:" question (exercising the MCP tool path), checks both
#      got answered and logged, and separately checks the plain-question
#      path against the 1-second exit criterion (the tool-call path's
#      real measured latency is reported, not gated — see hub/README.md)
#   5. AT-2-2: repeats the plain-question check with the ENTIRE hub
#      process (llama-server + agent) running inside a network namespace
#      with no WAN route, confirming it still works and that an outbound
#      call from that namespace genuinely fails
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HUB_DIR/.." && pwd)"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/tmp/nex-llama.cpp}"
VENV_DIR="${VENV_DIR:-/tmp/nex-hub-venv}"
MODEL_PATH="${MODEL_PATH:-/tmp/nex-hub-models/nex-tiny-qwen2.gguf}"
APP_PORT=8091
AIRPLANE_NS=nex-hub-airplane

RESULTS=()
PASS=0
FAIL=0
log() { echo "[hub-demo] $*"; }
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

# --- 1. llama.cpp ---
LLAMA_SERVER_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
  log "building llama.cpp (CPU) at $LLAMA_CPP_DIR"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
  cmake -B "$LLAMA_CPP_DIR/build" -S "$LLAMA_CPP_DIR" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF
  cmake --build "$LLAMA_CPP_DIR/build" --config Release -j"$(nproc)" --target llama-server
fi
log "llama-server: $LLAMA_SERVER_BIN"

# --- 2. Python venv ---
if [ ! -x "$VENV_DIR/bin/python3" ]; then
  log "creating venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet -r "$HUB_DIR/agent/requirements.txt"
fi
PYTHON="$VENV_DIR/bin/python3"

# --- 3. tiny synthetic model ---
if [ ! -f "$MODEL_PATH" ]; then
  log "generating synthetic tiny qwen2-arch model at $MODEL_PATH"
  mkdir -p "$(dirname "$MODEL_PATH")"
  "$PYTHON" "$HUB_DIR/models/make-tiny-model.py" \
    --out "$MODEL_PATH" \
    --vocab-gguf "$LLAMA_CPP_DIR/models/ggml-vocab-qwen2.gguf" \
    --n-embd 64 --n-layer 2 --n-head 2
fi

DB_PATH="$(mktemp -u /tmp/nex-hub-eventlog.XXXXXX.db)"

ask() {
  local question="$1" port="$2"
  "$PYTHON" "$HUB_DIR/agent/agent.py" "$question" \
    --db-path "$DB_PATH" --mcp-root "$REPO_ROOT" --model-path "$MODEL_PATH" \
    --llama-url "http://127.0.0.1:$port"
}

wait_for_llama_server() {
  local port="$1" ns_prefix="$2"
  for _ in $(seq 1 60); do
    if $ns_prefix curl -sSf -o /dev/null "http://127.0.0.1:$port/completion" \
      -H "Content-Type: application/json" \
      -d '{"prompt":"x","n_predict":1}' 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  echo "llama-server never became ready on port $port" >&2
  return 1
}

latest_latency_ms() {
  "$PYTHON" "$HUB_DIR/memory/eventlog.py" "$DB_PATH" -n 1 | \
    "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)[0]['latency_ms'])"
}

# --- 4. AT-2-1: ask over CLI, local model answers, logged within 1s ---
log "AT-2-1: starting llama-server on port $APP_PORT"
"$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$APP_PORT" --skip-chat-parsing \
  > /tmp/nex-hub-llama-server.log 2>&1 &
LLAMA_SERVER_PID=$!
wait_for_llama_server "$APP_PORT" ""

ANSWER=$(ask "Hello, hub." "$APP_PORT")
LATENCY=$(latest_latency_ms)
log "plain question answered (${LATENCY}ms), logged"
if [ -n "$ANSWER" ] && awk -v l="$LATENCY" 'BEGIN{exit !(l < 1000)}'; then
  result "AT-2-1 (plain question, <1s log)" PASS "latency=${LATENCY}ms"
else
  result "AT-2-1 (plain question, <1s log)" FAIL "latency=${LATENCY}ms answer_empty=$([ -z "$ANSWER" ] && echo yes || echo no)"
fi

TOOL_ANSWER=$(ask "search: Phase 1" "$APP_PORT")
TOOL_LATENCY=$(latest_latency_ms)
if [ -n "$TOOL_ANSWER" ]; then
  result "MCP tool call (search_files)" PASS "latency=${TOOL_LATENCY}ms (not gated at 1s — see hub/README.md)"
else
  result "MCP tool call (search_files)" FAIL "empty answer"
fi

kill "$LLAMA_SERVER_PID" 2>/dev/null || true
wait "$LLAMA_SERVER_PID" 2>/dev/null || true
LLAMA_SERVER_PID=""

# --- 5. AT-2-2: whole hub process survives a real network cable pull ---
log "AT-2-2: running the same check with no WAN route (airplane mode)"
ip netns add "$AIRPLANE_NS"
ip netns exec "$AIRPLANE_NS" ip link set lo up

if ip netns exec "$AIRPLANE_NS" timeout 3 sh -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' 2>/dev/null; then
  result "AT-2-2 isolation sanity" FAIL "outbound connection unexpectedly succeeded in airplane-mode namespace"
else
  result "AT-2-2 isolation sanity" PASS "no outbound WAN access available"
fi

ip netns exec "$AIRPLANE_NS" "$LLAMA_SERVER_BIN" -m "$MODEL_PATH" --host 127.0.0.1 --port "$APP_PORT" --skip-chat-parsing \
  > /tmp/nex-hub-llama-server-airplane.log 2>&1 &
LLAMA_SERVER_PID=$!
wait_for_llama_server "$APP_PORT" "ip netns exec $AIRPLANE_NS"

AIRPLANE_ANSWER=$(ip netns exec "$AIRPLANE_NS" "$PYTHON" "$HUB_DIR/agent/agent.py" "Hello from airplane mode." \
  --db-path "$DB_PATH" --mcp-root "$REPO_ROOT" --model-path "$MODEL_PATH" --llama-url "http://127.0.0.1:$APP_PORT")
AIRPLANE_LATENCY=$(latest_latency_ms)

if kill -0 "$LLAMA_SERVER_PID" 2>/dev/null && [ -n "$AIRPLANE_ANSWER" ] && \
   awk -v l="$AIRPLANE_LATENCY" 'BEGIN{exit !(l < 1000)}'; then
  result "AT-2-2 (survives no-WAN, <1s log)" PASS "latency=${AIRPLANE_LATENCY}ms, llama-server still running"
else
  result "AT-2-2 (survives no-WAN, <1s log)" FAIL "latency=${AIRPLANE_LATENCY}ms process_alive=$(kill -0 "$LLAMA_SERVER_PID" 2>/dev/null && echo yes || echo no)"
fi

kill "$LLAMA_SERVER_PID" 2>/dev/null || true
wait "$LLAMA_SERVER_PID" 2>/dev/null || true
LLAMA_SERVER_PID=""

echo
echo "=== RESULTS (Phase 2 hub stack) ==="
printf '%s\n' "${RESULTS[@]}"
echo
rm -f "$DB_PATH"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
