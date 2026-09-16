# hub/dreaming

The Phase 3 "dreaming" pipeline (`CLAUDE.md` §5, Phase 3): a nightly job
that reads the event log since it last ran, extracts stable facts,
stores them with full source traceability, and decays anything not
reinforced — without ever silently deleting it. See `hub/README.md`
for how this fits into the rest of the hub stack.

Explicitly **not** fine-tuning. Nothing here touches model weights, on
purpose — `CLAUDE.md`'s risk register calls out real weight updates in
Phase 3 as premature (catastrophic forgetting, no rollback, no safety
framework yet).

## Files

- `facts.py` — `FactStore`: rule-based fact extraction plus a Qdrant
  fact store with reinforcement counting and decay/pruning, all logged
  to a `dreaming_log` audit table.
- `consolidate.py` — the nightly job itself. Reads new events since
  its own checkpoint, extracts/reinforces facts, prunes stale ones.

## Why extraction is rule-based, not model-driven

Same scope call as `hub/agent/README.md`'s for tool-call dispatch, for
the same reason: judging what's a "stable fact" versus "noise"
(`CLAUDE.md`'s own phrasing) needs a model capable of judgment. This
hub's model has random, untrained weights (`hub/models/README.md`) and
isn't capable of that — it would extract nothing reliably, or extract
gibberish mislabeled as facts about the user, which is worse than a
narrow deterministic rule set over the user's own words. A short list
of regexes (`facts.py`'s `EXTRACTION_RULES`) stands in for now.
Swapping it for model-driven extraction — the local model reading a
day's interactions and proposing candidate facts — is the direct next
step once real trained weights exist; the fact store, decay logic, and
audit trail underneath don't change.

## Why embeddings are real even though the model isn't

Each fact gets a real vector from `hub`'s actual `llama-server`,
computed by a real forward pass through the actual (untrained, random-
weight) synthetic model, via llama.cpp's own `/embedding` endpoint. The
vector is semantically meaningless for the same reason the model's
text output is (`hub/models/README.md`), but the *mechanism* —
tokenize, embed, store, retrieve by similarity — is real and would work
identically with a real trained model dropped in.

## Storage

Qdrant, run embedded (`qdrant_client.QdrantClient(path=...)`, no server
process) rather than as a standalone service — this environment's
network policy also blocks Docker Hub, so the containerized Qdrant
`infra/headscale/`-style deployment isn't available here either. The
embedded mode is genuinely the same Qdrant storage/query engine, just
in-process; swapping to a served Qdrant instance (`DEPENDENCIES.md`'s
hub-side vector store) is a connection-string change, not a rewrite.

## Running it

```sh
python3 consolidate.py \
  --event-db /path/to/hub-events.db \
  --qdrant-path /path/to/qdrant-data \
  --audit-db /path/to/dreaming-audit.db
```

Intended to run nightly via a systemd timer (`hub/flake.nix`'s
`nex-dreaming` timer — declared, not yet deployed, same caveat as the
rest of that file) or cron in the meantime. See
`hub/scripts/dreaming-demo.sh` for the full simulated-week exit-criteria
test.
