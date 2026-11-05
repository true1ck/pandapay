'use strict';
// Lane U (LO-10, LO-15): App Check tokens are bound to the account and installation, limited-use
// replay protection is available behind config, and debug tokens do not reach production.
// Run: node --test api/test/sms_v2/lane_u_attestation.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const { createAppCheckVerifier, createSecurity, createAttestationBinder, createLimitedUseConsumer } = require('../../src/sms_v2/security');

const projectNumber = '123456789';
const appId = '1:123456789:android:synthetic';
const key = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...key.publicKey.export({ format: 'jwk' }), kid: 'test-key', use: 'sig', alg: 'RS256' };
const now = Date.parse('2026-11-20T10:00:00Z');
const ALICE = '00000000-0000-4000-8000-0000000000a1';
const BOB = '00000000-0000-4000-8000-0000000000b2';
const PHONE_A = '2ba4d7d3-8b21-4c76-985a-650f099bca3e';
const PHONE_B = '9c1e0f55-1d7b-4f43-8b5c-0a0e5f6a7b8c';

function token(extra = {}) {
  const claims = {
    sub: appId, iss: `https://firebaseappcheck.googleapis.com/${projectNumber}`,
    aud: [`projects/${projectNumber}`], iat: now / 1000 - 60, exp: now / 1000 + 300, ...extra,
  };
  return jwt.sign(claims, key.privateKey, { algorithm: 'RS256', keyid: 'test-key', header: { typ: 'JWT' } });
}
const request = (user, device, attestation) => ({
  userId: user,
  headers: { 'x-sms-device-id': device, ...(attestation ? { 'x-device-attestation': attestation } : {}) },
  res: { headers: {}, set(k, v) { this.headers[k] = v; } },
});
const verifier = (options = {}) => createAppCheckVerifier({
  projectNumber, appIds: [appId], now: () => now, fetchJwks: async () => ({ keys: [jwk] }), ...options,
});
const consume = async () => ({ allowed: true, retryAfterSeconds: 0 });
const make = (env = {}, options = {}) => createSecurity({ env, verifyToken: verifier(), consume, now: () => now, log: () => {}, ...options });

// ---- LO-10 binding ----

test('LO-10 a token first used by one account is not verified for another account', async () => {
  const security = make();
  const t = token();
  const alice = request(ALICE, PHONE_A, t);
  assert.equal(await security.verifyAttestation(alice), true);
  assert.equal(alice.smsV2Security.verified, true);
  const bob = request(BOB, PHONE_A, t);
  assert.equal(await security.verifyAttestation(bob), true, 'monitor mode still admits');
  assert.equal(bob.smsV2Security.verified, false);
  assert.equal(bob.smsV2Security.sharedLearningEligible, false);
});

test('LO-10 a token is also bound to the installation id', async () => {
  const security = make();
  const t = token();
  assert.equal((await (async () => { const r = request(ALICE, PHONE_A, t); await security.verifyAttestation(r); return r; })()).smsV2Security.verified, true);
  const other = request(ALICE, PHONE_B, t);
  await security.verifyAttestation(other);
  assert.equal(other.smsV2Security.verified, false);
  const same = request(ALICE, PHONE_A, t);
  await security.verifyAttestation(same);
  assert.equal(same.smsV2Security.verified, true, 'the owner keeps working');
});

test('LO-10 enforce mode rejects a replayed token and monitor mode halves its limits', async () => {
  const t = token();
  const enforce = make({ SMS_V2_ATTESTATION_MODE: 'enforce' });
  assert.equal(await enforce.verifyAttestation(request(ALICE, PHONE_A, t)), true);
  assert.equal(await enforce.verifyAttestation(request(BOB, PHONE_A, t)), false);

  const limits = [];
  const monitor = make({}, { consume: async (_p, _d, checks) => { limits.push(checks[0].limit); return { allowed: true, retryAfterSeconds: 0 }; } });
  const t2 = token({ exp: now / 1000 + 301 });
  await monitor.checkRate(request(ALICE, PHONE_A, t2), 'sync');
  await monitor.checkRate(request(BOB, PHONE_A, t2), 'sync');
  assert.deepEqual(limits, [120, 60]);
});

test('LO-10 monitor mode behaviour without a token is unchanged', async () => {
  const security = make();
  const req = request(ALICE, PHONE_A);
  assert.equal(await security.verifyAttestation(req), true);
  assert.equal(req.smsV2Security.verified, false);
  assert.equal(await make({ SMS_V2_ATTESTATION_MODE: 'enforce' }).verifyAttestation(request(ALICE, PHONE_A)), false);
});

test('LO-10 binding can be switched off and rejects bad config', async () => {
  const security = make({ SMS_V2_ATTESTATION_BINDING: 'off' });
  const t = token();
  await security.verifyAttestation(request(ALICE, PHONE_A, t));
  const bob = request(BOB, PHONE_A, t);
  await security.verifyAttestation(bob);
  assert.equal(bob.smsV2Security.verified, true);
  assert.throws(() => make({ SMS_V2_ATTESTATION_BINDING: 'db' }), /binding_invalid/);
  assert.throws(() => make({ SMS_V2_ATTESTATION_BINDING: 'x' }), /binding_invalid/);
});

test('LO-10 db mode records the first sighting in Postgres and trusts its verdict', async () => {
  const calls = [];
  const owners = new Map();
  const withUserClient = async (profile, fn) => fn({ query: async (sql, params) => {
    calls.push({ profile, sql, params });
    assert.match(sql, /sms_v2_bind_attestation/);
    const [digest, device] = params;
    if (!owners.has(digest)) owners.set(digest, { profile, device });
    const owner = owners.get(digest);
    return { rows: [{ bound: owner.profile === profile && owner.device === device }] };
  } });
  const security = make({ SMS_V2_ATTESTATION_BINDING: 'db' }, { withUserClient });
  const t = token();
  const a = request(ALICE, PHONE_A, t);
  await security.verifyAttestation(a);
  assert.equal(a.smsV2Security.verified, true);
  await security.verifyAttestation(request(ALICE, PHONE_A, t)); // process cache: no second query
  assert.equal(calls.length, 1);
  assert.match(calls[0].params[0], /^[0-9a-f]{64}$/);
  assert.match(calls[0].params[1], /^[0-9a-f]{64}$/);
  assert.ok(!calls[0].params.includes(t), 'the raw token never reaches the database');
  assert.ok(!calls[0].params.includes(PHONE_A), 'the raw installation id never reaches the database');
  // A different replica (empty cache) gets the same answer from the database.
  const other = make({ SMS_V2_ATTESTATION_BINDING: 'db' }, { withUserClient });
  const b = request(BOB, PHONE_A, t);
  await other.verifyAttestation(b);
  assert.equal(b.smsV2Security.verified, false);
  const again = request(ALICE, PHONE_A, t);
  await other.verifyAttestation(again);
  assert.equal(again.smsV2Security.verified, true, 'a conflict is not cached against the owner');
});

test('LO-10 a malformed database answer or outage surfaces as an error, never as verified', async () => {
  const bad = make({ SMS_V2_ATTESTATION_BINDING: 'db' }, { withUserClient: async (_p, fn) => fn({ query: async () => ({ rows: [{}] }) }) });
  await assert.rejects(bad.verifyAttestation(request(ALICE, PHONE_A, token())), /binding_invalid_result/);
  const down = make({ SMS_V2_ATTESTATION_BINDING: 'db' }, { withUserClient: async () => { throw new Error('down'); } });
  await assert.rejects(down.verifyAttestation(request(ALICE, PHONE_A, token())), /down/);
});

test('LO-10 production defaults to durable binding when a database client exists', async () => {
  let queried = 0;
  const withUserClient = async (_p, fn) => fn({ query: async () => { queried += 1; return { rows: [{ bound: true }] }; } });
  const security = make({ NODE_ENV: 'production' }, { withUserClient });
  await security.verifyAttestation(request(ALICE, PHONE_A, token()));
  assert.equal(queried, 1);
});

test('LO-10 the process cache is bounded and forgets expired tokens', async () => {
  let clock = 1000;
  const bind = createAttestationBinder({ mode: 'memory', now: () => clock });
  assert.equal(await bind(ALICE, 'a'.repeat(64), 'd'.repeat(64), 5000), true);
  assert.equal(await bind(BOB, 'a'.repeat(64), 'd'.repeat(64), 5000), false);
  clock = 6000;
  assert.equal(await bind(BOB, 'a'.repeat(64), 'd'.repeat(64), 9000), true, 'expired binding is gone');
  assert.equal(await bind(null, 'b'.repeat(64), 'd'.repeat(64), 9000), false, 'no profile, no binding');
});

// ---- LO-10 limited-use tokens ----

test('LO-10 limited-use replay protection is off by default', async () => {
  let consumed = 0;
  const security = make({}, { consumeLimitedUse: async () => { consumed += 1; return false; } });
  const req = request(ALICE, PHONE_A, token());
  assert.equal(await security.checkRate(req, 'corrections', 1), true);
  assert.equal(consumed, 0);
  assert.equal(req.smsV2Security.verified, true);
});

test('LO-10 with replay protection on, a consumed token is not verified on high-value routes only', async () => {
  const limits = [];
  const record = async (_p, _d, checks) => { limits.push(checks[0].limit); return { allowed: true, retryAfterSeconds: 0 }; };
  let fresh = true;
  const on = (extra = {}) => make({ SMS_V2_APPCHECK_REPLAY_PROTECTION: 'on', ...extra }, { consume: record, consumeLimitedUse: async () => fresh });
  const monitor = on();
  const ok = request(ALICE, PHONE_A, token());
  assert.equal(await monitor.checkRate(ok, 'corrections', 1), true);
  assert.equal(ok.smsV2Security.verified, true);
  fresh = false;
  const replayed = request(ALICE, PHONE_A, token({ exp: now / 1000 + 299 }));
  assert.equal(await monitor.checkRate(replayed, 'corrections', 1), true, 'monitor admits at half limits');
  assert.equal(replayed.smsV2Security.verified, false);
  assert.equal(replayed.smsV2Security.sharedLearningEligible, false);
  assert.deepEqual(limits, [200, 100]);
  const sync = request(ALICE, PHONE_A, token({ exp: now / 1000 + 298 }));
  assert.equal(await monitor.checkRate(sync, 'sync', 1), true);
  assert.equal(sync.smsV2Security.verified, true, 'sync is not a limited-use route');
  const enforce = on({ SMS_V2_ATTESTATION_MODE: 'enforce' });
  assert.equal(await enforce.checkRate(request(ALICE, PHONE_A, token({ exp: now / 1000 + 297 })), 'rule-stats', 1), false);
});

test('LO-10 replay protection refuses to start without credentials and fails closed on errors', async () => {
  assert.throws(() => make({ SMS_V2_APPCHECK_REPLAY_PROTECTION: 'on' }), /replay_unconfigured/);
  assert.throws(() => make({ SMS_V2_APPCHECK_REPLAY_PROTECTION: 'maybe' }), /replay_invalid/);
  const seen = [];
  const consume = createLimitedUseConsumer({
    projectNumber, getAccessToken: async () => 'access',
    fetchImpl: async (url, init) => { seen.push({ url, init }); return { ok: true, json: async () => ({ alreadyConsumed: false }) }; },
  });
  assert.equal(await consume('tok'), true);
  assert.match(seen[0].url, /projects\/123456789:verifyAppCheckToken$/);
  assert.equal(seen[0].init.headers.authorization, 'Bearer access');
  assert.deepEqual(JSON.parse(seen[0].init.body), { appCheckToken: 'tok' });
  const cases = [
    async () => ({ ok: true, json: async () => ({ alreadyConsumed: true }) }),
    async () => ({ ok: false, json: async () => ({}) }),
    async () => { throw new Error('network'); },
  ];
  for (const fetchImpl of cases) {
    assert.equal(await createLimitedUseConsumer({ projectNumber, getAccessToken: async () => 'a', fetchImpl })('tok'), false);
  }
  assert.equal(await createLimitedUseConsumer({ projectNumber, getAccessToken: async () => { throw new Error('no creds'); }, fetchImpl: async () => ({ ok: true, json: async () => ({}) }) })('tok'), false);
});

// ---- LO-15 debug providers ----

test('LO-15 the verifier rejects debug-provider tokens when told to, and by dedicated app id', async () => {
  const open = verifier();
  assert.ok(await open(token({ provider: 'debug' })), 'allowed outside production');
  const strict = verifier({ rejectDebug: true });
  assert.ok(await strict(token()));
  assert.equal(await strict(token({ provider: 'debug' })), null);
  assert.equal(await strict(token({ firebase: { provider: 'AppCheckDebug' } })), null);
  const byApp = createAppCheckVerifier({ projectNumber, appIds: [appId, '1:1:ios:dbg'], rejectDebug: true, debugAppIds: ['1:1:ios:dbg'],
    now: () => now, fetchJwks: async () => ({ keys: [jwk] }) });
  assert.equal(await byApp(token({ sub: '1:1:ios:dbg' })), null);
  assert.ok(await byApp(token()));
});

test('LO-15 production rejects debug tokens unless SMS_V2_ALLOW_DEBUG_APP_CHECK=true', async () => {
  const base = { SMS_V2_FIREBASE_PROJECT_NUMBER: projectNumber, SMS_V2_FIREBASE_APP_IDS: `${appId},1:1:ios:dbg` };
  const build = (env) => createSecurity({ env: { ...base, ...env }, consume, now: () => now, log: () => {}, fetchJwks: async () => ({ keys: [jwk] }) });
  const verified = async (env, extra) => {
    const req = request(ALICE, PHONE_A, token(extra));
    await build(env).verifyAttestation(req);
    return req.smsV2Security.verified;
  };
  assert.equal(await verified({ NODE_ENV: 'production' }, { provider: 'debug' }), false);
  assert.equal(await verified({ NODE_ENV: 'production', SMS_V2_DEBUG_APP_IDS: '1:1:ios:dbg' }, { sub: '1:1:ios:dbg' }), false);
  assert.equal(await verified({ NODE_ENV: 'production', SMS_V2_ALLOW_DEBUG_APP_CHECK: 'true' }, { provider: 'debug' }), true);
  assert.equal(await verified({ NODE_ENV: 'development' }, { provider: 'debug' }), true);
  assert.equal(await verified({ NODE_ENV: 'production' }, {}), true, 'a normal token still verifies in production');
});
