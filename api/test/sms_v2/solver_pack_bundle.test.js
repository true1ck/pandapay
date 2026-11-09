'use strict';
// The evidence solver's vocabulary ships inside the signed bundle as one optional part.
// Run: node --test api/test/sms_v2/solver_pack_bundle.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const builder = require('../../src/sms_v2/bundle_builder');
const { validateBundle } = require('../../src/sms_v2/contracts');
const { canonicalize } = require('../../src/sms_v2/signer');

const CONTRACTS = path.resolve(__dirname, '../../../contracts/sms/v2');
const fullBundle = JSON.parse(fs.readFileSync(path.join(CONTRACTS, 'fixtures/valid/bundle/full.json'), 'utf8'));
const pack = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../rules/sms/solver/pack.json'), 'utf8'));

const assemble = (source) => builder.assembleBundle({
  manifest: {},
  rules: [],
  parts: builder.partsOf(source),
  bundleVersion: 1,
  createdAt: '2026-11-09T00:00:00Z',
  expiresAt: '2026-11-16T00:00:00Z',
});

test('solverPack is a bundle part, stored and rebuilt like the other parts', () => {
  assert.ok(builder.PART_KEYS.includes('solverPack'));
  assert.deepEqual(builder.partsOf({ ...fullBundle, solverPack: pack }).solverPack, pack);
});

test('a bundle assembled with a pack carries it and passes the contract', () => {
  const bundle = assemble({ ...fullBundle, solverPack: pack });
  assert.deepEqual(bundle.solverPack, pack);
  assert.doesNotThrow(() => builder.assertValidBundle(bundle));
});

test('without a pack the bundle has no solverPack key, so it signs exactly as before', () => {
  const bundle = assemble(fullBundle);
  assert.equal('solverPack' in bundle, false);
  assert.equal(canonicalize(bundle).includes('solverPack'), false);
  assert.doesNotThrow(() => builder.assertValidBundle(bundle));
});

test('a malformed pack is refused by the contract', () => {
  for (const bad of [{ schema: 'other/1', version: 1, lexicons: {} }, { schema: pack.schema, version: 0, lexicons: {} }, { schema: pack.schema, version: 1 }, 'text', []]) {
    const doc = { ...assemble(fullBundle), solverPack: bad, signature: { alg: 'Ed25519', keyId: 'x', value: 'AAAA' } };
    assert.equal(validateBundle(doc).ok, false, JSON.stringify(bad).slice(0, 60));
  }
});

test('the pack is content-addressed: changing a word changes the bundle content hash', () => {
  const a = builder.contentSha256(assemble({ ...fullBundle, solverPack: pack }));
  const changed = JSON.parse(JSON.stringify(pack));
  changed.lexicons.debit.push('some-new-wording');
  const b = builder.contentSha256(assemble({ ...fullBundle, solverPack: changed }));
  assert.notEqual(a, b);
  assert.notEqual(a, builder.contentSha256(assemble(fullBundle)));
});
