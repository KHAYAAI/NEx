import { createLibp2p } from 'libp2p';
import { tcp } from '@libp2p/tcp';
import { noise } from '@chainsafe/libp2p-noise';
import { yamux } from '@chainsafe/libp2p-yamux';
import { identify } from '@libp2p/identify';

// Builds one libp2p node: TCP transport, Noise for encryption + peer
// authentication, Yamux for stream multiplexing. In production this
// rides *inside* a WireGuard tunnel set up via Headscale (see
// infra/headscale/) — WireGuard secures the network path between the
// hub and phone, Noise here secures and authenticates the libp2p
// session itself, and libp2p's stream multiplexing is what lets many
// independent protocols (this sync protocol among them) share one
// connection. Two independent encryption layers is intentional
// defense-in-depth, not redundancy to strip out later.
export async function createNode({ listenAddresses = ['/ip4/127.0.0.1/tcp/0'] } = {}) {
  return createLibp2p({
    addresses: { listen: listenAddresses },
    transports: [tcp()],
    connectionEncrypters: [noise()],
    streamMuxers: [yamux()],
    services: { identify: identify() },
    connectionManager: {
      // Prototype runs many dial/hangup cycles per test; don't let the
      // default minute-scale dial timeout slow the suite down.
      dialTimeout: 5_000,
    },
  });
}
