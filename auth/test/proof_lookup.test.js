'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createProofLookupHandler, OWN_ACCOUNT_STATUS_SQL } = require('../src/routes/proofLookupRoutes');

const SUBJECT = '10000000-0000-4000-8000-000000000001';
const OTHER = '10000000-0000-4000-8000-000000000002';
const NOW = 1792810000000;

function proof(overrides = {}) {
  return {
    token_valid: true, valid: true, guest: false, subject: SUBJECT, device_id: 'signed-device',
    session: { active: true, revoked: false },
    auth_proof: { channel: 'email', verified_at: Math.floor(NOW/1000)-10 },
    verified_contacts: { email: { verified: true, value: 'operator@example.test' }, phone: { verified: true, value: '+919000000001' } },
    ...overrides,
  };
}

function harness({ proofs = [proof()], rows = [{ id: SUBJECT, profile_complete: true, device_active: true, google_linked: true }], queryError } = {}) {
  const queries = [], tokens = [];
  let index = 0;
  const handler = createProofLookupHandler({
    now: () => NOW,
    verifySession: async token => {
      tokens.push(token);
      const value = proofs[Math.min(index++, proofs.length-1)];
      if (value instanceof Error) throw value;
      return value;
    },
    query: async (sql, values) => { queries.push({ sql, values }); if (queryError) throw queryError; return { rows }; },
  });
  async function request({ authorization = 'Bearer synthetic-signed-access', body = {}, query = {} } = {}) {
    let status = 200, data;
    const headers = {};
    const res = { setHeader(key, value) { headers[key] = value; }, status(value) { status = value; return this; }, json(value) { data = value; return this; } };
    await handler({ headers: { authorization }, body, query }, res);
    return { status, data, headers };
  }
  return { request, queries, tokens };
}

test('proof lookup requires explicit verifier/database dependencies', () => {
  assert.throws(() => createProofLookupHandler(), /explicit session/);
  assert.throws(() => createProofLookupHandler({ verifySession() {} }), /explicit session/);
});

test('missing, malformed, duplicate-looking and oversized bearer inputs never query identity', async () => {
  const h = harness();
  for (const authorization of [undefined, '', 'Basic value', 'Bearer ', 'Bearer a b', 'Bearer a, Bearer b', ['Bearer a'], 'Bearer '+ 'a'.repeat(8193)]) {
    // undefined is deliberately translated to a missing header by null here.
    const result = await h.request({ authorization: authorization === undefined ? null : authorization });
    assert.equal(result.status, 401); assert.deepEqual(result.data, { error: 'proof_required' });
  }
  assert.equal(h.queries.length, 0); assert.equal(h.tokens.length, 0);
});

test('current recent device proof returns only its own masked verified contacts and profile status', async () => {
  const h = harness(), result = await h.request();
  assert.equal(result.status, 200);
  assert.deepEqual(result.data, { version: 2, account_exists: true, profile_complete: true, contact_hints: { email: 'o•••@example.test', phone: '+91 •••• 0001' } });
  assert.equal(result.headers['Cache-Control'], 'no-store'); assert.equal(result.headers.Pragma, 'no-cache');
  assert.deepEqual(h.queries, [{ sql: OWN_ACCOUNT_STATUS_SQL, values: [SUBJECT, 'signed-device'] }]);
  assert.deepEqual(h.tokens, ['synthetic-signed-access', 'synthetic-signed-access']);
  assert.doesNotMatch(JSON.stringify(result.data), /operator@example|919000000001|synthetic-signed|access_token|refresh_token|token_version/);
});

test('all caller-supplied contact, identity and device selectors are uniformly rejected', async () => {
  const h = harness();
  for (const selector of [
    { email: 'operator@example.test' }, { email: 'other@example.test' }, { phone_number: '+919000000001' },
    { subject: SUBJECT }, { subject: OTHER }, { user_id: OTHER }, { device_id: 'signed-device' },
    { name: 'ignored' }, { phone_number: "'; SELECT * FROM users; --" },
  ]) {
    for (const where of ['body', 'query']) {
      const result = await h.request({ [where]: selector });
      assert.equal(result.status, 400); assert.deepEqual(result.data, { error: 'invalid_request' });
    }
  }
  for (const body of [[], ['x'], 'value', 1, true]) assert.equal((await h.request({ body })).status, 400);
  assert.equal(h.queries.length, 0);
});

test('guests, invalid/revoked/inactive sessions and unbound devices receive no profile data', async () => {
  for (const candidate of [
    proof({ guest: true }), proof({ valid: false }), proof({ token_valid: false }),
    proof({ session: { active: false, revoked: true } }), proof({ session: { active: true, revoked: true } }),
    proof({ device_id: undefined }), proof({ device_id: '' }), proof({ device_id: 'x\nvalue' }),
    proof({ device_id: '💡'.repeat(64) }), proof({ subject: 'not-a-user-uuid' }),
  ]) {
    const h = harness({ proofs: [candidate] });
    assert.equal((await h.request()).status, 401); assert.equal(h.queries.length, 0);
  }
});

test('the recent-factor window accepts exactly 300 seconds and refuses stale/future/missing proof', async () => {
  const timestamp = Math.floor(NOW/1000);
  for (const [verified_at, status] of [[timestamp, 200], [timestamp-300, 200], [timestamp-301, 403], [timestamp+1, 403], [null, 403], [timestamp-0.5, 403], [String(timestamp), 403]]) {
    const h = harness({ proofs: [proof({ auth_proof: { channel: 'email', verified_at } })] });
    assert.equal((await h.request()).status, status, String(verified_at));
  }
  for (const channel of [null, 'sms', 'password', 'admin']) {
    assert.equal((await harness({ proofs: [proof({ auth_proof: { channel, verified_at: timestamp } })] }).request()).status, 403);
  }
});

test('email and phone proof require their current verified factor rather than a token role label', async () => {
  for (const channel of ['email', 'phone']) {
    for (const contact of [{ verified: false, value: 'claimed' }, { verified: true, value: null }, { verified: true, value: 'malformed' }]) {
      const candidate = proof({ auth_proof: { channel, verified_at: Math.floor(NOW/1000) }, verified_contacts: { [channel]: contact }, role: 'admin' });
      const h = harness({ proofs: [candidate] });
      assert.equal((await h.request()).status, 403); assert.equal(h.queries.length, 0);
    }
  }
});

test('own-account query denies missing/misbound/inactive-device records without contact lookups', async () => {
  for (const rows of [[], [{ id: OTHER, profile_complete: true, device_active: true }], [{ id: SUBJECT, profile_complete: true, device_active: false }], [{ id: SUBJECT, device_active: true }, { id: OTHER, device_active: true }]]) {
    const h = harness({ rows });
    const result = await h.request();
    assert.equal(result.status, 403); assert.deepEqual(result.data, { error: 'proof_required' });
    assert.deepEqual(h.queries[0].values, [SUBJECT, 'signed-device']);
  }
  assert.match(OWN_ACCOUNT_STATUS_SQL, /WHERE u\.id=\$1/);
  assert.match(OWN_ACCOUNT_STATUS_SQL, /d\.user_id=u\.id AND d\.device_identifier=\$2/);
  assert.match(OWN_ACCOUNT_STATUS_SQL, /u\.is_active=true AND u\.deleted=false/);
  assert.doesNotMatch(OWN_ACCOUNT_STATUS_SQL, /phone_lookup_hash|lower\(email\)|decrypt|INSERT|UPDATE|DELETE/);
});

test('Google factor needs a current own-account provider link and never implies an unverified contact', async () => {
  const candidate = proof({ auth_proof: { channel: 'google', verified_at: Math.floor(NOW/1000) }, verified_contacts: { email: { verified: false, value: 'unverified@example.test' }, phone: { verified: false, value: '+919000000001' } } });
  assert.equal((await harness({ proofs: [candidate], rows: [{ id: SUBJECT, device_active: true, google_linked: false }] }).request()).status, 403);
  const result = await harness({ proofs: [candidate] }).request();
  assert.equal(result.status, 200); assert.deepEqual(result.data.contact_hints, { email: null, phone: null });
});

test('an incomplete existing profile remains distinct from a missing account', async () => {
  const result = await harness({ rows: [{ id: SUBJECT, device_active: true, profile_complete: false, google_linked: false }] }).request();
  assert.equal(result.status, 200); assert.equal(result.data.account_exists, true); assert.equal(result.data.profile_complete, false);
});

test('revocation, device rebinding or changed proof between checks cannot disclose the earlier snapshot', async () => {
  for (const current of [
    proof({ valid: false }), proof({ subject: OTHER }), proof({ device_id: 'other-device' }),
    proof({ auth_proof: { channel: 'phone', verified_at: Math.floor(NOW/1000)-10 } }),
    proof({ auth_proof: { channel: 'email', verified_at: Math.floor(NOW/1000)-11 } }),
  ]) {
    const result = await harness({ proofs: [proof(), current] }).request();
    assert.equal(result.status, 403); assert.deepEqual(result.data, { error: 'proof_required' });
  }
});

test('contact replacements use the newer verified snapshot and omit unverified contact data', async () => {
  const current = proof({ verified_contacts: { email: { verified: true, value: 'replacement@example.test' }, phone: { verified: false, value: '+919000000001' } } });
  const result = await harness({ proofs: [proof(), current] }).request();
  assert.equal(result.status, 200); assert.deepEqual(result.data.contact_hints, { email: 'r•••@example.test', phone: null });
  assert.doesNotMatch(JSON.stringify(result.data), /operator|replacement@example|9000000001/);
});

test('invalid tokens and storage failures are sanitized and never echo identifiers or credentials', async () => {
  for (const [options, status, error] of [
    [{ proofs: [new Error('invalid_token')] }, 401, 'proof_required'],
    [{ proofs: [new Error('postgresql://private-token@private-host/private-db')] }, 503, 'proof_lookup_unavailable'],
    [{ queryError: new Error('operator@example.test raw-private-query') }, 503, 'proof_lookup_unavailable'],
    [{ proofs: [proof(), new Error('private-revocation-connection-error')] }, 503, 'proof_lookup_unavailable'],
  ]) {
    const result = await harness(options).request();
    assert.equal(result.status, status); assert.deepEqual(result.data, { error });
    assert.doesNotMatch(JSON.stringify(result.data), /postgresql|operator|private|raw/);
  }
});
