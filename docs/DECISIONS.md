# NEx Decisions Log

Every entry is dated. Later entries can supersede earlier ones — when they do, the old entry stays (struck through in prose, not deleted) so the reasoning trail is auditable.

## D1 — Cloud fallback

**Decided: 2026-09-16 — No cloud fallback. Strict local-only.**

NEx makes zero outbound calls to any cloud service, for inference or anything else, after initial setup. There is no LiteLLM-style gateway in the hub stack and no code path that can silently reach the internet for a "better answer." If local model quality proves inadequate for common queries during Phase 5's real-use week, the fix is a better/bigger local model or a narrower feature scope — not a cloud call. This decision may be revisited only as a new, dated entry below, and only as a narrow, user-toggled, clearly-logged opt-in (never a default-on path), per the Phase 5 risk register.

## D2 — Hub OS

**Decided: 2026-09-16 — NixOS, native generations/rollback. No OSTree/RAUC on the hub.**

The hub boots a declarative NixOS configuration (`hub/flake.nix`). Updates are Nix generation switches; rollback is `nixos-rebuild switch --rollback` (or boot-menu generation select), not an image-level A/B mechanism. OSTree/RAUC is dropped from the hub's update path — mixing declarative-package and image-atomic update philosophies produces two different failure/rollback models to reason about, and Nix's generation model already gives atomic, auditable rollback. (OSTree/RAUC may still be relevant for non-Nix embedded targets evaluated later, e.g. a stripped-down Sophon SE9 image, but that would be a separate, explicitly-scoped decision, not a hub default.)

## D3 — Dev-phase hardware tier

**Decided: 2026-09-16 — Jetson AGX Orin 64GB for Phases 1-4 dev; Sophon SE9/BM1688 validated in parallel once the software stack is stable.**

Jetson is the primary dev target: fastest iteration, most mature llama.cpp/CUDA/TensorRT-LLM tooling, best-documented path through Phases 1-4. Sophon SE9 (BM1688, 16 TOPS, open TPU-MLIR toolchain, no export exposure) is the more likely real shipping tier for cost and export-control reasons, and gets validated on the same software stack starting once Phase 2 is stable on Jetson — not deferred to Phase 6. RK3588 stays a reserve option (cheapest, most mature community Linux support, but only 6 TOPS) if Sophon's LLM tooling proves too immature within the Phase 2 timeline.

## D4 — Agent runtime

**Decided: 2026-09-16 — smolagents for the Phase 2 minimal agent loop.**

smolagents' smaller surface area is easier to audit line-by-line, which matters more than LangGraph's richer branching/state model at this stage — Phase 2's exit criteria only need a linear "answer, maybe call one tool, log it" loop. LangGraph is a reserve dependency (see `DEPENDENCIES.md`) if the agent loop needs more complex branching or multi-step state later (e.g. multi-tool plans in Phase 6+). OpenClaw/Hermes Agent are noted as reserves only, and only if D4 is revisited — they're faster to stand up but less auditable, which cuts against the project's core "auditable down to the schematic" principle.

## D5 — Pocket node OS

**Decided: 2026-09-16 — /e/OS or LineageOS as the buildable pocket-node base.**

Both are buildable, redistributable, de-Googled Android bases suitable for Phase 4's app shell. GrapheneOS is study-only: its hardening techniques and threat-model writing inform NEx's own `THREAT-MODEL.md`, but it is source-available (not fully open/redistributable in the same sense) and its signing infrastructure is not to be forked or reused. Final choice between /e/OS and LineageOS is deferred to Phase 4 kickoff, based on target device support at that time — both satisfy the Phase 0-3 planning needs equally, so this doesn't block earlier phases.
