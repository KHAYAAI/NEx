# NEx Build Plan — for Claude Code
Copy this file into your Claude Code session as `CLAUDE.md` at the repo root. It expands the original project brief into a phased, testable execution plan. Work top to bottom; do not skip the decision log — several choices below directly change what you build in Phase 1.

---

## 0. Mission (one paragraph)

A two-node, cloud-independent personal AI system: an open-hardware home hub ("the brain") paired with a privacy-first handset ("the body"), synchronized over encrypted P2P links, with personalization handled by on-device nightly consolidation instead of data extraction. Bought once, owned forever, auditable down to the schematic. This is the consumer proof-of-architecture for NEx's tactical/defense line (NEx OS, NEx Eye) — the hub↔handset split, offline fallback, and federated node mesh are the same patterns reused at the tactical edge later.

## 1. Non-negotiable principles (the acceptance test for every PR)

- No cloud calls, no telemetry, ever — unless Decision D1 below explicitly opts into a narrow, user-toggled exception.
- All hub↔phone sync is end-to-end encrypted.
- All user-facing components are open source.
- Closed blobs (modem firmware, NPU firmware) are isolated behind a documented boundary and never trusted with plaintext user data.
- Every feature must degrade gracefully to **zero internet** after initial setup. If a PR breaks offline operation, it does not merge.

## 2. Architecture recap

```
┌─────────────────────────────────────────────────────────┐
│  TIER 1 — HUB NODE ("Brain")                            │
│  Fanless box, wall-powered.                              │
│  • Model routing (concurrent small models)               │
│  • Persistent memory store (event log + vectors)         │
│  • Sandboxed agent/tool runtime ("Apps")                 │
│  • Nightly consolidation ("dreaming")                    │
│  • Home Assistant / IoT integration                      │
└──────────────┬────────────────────────────────────────────┘
               │ WireGuard tunnel (Headscale control plane)
               │ Automerge/Yjs CRDT sync of memory event log
┌──────────────┴────────────────────────────────────────────┐
│  TIER 2 — POCKET NODE ("Body")                            │
│  De-Googled handset.                                      │
│  • Thin client UI (voice/text)                            │
│  • Local 3-8B quantized fallback model (offline mode)     │
│  • Store-and-forward sync when disconnected               │
│  • Hardware modem kill switch                             │
└─────────────────────────────────────────────────────────┘
```

## 3. Decisions to lock BEFORE Phase 1 (do not start coding until these are answered)

These aren't implementation details — each one changes what gets built.

- **D1 — Cloud fallback.** Fully local forever (strict reading of the acceptance test), or a narrow, user-toggled, clearly-logged cloud fallback for queries the local model can't handle? This determines whether a LiteLLM-style gateway belongs in the hub stack at all. *Default if undecided: no fallback. Strict local-only is the more defensible sovereignty claim and the safer default to build toward.*
- **D2 — Hub OS.** Full NixOS (use Nix's native generations/rollback, drop OSTree/RAUC), or a lighter Armbian/Debian base with Nix packages layered in (keep OSTree/RAUC for image-level atomic updates)? These are two different update philosophies — pick one, don't mix them. *Default if undecided: NixOS native, for the strongest declarative/auditable story.*
- **D3 — Dev-phase hardware tier.** Jetson AGX Orin 64GB (fastest path, most mature software, but US export exposure) vs. Sophon SE9/BM1688 (16 TOPS, genuinely open TPU-MLIR toolchain, no export exposure, less mature LLM tooling) vs. RK3588 (cheapest, 6 TOPS, most mature community Linux support). *Default: prototype on Jetson for speed of iteration (best-documented path for Phases 1-4), validate the real Phase 6+ shipping tier on Sophon SE9 in parallel once the software stack is stable.*
- **D4 — Agent runtime.** smolagents vs. LangGraph (both self-hosted, both thinner/more auditable than OpenClaw/Hermes, no built-in skill marketplace — you're building the "App" ecosystem from scratch via MCP). *Default: smolagents for Phase 2's minimal agent loop — smaller surface area, easier to audit line-by-line; revisit LangGraph if the agent loop needs more complex branching/state later.*
- **D5 — Pocket node OS.** LineageOS/e/OS base vs. studying GrapheneOS without forking it (source-available, not redistributable — do not fork or reuse their signing infrastructure). *Default: /e/OS or LineageOS as the buildable base.*

Record answers to D1-D5 at the top of the repo README before Phase 1 starts.

## 4. Repo structure

```
nex/
├── hub/                  # Hub node software (NixOS config + services)
│   ├── flake.nix         # or equivalent per D2
│   ├── agent/            # smolagents/LangGraph agent loop
│   ├── memory/           # event log, LanceDB/Qdrant, Letta integration
│   ├── dreaming/         # nightly consolidation pipeline
│   ├── sync/             # Automerge/Yjs + libp2p + WireGuard client
│   └── apps/             # MCP server integrations ("Apps")
├── pocket/                # Android app (LineageOS/e/OS target)
│   ├── client/            # thin UI, voice/text front-end
│   ├── local-model/       # MLC LLM 3-8B quantized fallback
│   └── sync/               # CRDT client, store-and-forward queue
├── sync-protocol/         # Shared: the sync prototype (build first, see Phase 1)
├── infra/
│   ├── headscale/          # self-hosted mesh control plane config
│   └── update-server/      # Mender/RAUC or Nix binary cache, per D2
├── docs/
│   ├── DECISIONS.md        # D1-D5 answers + any new decisions, dated
│   ├── THREAT-MODEL.md     # what's protected, what's out of scope
│   └── ACCEPTANCE-TESTS.md # the "zero internet" test suite, versioned
└── CLAUDE.md               # this file
```

## 5. Phased roadmap

### Phase 0 — Scaffolding (½–1 day)

- Stand up the repo structure above.
- Write `docs/DECISIONS.md` with D1-D5 resolved.
- Write `docs/THREAT-MODEL.md`: what NEx protects against (cloud data extraction, telemetry, unencrypted sync) and what it explicitly does not attempt to protect against (physical device seizure, supply-chain firmware compromise) — state this honestly, don't oversell, given the Brax Technologies lesson from the research phase (a privacy product that overstates its guarantees loses trust fast).
- Set up CI that runs `docs/ACCEPTANCE-TESTS.md`'s "airplane mode" test on every PR from Phase 2 onward.

### Phase 1 — Sync protocol prototype (the moat — riskiest, do this first)

**Goal:** two plain Linux nodes (not yet the real hub/phone) sync a simple event log over an encrypted P2P link, with no server in the middle.

- Prototype Automerge (or Yjs) syncing a JSON event log between two processes over libp2p.
- Wrap the transport in WireGuard; stand up Headscale as the self-hosted control plane for peer discovery/key exchange.
- Test matrix: both nodes online; one node offline then reconnecting; both nodes offline simultaneously with local writes, then reconciling (this is the actual hard case — verify Automerge's CRDT merge behaves correctly on conflicting concurrent writes).
- **Exit criteria:** a 3-way conflict (both nodes write to the same logical field while disconnected) resolves deterministically and losslessly on reconnect, with no manual intervention. Document the merge semantics in `docs/`.
- Do not proceed to Phase 2 until this works — everything downstream assumes this layer is solid.

### Phase 2 — Hub software stack bring-up

**Goal:** a single dev board (per D3) running the full hub stack, answering questions from local models, logging every interaction.

- NixOS (or chosen base, per D2) install on the dev board.
- Bring up: llama.cpp or Ollama (D3-dependent — RKLLM/TPU-MLIR toolchain if Sophon/Rockchip, standard llama.cpp CUDA build if Jetson) serving at least one quantized model.
- Bring up: Letta (MemGPT) for persistent memory, backed by LanceDB or Qdrant.
- Bring up: minimal agent loop (per D4) that can (a) answer a question using the local model, (b) call at least one MCP tool (start with something low-stakes, e.g. a local file-search MCP server), (c) log the full interaction to the event log from Phase 1.
- Bring up: Home Assistant, minimally — enough to prove the hub can see and act on at least one real IoT device.
- **Exit criteria:** ask the hub a question over SSH/CLI, it answers using the local model, the interaction appears in the event log within 1 second, and the process survives a network cable pull without crashing.

### Phase 3 — Dreaming pipeline v0 (consolidation, not fine-tuning)

**Goal:** a nightly job that makes the hub "know you better" without touching model weights.

- Cron job (or systemd timer) reads the day's event log.
- Summarizes with the local small model — extract stable facts/preferences, discard noise.
- Store extracted facts as structured entries in the vector store (LanceDB/Qdrant), tagged with source event IDs for traceability.
- Prune/re-rank: implement a simple decay so facts not reinforced over N days lose priority (but are never silently deleted without being logged as pruned — this matters for the "auditable" principle).
- **Exit criteria:** after a week of varied test interactions, the hub's answers to "what do you know about me" visibly reflect accumulated facts, and every fact is traceable back to the source interaction that produced it. QLoRA fine-tuning is explicitly out of scope for v0 — do not attempt real weight updates until this pipeline has real usage data behind it (see the earlier design discussion on why: catastrophic forgetting, no rollback, safety drift).

### Phase 4 — Pocket node client v0

**Goal:** an Android app that talks to the hub and has a real offline mode.

- App shell on the chosen OS target (D5), connecting to the hub over the Phase 1 sync layer.
- Integrate Faster-Whisper (streamed to the hub when connected) for voice input.
- Integrate MLC LLM running a 3-8B quantized model locally on the phone for the offline fallback path.
- Implement the store-and-forward queue: interactions while offline get logged locally and merged into the shared event log via the CRDT sync layer on reconnect (this exercises Phase 1's conflict-resolution path for real).
- Wire up the hardware modem kill switch state as a first-class UI element, not an afterthought.
- **Exit criteria:** put the phone in airplane mode, ask it five different questions (mix of simple/complex), confirm the offline model answers all five reasonably, confirm all five appear correctly ordered in the hub's event log within 60 seconds of reconnecting.

### Phase 5 — Integration & the real acceptance test

- Run the full "zero internet after initial setup" test end-to-end: hub + phone, both on an isolated network with no WAN, for a full week of simulated real use (calendar queries, notes, home automation, voice interactions).
- Load-test the sync layer with realistic conflict rates (both nodes writing within the same few seconds, repeatedly).
- Security pass: confirm no component makes an outbound DNS or HTTP call outside the WireGuard tunnel — instrument the network namespace and fail the build if anything tries.

### Phase 6 — Hardening

- Integrate the SE050 secure element for device identity (replaces any software-only key storage).
- Move the agent/tool runtime into gVisor or Firecracker sandboxing on the hub; Wasmtime for anything lightweight enough to run in-process.
- Stand up the update mechanism per D2 (Nix generations, or OSTree/RAUC) and test a rollback from a deliberately broken update.
- Stand up the F-Droid repo (or Obtainium-compatible feed) for distributing "App" (MCP integration) packages.
- Isolate the modem/NPU firmware blobs behind their documented boundary; write the isolation test that proves the rest of the system functions with the modem physically switched off.

### Phase 7 — Multi-hub mesh (v2 / stretch, not required for v0 ship)

- Evaluate `exo` (exo-explore/exo) for pooling compute across multiple hub units in the same household — this solves a different problem than Phase 1's CRDT sync (compute partitioning for bigger models, not state consistency for a small event log), so it's additive, not a replacement.
- Only start this once Phases 1-6 are stable and shipping — don't let mesh ambitions delay the core two-node product.

## 6. Hardware to buy now (dev phase, per D3 default)

- 1x Jetson AGX Orin 64GB developer kit — primary dev target for Phases 1-4
- 1x Sophon SE9 micro server (BM1688, 16GB variant) — parallel validation target once Phase 2 stack is stable, since this is the more likely real shipping tier for cost/export reasons
- 1x Android test device compatible with LineageOS or /e/OS, for Phase 4
- 2x cheap Linux boxes (even laptops) for the Phase 1 sync prototype — don't waste the Jetson/Sophon hardware on the earliest, most iterative phase

## 7. Risk register (revisit at the start of each phase)

| Risk | Phase | Watch for |
|---|---|---|
| CRDT merge semantics are subtly wrong under real concurrent writes | 1 | Silent data loss on conflict — test conflicting writes explicitly, don't just test the happy path |
| Local model quality ceiling makes D1's "no fallback" stance feel bad in practice | 2, 5 | If Phase 5's real-use week produces consistently bad answers on common queries, resurface D1 rather than quietly adding a cloud call |
| "Dreaming" pipeline scope-creeps toward real fine-tuning before it's earned | 3 | Any PR touching model weights in Phase 3 should be rejected — that's Phase 3+ (post-v0), and only with the safety framework from the design discussion in place |
| Sophon toolchain (TPU-MLIR) has rougher edges than llama.cpp/CUDA for the specific models you need | 2 | Budget extra time if D3 validation moves to Sophon; keep Jetson as the fallback dev path |
| Overstating privacy/security guarantees before the threat model and audit are real | 0, 6 | Re-read `docs/THREAT-MODEL.md` before any public-facing claim — this is the Brax Technologies lesson |
