const test = require('node:test');
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'test';
process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';

const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
const { PhoneClaimError, claimPhone, getPhoneClaimStatus, releaseClaimedPhone } = require('../src/services/phoneClaim');

// A tiny in-memory stand-in for the users table that behaves like the real
// queries: row lock, "another live account has it" lookup, and the unique index.
function fakeDatabase(initialUsers) {
  const users = new Map(initialUsers.map(user => [user.id, {
    deleted: false, is_active: true, claimed_phone_hash: null, claimed_phone_enc: null, claimed_phone_at: null,
    phone_lookup_hash: null, phone_number: null, is_phone_verified: false, ...user,
  }]));
  const log = { statements: [], audits: [], connects: 0, rollbacks: 0, commits: 0, updates: 0 };
  let forceUniqueViolation = false;

  function live(user) { return user && !user.deleted; }
  const client = {
    async query(sql, args = []) {
      log.statements.push(sql.replace(/\s+/g, ' ').trim().slice(0, 60));
      if (sql === 'BEGIN' || sql.startsWith('SET LOCAL') || sql.includes('pg_advisory_xact_lock')) return { rows: [] };
      if (sql === 'COMMIT') { log.commits++; return { rows: [] }; }
      if (sql === 'ROLLBACK') { log.rollbacks++; return { rows: [] }; }
      if (sql.includes('FOR UPDATE')) {
        const user = users.get(args[0]);
        return { rows: live(user) && user.is_active ? [{ ...user }] : [] };
      }
      if (sql.includes('WHERE id <> $1')) {
        const [id, hash] = args;
        const other = [...users.values()].find(u => u.id !== id && live(u) && (u.claimed_phone_hash === hash || u.phone_lookup_hash === hash));
        return { rows: other ? [{ '?column?': 1 }] : [] };
      }
      if (sql.includes('SET claimed_phone_enc = $2')) {
        const [id, enc, hash] = args;
        if (forceUniqueViolation || [...users.values()].some(u => u.id !== id && live(u) && u.claimed_phone_hash === hash)) {
          throw Object.assign(new Error('duplicate key value violates unique constraint "uq_users_live_claimed_phone"'), { code: '23505' });
        }
        Object.assign(users.get(id), { claimed_phone_enc: enc, claimed_phone_hash: hash, claimed_phone_at: new Date() });
        log.updates++;
        return { rows: [] };
      }
      if (sql.includes('SET claimed_phone_enc = NULL')) {
        const user = users.get(args[0]);
        if (!user || !user.claimed_phone_hash) return { rows: [] };
        Object.assign(user, { claimed_phone_enc: null, claimed_phone_hash: null, claimed_phone_at: null });
        return { rows: [{ id: user.id }] };
      }
      if (sql.includes('INSERT INTO auth_audit')) { log.audits.push({ userId: args[0], meta: JSON.parse(args[1]) }); return { rows: [] }; }
      if (sql.includes('FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE')) {
        const user = users.get(args[0]);
        return { rows: live(user) && user.is_active ? [{ ...user }] : [] };
      }
      throw new Error(`Unexpected SQL: ${sql.slice(0, 80)}`);
    },
    release() {},
  };
  const pool = { async connect() { log.connects++; return client; } };
  return { users, log, pool, query: client.query, breakUniqueIndex() { forceUniqueViolation = true; } };
}

test('a typed number is locked to the account, with only a hash and an encrypted copy stored', async () => {
  const db = fakeDatabase([{ id: 'a' }]);
  const result = await claimPhone({ pool: db.pool, userId: 'a', phone: '98765 43210' });
  assert.deepEqual(result, { phone_hint: '+91 •••• 3210', already: false });
  const row = db.users.get('a');
  assert.equal(row.claimed_phone_hash, phoneLookupHash('+919876543210'));
  assert.ok(row.claimed_phone_enc && row.claimed_phone_at);
  assert.equal(row.is_phone_verified, false, 'a typed number is never marked verified');
  assert.equal(row.phone_lookup_hash, null, 'the verified-phone column is untouched');
  assert.equal(db.log.commits, 1);
});

test('claiming the same number again is harmless and writes nothing', async () => {
  const db = fakeDatabase([{ id: 'a' }]);
  await claimPhone({ pool: db.pool, userId: 'a', phone: '9876543210' });
  const again = await claimPhone({ pool: db.pool, userId: 'a', phone: '+91-98765-43210' });
  assert.equal(again.already, true);
  assert.equal(db.log.updates, 1);
});

test('a person cannot swap the number once it is set', async () => {
  const db = fakeDatabase([{ id: 'a' }]);
  await claimPhone({ pool: db.pool, userId: 'a', phone: '9876543210' });
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'a', phone: '9123456780' }),
    error => error instanceof PhoneClaimError && error.code === 'phone_already_set' && error.status === 409);
  assert.equal(db.users.get('a').claimed_phone_hash, phoneLookupHash('+919876543210'));
});

test('a number on another live account is refused, however it is written', async () => {
  const db = fakeDatabase([{ id: 'a' }, { id: 'b' }]);
  await claimPhone({ pool: db.pool, userId: 'a', phone: '98765 43210' });
  for (const typed of ['9876543210', '+91-98765-43210', '09876543210', '919876543210']) {
    await assert.rejects(claimPhone({ pool: db.pool, userId: 'b', phone: typed }),
      error => error.code === 'phone_unavailable' && error.status === 409, typed);
  }
  assert.equal(db.users.get('b').claimed_phone_hash, null);
  assert.ok(db.log.rollbacks >= 4);
});

test('a number that is a verified phone on another account is refused', async () => {
  const hash = phoneLookupHash('+919876543210');
  const db = fakeDatabase([{ id: 'a', phone_number: '+919876543210', phone_lookup_hash: hash, is_phone_verified: true }, { id: 'b' }]);
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'b', phone: '9876543210' }), error => error.code === 'phone_unavailable');
});

test('an account that already has a verified phone needs no claim', async () => {
  const hash = phoneLookupHash('+919876543210');
  const db = fakeDatabase([{ id: 'a', phone_number: '+919876543210', phone_lookup_hash: hash, is_phone_verified: true }]);
  assert.equal((await claimPhone({ pool: db.pool, userId: 'a', phone: '9876543210' })).already, true);
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'a', phone: '9123456780' }), error => error.code === 'phone_already_set');
});

test('a deleted account frees its number', async () => {
  const db = fakeDatabase([{ id: 'a' }, { id: 'b' }]);
  await claimPhone({ pool: db.pool, userId: 'a', phone: '9876543210' });
  db.users.get('a').deleted = true;
  assert.equal((await claimPhone({ pool: db.pool, userId: 'b', phone: '9876543210' })).already, false);
});

test('bad input is refused before any database work', async () => {
  const db = fakeDatabase([{ id: 'a' }]);
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'a', phone: '12345' }), error => error.code === 'phone_invalid' && error.status === 400);
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'a', phone: '+44 7911 123456' }), error => error.code === 'phone_country_unsupported' && error.status === 400);
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'a', phone: null }), error => error.code === 'phone_invalid');
  assert.equal(db.log.connects, 0);
});

test('a missing, deleted or disabled account cannot claim', async () => {
  const db = fakeDatabase([{ id: 'gone', deleted: true }, { id: 'off', is_active: false }]);
  for (const userId of ['nobody', 'gone', 'off']) {
    await assert.rejects(claimPhone({ pool: db.pool, userId, phone: '9876543210' }), error => error.code === 'account_unavailable' && error.status === 401, userId);
  }
});

test('if two sign-ups race past the lock, the unique index still stops the second', async () => {
  const db = fakeDatabase([{ id: 'a' }]);
  db.breakUniqueIndex();
  await assert.rejects(claimPhone({ pool: db.pool, userId: 'a', phone: '9876543210' }), error => error.code === 'phone_unavailable');
  assert.equal(db.log.rollbacks, 1);
});

test('support can release a number, with a named person and a reason, and it is audited', async () => {
  const db = fakeDatabase([{ id: 'a' }, { id: 'b' }]);
  await claimPhone({ pool: db.pool, userId: 'a', phone: '9876543210' });
  await assert.rejects(releaseClaimedPhone({ pool: db.pool, userId: 'a', actor: '', reason: 'owner proved the number' }), /named actor/);
  await assert.rejects(releaseClaimedPhone({ pool: db.pool, userId: 'a', actor: 'Asha', reason: 'short' }), /written reason/);
  assert.deepEqual(await releaseClaimedPhone({ pool: db.pool, userId: 'a', actor: 'Asha', reason: 'real owner showed their SIM and ID' }), { released: true });
  assert.equal(db.users.get('a').claimed_phone_hash, null);
  assert.deepEqual(db.log.audits, [{ userId: 'a', meta: { actor: 'Asha', reason: 'real owner showed their SIM and ID' } }]);
  assert.equal((await claimPhone({ pool: db.pool, userId: 'b', phone: '9876543210' })).already, false);
  assert.deepEqual(await releaseClaimedPhone({ pool: db.pool, userId: 'a', actor: 'Asha', reason: 'nothing left to release' }), { released: false });
});

test('status says whether the lock needs a phone, and a verified phone counts', async () => {
  const hash = phoneLookupHash('+919123456780');
  const db = fakeDatabase([{ id: 'none' }, { id: 'claimed' }, { id: 'verified', phone_number: '+919123456780', phone_lookup_hash: hash, is_phone_verified: true }]);
  await claimPhone({ pool: db.pool, userId: 'claimed', phone: '9876543210' });
  const off = {}; const on = { REQUIRE_PHONE_AT_SIGNUP: 'true' };
  assert.deepEqual(await getPhoneClaimStatus({ query: db.query, userId: 'none', env: off }), { claimed: false, verified: false, required: false, needs_phone: false, phone_hint: null });
  assert.equal((await getPhoneClaimStatus({ query: db.query, userId: 'none', env: on })).needs_phone, true);
  const claimed = await getPhoneClaimStatus({ query: db.query, userId: 'claimed', env: on });
  assert.deepEqual([claimed.claimed, claimed.needs_phone, claimed.phone_hint], [true, false, '+91 •••• 3210']);
  const verified = await getPhoneClaimStatus({ query: db.query, userId: 'verified', env: on });
  assert.deepEqual([verified.verified, verified.needs_phone], [true, false]);
  await assert.rejects(getPhoneClaimStatus({ query: db.query, userId: 'ghost', env: on }), error => error.code === 'account_unavailable');
});
