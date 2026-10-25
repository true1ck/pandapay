'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveGoogleAccount, advisoryKey } = require('../src/services/googleIdentity');
const googleUser = { googleId: '123456789', email: 'synthetic@gmail.com', emailVerified: true, emailAuthoritative: true, name: 'Test', picture: null };
const account = { id: 'c3c9b539-9718-4027-ae89-e06709f9cf48', email: 'retained@example.test', name: 'Retained', role: 'user', token_version: 1, deleted: false, is_active: true };

function fakePool(handler) {
  const queries = [];
  let releases = 0;
  const client = {
    async query(sql, args) {
      queries.push({ sql, args });
      if (/^(BEGIN|COMMIT|ROLLBACK|SET LOCAL|SELECT pg_advisory)/.test(sql)) return { rows: [] };
      return handler(sql, args);
    },
    release() { releases++; },
  };
  return { pool: { connect: async () => client }, client, queries, get releases() { return releases; } };
}

test('Google provider subject wins over changed email without contact mutation', async () => {
  const f = fakePool(sql => {
    if (sql.includes('FROM public.oauth_accounts')) return { rows: [{ ...account }] };
    if (sql.startsWith('UPDATE public.users SET last_login_at')) return { rows: [] };
    throw new Error(sql);
  });
  const result = await resolveGoogleAccount({ pool: f.pool, googleUser });
  assert.equal(result.user.id, account.id);
  assert.equal(result.user.email, account.email);
  assert.equal(result.isNewAccount, false);
  assert.equal('deleted' in result.user, false);
  assert.equal(f.releases, 1);
  assert.ok(f.queries.some(q => q.sql === 'COMMIT'));
  assert.ok(!f.queries.some(q => /SET email|is_email_verified =/.test(q.sql)));
});

test('new-account pause rejects Google creation but preserves established provider sign-in', async () => {
  const original = process.env.NEW_ACCOUNT_REGISTRATIONS_PAUSED;
  process.env.NEW_ACCOUNT_REGISTRATIONS_PAUSED = 'true';
  try {
    const fresh = fakePool(() => ({ rows: [] }));
    await assert.rejects(resolveGoogleAccount({ pool: fresh.pool, googleUser }), { code: 'NEW_ACCOUNT_REGISTRATION_PAUSED', status: 503 });
    assert.equal(fresh.queries.some(query => /INSERT INTO public.users|INSERT INTO public.oauth_accounts/.test(query.sql)), false);
    assert.equal(fresh.queries.some(query => query.sql === 'ROLLBACK'), true);
    const existing = fakePool(sql => ({ rows: sql.includes('FROM public.oauth_accounts') ? [{ ...account }] : [] }));
    const result = await resolveGoogleAccount({ pool: existing.pool, googleUser });
    assert.equal(result.user.id, account.id);
    assert.equal(result.isNewAccount, false);
  } finally {
    if (original === undefined) delete process.env.NEW_ACCOUNT_REGISTRATIONS_PAUSED;
    else process.env.NEW_ACCOUNT_REGISTRATIONS_PAUSED = original;
  }
});

test('matching email alone cannot acquire an existing UUID', async () => {
  const f = fakePool(sql => ({ rows: sql.includes('FROM public.oauth_accounts') ? [] : [{ id: account.id }] }));
  await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser }), { code: 'GOOGLE_ACCOUNT_LINK_REQUIRED', status: 409 });
  assert.ok(f.queries.some(q => q.sql === 'ROLLBACK'));
  assert.ok(!f.queries.some(q => /^INSERT|^UPDATE/.test(q.sql)));
  assert.equal(f.releases, 1);
});

for (const flag of ['deleted', 'is_active']) {
  test(`Google cannot revive ${flag === 'deleted' ? 'deleted' : 'inactive'} linked account`, async () => {
    const f = fakePool(() => ({ rows: [{ ...account, [flag]: flag === 'deleted' }] }));
    await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser }), { code: 'GOOGLE_ACCOUNT_UNAVAILABLE', status: 403 });
    assert.ok(!f.queries.some(q => /^INSERT|^UPDATE/.test(q.sql)));
    assert.equal(f.releases, 1);
  });
}

test('new non-authoritative Google email uses existing OTP flow', async () => {
  const f = fakePool(() => ({ rows: [] }));
  await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser: { ...googleUser, emailAuthoritative: false } }), { code: 'GOOGLE_EMAIL_PROOF_REQUIRED' });
  assert.ok(!f.queries.some(q => /^INSERT/.test(q.sql)));
});

test('new Google identity inserts user and provider atomically', async () => {
  const f = fakePool(sql => ({ rows: sql.startsWith('INSERT INTO public.users') ? [{ ...account }] : [] }));
  const result = await resolveGoogleAccount({ pool: f.pool, googleUser });
  assert.equal(result.isNewAccount, true);
  assert.ok(f.queries.some(q => q.sql.includes('INSERT INTO public.oauth_accounts')));
  assert.ok(f.queries.some(q => q.sql === 'COMMIT'));
});

test('informational device metadata fits profile columns without changing the device payload', async () => {
  for (const deviceInfo of [{ language_code: 'a'.repeat(100), timezone: 'b'.repeat(100) },
    { language_code: '\u{1f30f}'.repeat(20), timezone: '\u{1f30f}'.repeat(60) },
    { language_code: { invalid: true }, timezone: 42 }]) {
    const original = structuredClone(deviceInfo);
    const f = fakePool(sql => ({ rows: sql.startsWith('INSERT INTO public.users') ? [{ ...account }] : [] }));
    await resolveGoogleAccount({ pool: f.pool, googleUser, deviceInfo });
    const inserted = f.queries.find(q => q.sql.startsWith('INSERT INTO public.users')).args;
    assert.equal(inserted[3], typeof deviceInfo.language_code === 'string' ? Array.from(deviceInfo.language_code).slice(0, 10).join('') : null);
    assert.equal(inserted[4], typeof deviceInfo.timezone === 'string' ? Array.from(deviceInfo.timezone).slice(0, 50).join('') : null);
    assert.deepEqual(deviceInfo, original);
  }
});

test('concurrent email uniqueness conflict rolls back and requests existing account proof', async () => {
  const f = fakePool(sql => {
    if (sql.startsWith('INSERT INTO public.users')) throw Object.assign(new Error('duplicate'), { code: '23505' });
    return { rows: [] };
  });
  await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser }), { code: 'GOOGLE_ACCOUNT_LINK_REQUIRED' });
  assert.ok(f.queries.some(q => q.sql === 'ROLLBACK'));
  assert.equal(f.releases, 1);
});

function proof(changes = {}) {
  return { valid: true, guest: false, subject: account.id, session: { active: true }, auth_proof: { channel: 'email', verified_at: Math.floor(Date.now() / 1000) }, ...changes };
}

test('explicit linking checks recent current account proof twice on checked-out connection', async () => {
  const f = fakePool(sql => ({ rows: sql.includes('FROM public.users') ? [{ ...account }] : [] }));
  let checks = 0;
  const result = await resolveGoogleAccount({ pool: f.pool, googleUser, linkingToken: 'signed-session', verifySession: async (token, client) => {
    assert.equal(token, 'signed-session'); assert.equal(client, f.client); checks++; return proof();
  } });
  assert.equal(result.user.id, account.id);
  assert.equal(result.isNewAccount, false);
  assert.equal(checks, 2);
  assert.ok(f.queries.some(q => q.sql.includes('FOR UPDATE')));
  assert.ok(!f.queries.some(q => q.sql.startsWith('INSERT INTO public.users')));
});

for (const [label, value] of Object.entries({
  guest: proof({ guest: true }), revoked: proof({ valid: false }),
  stale: proof({ auth_proof: { channel: 'email', verified_at: 1 } }),
  future: proof({ auth_proof: { channel: 'phone', verified_at: Math.floor(Date.now() / 1000) + 60 } }),
  missing: proof({ auth_proof: {} }),
})) {
  test(`explicit linking rejects ${label} proof without creating identities`, async () => {
    const f = fakePool(() => ({ rows: [{ ...account }] }));
    await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser, linkingToken: 'signed-session', verifySession: async () => value }), { code: 'GOOGLE_ACCOUNT_LINK_REQUIRED' });
    assert.ok(!f.queries.some(q => /^INSERT|^UPDATE/.test(q.sql)));
  });
}

test('transaction failure rolls back and releases client', async () => {
  const f = fakePool(() => { throw Object.assign(new Error('offline'), { code: '08006' }); });
  await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser }), { code: '08006' });
  assert.ok(f.queries.some(q => q.sql === 'ROLLBACK'));
  assert.equal(f.releases, 1);
});

test('explicit linking cannot move a provider subject already owned by another UUID', async () => {
  const f = fakePool(sql => ({ rows: sql.includes('FROM public.oauth_accounts')
    ? [{ ...account, id: 'b58a14b5-cc0a-4a98-93ed-a4fe7b3fa7dd' }] : [{ ...account }] }));
  await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser, linkingToken: 'signed-session', verifySession: async () => proof() }), { code: 'GOOGLE_ACCOUNT_LINK_REQUIRED' });
  assert.ok(!f.queries.some(q => /^INSERT|^UPDATE/.test(q.sql)));
});

test('session revocation discovered after acquiring the user lock blocks linking', async () => {
  const f = fakePool(() => ({ rows: [{ ...account }] }));
  let checks = 0;
  await assert.rejects(resolveGoogleAccount({ pool: f.pool, googleUser, linkingToken: 'signed-session', verifySession: async () => ++checks === 1 ? proof() : proof({ valid: false }) }), { code: 'GOOGLE_ACCOUNT_LINK_REQUIRED' });
  assert.equal(checks, 2);
  assert.ok(!f.queries.some(q => /^INSERT|^UPDATE/.test(q.sql)));
});

test('failure to roll back discards the broken pooled connection', async () => {
  const rollbackError = new Error('rollback lost connection');
  let releasedWith;
  const client = {
    async query(sql) {
      if (sql === 'ROLLBACK') throw rollbackError;
      if (sql.includes('FROM public.oauth_accounts')) throw new Error('query failed');
      return { rows: [] };
    },
    release(error) { releasedWith = error; },
  };
  await assert.rejects(resolveGoogleAccount({ pool: { connect: async () => client }, googleUser }), /query failed/);
  assert.equal(releasedWith, rollbackError);
});

test('subject lock keys are opaque stable signed int64', () => {
  assert.equal(advisoryKey('123456789'), advisoryKey('123456789'));
  assert.notEqual(advisoryKey('123456789'), advisoryKey('987654321'));
  assert.match(advisoryKey('123456789'), /^-?\d+$/);
});
