'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { notifyAfterCommit, plan } = require('../src/shared_expenses/notifications');

const actor = '11111111-1111-4111-8111-111111111111';
const owner = '22222222-2222-4222-8222-222222222222';
const friend = '33333333-3333-4333-8333-333333333333';
const ctx = '44444444-4444-4444-8444-444444444444';
const members = [
  { memberId: 'm-actor', profileId: actor, role: 'member', name: 'Asha' },
  { memberId: 'm-owner', profileId: owner, role: 'owner', name: 'Owner' },
  { memberId: 'm-friend', profileId: friend, role: 'member', name: 'Ravi' },
];
const base = { actorMemberName: 'Asha', contextName: 'Goa trip', members, actorId: actor };
const quiet = { warn() {} };

test('a new expense notifies everyone else, never the author, and carries no amount', () => {
  const out = plan({ ...base, kind: 'expense.propose', payload: {} });
  assert.deepEqual(out.map((o) => o.profileId).sort(), [friend, owner].sort());
  for (const o of out) assert.doesNotMatch(o.title + o.body, /₹|\d{3,}/);
});

test('a payment report notifies only the receiver', () => {
  const out = plan({ ...base, kind: 'settlement.report', payload: { receiverMemberId: 'm-friend' } });
  assert.deepEqual(out.map((o) => o.profileId), [friend]);
  assert.equal(plan({ ...base, kind: 'settlement.report', payload: { receiverMemberId: 'm-actor' } }).length, 0);
});

test('a join request notifies owners only', () => {
  const out = plan({ ...base, kind: 'invitation.requested', payload: {} });
  assert.deepEqual(out.map((o) => o.profileId), [owner]);
});

test('unrelated command kinds notify nobody', () => {
  for (const kind of ['context.create', 'member.invite', 'expense.respond', 'settlement.respond']) {
    assert.equal(plan({ ...base, kind, payload: {} }).length, 0, kind);
  }
});

function fakeDb(log, { failFor } = {}) {
  return async (profileId, fn) => {
    const client = {
      async query(sql, params) {
        log.push({ profileId, sql: sql.replace(/\s+/g, ' ').trim().slice(0, 40), params });
        if (/FROM shared_expenses.members/.test(sql)) {
          return { rows: members.map((m) => ({ member_id: m.memberId, profile_id: m.profileId, role: m.role, display_name: m.name })) };
        }
        if (/_context_label/.test(sql)) return { rows: [{ name: 'Goa trip' }] };
        if (/notification_preferences/.test(sql)) return { rowCount: 0, rows: [] };
        if (/INSERT INTO notifications/.test(sql)) {
          if (failFor === profileId) throw new Error('boom');
          return { rowCount: 1, rows: [{ id: 'n-' + profileId }] };
        }
        return { rows: [] };
      },
    };
    return fn(client);
  };
}

test('kill switch off: nothing is read or written', async () => {
  const log = [];
  const sent = await notifyAfterCommit({ withUserClient: fakeDb(log), actorId: actor, kind: 'expense.propose', payload: {}, contextId: ctx, operationId: 'op', options: { enabled: false }, logger: quiet });
  assert.equal(sent, 0);
  assert.equal(log.length, 0);
});

test('enabled: one dedupe key per operation and recipient, deep link to the split', async () => {
  const log = [];
  const sent = await notifyAfterCommit({ withUserClient: fakeDb(log), actorId: actor, kind: 'expense.propose', payload: {}, contextId: ctx, operationId: 'op-1', options: { enabled: true }, logger: quiet });
  assert.equal(sent, 2);
  const inserts = log.filter((l) => l.sql.startsWith('INSERT INTO notifi'));
  assert.deepEqual(inserts.map((i) => i.params[5]).sort(), [`split:op-1:${friend}`, `split:op-1:${owner}`].sort());
  assert.ok(inserts.every((i) => i.params[4] === `/insights/splits/${ctx}`));
  assert.ok(inserts.every((i) => i.profileId !== actor));
});

test('one recipient failing never throws and does not stop the others', async () => {
  const log = [];
  const sent = await notifyAfterCommit({ withUserClient: fakeDb(log, { failFor: owner }), actorId: actor, kind: 'expense.propose', payload: {}, contextId: ctx, operationId: 'op-2', options: { enabled: true }, logger: quiet });
  assert.equal(sent, 1);
});

test('a database failure resolves quietly instead of rejecting', async () => {
  const sent = await notifyAfterCommit({ withUserClient: async () => { throw new Error('db down'); }, actorId: actor, kind: 'expense.propose', payload: {}, contextId: ctx, operationId: 'op-3', options: { enabled: true }, logger: quiet });
  assert.equal(sent, 0);
});

test('join request: a claimant who cannot read the roster still notifies the owner, by name', async () => {
  const seen = [];
  const withUserClient = async (profileId, fn) => fn({
    async query(sql, params) {
      seen.push({ profileId, sql: sql.replace(/\s+/g, ' ').slice(0, 60), params });
      if (/invitation_audience/.test(sql)) {
        return { rows: [{ result: { contextId: ctx, contextName: 'Goa trip', claimantName: 'Ravi', owners: [owner] } }] };
      }
      if (/FROM shared_expenses.members/.test(sql)) throw new Error('claimant must not read the roster');
      if (/notification_preferences/.test(sql)) return { rowCount: 0, rows: [] };
      if (/INSERT INTO notifications/.test(sql)) return { rowCount: 1, rows: [{ id: 'n1' }] };
      return { rows: [] };
    },
  });
  const sent = await notifyAfterCommit({ withUserClient, actorId: friend, kind: 'invitation.requested', payload: {}, contextId: ctx, operationId: 'op-j', tokenHash: 'a'.repeat(64), options: { enabled: true }, logger: quiet });
  assert.equal(sent, 1);
  const insert = seen.find((s) => s.sql.startsWith('INSERT INTO notifi'));
  assert.equal(insert.profileId, owner);
  assert.match(insert.params[3], /Ravi asked to join/);
  assert.equal(insert.params[5], `split:op-j:${owner}`);
});
