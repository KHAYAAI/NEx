# NEx

A two-node, cloud-independent personal AI system: an open-hardware home hub (the "brain") paired with a privacy-first handset (the "body"), synchronized over encrypted P2P links, with personalization handled by on-device nightly consolidation instead of data extraction.

See `CLAUDE.md` for the full build plan and phased roadmap, `DEPENDENCIES.md` for the dependency list by phase, and `docs/` for decisions, the threat model, and the acceptance test suite.

## Decisions (D1-D5)

Locked before Phase 1 work starts. Full reasoning in `docs/DECISIONS.md`.

- **D1 — Cloud fallback:** none. Strict local-only, no cloud calls ever.
- **D2 — Hub OS:** NixOS, native generations/rollback. No OSTree/RAUC on the hub.
- **D3 — Dev hardware:** Jetson AGX Orin 64GB for Phases 1-4 dev; Sophon SE9/BM1688 validated in parallel once the stack is stable.
- **D4 — Agent runtime:** smolagents for the Phase 2 minimal agent loop.
- **D5 — Pocket OS:** /e/OS or LineageOS (final pick deferred to Phase 4 kickoff).

## Status

- **Phase 0** — scaffolding. Done.
- **Phase 1** — sync protocol prototype. Exit criteria met: CRDT sync (`sync-protocol/`) validated both on loopback and over a real WireGuard tunnel between two network namespaces (`infra/wireguard-poc/`). See `docs/MERGE-SEMANTICS.md`.
- **Phase 2** — hub software stack bring-up. Exit criteria met (`hub/`): local model + agent loop + one MCP tool + event log, verified both online and with no WAN route at all. Runs on a real llama.cpp + real Qwen2 tokenizer with synthetic (untrained) weights — see `hub/models/README.md` for why, and `hub/README.md` for what's deliberately still open (Letta/Qdrant, Home Assistant, NixOS validation).

See `CLAUDE.md` §5 for the full phase list and exit criteria, and `docs/ACCEPTANCE-TESTS.md` for the versioned test-by-test status.

## Repo layout

```
nex/
├── hub/            # Hub node software (NixOS config + services)
├── pocket/         # Android app (LineageOS/e/OS target)
├── sync-protocol/  # Shared sync prototype (Phase 1)
├── infra/          # Headscale control plane, update server
└── docs/           # Decisions, threat model, acceptance tests
```
