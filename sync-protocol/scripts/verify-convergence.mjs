#!/usr/bin/env node
// Standalone check for the AT-1-3 conflict scenario once both sides have
// saved their post-reconnect doc to disk (see infra/wireguard-poc/run-demo.sh):
// loads both files independently and asserts they converged to the same
// value for the given field, and that neither concurrent write got
// silently dropped (both are still visible via Automerge's conflicts API).
import fs from 'node:fs';
import * as Automerge from '@automerge/automerge';

const [, , fileA, fileB, fieldKey, expectedValuesCsv] = process.argv;
if (!fileA || !fileB || !fieldKey || !expectedValuesCsv) {
  console.error(
    'usage: verify-convergence.mjs <docFileA> <docFileB> <fieldKey> <expectedValue1,expectedValue2>',
  );
  process.exit(2);
}
const expected = new Set(expectedValuesCsv.split(','));

const docA = Automerge.load(fs.readFileSync(fileA));
const docB = Automerge.load(fs.readFileSync(fileB));

const valueA = docA.fields[fieldKey];
const valueB = docB.fields[fieldKey];
const conflictsA = Automerge.getConflicts(docA.fields, fieldKey) ?? {};
const conflictsB = Automerge.getConflicts(docB.fields, fieldKey) ?? {};
const conflictValuesA = new Set(Object.values(conflictsA));
const conflictValuesB = new Set(Object.values(conflictsB));

console.log(`A: fields.${fieldKey} = ${JSON.stringify(valueA)}, conflicts = ${JSON.stringify(conflictsA)}`);
console.log(`B: fields.${fieldKey} = ${JSON.stringify(valueB)}, conflicts = ${JSON.stringify(conflictsB)}`);

const failures = [];
if (valueA === undefined) failures.push('A has no value for the field');
if (valueB === undefined) failures.push('B has no value for the field');
if (valueA !== valueB) failures.push(`A and B disagree on the winner: ${valueA} !== ${valueB} (not deterministic)`);
for (const v of expected) {
  if (!conflictValuesA.has(v)) failures.push(`A's conflict set is missing ${JSON.stringify(v)} (lost a write)`);
  if (!conflictValuesB.has(v)) failures.push(`B's conflict set is missing ${JSON.stringify(v)} (lost a write)`);
}

if (failures.length > 0) {
  console.error('FAIL:', failures.join('; '));
  process.exit(1);
}
console.log(`PASS: both nodes converged deterministically on ${JSON.stringify(valueA)}, and both original writes (${expectedValuesCsv}) remain recoverable via the conflicts API on both sides.`);
