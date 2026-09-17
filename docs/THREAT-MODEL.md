# NEx Threat Model

This document states honestly what NEx protects against and what it explicitly does not attempt to protect against. Overstating guarantees is the single fastest way to lose user trust in a privacy product — a lesson worth taking seriously from prior failures in this space (privacy products that made claims their architecture couldn't back up, then lost credibility the moment that gap surfaced publicly). Every claim below must be re-read before any public-facing statement about NEx's security or privacy properties, and none of them should be quoted out of the "in scope" / "out of scope" pairing that gives them their actual meaning.

## Scope of this document

This covers the hub↔pocket two-node consumer architecture described in `CLAUDE.md`. It does not cover the tactical/defense line (NEx OS, NEx Eye) — that gets its own threat model once that line has its own architecture to model.

## What NEx protects against (in scope)

- **Cloud data extraction.** Per Decision D1, no user data — queries, memory, event log contents, model inputs/outputs — leaves the hub↔phone pair to any third-party cloud service. There is no vendor with standing access to your data, because there is no vendor in the data path at all. As of Phase 5, this is checked, not just asserted: `infra/zero-internet/run-week.sh` locks both nodes' egress to loopback and the WireGuard tunnel only, proves that lockdown actually catches a bypass attempt (a canary check, not just an absence of failures), then runs a full simulated week of real activity and confirms zero violations. That's one CI run's worth of evidence on synthetic hardware, not a standing guarantee about every future build — see `infra/zero-internet/README.md` for exactly what it does and doesn't cover.
- **Behavioral telemetry.** No usage analytics, crash reporting, or "anonymous" usage metrics are transmitted off-device. Any local metrics (e.g. Prometheus/Grafana per Phase 6) stay on the hub's LAN and are never exported.
- **Unencrypted sync interception.** All hub↔phone traffic is end-to-end encrypted (WireGuard transport, Automerge/Yjs CRDT payloads) — a network observer between the two nodes, including whoever operates the WiFi/LAN they're on, sees only encrypted tunnel traffic, not plaintext memory or conversation content.
- **Vendor lock-in / forced obsolescence.** All user-facing software is open source and the hardware is designed to be auditable down to the schematic. A NEx unit is not bricked or degraded by a vendor decision, because there's no vendor-controlled backend it depends on to keep functioning.
- **Silent, unaccountable personalization.** The "dreaming" consolidation pipeline (Phase 3) writes traceable, source-linked facts, and prunes them with a logged decay — not a black-box weight update a user can't audit or roll back.

## What NEx does not attempt to protect against (explicitly out of scope)

- **Physical device seizure.** If someone has physical possession of the hub or phone and the time/tools to attack it directly (cold-boot attacks, chip-off extraction, evil-maid firmware tampering), NEx v0 does not defend against that. Phase 6's SE050 secure element and full-disk encryption raise the bar but do not make physical seizure a solved problem — treat this as risk-reduction, not a guarantee, until it's actually been red-teamed.
- **Supply-chain / firmware compromise.** The modem and NPU firmware blobs are closed and are isolated behind a documented boundary (never trusted with plaintext user data), but NEx does not verify or attest to the integrity of that firmware itself, and cannot detect a compromise injected upstream of NEx's own build (e.g. at the chip vendor). This is a known, named gap, not a solved one.
- **A compromised or malicious "App" (MCP integration).** Phase 6's sandboxing (gVisor/Firecracker/Wasmtime) limits blast radius, but a malicious or buggy MCP server can still misuse whatever tool permissions the user explicitly granted it. NEx does not currently attempt static/behavioral vetting of third-party Apps beyond the F-Droid-style distribution channel's own review process.
- **Coercion of the user.** No technical design defends against a user being compelled (legally or otherwise) to unlock their own device and hand over data. This is an acknowledged limit of on-device architectures generally, not something NEx claims to solve.
- **Side-channel and traffic-analysis attacks.** Someone observing encrypted WireGuard traffic patterns (timing, packet size, frequency) between hub and phone could plausibly infer *that* interaction is happening and roughly *when*, even without reading contents. NEx v0 does not attempt traffic obfuscation against this.
- **Denial of service against the hub or phone.** Availability is not a security property NEx makes claims about in v0 — a determined local attacker who can access the hub's LAN or the phone's radio can degrade or interrupt service.

## Working principle for future claims

Any public statement about what NEx protects should name the specific mechanism (encryption, no-cloud-path, open source, traceable memory) and should be checkable against this document. If a claim can't be traced to a specific line above, it doesn't get made until this document is updated first — updating the threat model is not paperwork, it's the thing that keeps the claims honest.
