'use strict';
// src/auth.js loads config, which refuses to start without these; CI sets neither.
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
// src/auth.js loads the server config, which wants these (the CI job has no .env).
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
process.env.DATABASE_URL ||= 'postgresql://ci:ci@127.0.0.1:5432/ci_never_connected';
const test=require('node:test');
const assert=require('node:assert/strict');
const {normalizePhone,inviteCredentials,verifiedPhoneHash}=require('../src/shared_expenses/invitations');
const secret='synthetic-secret-for-tests-only-32-bytes', actor='11111111-1111-4111-8111-111111111111', id='22222222-2222-4222-8222-222222222222';
test('selected Indian and international phone inputs normalize without a contact upload',()=>{
  assert.equal(normalizePhone('98765 43210'),'+919876543210');
  assert.equal(normalizePhone('+91 (98765) 43210'),'+919876543210');
  assert.equal(normalizePhone('+44 7700 900123'),'+447700900123');
  for(const value of ['rahul@upi','123','+919876543210ignore','0000000000','https://evil']) assert.throws(()=>normalizePhone(value));
});
test('invite links are purpose-bound stable secrets and only hashes reach the database',()=>{
  const first=inviteCredentials(secret,actor,id);
  assert.equal(inviteCredentials(secret,actor,id).token,first.token);
  assert.match(first.token,/^[A-Za-z0-9_-]{43}$/);
  assert.match(first.tokenHash,/^[a-f0-9]{64}$/);
  assert.notEqual(inviteCredentials(secret,id,actor).token,first.token);
  assert.throws(()=>inviteCredentials('',actor,id));
});
test('only the current authenticated verified phone can satisfy a bound invitation',()=>{
  assert.equal(verifiedPhoneHash(secret,{phone:{verified:false,value:'+919876543210'}}),null);
  assert.equal(verifiedPhoneHash(secret,{phone:{verified:true,value:null}}),null);
  const hash=verifiedPhoneHash(secret,{phone:{verified:true,value:'+919876543210'}});
  assert.match(hash,/^[a-f0-9]{64}$/);
  assert.ok(!hash.includes('9876543210'));
});

test('public install page never joins, never queries the database and carries the token only in the store referrer', () => {
  const routes = {};
  const app = { get: (path, ...h) => { routes[path] = h[h.length - 1]; }, post() {} };
  require('../src/shared_expenses/invitations').registerInvitationRoutes(app, {
    protect: (fn) => [fn], withUserClient() { throw new Error('database must not be used'); },
    sendError() {}, secret: 'x'.repeat(40), androidPackageId: 'app.pandapay.pandapay',
  });
  const handler = routes['/split/join/:token'];
  assert.ok(handler);
  const token = 'A'.repeat(43);
  const run = (t) => {
    const out = { headers: {}, code: 200 };
    const res = {
      set(h) { Object.assign(out.headers, h); return res; },
      status(c) { out.code = c; return res; },
      type() { return res; },
      send(b) { out.body = b; return res; },
    };
    handler({ params: { token: t } }, res);
    return out;
  };
  const ok = run(token);
  assert.equal(ok.code, 200);
  assert.match(ok.body, /referrer=split_join%3DA{43}/);
  assert.match(ok.body, /Install PandaPay/);
  assert.equal(ok.headers['Referrer-Policy'], 'no-referrer');
  assert.equal(ok.headers['Cache-Control'], 'no-store');
  assert.doesNotMatch(ok.body, /₹|group name/i);
  assert.equal(run('short').code, 404);
  assert.equal(run('<script>' + 'a'.repeat(40)).code, 404);
});

test('directory names are masked to first name and last initial', () => {
  const { maskName } = require('../src/shared_expenses/invitations');
  assert.equal(maskName('Rahul Kumar Sharma'), 'Rahul S.');
  assert.equal(maskName('  Priya  '), 'Priya');
  assert.equal(maskName(''), null);
  assert.equal(maskName(null), null);
});

test('directory registration is throttled, skips unverified phones and never throws', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  let calls = 0, clock = 1000, fail = false;
  const withUserClient = async (_user, fn) => { calls++; if (fail) throw new Error('db down'); return fn({ query: async () => ({ rows: [{ result: {} }] }) }); };
  const touch = createDirectoryToucher({ withUserClient, secret, ttlMs: 100, now: () => clock });
  const verified = (value) => ({ userId: actor, verifiedSession: { verifiedContacts: { phone: { verified: true, value } } } });
  assert.equal(await touch({ userId: actor, verifiedSession: { verifiedContacts: { phone: { verified: false, value: '+919876543210' } } } }), false);
  assert.equal(calls, 0);
  assert.equal(await touch(verified('+919876543210')), true);
  assert.equal(await touch(verified('+919876543210')), false);
  assert.equal(calls, 1);
  assert.equal(await touch(verified('+919876543211')), true, 'a changed number registers immediately');
  clock += 101;
  assert.equal(await touch(verified('+919876543211')), true, 'refreshes after the ttl');
  fail = true; clock += 101;
  assert.equal(await touch(verified('+919876543211')), false, 'database failure is swallowed and retried later');
  assert.equal(await touch({}), false);
});

test('lookup, inbox and decision routes use only the verified phone and never return hashes', async () => {
  const routes = {};
  const app = { get: (p, ...h) => { routes['GET ' + p] = h[h.length - 1]; }, post: (p, ...h) => { routes['POST ' + p] = h[h.length - 1]; } };
  const queries = [];
  const responses = [
    { found: true, self: false, displayName: 'Rahul Kumar Sharma', existingContextId: null },
    { items: [{ invitationId: id, inviterName: 'Asha Verma Rao', contextName: 'Goa' }] },
  ];
  const withUserClient = async (_u, fn) => fn({ query: async (sql, args) => { queries.push([sql, args]); if (/register_phone/.test(sql)) return { rows: [{ result: {} }] }; return { rows: [{ result: responses.shift() ?? { status: 'joined' } }] }; } });
  require('../src/shared_expenses/invitations').registerInvitationRoutes(app, { protect: (fn) => [fn], withUserClient, sendError() {}, secret, androidPackageId: 'x' });
  const call = async (key, req) => { const out = {}; const res = { status(c) { out.code = c; return res; }, json(b) { out.body = b; return res; } }; await routes[key](req, res); return out; };
  const verified = { verifiedContacts: { phone: { verified: true, value: '+919876543210' } } };
  const lookup = await call('POST /shared-expenses/directory/lookup', { userId: actor, body: { phoneNumber: '98765 43211' }, verifiedSession: verified });
  assert.deepEqual(lookup.body, { found: true, self: false, displayName: 'Rahul S.', existingContextId: null });
  assert.match(queries[0][1][0], /^[a-f0-9]{64}$/);
  const inbox = await call('GET /shared-expenses/invitations/inbox', { userId: actor, query: {}, verifiedSession: verified });
  assert.equal(inbox.body.items[0].inviterName, 'Asha R.');
  const unverified = { verifiedContacts: { phone: { verified: false, value: '+919876543210' } } };
  assert.deepEqual((await call('GET /shared-expenses/invitations/inbox', { userId: actor, query: {}, verifiedSession: unverified })).body, { phoneVerified: false, emailVerified: false, items: [] });
  const before = queries.length;
  const denied = await call('POST /shared-expenses/invitations/accept', { userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: unverified });
  assert.equal(denied.code, 409);
  assert.equal(queries.length, before, 'no database call without a verified phone');
  const ok = await call('POST /shared-expenses/invitations/decline', { userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: verified });
  assert.equal(ok.body.status, 'joined');
  const own = await call('POST /shared-expenses/directory/lookup', { userId: actor, body: { phoneNumber: '+919999999999', extra: 1 }, verifiedSession: verified }).catch((e) => e);
  assert.ok(own instanceof Error || own.code, 'unexpected body fields are refused');
});

test('group links are per-group, per-generation secrets and only a hash reaches the database', () => {
  const { groupLinkCredentials } = require('../src/shared_expenses/invitations');
  const ctx = '33333333-3333-4333-8333-333333333333', gen = '44444444-4444-4444-8444-444444444444';
  const one = groupLinkCredentials(secret, actor, ctx, gen);
  assert.equal(groupLinkCredentials(secret, actor, ctx, gen).token, one.token);
  assert.match(one.token, /^[A-Za-z0-9_-]{43}$/);
  assert.match(one.tokenHash, /^[a-f0-9]{64}$/);
  assert.notEqual(groupLinkCredentials(secret, actor, ctx, id).token, one.token, 'a reset makes a different link');
  assert.notEqual(groupLinkCredentials(secret, id, ctx, gen).token, one.token);
  assert.notEqual(one.token, inviteCredentials(secret, actor, gen).token, 'invite and group links never collide');
});

test('a failed directory write backs off instead of retrying on every request', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  let calls = 0, clock = 1000;
  const withUserClient = async () => { calls++; throw new Error('feature off'); };
  const touch = createDirectoryToucher({ withUserClient, secret, ttlMs: 100000, retryMs: 500, now: () => clock });
  const req = { userId: actor, verifiedSession: { verifiedContacts: { phone: { verified: true, value: '+919876543210' } } } };
  assert.equal(await touch(req), false);
  assert.equal(await touch(req), false);
  assert.equal(await touch(req), false);
  assert.equal(calls, 1, 'one attempt, then quiet');
  clock += 501;
  await touch(req);
  assert.equal(calls, 2, 'tries again after the short backoff');
});

test('a signed-in person is registered by any authenticated request, without opening Splits', async () => {
  const auth = require('../src/auth');
  const { registerInvitationRoutes } = require('../src/shared_expenses/invitations');
  const writes = [];
  const withUserClient = async (user, fn) => fn({ query: async (sql, args) => { if (/register_phone/.test(sql)) writes.push({ user, hash: args[0] }); return { rows: [{ result: {} }] }; } });
  registerInvitationRoutes({ get() {}, post() {} }, { protect: () => [], withUserClient, sendError() {}, secret });
  const verifiedReq = { userId: actor, verifiedSession: { verifiedContacts: { phone: { verified: true, value: '+919876543210' } } } };
  auth._runVerifiedSessionHooks(verifiedReq);
  await new Promise((r) => setImmediate(r));
  assert.equal(writes.length, 1, 'registered on an ordinary request');
  assert.equal(writes[0].user, actor);
  assert.match(writes[0].hash, /^[a-f0-9]{64}$/, 'only a keyed hash is stored');
  // Someone with no verified phone is simply skipped.
  auth._runVerifiedSessionHooks({ userId: '99999999-9999-4999-8999-999999999999', verifiedSession: { verifiedContacts: {} } });
  await new Promise((r) => setImmediate(r));
  assert.equal(writes.length, 1);
});

const emailOnly = { verifiedContacts: { email: { verified: true, value: 'Chandresh@Example.com' }, phone: { verified: false, value: null } } };
function emailRig(responder) {
  const routes = {}, queries = [];
  const app = { get: (p, ...h) => { routes['GET ' + p] = h[h.length - 1]; }, post: (p, ...h) => { routes['POST ' + p] = h[h.length - 1]; } };
  const withUserClient = async (_u, fn) => fn({ query: async (sql, args) => { queries.push([sql, args]); if (/register_phone/.test(sql)) return { rows: [{ result: {} }] }; return { rows: [{ result: responder(sql, args) }] }; } });
  require('../src/shared_expenses/invitations').registerInvitationRoutes(app, { protect: (fn) => [fn], withUserClient, sendError() {}, secret, androidPackageId: 'x' });
  const call = async (key, req) => { const out = {}; const res = { status(c) { out.code = c; return res; }, json(b) { out.body = b; return res; } }; await routes[key](req, res); return out; };
  return { call, queries };
}

test('an email is normalised and hashed apart from phone numbers', () => {
  const { normalizeEmail, emailHash, verifiedEmailHash, identityHashes } = require('../src/shared_expenses/invitations');
  assert.equal(normalizeEmail('  Chandresh@Example.COM '), 'chandresh@example.com');
  assert.throws(() => normalizeEmail('not-an-email'));
  assert.throws(() => normalizeEmail('a@b'));
  assert.equal(emailHash(secret, 'Chandresh@Example.com'), emailHash(secret, 'chandresh@example.com'));
  assert.match(emailHash(secret, 'a@b.co'), /^[a-f0-9]{64}$/);
  assert.notEqual(emailHash(secret, 'a@b.co'), verifiedPhoneHash(secret, { phone: { verified: true, value: '+919876543210' } }));
  assert.equal(verifiedEmailHash(secret, { email: { verified: false, value: 'a@b.co' } }), null);
  assert.equal(verifiedEmailHash(secret, {}), null);
  const both = { email: { verified: true, value: 'a@b.co' }, phone: { verified: true, value: '+919876543210' } };
  assert.equal(identityHashes(secret, both).length, 2);
  assert.equal(identityHashes(secret, both)[0], emailHash(secret, 'a@b.co'), 'email comes first');
  assert.deepEqual(identityHashes(secret, { email: { verified: false }, phone: { verified: false } }), []);
});

test('a person with only a verified email is registered, found by email and sees invites', async () => {
  const { emailHash, createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const writes = [];
  const rig = emailRig((sql) => {
    if (/lookup_phone/.test(sql)) return { found: true, self: false, displayName: 'Chandresh Kerkar', existingContextId: null };
    if (/list_my_invitations/.test(sql)) return { items: [{ invitationId: id, createdAt: '2026-11-10T10:00:00Z', inviterName: 'Sujay K' }] };
    return { status: 'joined' };
  });
  const want = emailHash(secret, 'chandresh@example.com');
  const lookup = await rig.call('POST /shared-expenses/directory/lookup', { userId: actor, body: { email: 'chandresh@example.com' }, verifiedSession: emailOnly });
  assert.equal(lookup.body.found, true);
  assert.equal(rig.queries[0][1][0], want, 'lookup hashes the typed address');
  const inbox = await rig.call('GET /shared-expenses/invitations/inbox', { userId: actor, query: {}, verifiedSession: emailOnly });
  assert.equal(inbox.body.emailVerified, true);
  assert.equal(inbox.body.items.length, 1);
  assert.equal(rig.queries.find(([sql]) => /list_my_invitations/.test(sql))[1][0], want, 'inbox matches on the verified email');
  const accept = await rig.call('POST /shared-expenses/invitations/accept', { userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: emailOnly });
  assert.equal(accept.body.status, 'joined');
  const claim = rig.queries.find(([sql]) => /claim_invitation_by_id/.test(sql));
  assert.equal(claim[1][1], want);
  assert.equal(claim[1][2], null, 'no phone suffix for an email identity');
  const touch = createDirectoryToucher({ withUserClient: async (u, fn) => fn({ query: async (sql, a) => { writes.push(a[0]); return { rows: [{ result: {} }] }; } }), secret });
  assert.equal(await touch({ userId: actor, verifiedSession: emailOnly }), true);
  assert.equal(writes[0], want, 'the directory stores the email hash');
});

test('an invite by email is created, and your own address is refused', async () => {
  const { emailHash } = require('../src/shared_expenses/invitations');
  const ctx = '33333333-3333-4333-8333-333333333333', member = '44444444-4444-4444-8444-444444444444';
  const rig = emailRig(() => ({ invitationId: id, contextId: ctx, memberId: member, status: 'open' }));
  const ok = await rig.call('POST /shared-expenses/invitations', { userId: actor, body: { invitationId: id, contextId: ctx, memberId: member, email: 'Friend@Example.com' }, verifiedSession: emailOnly });
  assert.ok(ok.body.joinUrl);
  assert.equal(JSON.parse(rig.queries[0][1][0]).targetPhoneHash, emailHash(secret, 'friend@example.com'));
  const self = await rig.call('POST /shared-expenses/invitations', { userId: actor, body: { invitationId: id, contextId: ctx, memberId: member, email: 'chandresh@EXAMPLE.com' }, verifiedSession: emailOnly });
  assert.equal(self.code, 400);
  assert.equal(self.body.error, 'invitation_self');
  await assert.rejects(rig.call('POST /shared-expenses/invitations', { userId: actor, body: { invitationId: id, contextId: ctx, memberId: member, email: 'a@b.co', phoneNumber: '9876543210' }, verifiedSession: emailOnly }));
});

test('accept tries the next verified address when the first does not match the invite', async () => {
  const { emailHash } = require('../src/shared_expenses/invitations');
  const both = { verifiedContacts: { email: { verified: true, value: 'a@b.co' }, phone: { verified: true, value: '+919876543210' } } };
  const tried = [];
  const withUserClient = async (_u, fn) => fn({ query: async (sql, args) => { tried.push(args[1]); if (tried.length === 1) throw new Error('invitation_unavailable'); return { rows: [{ result: { status: 'joined' } }] }; } });
  const routes = {};
  require('../src/shared_expenses/invitations').registerInvitationRoutes({ get() {}, post: (p, ...h) => { routes[p] = h[h.length - 1]; } }, { protect: (fn) => [fn], withUserClient, sendError() {}, secret });
  const out = {};
  const res = { status(c) { out.code = c; return res; }, json(b) { out.body = b; return res; } };
  await routes['/shared-expenses/invitations/accept']({ userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: both }, res);
  assert.equal(out.body.status, 'joined');
  assert.equal(tried.length, 2);
  assert.equal(tried[0], emailHash(secret, 'a@b.co'));
  assert.equal(tried[1], verifiedPhoneHash(secret, both.verifiedContacts));
});
