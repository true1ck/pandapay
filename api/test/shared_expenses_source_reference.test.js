'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vectors = require('../../contracts/shared_expenses/v1/source_reference_vectors.json');
const { parseSharedExpenseSourceReference, canonicalLegacySplitTarget } = require('../src/shared_expenses/source_reference');
const { SharedExpenseError } = require('../src/shared_expenses/domain');

for (const vector of vectors.valid) {
  test(vector.id, () => {
    const original = structuredClone(vector.input);
    const parsed = parseSharedExpenseSourceReference(original);
    assert.deepEqual(parsed, vector.input);
    assert.equal(canonicalLegacySplitTarget(parsed), vector.target);
    assert.notEqual(parsed, original);
    assert.deepEqual(original, vector.input);
  });
}

const legacy = vectors.valid[0].input, pending = vectors.valid[1].input;
function rejects(input) {
  assert.throws(() => parseSharedExpenseSourceReference(input), error =>
    error instanceof SharedExpenseError && error.code === 'INVALID_SOURCE_REFERENCE' && typeof error.field === 'string');
  assert.throws(() => canonicalLegacySplitTarget(input), { code: 'INVALID_SOURCE_REFERENCE' });
}
test('closed shapes reject missing, unknown and cross-kind fields', () => {
  for (const input of [null, [], '', 1, {}, { ...legacy, rawSms: 'private' },
    { ...legacy, eventId: pending.eventId }, { ...pending, foreignPaymentId: legacy.canonicalTransactionId },
    { ...legacy, kind: 'other' }]) rejects(input);
  for (const key of Object.keys(legacy).filter(key => key !== 'sourceKey')) {
    const input = { ...legacy }; delete input[key]; rejects(input);
  }
});
test('local aliases and hashes never become legacy transaction UUIDs', () => {
  for (const id of [pending.localProjectionId, pending.eventId, 'not-a-uuid', legacy.canonicalTransactionId + '\n', legacy.canonicalTransactionId.toUpperCase().replace('2222', 'AAAA')]) {
    rejects({ ...legacy, canonicalTransactionId: id });
    rejects({ ...legacy, ownerAccountId: id });
  }
  rejects({ ...pending, eventId: 'A'.repeat(64) });
  rejects({ ...pending, localProjectionId: 'v2:' + 'b'.repeat(64) });
  rejects({ ...pending, canonicalTransactionId: legacy.canonicalTransactionId });
  rejects({ ...pending, sourceVersion: '1' });
  rejects({ ...pending, canonicalTransactionId: null, sourceVersion: null });
  assert.equal(canonicalLegacySplitTarget(pending), null);
});
test('opaque identity tokens are bounded, not free-text private payloads', () => {
  for (const token of ['', null, 123, 'a'.repeat(129), 'raw message text', 'rahul@upi', 'ok\n', '₹100', '../x']) {
    rejects({ ...legacy, sourceKey: token });
    rejects({ ...legacy, sourceVersion: token });
  }
});
test('error messages contain codes and field paths, never private input', () => {
  const secret = 'private SMS with account 123456';
  assert.throws(() => parseSharedExpenseSourceReference({ ...legacy, sourceKey: secret }), error => {
    assert.equal(error.message, 'INVALID_SOURCE_REFERENCE at sourceKey');
    assert.ok(!error.message.includes(secret));
    return true;
  });
});
