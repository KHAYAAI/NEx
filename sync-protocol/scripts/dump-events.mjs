#!/usr/bin/env node
// Small utility for pocket/scripts/pocket-demo.sh: load a saved
// Automerge doc and print its `events` list as JSON ({text, ts, id}
// per event) — kept as its own script rather than an inline `node -e`
// one-liner so callers (bash, Python) don't have to fight shell/string
// quoting to get structured data out.
import fs from 'node:fs';
import * as Automerge from '@automerge/automerge';

const [, , docFile] = process.argv;
if (!docFile) {
  console.error('usage: dump-events.mjs <docFile>');
  process.exit(2);
}
const doc = Automerge.load(fs.readFileSync(docFile));
console.log(JSON.stringify(doc.events));
