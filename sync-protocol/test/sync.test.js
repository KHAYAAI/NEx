import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import * as Automerge from '@automerge/automerge';
import { Peer } from '../src/peer.js';
import { createGenesisDoc } from '../src/eventLog.js';
import { waitFor } from './helpers.js';

// This suite is Phase 1's exit criteria from CLAUDE.md: prove the CRDT
// sync layer handles the online case, the reconnect-after-offline case,
// and — the actual hard case — a concurrent conflicting write on both
// nodes while disconnected, resolving deterministically and losslessly
// on reconnect with no manual intervention. IDs below (AT-1-1, AT-1-2,
// AT-1-3) match docs/ACCEPTANCE-TESTS.md.

describe('Phase 1 sync protocol prototype', () => {
  let a;
  let b;

  beforeEach(async () => {
    // Models the one-time pairing step from CLAUDE.md's architecture:
    // hub and phone agree on a shared starting document before either
    // one is ever allowed to go offline and diverge.
    const genesisDoc = createGenesisDoc();
    a = await new Peer({ genesisDoc }).start();
    b = await new Peer({ genesisDoc }).start();
  });

  afterEach(async () => {
    await a.stop();
    await b.stop();
  });

  test('AT-1-1: both nodes online — a write on A appears on B', async () => {
    await a.connectTo(b);

    a.appendEvent({ text: 'hello from A' });

    await waitFor(() => b.log.events.length === 1);
    assert.equal(b.log.events[0].text, 'hello from A');
    assert.equal(b.log.events[0].id, a.log.events[0].id);
  });

  test('AT-1-2: node B goes offline, A writes, B catches up on reconnect', async () => {
    await a.connectTo(b);
    await waitFor(() => b.isConnectedTo(a));

    b.disconnectFrom(a);
    assert.equal(b.isConnectedTo(a), false);

    a.appendEvent({ text: 'first' });
    a.appendEvent({ text: 'second' });
    a.appendEvent({ text: 'third' });

    // Confirm they really didn't arrive while offline.
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(b.log.events.length, 0);

    await b.connectTo(a);

    await waitFor(() => b.log.events.length === 3);
    assert.deepEqual(
      b.log.events.map((e) => e.text),
      ['first', 'second', 'third'],
    );
    assert.deepEqual(
      b.log.events.map((e) => e.id),
      a.log.events.map((e) => e.id),
    );
  });

  test('AT-1-3: concurrent conflicting map write resolves deterministically and losslessly', async () => {
    await a.connectTo(b);
    await waitFor(() => b.isConnectedTo(a));

    a.disconnectFrom(b);
    b.disconnectFrom(a);

    // Both nodes write to the *same logical field* while fully disconnected
    // from each other — the actual hard case (CLAUDE.md Phase 1 exit
    // criteria / docs/ACCEPTANCE-TESTS.md AT-1-3).
    a.setField('mode', 'A-wins-mode');
    b.setField('mode', 'B-wins-mode');

    await a.connectTo(b);

    await waitFor(() => {
      const aDoc = a.log.fields;
      const bDoc = b.log.fields;
      return aDoc.mode !== undefined && aDoc.mode === bDoc.mode;
    });

    // Deterministic: both nodes converge on the identical winner, with no
    // human/manual conflict resolution step.
    assert.equal(a.log.fields.mode, b.log.fields.mode);

    // Lossless: Automerge doesn't silently drop the losing write — both
    // original values are still recoverable via the conflicts API on both
    // nodes, identically.
    const conflictsOnA = a.conflictsFor('mode');
    const conflictsOnB = b.conflictsFor('mode');
    const valuesOnA = new Set(Object.values(conflictsOnA));
    const valuesOnB = new Set(Object.values(conflictsOnB));
    assert.deepEqual(valuesOnA, new Set(['A-wins-mode', 'B-wins-mode']));
    assert.deepEqual(valuesOnB, new Set(['A-wins-mode', 'B-wins-mode']));
  });

  test('AT-1-3b: concurrent list appends (both nodes write while disconnected) lose nothing', async () => {
    await a.connectTo(b);
    await waitFor(() => b.isConnectedTo(a));

    a.disconnectFrom(b);
    b.disconnectFrom(a);

    a.appendEvent({ text: 'from A while split' });
    b.appendEvent({ text: 'from B while split' });

    await a.connectTo(b);

    await waitFor(() => a.log.events.length === 2 && b.log.events.length === 2);

    // Both events survive on both sides, and both sides converge on the
    // exact same order (Automerge's list CRDT gives a total order, it
    // doesn't just concatenate arbitrarily).
    assert.deepEqual(
      a.log.events.map((e) => e.id),
      b.log.events.map((e) => e.id),
    );
    const texts = a.log.events.map((e) => e.text);
    assert.ok(texts.includes('from A while split'));
    assert.ok(texts.includes('from B while split'));
  });

  test('sanity: Automerge doc is a real CRDT (not just a plain object)', () => {
    assert.ok(Automerge.isAutomerge(a.doc));
  });
});
