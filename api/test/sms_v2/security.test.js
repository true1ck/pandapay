'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const { createAppCheckVerifier, createSecurity, createPgRateStore } = require('../../src/sms_v2/security');

const projectNumber = '123456789';
const appId = '1:123456789:android:synthetic';
const key = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...key.publicKey.export({ format: 'jwk' }), kid: 'test-key', use: 'sig', alg: 'RS256' };
const now = Date.parse('2026-11-20T10:00:00Z');
function token(extra = {}, options = {}) {
  const claims = {
    sub: appId, iss: `https://firebaseappcheck.googleapis.com/${projectNumber}`,
    aud: [`projects/${projectNumber}`], iat: now / 1000 - 60, exp: now / 1000 + 300,
    ...extra,
  };
  for (const key of Object.keys(claims)) if (claims[key] === undefined) delete claims[key];
  return jwt.sign(claims, key.privateKey, { algorithm: 'RS256', keyid: 'test-key', header: { typ: 'JWT' }, ...options });
}
function request(attestation) {
  const headers = { 'x-sms-device-id': '2ba4d7d3-8b21-4c76-985a-650f099bca3e' };
  if (attestation) headers['x-device-attestation'] = attestation;
  return { userId: '00000000-0000-4000-8000-000000000001', headers, res: { headers: {}, set(k,v) { this.headers[k] = v; } } };
}
const verifier = (options = {}) => createAppCheckVerifier({
  projectNumber, appIds: [appId], now: () => now,
  fetchJwks: async () => ({ keys: [jwk] }), ...options,
});

test('App Check validates signature, expiry, issuer, audience, subject and algorithm', async () => {
  const verify = verifier();
  assert.equal((await verify(token())).appId, appId);
  for (const value of [
    token({ exp: now / 1000 - 1 }),
    token({ iss: 'https://attacker.invalid/' }),
    token({ aud: ['projects/999'] }),
    token({ sub: 'other-app' }),
    token({ exp: undefined }),
    'not-a-token',
  ]) assert.equal(await verify(value), null);
  assert.equal(await verify(jwt.sign({ sub: appId }, 'wrong-key')), null);
});

test('JWKS refresh is coalesced and keys cache for six hours', async () => {
  let reads = 0;
  let clock = now;
  const verify = verifier({ now: () => clock, fetchJwks: async () => { reads++; return { keys: [jwk] }; } });
  await Promise.all(Array.from({ length: 20 }, () => verify(token())));
  assert.equal(reads, 1);
  await verify(token());
  assert.equal(reads, 1);
  clock += 6 * 60 * 60 * 1000 + 1;
  await verify(token({ exp: clock / 1000 + 300 }));
  assert.equal(reads, 2);
});

test('monitor accepts unverified devices with lower limits and no shared learning', async () => {
  const recorded = [];
  const security = createSecurity({
    env: {}, verifyToken: verifier(),
    consume: async (profile, device, checks) => { recorded.push({ profile, device, checks }); return { allowed: true, retryAfterSeconds: 0 }; },
    log: () => {},
  });
  const req = request();
  assert.equal(await security.verifyAttestation(req), true);
  assert.equal(req.smsV2Security.verified, false);
  assert.equal(req.smsV2Security.sharedLearningEligible, false);
  assert.equal(await security.checkRate(req, 'facts:batch', 500), true);
  assert.deepEqual(recorded[0].checks.map(x => x.limit), [30, 10000]);
  assert.deepEqual(recorded[0].checks.map(x => x.units), [1, 500]);
  assert.match(recorded[0].device, /^[0-9a-f]{64}$/);
});

test('enforce rejects missing and invalid tokens and accepts a verified one', async () => {
  const security = createSecurity({
    env: { SMS_V2_ATTESTATION_MODE: 'enforce' }, verifyToken: verifier(),
    consume: async () => ({ allowed: true }), log: () => {},
  });
  assert.equal(await security.verifyAttestation(request()), false);
  assert.equal(await security.verifyAttestation(request('invalid')), false);
  const req = request(token());
  assert.equal(await security.verifyAttestation(req), true);
  assert.equal(req.smsV2Security.sharedLearningEligible, true);
});

test('each route has its budget and Retry-After comes from shared storage', async () => {
  const captured = [];
  const security = createSecurity({
    env: {}, verifyToken: verifier(),
    consume: async (_profile, _device, checks) => { captured.push(checks); return { allowed: false, retryAfterSeconds: 17 }; },
    log: () => {},
  });
  for (const route of ['facts:batch', 'rules', 'sync', 'unknown-templates', 'corrections', 'rule-stats']) {
    const req = request(token());
    assert.equal(await security.checkRate(req, route, 2), false);
    assert.equal(req.res.headers['Retry-After'], '17');
  }
  assert.deepEqual(captured.map(checks => checks.map(x => x.limit)), [[60,20000],[30],[120],[50],[200],[24]]);
  assert.deepEqual(captured.map(checks => checks.map(x => x.units)), [[1,2],[1],[1],[2],[2],[1]]);
});

test('entitlement is open by default and fails closed when required', async () => {
  const opts = { consume: async () => ({ allowed: true }), log: () => {} };
  assert.equal(await createSecurity({ ...opts, env: {} }).checkEntitlement(request()), true);
  assert.equal(await createSecurity({ ...opts, env: { SMS_V2_REQUIRE_ENTITLEMENT: 'true' } }).checkEntitlement(request()), false);
  assert.equal(await createSecurity({ ...opts, env: { SMS_V2_REQUIRE_ENTITLEMENT: 'true' }, hasEntitlement: async () => true }).checkEntitlement(request()), true);
});

test('Postgres adapter binds profile, device and budgets and validates response', async () => {
  let called;
  const consume = createPgRateStore({ withUserClient: async (id, operation) => {
    assert.equal(id, 'p');
    return operation({ query: async (sql, values) => { called = { sql, values }; return { rows: [{ allowed: false, retry_after_seconds: 25 }] }; } });
  } });
  const checks = [{ bucket: 'sync', seconds: 3600, limit: 120, units: 1 }];
  assert.deepEqual(await consume('p', 'd', checks), { allowed: false, retryAfterSeconds: 25 });
  assert.match(called.sql, /sms_v2_consume_rate/);
  assert.deepEqual(called.values, ['d', JSON.stringify(checks)]);
});

test('a tester the owner chose to count is eligible without App Check; limits still treat the phone as unverified', async () => {
  const asked = [];
  const security = createSecurity({
    env: { SMS_V2_ATTESTATION_BINDING: 'off' }, verifyToken: verifier(), now: () => now,
    withUserClient: async (profile, operation) => operation({
      query: async (sql) => { asked.push(sql); return { rows: [{ counts: true }] }; },
    }),
    consume: async () => ({ allowed: true, retryAfterSeconds: 0 }),
    log: () => {},
  });
  const first = request();
  assert.equal(await security.verifyAttestation(first), true);
  assert.equal(first.smsV2Security.verified, false, 'rate limits trust only a real attestation');
  assert.equal(first.smsV2Security.sharedLearningEligible, true);
  const second = request();
  await security.verifyAttestation(second);
  assert.equal(second.smsV2Security.sharedLearningEligible, true);
  assert.equal(asked.length, 1, 'asked once a minute per account, not on every request');
  assert.match(asked[0], /sms_v2_tester_counts/);
});

test('a phone that is not counted, or when the question fails, stays not eligible and the request is never refused for it', async () => {
  for (const withUserClient of [
    async (_profile, operation) => operation({ query: async () => ({ rows: [{ counts: false }] }) }),
    async () => { throw new Error('database down'); },
  ]) {
    const security = createSecurity({
      env: { SMS_V2_ATTESTATION_BINDING: 'off' }, verifyToken: verifier(), now: () => now, withUserClient,
      consume: async () => ({ allowed: true, retryAfterSeconds: 0 }), log: () => {},
    });
    const req = request();
    assert.equal(await security.verifyAttestation(req), true);
    assert.equal(req.smsV2Security.sharedLearningEligible, false);
  }
});

test('a real attestation is unchanged by the tester setting', async () => {
  let asked = 0;
  const security = createSecurity({
    env: { SMS_V2_ATTESTATION_BINDING: 'off' }, verifyToken: verifier(), now: () => now,
    withUserClient: async () => { asked++; return false; },
    consume: async () => ({ allowed: true, retryAfterSeconds: 0 }), log: () => {},
  });
  const req = request(token());
  assert.equal(await security.verifyAttestation(req), true);
  assert.equal(req.smsV2Security.verified, true);
  assert.equal(req.smsV2Security.sharedLearningEligible, true);
  assert.equal(asked, 0, 'no question is asked for an attested phone');
});
