# WireGuard transport validation (Phase 1)

Closes the gap `docs/MERGE-SEMANTICS.md` used to flag under "What's not yet validated": `sync-protocol/`'s CRDT sync test matrix (AT-1-1, AT-1-2, AT-1-3 — `docs/ACCEPTANCE-TESTS.md`) running over a real WireGuard tunnel between two genuinely separate Linux network namespaces, instead of loopback.

## What `run-demo.sh` actually does

1. Creates two real network namespaces (`nex-hub`, `nex-phone`), linked only by a plain veth pair — standing in for "the internet" between a hub and a phone. No traffic can cross between them except through what gets explicitly routed.
2. Generates a fresh WireGuard keypair for each side and brings up a real WireGuard tunnel over that link, using [`wireguard-go`](https://git.zx2c4.com/wireguard-go/) (the userspace implementation — this environment has no kernel WireGuard module, but the protocol and the resulting tunnel are identical from every layer above it). Confirms a real handshake completed and the overlay actually carries traffic (`wg show ... latest-handshakes`, then a ping across the WireGuard addresses).
3. Runs `sync-protocol/scripts/wg-node.mjs` as separate OS processes — hub's process runs inside `nex-hub`, phone's inside `nex-phone` — bound to their namespace's WireGuard overlay address. Neither process can reach the other except through the tunnel.
4. Re-runs the Phase 1 exit-criteria scenarios across that real tunnel:
   - **AT-1-1** — hub appends an event while both are up; phone receives it.
   - **AT-1-2** — phone's process isn't running at all (not just disconnected — actually offline); hub appends more events; phone's process starts, reconnects over the tunnel, and catches up.
   - **AT-1-3** — both processes exit; each independently sets the same field to a different value entirely offline; both restart and reconnect over the tunnel; `sync-protocol/scripts/verify-convergence.mjs` checks the two saved documents converged to the identical value and that neither write was lost (both remain visible via Automerge's conflicts API).

## Running it

```sh
sudo infra/wireguard-poc/run-demo.sh
```

Requires root (network namespace and WireGuard interface creation), `ip`/`wg` (`apt install iproute2 wireguard-tools`), `wireguard-go` on `$PATH` (build with `go install` from [WireGuard/wireguard-go](https://github.com/WireGuard/wireguard-go) if there's no kernel module — see the script's header comment), and Node 20+. It's self-cleaning (removes its namespaces/interfaces on exit, including on failure) and safe to re-run.

## What this does and doesn't prove

**Proves:** the CRDT sync layer works correctly when carried over an actual encrypted WireGuard tunnel between two separate network stacks — not just over loopback inside one process's address space. This was the concrete, checkable gap between "the moat works in principle" and "the moat works on the real transport," called out explicitly in `docs/MERGE-SEMANTICS.md`.

**Doesn't prove:**
- **Headscale-mediated discovery.** This script configures both sides' WireGuard peers statically (keys and endpoints known in advance). `infra/headscale/` documents the intended control-plane for dynamic peer discovery/key exchange in the real product — that integration is still unbuilt and untested.
- **Real network conditions.** The veth link between the two namespaces is effectively perfect — no latency, no packet loss, no NAT. A real hub behind a home router and a phone on cellular will see all three, and Phase 5's load test is where that gets exercised.
- **Real hardware.** Both "nodes" are processes on the same physical machine, in different network namespaces. This is a legitimate, standard technique for testing network-layer code without needing two physical hosts (the namespaces are genuinely separate network stacks — routing tables, interfaces, sockets — sharing only the kernel and filesystem), but it's still one machine.
