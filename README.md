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
- **Phase 2** — hub software stack bring-up. Exit criteria met (`hub/`): local model + agent loop + one MCP tool + event log, verified both online and with no WAN route at all. Runs on a real llama.cpp + real Qwen2 tokenizer with synthetic (untrained) weights — see `hub/models/README.md` for why, and `hub/README.md` for what's deliberately still open (Letta, Home Assistant, NixOS validation).
- **Phase 3** — dreaming pipeline v0. Exit criteria met (`hub/dreaming/`): a simulated week of interactions shows reinforced facts staying active and traceable to their source interactions, while an unreinforced fact decays — logged, never silently dropped. Rule-based extraction, real embedded Qdrant, real embeddings from the hub's own (synthetic-weight) model. No model-weight updates, ever, per the plan.
- **Phase 4** — pocket node client v0. Exit criteria met (`pocket/`): five questions answered fully offline (real network namespace, no WAN route), queued in a real unit-tested Kotlin store-and-forward module, synced to the hub in seconds (well under the 60s budget) via Phase 1's proven CRDT layer, arriving in order and traceable — and mirrored into the hub's real event log, closing a Phase 1/2 integration gap. No real Android build or emulator here — verified unavailable (`dl.google.com` blocked, no `/dev/kvm`), not assumed; see `pocket/README.md`.
- **Phase 5** — full integration, load test, security pass. Done (`infra/zero-internet/`): a real WireGuard tunnel between two namespaces, both locked down to loopback + tunnel only by `iptables` (a canary check confirms the lockdown actually catches a bypass, not just that nothing tried); a 7-day simulated week of hub activity (two new real MCP tools — `hub/apps/notes/`, `hub/apps/smart-home/`) plus two phone reconnect cycles over the real tunnel; a 100-write concurrent-conflict load test that converges deterministically on both sides; zero egress-rule violations across the whole run, every run. "Voice" and "calendar" activity is plain text/Q&A, not real transcription or a real calendar — disclosed in `infra/zero-internet/README.md`, not implied.

See `CLAUDE.md` §5 for the full phase list and exit criteria, and `docs/ACCEPTANCE-TESTS.md` for the versioned test-by-test status.

## Repo layout

```
nex/
├── hub/            # Hub node software (NixOS config + services)
├── pocket/         # Android app (LineageOS/e/OS target)
├── sync-protocol/  # Shared sync prototype (Phase 1)
├── infra/          # Headscale control plane, WireGuard PoC, Phase 5 integration test
└── docs/           # Decisions, threat model, acceptance tests
```
