'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { makeProposal, markdown } = require('../scripts/plan_contact_conflicts');

function account(id, date, verified = true) {
  return { id, email: 'tester@example.invalid', phone_number: 'original-private-ciphertext',
    phone_lookup_hash: 'a'.repeat(64), created_at: date, deleted: false,
    is_phone_verified: verified, is_email_verified: true };
}
test('conflict proposal preserves every account and prefers the oldest verified account', () => {
  const rows = [account('new', '2026-02-01'), account('old', '2026-01-01'), account('unverified', '2025-01-01', false)];
  const proposal = makeProposal(rows);
  assert.equal(proposal.groups[0].proposed_phone_account_id, 'old');
  assert.equal(proposal.groups[0].accounts.length, 3);
  assert.equal(proposal.groups[0].accounts[1].phone_number, rows[0].phone_number);
  assert.equal(proposal.status, 'proposal_only_no_changes_applied');
});
test('review markdown contains masked email hints and no phone ciphertext/hash', () => {
  const output = markdown(makeProposal([account('one', '2026-01-01'), account('two', '2026-02-01')]));
  assert.ok(output.includes('t…@example.invalid'));
  assert.ok(!output.includes('tester@example.invalid'));
  assert.ok(!output.includes('original-private-ciphertext'));
  assert.ok(!output.includes('a'.repeat(64)));
});
test('proposal rejects undefined deletion states and incomplete groups', () => {
  assert.throws(() => makeProposal([{ ...account('one', '2026-01-01'), deleted: null }]), /Invalid conflict/);
  assert.throws(() => makeProposal([account('one', '2026-01-01')]), /Incomplete conflict/);
});
