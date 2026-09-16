import * as Automerge from '@automerge/automerge';

// The document synced between nodes. `events` is an append-only CRDT list
// (Phase 1 test matrix's ordering/loss cases); `fields` is a CRDT map used
// to exercise same-key concurrent writes (the "3-way conflict" exit
// criterion — see docs/MERGE-SEMANTICS.md).
//
// Real hub/phone nodes are paired once during setup, not spawned with
// independently-created documents — pairing is what lets two nodes agree
// on *which* `fields` map they're both writing to before they ever go
// offline and diverge. `createGenesisDoc` models that one-time pairing
// step: every node clones the same genesis rather than calling
// `Automerge.from` for itself, so the two sides start from a shared
// object identity, not just structurally-identical-looking copies.
export function createGenesisDoc() {
  return Automerge.from({ events: [], fields: {} });
}

export class EventLog {
  #doc;

  constructor(doc = createGenesisDoc()) {
    this.#doc = doc;
  }

  get doc() {
    return this.#doc;
  }

  set doc(next) {
    this.#doc = next;
  }

  appendEvent(payload) {
    this.#doc = Automerge.change(this.#doc, (d) => {
      d.events.push({ id: crypto.randomUUID(), ts: Date.now(), ...payload });
    });
    return this.#doc;
  }

  setField(key, value) {
    this.#doc = Automerge.change(this.#doc, (d) => {
      d.fields[key] = value;
    });
    return this.#doc;
  }

  get events() {
    return this.#doc.events;
  }

  get fields() {
    return this.#doc.fields;
  }

  conflictsFor(key) {
    return Automerge.getConflicts(this.#doc.fields, key);
  }
}
