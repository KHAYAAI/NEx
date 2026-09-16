# sync-protocol

Phase 1 sync prototype (`CLAUDE.md` §5, Phase 1): two nodes syncing an Automerge event log over an encrypted libp2p transport, with no server in the middle. This is the CRDT-correctness layer — see `infra/headscale/` for the WireGuard/Headscale transport wrapping, which is documented but not yet integrated with this prototype (loopback stands in for the tunnel today; see `docs/MERGE-SEMANTICS.md`).

## Layout

- `src/eventLog.js` — the synced document: an Automerge doc with an append-only `events` list and a `fields` map (the latter used to exercise same-key concurrent-write conflicts).
- `src/node.js` — libp2p node factory (TCP + Noise encryption + Yamux multiplexing).
- `src/framing.js` — length-prefixed framing for Automerge sync messages over a libp2p stream.
- `src/peer.js` — `Peer`: ties a libp2p identity to an `EventLog` and runs Automerge's generate/receive sync-message protocol over `/nex-sync/1.0.0`.
- `test/sync.test.js` — the Phase 1 exit-criteria test matrix (IDs match `docs/ACCEPTANCE-TESTS.md`): both-online sync, offline-then-reconnect, and the concurrent-conflicting-write case.

## Running

```sh
npm install
npm test
```

## Usage sketch

```js
import { Peer } from './src/peer.js';
import { createGenesisDoc } from './src/eventLog.js';

// Real nodes are paired once during setup and share a starting
// document from that point on — see docs/MERGE-SEMANTICS.md for why
// this isn't optional.
const genesisDoc = createGenesisDoc();
const hub = await new Peer({ genesisDoc }).start();
const phone = await new Peer({ genesisDoc }).start();

await hub.connectTo(phone);
hub.appendEvent({ text: 'hello from the hub' });
// phone.log.events will contain it shortly after.
```
