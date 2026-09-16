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

**Current status (Phase 0):** no hub stack exists yet. The CI job for this phase runs a placeholder that asserts the network-namespace harness itself works (i.e. that a job run inside it correctly has no WAN access), so the harness is proven before there's a real service to test. This gets replaced with the real test the moment Phase 2 has a running hub process.

### AT-1-1 — CRDT reconciliation, both nodes online

**Phase:** 1 (sync protocol prototype)

**Steps:** with both prototype nodes connected over the Phase 1 sync layer, write an event on node A, confirm it appears on node B within a bounded time window (document the observed latency).

**Pass condition:** event appears on B, unmodified, within the documented window.

### AT-1-2 — Reconnect after single-node offline

**Phase:** 1

**Steps:** disconnect node B, write several events on node A while B is offline, reconnect B.

**Pass condition:** all events written on A while B was offline appear on B after reconnect, in a consistent order, with no data loss.

### AT-1-3 — Concurrent conflicting write (the hard case)

**Phase:** 1 — this is Phase 1's actual exit criteria (`CLAUDE.md` §5, Phase 1).

**Steps:** disconnect both nodes from each other. On each node, independently write to the *same logical field* (e.g. both set the same key to different values, or both append conflicting edits to the same structure). Reconnect both nodes.

**Pass condition:** the conflict resolves deterministically (both nodes converge to the identical resulting state) and losslessly (per Automerge/Yjs CRDT semantics — e.g. both values preserved in a way the app layer can surface, or a documented deterministic winner) with **no manual intervention**. Document the exact merge semantics observed in `docs/` alongside this test's result.

### AT-2-1 — Hub answers a question and logs it **(CI, from Phase 2)**

**Phase:** 2 exit criteria.

**Steps:** send a question to the hub over SSH/CLI.

**Pass condition:** the hub answers using the local model, and the interaction appears in the event log within 1 second.

### AT-2-2 — Survives network cable pull

**Phase:** 2 exit criteria.

**Steps:** while the hub is running, physically disconnect (or simulate disconnecting) its network connection.

**Pass condition:** the hub process does not crash; local-only functionality continues to work.

### AT-5-1 — No outbound calls outside the tunnel, instrumented **(CI, from Phase 5)**

**Phase:** 5 security pass.

**Steps:** run the full hub+phone stack inside an instrumented network namespace that logs/fails any DNS or HTTP(S) attempt outside the WireGuard tunnel interface, under a realistic week-long simulated-use script.

**Pass condition:** zero unexpected outbound attempts logged. Any attempt fails the build.

---

**Changelog**

- v0.1 (2026-09-16): initial set — AT-0-1 (placeholder harness), AT-1-1..3, AT-2-1..2, AT-5-1 stubs for future phases.
