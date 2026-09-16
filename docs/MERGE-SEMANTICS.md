# CRDT Merge Semantics — Phase 1 Sync Prototype

Observed and documented per `CLAUDE.md` Phase 1's exit criteria: "a 3-way conflict resolves deterministically and losslessly on reconnect, with no manual intervention. Document the merge semantics in `docs/`." This records what the prototype in `sync-protocol/` actually does, verified by `sync-protocol/test/sync.test.js` (test IDs cross-reference `docs/ACCEPTANCE-TESTS.md`).

## What was built

Two prototype nodes (`sync-protocol/src/peer.js`), each an Automerge document wrapped in a libp2p identity. Wire protocol is Automerge's own generate/receive sync-message exchange (the same one `automerge-repo` uses), carried over a libp2p stream (TCP + Noise encryption + Yamux multiplexing — see `sync-protocol/src/node.js`). Automerge sync messages are framed with a 4-byte length prefix (`sync-protocol/src/framing.js`) since libp2p's `Stream` interface doesn't guarantee message boundaries survive the underlying muxer.

This proves the CRDT sync layer itself. It does not yet run inside a real WireGuard tunnel with Headscale-mediated discovery across two physical machines — see "What's not yet validated" below.

## Pairing precondition

Two nodes must share a common genesis document (`sync-protocol/src/eventLog.js`'s `createGenesisDoc`, cloned per node) before they can usefully diverge and reconcile. This isn't an implementation shortcut — it mirrors the real architecture: a hub and phone are paired once during setup (that pairing is exactly where they'd agree on a shared starting document), not spontaneously generated with independent histories. Two Automerge documents built independently from scratch (`Automerge.from(...)` called twice) do **not** merge the way a single shared document diverging and reconverging does — each independent creation gives the same-named nested object (e.g. `fields`) a different underlying object identity, so a later "conflict" on, say, `fields.mode` actually becomes a conflict on the parent `fields` key itself, and the loser's data becomes unreachable via normal property access (still present in history, just not what `docs/THREAT-MODEL.md`'s "auditable" and "lossless" claims should be resting on). The prototype's test suite pairs nodes via a shared genesis for this reason, and any real hub/phone pairing flow (Phase 2+) needs to do the same at first-contact time.

## Observed semantics, by test

### AT-1-1 — both nodes online

An event appended on one node's list arrives at the other, unmodified, well within the sync-message round-trip latency (loopback TCP: low tens of milliseconds in practice, dominated by the libp2p stream handshake rather than the Automerge payload).

### AT-1-2 — one node offline, then reconnects

Events written while a peer is offline are queued only in the sense that they simply exist in the writer's local document; there is no explicit outbox. On reconnect, a fresh sync session (fresh `Automerge.initSyncState()` on both sides — the prior session's state is discarded, not resumed) runs Automerge's bloom-filter-based diff exchange and the reconnecting node receives every change it's missing, in the same order the writer created them (Automerge's list CRDT preserves insertion order per actor, and there was only one writing actor here, so this case doesn't yet exercise interleaving — see AT-1-3b for that).

### AT-1-3 — concurrent write to the same map key (the hard case)

Both nodes, disconnected from each other, set the same key (`fields.mode`) to different values. On reconnect:

- **Deterministic:** both nodes converge on the *identical* winning value for a plain read (`doc.fields.mode`). Automerge's map conflict resolution is deterministic given the same set of operations — it isn't last-write-wins by wall-clock time (which would be non-deterministic across nodes with clock skew) but a stable tie-break over each operation's Lamport timestamp and actor ID. No manual merge step is involved anywhere in this path.
- **Lossless:** the losing write is not discarded. `Automerge.getConflicts(doc.fields, 'mode')` returns *both* values, keyed by the operation ID (`counter@actorId`) that produced each, identically on both nodes after reconnect. An application layer that cares (unlike this prototype's plain `.mode` read) can surface the conflict to a user or apply its own resolution policy instead of silently trusting the CRDT's tie-break.

This is the exit criterion. It passes without any human intervention, code path, or retry — the two nodes disconnect, write independently, reconnect, and converge.

### AT-1-3b — concurrent list appends

Both nodes append a *different* event to the shared list while disconnected. Unlike the map case, list concurrent-insert isn't a "conflict" Automerge surfaces via `getConflicts` — both insertions are kept (nothing is lost), and Automerge's list CRDT gives both nodes the identical resulting order after merge (verified by comparing the two nodes' `events` id arrays directly, not just their lengths).

## Real WireGuard transport — validated

`infra/wireguard-poc/run-demo.sh` re-runs AT-1-1, AT-1-2, and AT-1-3 across a real WireGuard tunnel between two separate Linux network namespaces (not loopback, not libp2p's Noise encryption standing in for it — an actual WireGuard handshake and tunnel, built with `wireguard-go` since this environment has no kernel WireGuard module). All three passed. See `infra/wireguard-poc/README.md` for exactly what that does and doesn't prove — in short, it proves the CRDT layer survives a real encrypted tunnel between genuinely separate network stacks; it does not yet prove Headscale-mediated discovery or real-world network conditions (NAT, latency, packet loss), which remain open below.

## What's still not validated

- **Headscale-mediated discovery.** `infra/headscale/` documents the intended control-plane config; it has not been stood up and used to establish the connection nodes then ride on top of. `infra/wireguard-poc/run-demo.sh` configures WireGuard peers statically (keys and endpoints known in advance) rather than through Headscale.
- **NAT traversal / real network conditions.** The WireGuard tunnel validated above runs over a veth link between two namespaces on one machine — effectively zero latency, zero packet loss, no NAT. A real home hub behind a residential router and a phone on cellular will see all three, and Phase 5's load test is where that gets exercised.
- **Real hardware.** Both "nodes" in every scenario above, WireGuard-tunneled or not, are processes on the same physical machine. Two genuinely separate network namespaces is a legitimate, standard technique for testing network-layer code honestly, but it isn't two physical hosts.
- **Larger-scale conflict load.** The test matrix uses a handful of writes. Phase 5's "load-test the sync layer with realistic conflict rates" is explicitly future work, not covered here.

None of the above change the CRDT correctness result — Automerge's merge semantics don't depend on the transport underneath them, and that's now been shown true for a real encrypted tunnel, not just asserted. What's left is Headscale integration and real-hardware/real-network validation, which is Phase 2+ territory (the hub and phone don't exist as real devices yet) rather than something further loopback or namespace testing can close.
