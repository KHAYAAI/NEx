import * as Automerge from '@automerge/automerge';
import { multiaddr } from '@multiformats/multiaddr';
import { createNode } from './node.js';
import { EventLog } from './eventLog.js';
import { encodeFrame, FrameDecoder } from './framing.js';

export const SYNC_PROTOCOL = '/nex-sync/1.0.0';

// One prototype "node" from CLAUDE.md Phase 1: a libp2p identity plus an
// Automerge-backed event log, wired together by Automerge's own
// generate/receive sync-message protocol (the same wire protocol
// automerge-repo uses). Two Peers standing in for hub and phone.
export class Peer {
  #node;
  #log;
  #sessions = new Map(); // peerIdStr -> { stream, syncState, decoder }

  // `genesisDoc`: the shared document produced once during pairing
  // (see eventLog.js). Every real node clones it rather than creating
  // its own from scratch — omitting it is only for a standalone node
  // with nobody to pair with yet.
  constructor({ genesisDoc } = {}) {
    this.#log = new EventLog(genesisDoc && Automerge.clone(genesisDoc));
  }

  get log() {
    return this.#log;
  }

  get doc() {
    return this.#log.doc;
  }

  get peerId() {
    return this.#node.peerId;
  }

  async start(options = {}) {
    this.#node = await createNode(options);
    await this.#node.handle(SYNC_PROTOCOL, (stream, connection) => {
      this.#startSession(connection.remotePeer.toString(), stream);
    });
    return this;
  }

  async stop() {
    for (const peerIdStr of [...this.#sessions.keys()]) this.#endSession(peerIdStr);
    await this.#node.stop();
  }

  multiaddrs() {
    return this.#node.getMultiaddrs();
  }

  async connectTo(otherPeer) {
    const addrs = otherPeer.multiaddrs();
    if (addrs.length === 0) throw new Error('peer has no listen addresses');
    const stream = await this.#node.dialProtocol(addrs[0], SYNC_PROTOCOL);
    this.#startSession(otherPeer.peerId.toString(), stream);
  }

  // Same as connectTo, but for dialing a peer running in a different
  // process (e.g. across a real WireGuard tunnel) where there's no
  // in-process Peer object to call .multiaddrs() on — just the address
  // string it printed, e.g. "/ip4/10.99.0.1/tcp/4001/p2p/12D3Koo...".
  async connectToAddress(addrString) {
    const addr = multiaddr(addrString);
    const peerIdStr = addr.getComponents().find((c) => c.name === 'p2p')?.value;
    if (!peerIdStr) throw new Error(`multiaddr has no /p2p/<peerId> suffix: ${addrString}`);
    const stream = await this.#node.dialProtocol(addr, SYNC_PROTOCOL);
    this.#startSession(peerIdStr, stream);
    return peerIdStr;
  }

  disconnectFrom(otherPeer) {
    this.#endSession(otherPeer.peerId.toString());
  }

  isConnectedTo(otherPeer) {
    return this.#sessions.has(otherPeer.peerId.toString());
  }

  appendEvent(payload) {
    this.#log.appendEvent(payload);
    this.#pushToAllSessions();
  }

  setField(key, value) {
    this.#log.setField(key, value);
    this.#pushToAllSessions();
  }

  conflictsFor(key) {
    return this.#log.conflictsFor(key);
  }

  #pushToAllSessions() {
    for (const peerIdStr of this.#sessions.keys()) this.#trySync(peerIdStr);
  }

  #startSession(peerIdStr, stream) {
    if (this.#sessions.has(peerIdStr)) this.#endSession(peerIdStr);

    const session = { stream, syncState: Automerge.initSyncState(), decoder: new FrameDecoder() };
    this.#sessions.set(peerIdStr, session);

    (async () => {
      try {
        for await (const chunk of stream) {
          for (const frame of session.decoder.push(chunk.subarray())) {
            this.#receive(peerIdStr, frame);
          }
        }
      } catch {
        // Reset/abort surfaces here as a thrown or ended iteration; the
        // session is already torn down by disconnectFrom in that case, so
        // there's nothing left to clean up.
      }
    })();

    // Kick off the exchange immediately — Automerge's sync protocol is
    // request/response-free: each side just offers what it has and reacts
    // to what the other side is missing, so either party speaking first
    // is fine.
    this.#trySync(peerIdStr);
  }

  #endSession(peerIdStr) {
    const session = this.#sessions.get(peerIdStr);
    if (!session) return;
    this.#sessions.delete(peerIdStr);
    session.stream.abort(new Error('disconnected'));
  }

  #receive(peerIdStr, message) {
    const session = this.#sessions.get(peerIdStr);
    if (!session) return;
    const [nextDoc, nextSyncState] = Automerge.receiveSyncMessage(
      this.#log.doc,
      session.syncState,
      message,
    );
    this.#log.doc = nextDoc;
    session.syncState = nextSyncState;
    this.#trySync(peerIdStr);
    // Gossip whatever we just learned to any other connected peer too —
    // irrelevant for a two-node test but keeps this mesh-ready per
    // CLAUDE.md Phase 7.
    for (const otherPeerIdStr of this.#sessions.keys()) {
      if (otherPeerIdStr !== peerIdStr) this.#trySync(otherPeerIdStr);
    }
  }

  #trySync(peerIdStr) {
    const session = this.#sessions.get(peerIdStr);
    if (!session) return;
    const [nextSyncState, message] = Automerge.generateSyncMessage(
      this.#log.doc,
      session.syncState,
    );
    session.syncState = nextSyncState;
    if (message) session.stream.send(encodeFrame(message));
  }
}
