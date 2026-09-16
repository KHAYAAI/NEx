# hub

Phase 2 software stack (`CLAUDE.md` §5): a local model, a minimal agent
loop, one MCP tool, and an event log, all running and tested against
each other for real.

## Status

Working and tested (`hub/scripts/hub-stack-demo.sh`, wired into CI):

- **Local model serving** — real llama.cpp (`llama-server`), real
  qwen2 architecture, real Qwen2 tokenizer, **synthetic random weights**
  (see `hub/models/README.md` for why — this environment's network
  policy blocks downloading real trained checkpoints).
- **Agent loop** (`hub/agent/`) — answers a question via the local
  model; a `search:` prefix routes through a real MCP tool call instead.
  Tool-call *decisions* are rule-based rather than model-driven for now
  (`hub/agent/README.md` explains why — it needs a model capable of
  deciding, which the synthetic one isn't).
- **One MCP "App"** (`hub/apps/file-search/`) — real MCP protocol,
  real tool execution, scoped read-only file search.
- **Event log** (`hub/memory/eventlog.py`) — plain SQLite, one row per
  interaction, sub-second write latency verified.
- **Phase 2 exit criteria**, verified against the real running stack:
  a plain question answers and logs within 1 second (AT-2-1), and the
  whole thing keeps working with no WAN route at all (AT-2-2) — this is
  also the real replacement for the placeholder harness Phase 0's CI
  originally flagged as temporary.

Declared but **not yet deployed or validated**: `hub/flake.nix` (NixOS
config per Decision D2 — this environment has no `nix` installed, so
nothing here has run `nix flake check` against it, unlike everything
listed above).

Not yet started: Letta/Qdrant persistent memory, Home Assistant
integration (both listed as Phase 2 bring-up tasks in `CLAUDE.md` but
not part of its stated exit criteria — see the roadmap note below).

## Why the scope stops there

Phase 2's bring-up list in `CLAUDE.md` also names Letta+Qdrant
(persistent memory) and a minimal Home Assistant integration. Its
*exit criteria*, though, are specifically: ask a question over CLI, get
a local-model answer, see it logged within 1 second, and have the
process survive a network cut. That's what's built and verified here.
Letta/Qdrant and Home Assistant are real, valuable, and still open —
follow-up work, not silently dropped.

## Running it

```sh
sudo hub/scripts/hub-stack-demo.sh
```

Builds llama.cpp and generates the synthetic model on first run if
they don't already exist (see `LLAMA_CPP_DIR`, `VENV_DIR`, `MODEL_PATH`
env vars at the top of the script to point at existing ones instead).
Needs root for the AT-2-2 network-namespace check; everything else runs
unprivileged.
