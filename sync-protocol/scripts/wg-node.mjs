#!/usr/bin/env node
// Drives one sync-protocol Peer as a standalone process, so it can be run
// inside a real network namespace (e.g. `ip netns exec nex-hub node
// wg-node.mjs ...`) and dial a peer over a real transport — a real
// WireGuard tunnel, not loopback. See infra/wireguard-poc/ for the
// orchestration script that stands up two namespaces, a WireGuard tunnel
// between them, and runs a hub/phone pair of this script across it.
//
// The doc is persisted to --doc-file between runs (Automerge.save/load)
// so a process can exit ("go offline"), and a later run of this same
// script picks up exactly where it left off — that's how the offline/
// reconnect and conflict scenarios get exercised across real process
// boundaries instead of just in-memory.
import fs from 'node:fs';
import * as Automerge from '@automerge/automerge';
import { Peer } from '../src/peer.js';
import { createGenesisDoc } from '../src/eventLog.js';

function parseArgs(argv) {
  const args = { appends: [], sets: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case '--listen': args.listen = next(); break;
      case '--connect': args.connect = next(); break;
      case '--doc-file': args.docFile = next(); break;
      case '--genesis': args.genesis = true; break;
      case '--append': args.appends.push(next()); break;
      case '--set': args.sets.push(next()); break; // key=value
      case '--wait-events': args.waitEvents = Number(next()); break;
      case '--wait-field': args.waitField = next(); break; // key=value
      case '--hold-ms': args.holdMs = Number(next()); break;
      case '--label': args.label = next(); break;
      case '--timeout-ms': args.timeoutMs = Number(next()); break;
      case '--print-multiaddrs-only': args.printMultiaddrsOnly = true; break;
      default: throw new Error(`unknown arg ${a}`);
    }
  }
  return args;
}

function log(label, ...rest) {
  console.log(`[${label}] ${new Date().toISOString()}`, ...rest);
}

async function waitFor(predicate, timeout) {
  const deadline = Date.now() + timeout;
  for (;;) {
    if (await predicate()) return;
    if (Date.now() > deadline) throw new Error('timed out waiting for condition');
    await new Promise((r) => setTimeout(r, 50));
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const label = args.label ?? 'node';
  const timeoutMs = args.timeoutMs ?? 15000;

  let genesisDoc;
  if (args.docFile && fs.existsSync(args.docFile)) {
    genesisDoc = Automerge.load(fs.readFileSync(args.docFile));
    log(label, `loaded existing doc from ${args.docFile}`);
  } else if (args.genesis) {
    genesisDoc = createGenesisDoc();
    log(label, 'created fresh genesis doc');
  } else {
    throw new Error('need --genesis (first run) or an existing --doc-file to load');
  }

  const peer = new Peer({ genesisDoc });
  await peer.start(args.listen ? { listenAddresses: [args.listen] } : {});

  log(label, 'peerId', peer.peerId.toString());
  const addrs = peer.multiaddrs().map(String);
  log(label, 'listening on', JSON.stringify(addrs));

  if (args.printMultiaddrsOnly) {
    // Caller just wants this process's dialable address printed to
    // stdout in a stable, greppable form, then it keeps running.
    console.log(`MULTIADDR ${addrs[0]}`);
  }

  // Everything below can fail partway through (a dial that times out, a
  // --wait-* condition that never becomes true) without meaning the run
  // was worthless — whatever got synced before the failure is still real
  // progress. Save it and report final state regardless; only decide the
  // process's exit code afterward. Losing an already-synced doc to an
  // unrelated timeout further down is exactly the kind of bug that would
  // make a caller mistake "we didn't wait long enough" for "sync doesn't
  // work" — see infra/wireguard-poc/run-demo.sh's AT-1-3 step, which hit
  // this for real before the fix.
  let runError = null;
  try {
    if (args.connect) {
      log(label, 'dialing', args.connect);
      await peer.connectToAddress(args.connect);
      log(label, 'dial complete (protocol negotiated)');
    }

    for (const s of args.sets) {
      const [k, v] = s.split('=');
      peer.setField(k, v);
      log(label, 'setField', k, '=', v);
    }
    for (const text of args.appends) {
      peer.appendEvent({ text });
      log(label, 'appendEvent', text);
    }

    if (args.waitEvents != null) {
      await waitFor(() => peer.log.events.length >= args.waitEvents, timeoutMs);
      log(
        label,
        `events.length >= ${args.waitEvents} satisfied:`,
        JSON.stringify(peer.log.events.map((e) => e.text)),
      );
    }

    if (args.waitField) {
      const [k, v] = args.waitField.split('=');
      await waitFor(() => peer.log.fields[k] === v, timeoutMs);
      log(label, `fields.${k} === ${v} satisfied`);
    }

    if (args.holdMs) {
      log(label, `holding open for ${args.holdMs}ms`);
      await new Promise((r) => setTimeout(r, args.holdMs));
    }
  } catch (err) {
    runError = err;
    log(label, 'WARNING: a wait condition did not complete:', err.message);
  }

  if (args.docFile) {
    fs.writeFileSync(args.docFile, Automerge.save(peer.doc));
    log(label, 'saved doc to', args.docFile);
  }

  log(label, 'final fields', JSON.stringify(peer.log.fields));
  log(label, 'final events', JSON.stringify(peer.log.events.map((e) => e.text)));
  const conflicts = {};
  for (const key of Object.keys(peer.log.fields)) {
    const c = peer.conflictsFor(key);
    if (c && Object.keys(c).length > 1) conflicts[key] = c;
  }
  if (Object.keys(conflicts).length > 0) {
    log(label, 'field conflicts', JSON.stringify(conflicts));
  }

  await peer.stop();
  if (runError) {
    log(label, 'exiting non-zero because of the warning above (doc was still saved)');
    process.exit(1);
  }
  process.exit(0);
}

main().catch((err) => {
  console.error('[fatal]', err);
  process.exit(1);
});
