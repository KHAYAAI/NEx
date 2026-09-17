#!/usr/bin/env node
// Same idea as dump-events.mjs, for a single `fields.<key>` value —
// used by infra/zero-internet/run-week.sh's load test. Importing
// '@automerge/automerge' (the package entry point) rather than reaching
// into its dist/mjs/index.js directly matters here: the low-level
// module needs Automerge.use() called first to initialize its backend,
// which only the package's own index.js does — a direct dist import
// skips that and throws "Automerge.use() not called (load)". Real
// failure this hit during testing; a dedicated script keeps that
// footgun in one place instead of every inline `node -e` caller
// needing to know about it.
import fs from 'node:fs';
import * as Automerge from '@automerge/automerge';

const [, , docFile, fieldKey] = process.argv;
if (!docFile || !fieldKey) {
  console.error('usage: dump-field.mjs <docFile> <fieldKey>');
  process.exit(2);
}
const doc = Automerge.load(fs.readFileSync(docFile));
console.log(doc.fields[fieldKey] ?? '');
