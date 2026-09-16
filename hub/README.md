# hub

Phases 2-3 software stack (`CLAUDE.md` §5): a local model, a minimal
agent loop, one MCP tool, an event log, and a nightly consolidation
("dreaming") pipeline, all running and tested against each other for
real.

## Status

Working and tested (`hub/scripts/hub-stack-demo.sh` and
`hub/scripts/dreaming-demo.sh`, both wired into CI):

- **Local model serving** — real llama.cpp (`llama-server`), real
  qwen2 architecture, real Qwen2 tokenizer, **synthetic random weights**
  (see `hub/models/README.md` for why — this environment's network
  policy blocks downloading real trained checkpoints).
- **Agent loop** (`hub/agent/`) — answers a question via the local
  model; a `search:` prefix routes through a real MCP tool call instead;
  "what do you know about me?" routes to the Phase 3 fact store instead
  of the model. Tool-call and recall *decisions* are rule-based rather
  than model-driven for now (`hub/agent/README.md` explains why — it
  needs a model capable of deciding, which the synthetic one isn't).
- **One MCP "App"** (`hub/apps/file-search/`) — real MCP protocol,
  real tool execution, scoped read-only file search.
- **Event log** (`hub/memory/eventlog.py`) — plain SQLite, one row per
  interaction, sub-second write latency verified.
- **Dreaming pipeline** (`hub/dreaming/`) — nightly consolidation:
  rule-based fact extraction (same "needs real weights" caveat as tool
  dispatch — see `hub/dreaming/README.md`), real embeddings from the
  hub's own model, real Qdrant storage (embedded — Docker Hub is also
  blocked here, so this isn't a served instance yet), real reinforcement
  counting, and a real append-only audit log of every fact extracted,
  reinforced, or pruned. No model-weight updates, ever, per the plan.
- **Phase 2 exit criteria**, verified against the real running stack:
  a plain question answers and logs within 1 second (AT-2-1), and the
  whole thing keeps working with no WAN route at all (AT-2-2) — this is
  also the real replacement for the placeholder harness Phase 0's CI
  originally flagged as temporary.
- **Phase 3 exit criteria**, verified against a simulated week of
  interactions (AT-3-1): facts mentioned repeatedly stay active and
  traceable to their exact source interactions; a fact mentioned once
  and never reinforced decays — logged, not silently dropped.

Declared but **not yet deployed or validated**: `hub/flake.nix` (NixOS
config per Decision D2 — this environment has no `nix` installed, so
nothing here has run `nix flake check` against it, unlike everything
listed above).

Not yet started: Letta persistent-memory integration, a served
(non-embedded) Qdrant, Home Assistant integration (all listed as Phase
2/3 bring-up tasks in `CLAUDE.md` but not part of either phase's stated
exit criteria — see the roadmap note below).

## Why the scope stops there

`CLAUDE.md`'s Phase 2 bring-up list also names Letta+Qdrant (persistent
memory) and a minimal Home Assistant integration; Phase 3's mentions
LanceDB/Qdrant generally. Each phase's *exit criteria*, though, are
narrower and specific — see `docs/ACCEPTANCE-TESTS.md` AT-2-1/2 and
AT-3-1 for exactly what's required and verified. Letta and Home
Assistant are real, valuable, and still open — follow-up work, not
silently dropped.

## Running it

```sh
sudo hub/scripts/hub-stack-demo.sh    # Phase 2: local model, agent, MCP tool, event log
sudo hub/scripts/dreaming-demo.sh     # Phase 3: nightly consolidation, decay, recall
```

Both build llama.cpp and generate the synthetic model on first run if
they don't already exist (see `LLAMA_CPP_DIR`, `VENV_DIR`, `MODEL_PATH`
env vars at the top of each script to point at existing ones instead).
`hub-stack-demo.sh` needs root for its network-namespace check;
`dreaming-demo.sh` doesn't need root at all.
