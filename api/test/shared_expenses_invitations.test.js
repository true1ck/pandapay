'use strict';
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
  assert.deepEqual((await call('GET /shared-expenses/invitations/inbox', { userId: actor, query: {}, verifiedSession: unverified })).body, { phoneVerified: false, items: [] });
  const before = queries.length;
  const denied = await call('POST /shared-expenses/invitations/accept', { userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: unverified });
  assert.equal(denied.code, 409);
  assert.equal(queries.length, before, 'no database call without a verified phone');
  const ok = await call('POST /shared-expenses/invitations/decline', { userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: verified });
  assert.equal(ok.body.status, 'joined');
  const own = await call('POST /shared-expenses/directory/lookup', { userId: actor, body: { phoneNumber: '+919999999999', extra: 1 }, verifiedSession: verified }).catch((e) => e);
  assert.ok(own instanceof Error || own.code, 'unexpected body fields are refused');
});
