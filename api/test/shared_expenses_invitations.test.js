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

test('creating a group link carries the chosen join mode in the same transaction', async () => {
  const { registerInvitationRoutes } = require('../src/shared_expenses/invitations');
  const routes = {};
  const app = { get() {}, post: (path, ...h) => { routes['POST ' + path] = h[h.length - 1]; } };
  const queries = [];
  const withUserClient = async (_u, fn) => fn({ query: async (sql, args) => {
    queries.push([sql, args]);
    if (/set_group_link_mode/.test(sql)) return { rows: [{ result: { autoJoin: args[1] } }] };
    return { rows: [{ result: { contextId: args[0], active: true } }] };
  } });
  registerInvitationRoutes(app, { protect: (fn) => [fn], withUserClient, sendError() {}, secret, androidPackageId: 'x' });
  const ctx = '33333333-3333-4333-8333-333333333333', link = '44444444-4444-4444-8444-444444444444';
  const call = async (body) => {
    const out = {}; const res = { status(c) { out.code = c; return res; }, json(b) { out.body = b; return res; } };
    await routes['POST /shared-expenses/groups/link']({ userId: actor, body }, res); return out;
  };
  const open = await call({ contextId: ctx, linkId: link, autoJoin: true });
  assert.equal(open.body.autoJoin, true);
  const creds = require('../src/shared_expenses/invitations').groupLinkCredentials(secret, actor, ctx, link);
  const set = queries.find(([sql]) => /set_group_link_mode/.test(sql));
  assert.deepEqual(set[1], [ctx, true, creds.tokenHash], 'only the hash of THIS link is given, never the token');
  // Left out means approval (the safe, old behaviour).
  queries.length = 0;
  const approval = await call({ contextId: ctx, linkId: link });
  assert.equal(approval.body.autoJoin, false);
  assert.equal(queries.find(([sql]) => /set_group_link_mode/.test(sql))[1][1], false);
  // Anything that is not a boolean is refused before the database is touched.
  queries.length = 0;
  const bad = await call({ contextId: ctx, linkId: link, autoJoin: 'yes' }).catch((e) => e);
  assert.ok(bad instanceof Error || bad.code, 'non-boolean autoJoin is refused');
  assert.equal(queries.length, 0);
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

// People are found by the number we hold for them. Nobody confirms numbers by code, so no number is "verified".
const onFileOnly = { verifiedContacts: { phone: { verified: false, value: null }, email: { verified: true, value: 'friend@example.com' } }, claimedContacts: { phone: { claimed: false, value: null } }, phoneOnFile: { value: '+917030445936' } };
function onFileRig(responder) {
  const routes = {}, queries = [];
  const app = { get: (p, ...h) => { routes['GET ' + p] = h[h.length - 1]; }, post: (p, ...h) => { routes['POST ' + p] = h[h.length - 1]; } };
  const withUserClient = async (_u, fn) => fn({ query: async (sql, args) => { queries.push([sql, args]); if (/register_phone/.test(sql)) return { rows: [{ result: {} }] }; return { rows: [{ result: responder(sql, args) }] }; } });
  require('../src/shared_expenses/invitations').registerInvitationRoutes(app, { protect: (fn) => [fn], withUserClient, sendError() {}, secret, androidPackageId: 'x' });
  const call = async (key, req) => { const out = {}; const res = { status(c) { out.code = c; return res; }, json(b) { out.body = b; return res; } }; await routes[key](req, res); return out; };
  return { call, queries };
}

test('the number to match is the verified one, else a typed one, else the number on file', () => {
  const { sessionPhone, sessionPhoneHash } = require('../src/shared_expenses/invitations');
  assert.equal(sessionPhone(onFileOnly), '+917030445936');
  assert.equal(sessionPhone({ ...onFileOnly, phoneOnFile: { value: '7030445936' } }), '+917030445936', 'a bare ten digit number is read as Indian');
  assert.equal(sessionPhone({ ...onFileOnly, claimedContacts: { phone: { claimed: true, value: '+919999900000' } } }), '+919999900000', 'typed beats on file');
  assert.equal(sessionPhone({ ...onFileOnly, verifiedContacts: { phone: { verified: true, value: '+918888800000' } } }), '+918888800000', 'verified beats typed');
  assert.equal(sessionPhone({ verifiedContacts: {}, phoneOnFile: { value: 'garbage' } }), null, 'an unusable number is ignored, never thrown');
  assert.equal(sessionPhone({ verifiedContacts: {} }), null);
  assert.equal(sessionPhoneHash(secret, onFileOnly), verifiedPhoneHash(secret, { phone: { verified: true, value: '+917030445936' } }), 'same hash whether or not it was verified');
});

test('a person whose number is only on file is registered, found by that number and sees invites', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const want = verifiedPhoneHash(secret, { phone: { verified: true, value: '+917030445936' } });
  const rig = onFileRig((sql) => {
    if (/lookup_phone/.test(sql)) return { found: true, self: false, displayName: 'Chandresh Kerkar', existingContextId: null };
    if (/list_my_invitations/.test(sql)) return { items: [{ invitationId: id, inviterName: 'Sujay K' }] };
    return { status: 'awaiting_owner' };
  });
  // Another person types his number: the lookup hashes it the same way.
  const lookup = await rig.call('POST /shared-expenses/directory/lookup', { userId: actor, body: { phoneNumber: '70304 45936' }, verifiedSession: { verifiedContacts: {} } });
  assert.equal(lookup.body.found, true);
  assert.equal(rig.queries[0][1][0], want);
  // He opens the app: his inbox is matched on the number on file.
  const inbox = await rig.call('GET /shared-expenses/invitations/inbox', { userId: actor, query: {}, verifiedSession: onFileOnly });
  assert.equal(inbox.body.items.length, 1);
  assert.equal(rig.queries.find(([sql]) => /list_my_invitations/.test(sql))[1][0], want);
  // And can accept: no verified number, so no number suffix is stored.
  const accept = await rig.call('POST /shared-expenses/invitations/accept', { userId: actor, body: { invitationId: id, operationId: id }, verifiedSession: onFileOnly });
  assert.equal(accept.body.status, 'awaiting_owner');
  const claim = rig.queries.find(([sql]) => /claim_invitation_by_id/.test(sql));
  assert.equal(claim[1][1], want);
  assert.equal(claim[1][2], null);
  // His app registers him in the directory on any request.
  const writes = [];
  const touch = createDirectoryToucher({ withUserClient: async (u, fn) => fn({ query: async (sql, a) => { writes.push(a[0]); return { rows: [{ result: {} }] }; } }), secret });
  assert.equal(await touch({ userId: actor, verifiedSession: onFileOnly }), true);
  assert.equal(writes[0], want);
});

test('your own number on file is refused as an invite target, and no number means no registration', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const ctx = '33333333-3333-4333-8333-333333333333', member = '44444444-4444-4444-8444-444444444444';
  const rig = onFileRig(() => ({ invitationId: id, contextId: ctx, memberId: member, status: 'open' }));
  const self = await rig.call('POST /shared-expenses/invitations', { userId: actor, body: { invitationId: id, contextId: ctx, memberId: member, phoneNumber: '+91 70304 45936' }, verifiedSession: onFileOnly });
  assert.equal(self.code, 400);
  assert.equal(self.body.error, 'invitation_self');
  let calls = 0;
  const touch = createDirectoryToucher({ withUserClient: async () => { calls++; return {}; }, secret });
  assert.equal(await touch({ userId: actor, verifiedSession: { verifiedContacts: {}, phoneOnFile: { value: null } } }), false);
  assert.equal(calls, 0);
  const none = await rig.call('GET /shared-expenses/invitations/inbox', { userId: actor, query: {}, verifiedSession: { verifiedContacts: {} } });
  assert.equal(none.body.items.length, 0, 'an account with no number simply has no invites');
});

// A phone opening the app sends several requests at once. The directory write must not multiply by that, and it must
// never take a database connection a real request is waiting for (the 10-connection pool ran dry and requests got 503).
function deferredClient() {
  const started = [];
  const withUserClient = (user, fn) => new Promise((resolve, reject) => {
    started.push({ user, finish: () => resolve(fn({ query: async () => ({ rows: [{ result: {} }] }) })), fail: () => reject(new Error('db down')) });
  });
  return { started, withUserClient };
}
const verifiedFor = (userId, value = '+919876543210') => ({ userId, verifiedSession: { verifiedContacts: { phone: { verified: true, value } } } });
const tick = () => new Promise((r) => setImmediate(r));

test('directory registration: a burst of requests from one person makes one write', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const { started, withUserClient } = deferredClient();
  const touch = createDirectoryToucher({ withUserClient, secret });
  const burst = Array.from({ length: 6 }, () => touch(verifiedFor(actor)));
  await tick();
  assert.equal(started.length, 1, 'six parallel requests, one write');
  started[0].finish();
  const results = await Promise.all(burst);
  assert.equal(results.filter(Boolean).length, 1, 'only the first one did the work');
  assert.equal(await touch(verifiedFor(actor)), false, 'then throttled for the day as before');
  assert.equal(started.length, 1);
});

test('directory registration: at most two writes run at once; the rest wait for a later request', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const { started, withUserClient } = deferredClient();
  const touch = createDirectoryToucher({ withUserClient, secret, maxInFlight: 2 });
  const people = ['a', 'b', 'c', 'd', 'e'].map((c) => c.repeat(8) + '-1111-4111-8111-' + c.repeat(12));
  const first = people.map((p) => touch(verifiedFor(p)));
  await tick();
  assert.equal(started.length, 2, 'two people at a time');
  assert.deepEqual((await Promise.all(first.slice(2))), [false, false, false], 'the others are skipped, not queued');
  started[0].finish(); started[1].finish();
  await Promise.all(first.slice(0, 2));
  // Nothing was recorded for the skipped ones, so their next request registers them.
  const next = people.slice(2).map((p) => touch(verifiedFor(p)));
  await tick();
  assert.equal(started.length, 4, 'two more started, one still waits');
  assert.equal(await next[2], false, 'the third is skipped again, not queued');
  started[2].finish(); started[3].finish();
  assert.deepEqual(await Promise.all(next.slice(0, 2)), [true, true]);
});

test('directory registration: while the connection pool is short nothing is written or recorded', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const { started, withUserClient } = deferredClient();
  let busy = true;
  const touch = createDirectoryToucher({ withUserClient, secret, busy: () => busy });
  assert.equal(await touch(verifiedFor(actor)), false);
  assert.equal(started.length, 0, 'a request that needs the database always comes first');
  busy = false;
  const done = touch(verifiedFor(actor));
  await tick();
  assert.equal(started.length, 1, 'once connections are free, the very next request registers the person');
  started[0].finish();
  assert.equal(await done, true);
});

test('directory registration: a failed write frees its slot (and backs off for that person)', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  const { started, withUserClient } = deferredClient();
  let clock = 1000;
  const touch = createDirectoryToucher({ withUserClient, secret, maxInFlight: 1, now: () => clock });
  const other = '99999999-9999-4999-8999-999999999999';
  const failing = touch(verifiedFor(actor));
  await tick();
  assert.equal(await touch(verifiedFor(other)), false, 'the only slot is taken');
  started[0].fail();
  assert.equal(await failing, false, 'a database failure is swallowed');
  const second = touch(verifiedFor(other));
  await tick();
  assert.equal(started.length, 2, 'the slot is free again after the failure');
  started[1].finish();
  assert.equal(await second, true);
  assert.equal(await touch(verifiedFor(actor)), false, 'the failed person is not retried straight away');
});

test('directory registration: a database call that throws at once cannot leave a slot stuck', async () => {
  const { createDirectoryToucher } = require('../src/shared_expenses/invitations');
  let mode = 'throw-sync', calls = 0;
  const withUserClient = (_user, fn) => {
    calls++;
    if (mode === 'throw-sync') throw new Error('thrown before any promise exists');
    return Promise.resolve(fn({ query: async () => ({ rows: [{ result: {} }] }) }));
  };
  let clock = 1000;
  const touch = createDirectoryToucher({ withUserClient, secret, maxInFlight: 1, ttlMs: 100, retryMs: 50, now: () => clock });
  const a = '11111111-1111-4111-8111-111111111111', b = '22222222-2222-4222-8222-222222222222';
  // Three failures in a row with a single slot: if a slot leaked, the second person would never be tried.
  assert.equal(await touch(verifiedFor(a)), false);
  assert.equal(await touch(verifiedFor(b)), false);
  assert.equal(calls, 2, 'both were attempted: the slot was released after each failure');
  mode = 'ok';
  clock += 1000;
  assert.equal(await touch(verifiedFor(a)), true, 'and the feature still works once the database does');
  assert.equal(await touch(verifiedFor(b)), true);
});
