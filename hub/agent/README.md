# hub/agent

The Phase 2 minimal agent loop (`CLAUDE.md` §5, Phase 2): answer a
question using the local model, optionally call one MCP tool, log the
interaction. See `hub/README.md` for how this fits into the rest of the
hub stack and `hub/models/README.md` for why the model itself is
synthetic right now.

## Files

- `agent.py` — the loop itself. `search:<query>` as a question prefix
  triggers a real MCP tool call against `hub/apps/file-search/` (see
  below); anything else goes straight to the local model. Logs every
  interaction via `hub/memory/eventlog.py`.
- `requirements.txt` — `mcp`, `httpx` — covers both this and
  `hub/apps/file-search/`.

## Why tool-call decisions are rule-based, not model-driven

Decision D4 (`docs/DECISIONS.md`) names smolagents as the Phase 2 agent
runtime, and smolagents drives tool selection from the model's own
output — it needs a model that can actually decide, in natural language
or structured function-call syntax, when a tool is useful. The model
currently running on this hub has random, untrained weights (see
`hub/models/README.md`): it cannot make that decision, because it isn't
making decisions at all. Wiring smolagents in now would mean threading a
real framework through a code path that has nothing meaningful to
exercise it with.

What's implemented instead is a simple rule (`search:` prefix) that
triggers the same real machinery a model-driven version would use — a
real MCP client, talking the real protocol, to a real tool server, with
the result folded back into the model's prompt. Swapping the rule for
smolagents' model-driven dispatch is the direct next step once real
model weights are available; nothing about the MCP server or the event
log needs to change when that happens.

## Running it directly

```sh
python3 agent.py "Hello, hub." --db-path /tmp/hub-events.db --model-path /path/to/model.gguf
python3 agent.py "search: Phase 1" --db-path /tmp/hub-events.db --mcp-root /path/to/repo --model-path /path/to/model.gguf
```

Needs a running `llama-server` (default `http://127.0.0.1:8090`,
override with `--llama-url`). See `hub/scripts/hub-stack-demo.sh` for
the full end-to-end setup.
