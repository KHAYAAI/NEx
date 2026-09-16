# Headscale control plane (Phase 1)

Self-hosted Headscale instance acting as the WireGuard mesh control plane for hub↔phone (and later hub↔hub) peer discovery and key exchange, per `CLAUDE.md` §5 Phase 1 and §2's architecture diagram.

**Status: config only, Headscale itself not yet stood up or tested.** This directory documents the intended deployment so Phase 1's transport-layer work is reviewable. Note the scope: `infra/wireguard-poc/run-demo.sh` has validated that the CRDT sync prototype works correctly over a real WireGuard tunnel (see `docs/MERGE-SEMANTICS.md`), but that tunnel's peers are configured statically — known keys, known endpoints, no Headscale involved. What's still unvalidated here specifically is Headscale's own role: dynamic peer discovery and key exchange so hub and phone don't need to be manually configured with each other's keys/addresses. Do not cite this config as proof that part works; it isn't, yet.

## What this is for

Headscale is a self-hosted, open-source re-implementation of Tailscale's control plane. It doesn't carry any user traffic itself — it only helps two WireGuard peers (hub, phone) discover each other's current address and exchange the public keys needed to establish a direct WireGuard tunnel. Once that tunnel is up, Headscale is out of the path; hub↔phone traffic (including the `sync-protocol` CRDT exchange) flows directly, peer-to-peer, encrypted.

This matters for the "no cloud calls" principle (Decision D1, `docs/DECISIONS.md`): Headscale is self-hosted (on the hub itself, or on infrastructure the user controls), so there's no third-party operator with visibility into when hub and phone talk to each other, unlike using Tailscale's own hosted control plane.

## Files

- `docker-compose.yml` — runs `headscale` in a container, bind-mounting `config.yaml` and a data volume for its SQLite state.
- `config.yaml` — minimal Headscale server config for a single-user, two-node (hub + phone) mesh.

## Bringing it up (once there's real hardware to test against)

```sh
cd infra/headscale
docker compose up -d
docker compose exec headscale headscale users create nex-household
docker compose exec headscale headscale preauthkeys create --user nex-household --reusable --expiration 24h
```

Use the printed pre-auth key with `tailscale up --login-server https://<hub-address>:8080 --authkey <key>` on both the hub and the phone (Tailscale's client is protocol-compatible with a Headscale server). Once both show as connected peers (`headscale nodes list`), the hub and phone have a WireGuard tunnel between them and `sync-protocol`'s libp2p nodes can be pointed at each other's tunnel-interface addresses instead of loopback.

## Known gaps before this is Phase-1-complete

- No TLS termination configured for Headscale's own control-plane API (`config.yaml` runs it over HTTP for local dev only) — needs a reverse proxy with a real or self-signed cert before any non-loopback use.
- No ACL policy has been written yet (Headscale defaults to allowing all mesh members to reach each other, which is fine for a single hub+phone pair but should be tightened before a multi-hub mesh, per Phase 7).
- Not yet tested through a real NAT (home hub behind a residential router, phone on cellular) — Headscale/Tailscale's NAT traversal (DERP relay fallback) is a well-established feature of the upstream project, but it hasn't been exercised here.
