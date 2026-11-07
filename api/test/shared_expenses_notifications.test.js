'use strict';
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
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
const expensePayload = {
  contextId: ctx,
  expenseId: '66666666-6666-4666-8666-666666666666',
  revisionId: '77777777-7777-4777-8777-777777777777',
  expectedHeadRevisionId: null,
  snapshot: {
    currency: 'INR', totalMinor: '100', memberOrder: ['m-actor', 'm-friend'],
    contributions: [{ memberId: 'm-actor', amountMinor: '100' }],
    shares: [{ memberId: 'm-friend', amountMinor: '100' }],
  },
};

test('an expense reviewer audience excludes the author and carries no amount', () => {
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

function fakeDb(log, { failFor, audience = members, reviewers = audience, disabled = [], inbox = new Map() } = {}) {
  return async (profileId, fn) => {
    const client = {
      async query(sql, params) {
        log.push({ profileId, sql: sql.replace(/\s+/g, ' ').trim().slice(0, 40), params });
        // Stored revision members are authoritative: they include payers and
        // people removed by an edit, unlike the new snapshot's shares alone.
        const storedRows = (rows) => rows.map((m) => ({ member_id: m.memberId, profile_id: m.profileId, approver_profile_id: m.profileId, role: m.role, display_name: m.name, approval_required: true }));
        if (/shared_expenses\.revision_members/.test(sql)) return { rows: storedRows(reviewers) };
        if (/FROM shared_expenses.members/.test(sql)) return { rows: storedRows(audience) };
        if (/_context_label/.test(sql)) return { rows: [{ name: 'Goa trip' }] };
        if (/notification_preferences/.test(sql)) return disabled.includes(profileId)
          ? { rowCount: 1, rows: [{ enabled: false }] }
          : { rowCount: 0, rows: [] };
        if (/INSERT INTO notifications/.test(sql)) {
          if (failFor === profileId) throw new Error('boom');
          const key = `${params[0]}|${params[5]}`;
          if (inbox.has(key)) return { rowCount: 0, rows: [] };
          inbox.set(key, { profileId: params[0], deepLink: params[4], dedupeKey: params[5] });
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
  const sent = await notifyAfterCommit({ withUserClient: fakeDb(log), actorId: actor, kind: 'expense.propose', payload: expensePayload, contextId: ctx, operationId: 'op-1', options: { enabled: true }, logger: quiet });
  assert.equal(sent, 2);
  const inserts = log.filter((l) => l.sql.startsWith('INSERT INTO notifi'));
  assert.deepEqual(inserts.map((i) => i.params[5]).sort(), [`split:op-1:${friend}`, `split:op-1:${owner}`].sort());
  assert.ok(inserts.every((i) => i.params[4] === `/insights/splits/${ctx}`));
  assert.ok(inserts.every((i) => i.profileId !== actor));
});

test('one recipient failing never throws and does not stop the others', async () => {
  const log = [];
  const sent = await notifyAfterCommit({ withUserClient: fakeDb(log, { failFor: owner }), actorId: actor, kind: 'expense.propose', payload: expensePayload, contextId: ctx, operationId: 'op-2', options: { enabled: true }, logger: quiet });
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

test('a command that notifies nobody costs no database query, even when enabled by default', async () => {
  const { notifyAfterCommit, enabled } = require('../src/shared_expenses/notifications');
  assert.equal(enabled(), true, 'on by default');
  let calls = 0;
  const sent = await notifyAfterCommit({
    withUserClient: async () => { calls += 1; return {}; },
    actorId: '11111111-1111-4111-8111-111111111111',
    kind: 'context.create', payload: {}, contextId: '22222222-2222-4222-8222-222222222222',
    operationId: '33333333-3333-4333-8333-333333333333',
  });
  assert.equal(sent, 0);
  assert.equal(calls, 0);
});

test('the switch can still turn it off', async () => {
  const { notifyAfterCommit } = require('../src/shared_expenses/notifications');
  let calls = 0;
  const sent = await notifyAfterCommit({
    withUserClient: async () => { calls += 1; return {}; },
    actorId: '11111111-1111-4111-8111-111111111111', kind: 'expense.propose', payload: {},
    contextId: '22222222-2222-4222-8222-222222222222', operationId: '33333333-3333-4333-8333-333333333333',
    options: { enabled: false },
  });
  assert.equal(sent, 0);
  assert.equal(calls, 0);
});

test('join request title carries the label; no label falls back to "Someone"', () => {
  const requested = (actorMemberName) => plan({ ...base, actorMemberName, kind: 'invitation.requested', payload: {} });
  assert.equal(requested('Ravi')[0].title, 'Ravi wants to join');
  assert.match(requested('Ravi')[0].body, /^Ravi asked to join/);
  for (const none of [null, undefined, '', '   ', '\n\t']) {
    assert.equal(requested(none)[0].title, 'Someone wants to join');
    assert.match(requested(none)[0].body, /^Someone asked to join/);
  }
});

test('a 200-character label with newlines is cleaned and capped at 40 characters', () => {
  const nasty = `  Ravi\r\n\u0007Kumar\u0000${'x'.repeat(200)}\n`;
  const [out] = plan({ ...base, actorMemberName: nasty, kind: 'invitation.requested', payload: {} });
  const label = out.title.replace(/ wants to join$/, '');
  assert.ok(label.length <= 40, `label length ${label.length}`);
  assert.doesNotMatch(out.title + out.body, /[\u0000-\u001f\u007f]/);
  assert.match(label, /^Ravi Kumar/);
  assert.doesNotMatch(out.title, /\s{2,}/);
});

test('invite accepted: "<label> joined" with a label, "Invite accepted" without', () => {
  const joined = (actorMemberName) => plan({ ...base, actorMemberName, kind: 'invitation.joined', payload: {} });
  assert.equal(joined('Ravi')[0].title, 'Ravi joined');
  assert.equal(joined(null)[0].title, 'Invite accepted');
  assert.deepEqual(joined('Ravi').map((o) => o.profileId), [owner]);
});

test('claimantProfileName and the phone suffix never reach the push text', async () => {
  const seen = [];
  const withUserClient = async (profileId, fn) => fn({
    async query(sql, params) {
      seen.push({ sql: sql.replace(/\s+/g, ' ').slice(0, 60), params });
      if (/invitation_audience/.test(sql)) {
        return { rows: [{ result: { contextId: ctx, contextName: 'Goa trip', claimantName: 'Mom', claimantProfileName: 'Secret Profile Name', claimantPhoneSuffix: '4821', owners: [owner] } }] };
      }
      if (/notification_preferences/.test(sql)) return { rowCount: 0, rows: [] };
      if (/INSERT INTO notifications/.test(sql)) return { rowCount: 1, rows: [{ id: 'n1' }] };
      return { rows: [] };
    },
  });
  await notifyAfterCommit({ withUserClient, actorId: friend, kind: 'invitation.requested', payload: {}, contextId: ctx, operationId: 'op-k', tokenHash: 'a'.repeat(64), options: { enabled: true }, logger: quiet });
  const insert = seen.find((s) => s.sql.startsWith('INSERT INTO notifi'));
  assert.equal(insert.params[2], 'Mom wants to join');
  assert.doesNotMatch(`${insert.params[2]} ${insert.params[3]}`, /Secret|4821/);
});

test('a direct split with only the generic fallback title omits "in <split>"', () => {
  for (const contextName of ['PandaPay friend', '', null, '  ']) {
    const [req] = plan({ ...base, kind: 'invitation.requested', payload: {}, contextName });
    assert.equal(req.body, 'Asha asked to join your split. Approve or decline.', String(contextName));
    const [joined] = plan({ ...base, kind: 'invitation.joined', payload: {}, contextName });
    assert.equal(joined.body, 'Asha joined your split.');
  }
  const [named] = plan({ ...base, kind: 'invitation.requested', payload: {}, contextName: 'Goa trip' });
  assert.match(named.body, /^Asha asked to join "Goa trip"\./);
});

test('group-link join request: one "wants to join" inbox row per owner, deduped on replay, no phone data', async () => {
  const LINK_HASH = 'b'.repeat(64);
  const owner2 = '55555555-5555-4555-8555-555555555555';
  const inbox = new Map();
  const audienceCalls = [];
  const withUserClient = async (profileId, fn) => fn({
    async query(sql, params) {
      if (/invitation_audience/.test(sql)) {
        audienceCalls.push(params[0]);
        return { rows: [{ result: { contextId: ctx, contextName: 'Goa trip', claimantName: 'Ravi', claimantPhoneSuffix: '4821', owners: [owner, owner2] } }] };
      }
      if (/notification_preferences/.test(sql)) return { rowCount: 0, rows: [] };
      if (/INSERT INTO notifications/.test(sql)) {
        const key = `${params[0]}|${params[5]}`;
        if (inbox.has(key)) return { rowCount: 0, rows: [] };
        inbox.set(key, { profileId: params[0], title: params[2], body: params[3] });
        return { rowCount: 1, rows: [{ id: key }] };
      }
      return { rows: [] };
    },
  });
  const args = { withUserClient, actorId: friend, kind: 'invitation.requested', payload: {}, contextId: ctx, operationId: 'op-link', tokenHash: LINK_HASH, options: { enabled: true }, logger: quiet };
  assert.equal(await notifyAfterCommit(args), 2);
  assert.equal(await notifyAfterCommit(args), 0, 'a replayed claim does not notify again');
  assert.deepEqual(audienceCalls, [LINK_HASH, LINK_HASH], 'the link token is what the audience lookup receives');
  const rows = [...inbox.values()];
  assert.deepEqual(rows.map((r) => r.profileId).sort(), [owner, owner2].sort());
  for (const r of rows) {
    assert.equal(r.title, 'Ravi wants to join');
    assert.doesNotMatch(`${r.title} ${r.body}`, /\d{3,}|4821/);
  }
});



const expenseArgs = (withUserClient, operationId, payload = expensePayload) => ({
  withUserClient, actorId: actor, kind: 'expense.propose', payload,
  contextId: ctx, operationId, options: { enabled: true }, logger: quiet,
});
const notifiedProfiles = (log) => log.filter((row) => row.sql.startsWith('INSERT INTO notifi')).map((row) => row.params[0]).sort();

test('expense proposal notifies its stored required reviewer, not the uninvolved owner', async () => {
  const log = [];
  const withUserClient = fakeDb(log, { reviewers: [members[0], members[2]] });
  const sent = await notifyAfterCommit(expenseArgs(withUserClient, 'op-reviewer'));
  assert.equal(sent, 1);
  assert.deepEqual(notifiedProfiles(log), [friend]);
});

test('expense edit notifies a payer-only reviewer and an old participant removed from the new snapshot', async () => {
  const payer = { memberId: 'm-payer', profileId: '88888888-8888-4888-8888-888888888888', role: 'member', name: 'Payer' };
  const removed = { memberId: 'm-removed', profileId: '99999999-9999-4999-8999-999999999999', role: 'member', name: 'Old participant' };
  const audience = [...members, payer, removed];
  const reviewers = [members[0], members[2], payer, removed];
  const payload = {
    ...expensePayload, expectedHeadRevisionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    snapshot: {
      ...expensePayload.snapshot,
      memberOrder: ['m-actor', 'm-friend', 'm-payer'],
      contributions: [{ memberId: 'm-actor', amountMinor: '50' }, { memberId: 'm-payer', amountMinor: '50' }],
      // The old participant is absent here but remains a required reviewer of
      // the change to their already accepted position.
      shares: [{ memberId: 'm-friend', amountMinor: '100' }],
    },
  };
  const log = [];
  const sent = await notifyAfterCommit(expenseArgs(fakeDb(log, { audience, reviewers }), 'op-edit-reviewers', payload));
  assert.equal(sent, 3);
  assert.deepEqual(notifiedProfiles(log), [friend, payer.profileId, removed.profileId].sort());
});

test('all 116 required reviewers of a valid large edit receive a notification, with no 50-recipient cutoff', async () => {
  const person = (n) => ({
    memberId: `member-${n}`,
    profileId: `${n.toString(16).padStart(8, '0')}-0000-4000-8000-000000000000`,
    role: 'member', name: `Person ${n}`,
  });
  const reviewers = Array.from({ length: 116 }, (_, i) => person(i + 10));
  const bystanders = Array.from({ length: 83 }, (_, i) => person(i + 1000));
  const audience = [members[0], ...bystanders, ...reviewers];
  // The authoritative revision contains the old and new disjoint sets of
  // 50 sharers + 8 payers. Only the new set appears in this command body.
  const current = reviewers.slice(58);
  const payload = {
    ...expensePayload, expectedHeadRevisionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    snapshot: {
      currency: 'INR', totalMinor: '400', memberOrder: current.map((m) => m.memberId),
      contributions: current.slice(50).map((m) => ({ memberId: m.memberId, amountMinor: '50' })),
      shares: current.slice(0, 50).map((m) => ({ memberId: m.memberId, amountMinor: '8' })),
    },
  };
  const log = [];
  const sent = await notifyAfterCommit(expenseArgs(fakeDb(log, { audience, reviewers }), 'op-large-edit', payload));
  assert.equal(sent, 116);
  assert.deepEqual(notifiedProfiles(log), reviewers.map((m) => m.profileId).sort());
});

test('reviewer targeting preserves notification preferences, operation dedupe and split deep links', async () => {
  const log = [], inbox = new Map();
  const withUserClient = fakeDb(log, { reviewers: members, disabled: [owner], inbox });
  const args = expenseArgs(withUserClient, 'op-reviewer-dedupe');
  assert.equal(await notifyAfterCommit(args), 1);
  assert.equal(await notifyAfterCommit(args), 0, 'replaying the command creates no second inbox row');
  assert.deepEqual([...inbox.values()], [{
    profileId: friend, deepLink: `/insights/splits/${ctx}`, dedupeKey: `split:op-reviewer-dedupe:${friend}`,
  }]);
});
