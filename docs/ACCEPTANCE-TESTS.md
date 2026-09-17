# NEx Acceptance Tests

Versioned test suite for the "zero internet after initial setup" principle (`CLAUDE.md` §1) and other non-negotiables. CI runs the tests marked **CI** on every PR, starting Phase 2 (once there's a running hub stack for the tests to exercise against). Tests without **CI** are manual/hardware-in-the-loop and get run at the phase gate named.

Each test has a stable ID (`AT-<phase>-<n>`) so results and regressions can be referenced precisely (e.g. in PR descriptions, in the risk register).

## v0.1 — 2026-09-16 (initial)

### AT-0-1 — Airplane mode smoke test **(CI, from Phase 2)**

**Principle under test:** §1 "degrade gracefully to zero internet."

**Setup:** hub stack running (or, until Phase 2 lands real services, the placeholder CI job below) in a network namespace / container with all outbound network access removed except loopback and the hub↔phone tunnel interface.

**Steps:**
1. Cut all WAN-reachable network access (simulate airplane mode: block default route / disable the WAN interface, but keep loopback and any hub↔phone tunnel interface up).
2. Exercise the primary interaction path for the current phase (Phase 2+: ask the hub a question over CLI/SSH; Phase 4+: also exercise the phone client offline).
3. Confirm the interaction completes successfully using only local resources.
4. Confirm no process attempted an outbound DNS or HTTP/HTTPS call outside the tunnel (Phase 5 adds instrumented enforcement of this; until then, inspect logs/packet capture manually).

**Pass condition:** the interaction succeeds with WAN access removed, and no component crashes, hangs waiting on a network call, or silently fails without a clear local-mode indication to the user.

**Status:** the placeholder harness job still runs (cheap, still a valid sanity check), but the real test now exists too — see AT-2-2 below, which is this test run against the actual hub process (`hub/scripts/hub-stack-demo.sh`), not a generic namespace check.

### AT-1-1 — CRDT reconciliation, both nodes online **(CI, implemented — `sync-protocol/test/sync.test.js`)**

**Phase:** 1 (sync protocol prototype)

**Steps:** with both prototype nodes connected over the Phase 1 sync layer, write an event on node A, confirm it appears on node B within a bounded time window (document the observed latency).

**Pass condition:** event appears on B, unmodified, within the documented window.

**Status:** implemented and passing. Loopback round-trip is tens of milliseconds; see `docs/MERGE-SEMANTICS.md`.

### AT-1-2 — Reconnect after single-node offline **(CI, implemented — `sync-protocol/test/sync.test.js`)**

**Phase:** 1

**Steps:** disconnect node B, write several events on node A while B is offline, reconnect B.

**Pass condition:** all events written on A while B was offline appear on B after reconnect, in a consistent order, with no data loss.

**Status:** implemented and passing.

### AT-1-3 — Concurrent conflicting write (the hard case) **(CI, implemented — `sync-protocol/test/sync.test.js`)**

**Phase:** 1 — this is Phase 1's actual exit criteria (`CLAUDE.md` §5, Phase 1).

**Steps:** disconnect both nodes from each other. On each node, independently write to the *same logical field* (e.g. both set the same key to different values, or both append conflicting edits to the same structure). Reconnect both nodes.

**Pass condition:** the conflict resolves deterministically (both nodes converge to the identical resulting state) and losslessly (per Automerge/Yjs CRDT semantics — e.g. both values preserved in a way the app layer can surface, or a documented deterministic winner) with **no manual intervention**. Document the exact merge semantics observed in `docs/` alongside this test's result.

**Status:** implemented and passing, both for a same-key map write (`AT-1-3`) and a concurrent list append (`AT-1-3b`, added to cover the "nothing lost" case for the append-only event log specifically). Full writeup in `docs/MERGE-SEMANTICS.md`. AT-1-1 through AT-1-3 have also been re-run for real over an actual WireGuard tunnel between two separate network namespaces (`infra/wireguard-poc/run-demo.sh`), not just loopback — all passing. **Remaining caveat:** Headscale-mediated discovery and real network conditions (NAT, latency, packet loss, real hardware) are still unvalidated; see `docs/MERGE-SEMANTICS.md`'s "What's still not validated."

### AT-2-1 — Hub answers a question and logs it **(CI, implemented — `hub/scripts/hub-stack-demo.sh`)**

**Phase:** 2 exit criteria.

**Steps:** send a question to the hub over SSH/CLI.

**Pass condition:** the hub answers using the local model, and the interaction appears in the event log within 1 second.

**Status:** implemented and passing against the real running stack (real llama.cpp + real Qwen2 tokenizer + real MCP tool call, **synthetic random model weights** — see `hub/models/README.md` for why). Measured latency for a plain question is consistently under 1 second (typically 150–550ms in this environment). The MCP tool-call path (a `search:` question) is also exercised and answers correctly, but its measured latency (~1.1–1.4s, dominated by MCP subprocess startup) is reported rather than gated at 1 second — the stated exit criterion is about the baseline local-model answer, and `hub/README.md` explains the gap honestly rather than silently claiming it too.

### AT-2-2 — Survives network cable pull **(CI, implemented — `hub/scripts/hub-stack-demo.sh`)**

**Phase:** 2 exit criteria.

**Steps:** while the hub is running, physically disconnect (or simulate disconnecting) its network connection.

**Pass condition:** the hub process does not crash; local-only functionality continues to work.

**Status:** implemented and passing — the entire hub process (llama-server + agent + event log) runs inside a network namespace with no WAN route at all (not just a simulated cable pull on an already-running process), confirms an outbound call genuinely fails from that namespace, and confirms the hub still answers a question and logs it within 1 second regardless. This is the real replacement for AT-0-1's original placeholder, as that test's own note said it would be once Phase 2 existed.

### AT-3-1 — Dreaming pipeline: accumulated, decaying, auditable facts **(CI, implemented — `hub/scripts/dreaming-demo.sh`)**

**Phase:** 3 exit criteria (`CLAUDE.md` §5, Phase 3).

**Steps:** simulate a week of varied interactions (some facts mentioned repeatedly across days, one mentioned only once), running the nightly consolidation job once per simulated day. Ask "what do you know about me?" afterward.

**Pass condition:** the answer visibly reflects the accumulated, reinforced facts, each traceable back to the exact source interaction id(s) that produced it; a fact mentioned once and never reinforced loses active status (decays) after the configured threshold, but is never silently dropped — its pruning is itself logged with a reason, and the underlying record is retrievable.

**Status:** implemented and passing. Fact extraction is rule-based (regex over the user's own statements — see `hub/dreaming/README.md` for why, same reasoning as the agent loop's tool-call dispatch), but the storage/reinforcement/decay/audit mechanism is real: real Qdrant (embedded — Docker Hub is also blocked by this environment's network policy, so this runs `qdrant-client`'s embedded mode rather than a served instance), real embeddings from the hub's actual `llama-server` (semantically meaningless, since the underlying model is synthetic — same caveat as `hub/models/README.md` throughout), real reinforcement counting, and a real append-only audit log of every extract/reinforce/prune action. A real bug surfaced and fixed while building this: `consolidate.py` originally stamped every fact's "last reinforced" time with the *consolidation run's* clock instead of the *interaction's own* timestamp, which silently broke decay (see the comment in `hub/dreaming/consolidate.py`). QLoRA fine-tuning remains explicitly out of scope, per the plan — nothing here touches model weights.

### AT-4-1 — Offline for five questions, all reconcile within 60s **(CI, implemented — `pocket/scripts/pocket-demo.sh`)**

**Phase:** 4 exit criteria (`CLAUDE.md` §5, Phase 4).

**Steps:** put the phone in airplane mode, ask it five different questions, confirm the offline model answers all five, then reconnect.

**Pass condition:** the offline model answers all five reasonably; all five appear correctly ordered in the hub's event log within 60 seconds of reconnecting.

**Status:** implemented and passing, across repeated runs (observed sync time 3-4 seconds, well inside the 60s budget). "Airplane mode" is a real network namespace with no WAN route, not a simulated disconnect — same technique as AT-2-2. The offline answer is real (llama.cpp + the hub's synthetic-weight model — see `hub/models/README.md`; MLC LLM is the plan's stated target and is substituted here, per `pocket/README.md`). The queue is a real, unit-tested Kotlin/JVM module (`pocket/sync/`). The reconnect merge uses `sync-protocol/`'s already-proven Automerge `Peer` (Phase 1) rather than a real on-device CRDT binding — `pocket/README.md` explains exactly why that binding isn't built here. Synced events are also mirrored into the hub's real event log (`hub/memory/eventlog.py`), closing a gap between Phase 1's CRDT-log prototype and Phase 2's plain-SQLite hub log that had been open since Phase 2. **Not validated:** anything Android-specific — no build, no emulator (verified: the Android Gradle Plugin itself fails to resolve here, `dl.google.com` is blocked) — see `pocket/client/README.md`.

### AT-5-1 — No outbound calls outside the tunnel, instrumented **(CI, implemented — `infra/zero-internet/run-week.sh`)**

**Phase:** 5 security pass.

**Steps:** run the full hub+phone stack inside an instrumented network namespace that logs/fails any DNS or HTTP(S) attempt outside the WireGuard tunnel interface, under a realistic week-long simulated-use script.

**Pass condition:** zero unexpected outbound attempts logged. Any attempt fails the build.

**Status:** implemented and passing, across repeated runs. Both the hub and phone namespaces get an `iptables` OUTPUT lockdown (loopback and the WireGuard tunnel's own traffic only); a canary check first proves the lockdown actually catches a bypass attempt (a direct call to the peer's veth address, not through the tunnel) — before that fix, a naive canary against an unroutable public IP silently failed to trip the firewall at all (it failed at the routing stage, before ever reaching `iptables`), which would have made a "0 rejects" result meaningless. After the canary is confirmed working, a full simulated week of real hub/phone activity runs, and the counters are checked again — zero increase, both namespaces, every run.

### AT-5-2 — Sync layer load test: realistic conflict rates **(CI, implemented — `infra/zero-internet/run-week.sh`)**

**Phase:** 5 ("load-test the sync layer with realistic conflict rates").

**Steps:** with hub and phone both connected simultaneously (not offline-then-reconnect), fire 100 rapid writes to the *same* Automerge field — 50 from each side — and check convergence.

**Pass condition:** both peers converge on the identical final value, deterministically, with no crash or desync.

**Status:** implemented and passing. This is a genuinely different case from Phase 1's AT-1-3 (which tests two nodes disconnected, each writing once, then reconciling) — here both nodes are live and racing each other on the same field for the whole burst. Automerge's conflict-tracking only records the most recent concurrent pair once history moves on, so the meaningful assertion at this volume is convergence and stability, not enumerating every intermediate conflict (AT-1-3 already covers that at small scale).

### AT-5-3 — Full week, full integration **(CI, implemented — `infra/zero-internet/run-week.sh`)**

**Phase:** 5 ("run the full 'zero internet after initial setup' test end-to-end... for a full week of simulated real use").

**Steps:** 7 simulated days of hub local activity (Q&A, notes, mock smart-home) plus Phase 3's nightly consolidation, two phone offline/reconnect cycles over the real WireGuard tunnel, and the AT-5-2 load test — all with zero WAN route available to either side.

**Pass condition:** sustained operation across the week; interactions from both hub and phone end up in the hub's real event log.

**Status:** implemented and passing (11 interactions logged across the week in a representative run). "Voice" and "calendar" interaction slots are plain text/Q&A, not real voice transcription or a real calendar backend — see `infra/zero-internet/README.md`'s "What's honestly not exercised" for the complete list (also covers why "home automation" here is a real MCP tool call against a mock device, not a real Home Assistant integration).

### AT-6-1 — Device identity: non-extractable key, sign/verify, tamper rejection **(CI, implemented — `hub/identity/tpm-identity-demo.sh`)**

**Phase:** 6 ("Integrate the SE050 secure element for device identity").

**Steps:** stand up a real TPM 2.0 (swtpm), generate a persistent ECC signing key inside it, sign a device identity assertion, verify the signature, then verify a tampered copy of the assertion.

**Pass condition:** the identity key is generated and usable without ever being exported; the real signature verifies against the correct assertion; the tampered assertion is correctly rejected.

**Status:** implemented and passing (4/4 checks, reran clean twice). No SE050 hardware exists in this environment (or anywhere in this project's dev environment — see `docs/DECISIONS.md` D3), so this uses a software TPM (swtpm/libtpms) via the real `tpm2-tools` CLI as a disclosed stand-in, not the SE050's own API surface — `hub/identity/README.md` states this explicitly. What's real regardless of the specific chip: in-module key generation with no export path, and a real sign/verify/tamper-rejection cycle using the actual TPM 2.0 command set.

### AT-6-2 — Sandboxed tool runtime: gVisor + Wasmtime **(CI, implemented — `hub/sandbox/sandbox-demo.sh`)**

**Phase:** 6 ("Move the agent/tool runtime into gVisor or Firecracker sandboxing on the hub; Wasmtime for anything lightweight enough to run in-process").

**Steps:** run one of the hub's real MCP apps (`hub/apps/file-search/`) inside a gVisor (`runsc`) sandbox and confirm it both answers correctly and reports the sandbox's own fake kernel identity rather than the host's; write a canary file from inside the sandbox and confirm it's absent on the real host; run a real WebAssembly module through Wasmtime and confirm the correct result.

**Pass condition:** all four checks pass.

**Status:** implemented and passing (4/4 checks, reran clean twice). Uses `-platform=ptrace` rather than gVisor's default KVM platform — no `/dev/kvm` in this environment. Not Firecracker, for the same reason (`/dev/kvm` required). The WASM module is hand-written WAT, not compiled from a real hub component — no WASM toolchain is available here to do that compilation; `hub/sandbox/README.md` explains the gap.

### AT-6-3 — Update mechanism: real generations and rollback **(CI, implemented — `infra/update-mechanism/nix-rollback-demo.sh`)**

**Phase:** 6 ("Stand up the update mechanism per D2 (Nix generations, or OSTree/RAUC) and test a rollback from a deliberately broken update").

**Steps:** build and deploy two "hub config" generations via real Nix derivations and a real `nix-env --profile`; roll back from the broken one; separately confirm a build that fails outright never touches the active generation.

**Pass condition:** all five checks pass.

**Status:** implemented and passing (5/5 checks, reran clean twice), against a real `nix` installed in this session specifically to test Decision D2's chosen mechanism (see `infra/update-mechanism/README.md` for the non-trivial single-user-install group/user workaround this needed). Operates one level below a full bootable NixOS system switch — this environment is a container, not a NixOS host, and `hub/flake.nix` doesn't yet define a full `nixosConfigurations.<host>` output — so the "hub config" here is a toy derivation proving the generation/rollback primitive itself, not the full boot-time integration `nixos-rebuild switch --rollback` performs. This same real `nix` was also used to retroactively validate `hub/flake.nix` (`nix flake check` and a real devShell build both pass); see the updated header comment in that file.

### AT-6-4 — App distribution: real signing infra over a custom index **(CI, implemented — `infra/fdroid-repo/build-repo-demo.sh`)**

**Phase:** 6 ("Stand up the F-Droid repo (or Obtainium-compatible feed) for distributing 'App' (MCP integration) packages").

**Steps:** generate a real fdroidserver signing keystore; package real tarballs of the hub's actual MCP apps; build and sign an index over their real sha256 hashes; confirm a tampered copy of the signed index fails verification.

**Pass condition:** all five checks pass.

**Status:** implemented and passing (5/5 checks, reran clean twice). This is deliberately not a spec-compliant F-Droid or Obtainium index — both formats distribute signed Android APKs, and these "Apps" are Python MCP servers, not Android packages, so spec compliance would require misrepresenting what the packages are. A real placeholder-APK approach was tried and abandoned (verified, not assumed): no `android.jar` is available in this environment (`dl.google.com` blocked, apt's `android-sdk` ships build-tools/platform-tools only), confirmed by `aapt package` failing outright on manifest attribute resolution. `infra/fdroid-repo/README.md` covers the full reasoning, including a real bug found and fixed in the tampering negative-control itself (it originally tested a never-signed jar, not a tampered signed one).

### AT-6-5 — Modem/NPU isolation: functions with zero WAN, by construction **(CI, implemented — `infra/modem-isolation/isolation-test.sh`)**

**Phase:** 6 ("Isolate the modem/NPU firmware blobs behind their documented boundary; write the isolation test that proves the rest of the system functions with the modem physically switched off").

**Steps:** run AT-2-2, AT-4-1, and AT-5-1 as one gated check — each already proves, independently, that its component (hub, phone, hub+phone together) functions correctly inside a real network namespace with no WAN route at all.

**Pass condition:** all three underlying tests pass.

**Status:** implemented and passing. No modem or NPU hardware — or firmware blob — exists anywhere in this project's dev environment (Decision D3), so there is nothing to isolate a kill switch around, and no real kill-switch signal to read. What the deliverable actually needs proven — the rest of the system keeps working with the modem physically off — is exactly what those three already-real, already-CI-wired tests demonstrate via a real no-WAN network namespace, the honest software equivalent of a powered-off radio; building a fourth, separate no-WAN test would only duplicate them. What this does not and cannot prove: resilience against a *compromised* modem/NPU firmware blob attempting active exfiltration — that needs real hardware and a real isolation boundary to test adversarially, and `docs/THREAT-MODEL.md` already names this as an open, unsolved gap rather than overclaiming it.

---

**Changelog**

- v0.1 (2026-09-16): initial set — AT-0-1 (placeholder harness), AT-1-1..3, AT-2-1..2, AT-5-1 stubs for future phases.
- v0.2 (2026-09-16): AT-1-1, AT-1-2, AT-1-3(b) implemented and passing against `sync-protocol/`; wired into CI. See `docs/MERGE-SEMANTICS.md`.
- v0.3 (2026-09-16): AT-1-1..3 re-validated over a real WireGuard tunnel between two network namespaces (`infra/wireguard-poc/`), not just loopback.
- v0.4 (2026-09-16): AT-2-1 and AT-2-2 implemented and passing against `hub/scripts/hub-stack-demo.sh` (real llama.cpp + real Qwen2 tokenizer + synthetic weights — see `hub/models/README.md`); wired into CI. AT-2-2 fulfills AT-0-1's original placeholder note.
- v0.5 (2026-09-16): AT-3-1 implemented and passing against `hub/scripts/dreaming-demo.sh` (real Qdrant, embedded; real embeddings from the hub's own model; rule-based fact extraction — see `hub/dreaming/README.md`); wired into CI.
- v0.6 (2026-09-17): AT-4-1 implemented and passing against `pocket/scripts/pocket-demo.sh` (real airplane-mode network namespace, real Kotlin/JVM store-and-forward queue, real Automerge merge on reconnect via sync-protocol/'s Phase 1 Peer; hub/phone event-log gap closed — see `pocket/README.md`); wired into CI. No Android build or emulator — verified unavailable, not assumed.
- v0.7 (2026-09-17): AT-5-1..3 implemented and passing against `infra/zero-internet/run-week.sh` (real dual-namespace WireGuard tunnel with an instrumented, canary-verified egress lockdown; a 7-day simulated integration test covering two new real MCP apps — `hub/apps/notes/`, `hub/apps/smart-home/`; a 100-write concurrent-conflict load test); wired into CI.
- v0.8 (2026-09-17): AT-6-1..5 implemented and passing — AT-6-1 real TPM 2.0 (swtpm/tpm2-tools) device identity (`hub/identity/`); AT-6-2 real gVisor + Wasmtime sandboxing (`hub/sandbox/`); AT-6-3 real Nix generations/rollback (`infra/update-mechanism/`), which also retroactively validated `hub/flake.nix`; AT-6-4 real fdroidserver signing infra over a custom, explicitly-non-spec-compliant index (`infra/fdroid-repo/`); AT-6-5 modem/NPU isolation proven by gating on the three existing no-WAN tests (`infra/modem-isolation/`) rather than duplicating them, since no modem/NPU hardware exists in this environment. All wired into CI.
