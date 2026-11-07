'use strict';
// Adversarial input-validation checks for the shared_expenses command/validation
// layer, written as pure unit tests (no live stack, no network, no DB).
//
// Found via a worst-case-security pass against the local split/shared-expenses
// stack on 2026-11-07 (see docs/implementation/shared-expenses/worst-case-security-report.md).
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateCommand } = require('../src/shared_expenses/commands');
const { SharedExpenseError } = require('../src/shared_expenses/validation');
const { cleanLabel } = require('../src/shared_expenses/label');

const context = '22222222-2222-4222-8222-222222222222';
const member = '44444444-4444-4444-8444-444444444444';
const op = '33333333-3333-4333-8333-333333333333';

function renameCommand(displayName) {
  return { schemaVersion: 1, operationId: op, kind: 'member.rename', payload: { contextId: context, memberId: member, displayName } };
}
function inviteCommand(displayName) {
  return { schemaVersion: 1, operationId: op, kind: 'member.invite', payload: { contextId: context, memberId: member, displayName } };
}

test('SEC-INPUT-01: member.rename displayName rejects SQL-metacharacter and oversized strings cleanly (no crash)', () => {
  for (const name of [`Robert'); DROP TABLE shared_expenses.contexts;--`, 'A'.repeat(401), '']) {
    if (name === '') { assert.throws(() => validateCommand(renameCommand(name)), SharedExpenseError); continue; }
    if (name.length > 400) { assert.throws(() => validateCommand(renameCommand(name)), SharedExpenseError); continue; }
    // SQL-looking text is legitimate free text for a display name; the app relies on
    // parameterized queries downstream, not on rejecting punctuation here. This must
    // validate successfully (i.e. not be treated as an injection vector) and the raw
    // string is preserved verbatim for storage.
    const { command } = validateCommand(renameCommand(name));
    assert.equal(command.payload.displayName, name);
  }
});

test('SEC-INPUT-02: member names with embedded NUL are rejected before SQL', () => {
  for (const value of ['\u0000nullbyte', 'name\u0000end']) {
    assert.throws(() => validateCommand(renameCommand(value)), SharedExpenseError);
    assert.throws(() => validateCommand(inviteCommand(value)), SharedExpenseError);
  }
});

test('SEC-INPUT-03: member.invite/rename reject non-string, object, and other-typed displayName', () => {
  for (const bad of [12345, null, { nested: 'x' }, ['a'], true]) {
    assert.throws(() => validateCommand(renameCommand(bad)), SharedExpenseError);
    assert.throws(() => validateCommand(inviteCommand(bad)), SharedExpenseError);
  }
});

test('SEC-INPUT-04: unicode zero-width/bidi-override text is accepted (not an injection vector) '
  + 'and remains well-formed UTF-8 (parameterized storage is the actual defense, not server-side '
  + 'stripping at the validation layer)', () => {
    for (const name of ['‮reversed‬', '​​zerowidth', 'café'.normalize('NFD')]) {
      const { command } = validateCommand(renameCommand(name));
      assert.equal(command.payload.displayName, name);
    }
  });

test('SEC-INPUT-05: mass assignment of extra/unknown payload fields is rejected (role, isAdmin, __proto__)', () => {
  const polluted = { schemaVersion: 1, operationId: op, kind: 'member.rename', payload: { contextId: context, memberId: member, displayName: 'X', role: 'owner', isAdmin: true } };
  assert.throws(() => validateCommand(polluted), SharedExpenseError);
  // literal __proto__ own-property key must not pollute Object.prototype and must be rejected
  const protoPayload = JSON.parse('{"contextId":"' + context + '","memberId":"' + member + '","displayName":"PP","__proto__":{"polluted":true}}');
  assert.throws(() => validateCommand({ schemaVersion: 1, operationId: op, kind: 'member.rename', payload: protoPayload }), SharedExpenseError);
  assert.equal({}.polluted, undefined, 'Object.prototype must not be polluted by command validation');
});

test('SEC-INPUT-06: settlement.report amountMinor rejects negative, huge, hex, float, exponent, '
  + 'leading/trailing whitespace and leading-zero strings', () => {
    const base = { contextId: context, settlementId: '55555555-5555-4555-8555-555555555555', payerMemberId: member, receiverMemberId: '66666666-6666-4666-8666-666666666666', currency: 'INR', method: 'upi', paidOn: '2026-11-01' };
    for (const amountMinor of ['-100', '9'.repeat(40), '0x10', '1e10', 'NaN', '1.5', '', ' 100', '100 ', '00100']) {
      const command = { schemaVersion: 1, operationId: op, kind: 'settlement.report', payload: { ...base, amountMinor } };
      assert.throws(() => validateCommand(command), SharedExpenseError, `amountMinor=${JSON.stringify(amountMinor)} should be rejected`);
    }
  });

test('SEC-INPUT-07: payerMemberId === receiverMemberId is rejected (self-settlement)', () => {
  const command = { schemaVersion: 1, operationId: op, kind: 'settlement.report', payload: { contextId: context, settlementId: '55555555-5555-4555-8555-555555555555', payerMemberId: member, receiverMemberId: member, amountMinor: '100', currency: 'INR', method: 'upi', paidOn: '2026-11-01' } };
  assert.throws(() => validateCommand(command), SharedExpenseError);
});

test('SEC-INPUT-08: path-traversal / non-UUID shaped ids in any uuid field are rejected', () => {
  for (const badId of ['../../etc/passwd', '1;DROP TABLE x;--', "' OR '1'='1", context + "' --"]) {
    const command = { schemaVersion: 1, operationId: op, kind: 'member.rename', payload: { contextId: context, memberId: badId, displayName: 'ok' } };
    assert.throws(() => validateCommand(command), SharedExpenseError, `memberId=${JSON.stringify(badId)} should be rejected`);
  }
});
