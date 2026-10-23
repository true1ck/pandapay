const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcrypt');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

process.env.PHONE_LOOKUP_HMAC_KEY = 'test-phone-lookup-hmac-key-0123456789abcdef';

function load(relativePath, dependencies) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

function makeService(t, otpHash, clearError = null, otpPurpose = 'signin', markError = null) {
  const row = {
    id: 'otp-row', otp_hash: otpHash, expires_at: new Date(Date.now() + 60_000),
    attempt_count: 0, consumed_at: null, deleted: false, type: 'phone', purpose: otpPurpose, created_at: new Date(),
  };
  const calls = [];
  const cleared = [];
  const deleted = [];
  const db = {
    async query(sql, args) {
      calls.push({ sql, args });
      if (sql.startsWith('INSERT INTO otp_requests')) return { rows: [{ id: args[8] }] };
      if (sql.includes('UPDATE otp_requests') && sql.includes('SET deleted = TRUE')) {
        deleted.push({ sql, args });
        return { rows: [] };
      }
      if (sql.startsWith('SELECT') && sql.includes('FROM otp_requests')) {
        const purposeMatches = args[1] === 'signin'
          ? row.purpose === 'signin' || row.purpose === null
          : row.purpose === args[1];
        return row.consumed_at || row.deleted || !purposeMatches ? { rows: [] } : { rows: [{ ...row }] };
      }
      if (sql.includes('SET consumed_at = NOW()') && sql.includes('RETURNING id')) {
        const purposeMatches = args[2] === 'signin'
          ? row.purpose === 'signin' || row.purpose === null
          : row.purpose === args[2];
        if (row.consumed_at || row.deleted || !purposeMatches || row.expires_at <= new Date() || row.attempt_count >= args[1]) {
          return { rows: [] };
        }
        row.consumed_at = new Date();
        return { rows: [{ id: row.id }] };
      }
      if (sql.includes('SET attempt_count = attempt_count + 1')) {
        row.attempt_count++;
        return { rows: [{ attempt_count: row.attempt_count }] };
      }
      throw new Error(`Unexpected SQL: ${sql}`);
    },
  };
  const service = load('../src/services/otpService.js', {
    '../db': db,
    '../config': { isProduction: true },
    '../middleware/rateLimitMiddleware': {
      markActiveOtp: async () => { if (markError) throw markError; },
      clearActiveOtp: async (...args) => {
        cleared.push(args);
        if (clearError) throw clearError;
      },
    },
  });
  t.after(() => calls.length = 0);
  return { service, row, calls, cleared, deleted };
}

test('one correct OTP can be consumed by at most one concurrent verification', async t => {
  const { service, row, calls, cleared } = makeService(t, await bcrypt.hash('4826', 4));
  const results = await Promise.all([
    service.verifyOtp('+919876543210', '4826', 'phone'),
    service.verifyOtp('+919876543210', '4826', 'phone'),
  ]);
  assert.equal(results.filter(result => result.ok).length, 1);
  assert.equal(row.consumed_at instanceof Date, true);
  const atomicConsumes = calls.filter(call => call.sql.includes('RETURNING id'));
  assert.equal(atomicConsumes.length, 2);
  assert.ok(atomicConsumes.every(call => /consumed_at IS NULL/.test(call.sql)));
  assert.deepEqual(cleared, [['+919876543210', 'otp-row', 'signin']]);
});

test('successful OTP verification clears only its requested purpose window', async t => {
  const { service, cleared } = makeService(t, await bcrypt.hash('4826', 4), null, 'recovery');
  assert.deepEqual(await service.verifyOtp('member@example.com', '4826', 'email', 'recovery'), { ok: true });
  assert.deepEqual(cleared, [['member@example.com', 'otp-row', 'recovery']]);
});

test('purpose-specific verification cannot consume another purpose challenge', async t => {
  const { service, row } = makeService(t, await bcrypt.hash('4826', 4), null, 'signin');
  assert.equal((await service.verifyOtp('+919876543210', '4826', 'phone', 'recovery')).ok, false);
  assert.equal(row.consumed_at, null);
  assert.equal((await service.verifyOtp('+919876543210', '4826', 'phone', 'signin')).ok, true);
});

test('legacy NULL purpose is accepted for sign-in only', async t => {
  const { service, row } = makeService(t, await bcrypt.hash('4826', 4), null, null);
  assert.equal((await service.verifyOtp('+919876543210', '4826', 'phone', 'recovery')).ok, false);
  assert.equal(row.consumed_at, null);
  assert.equal((await service.verifyOtp('+919876543210', '4826', 'phone', 'signin')).ok, true);
});

test('OTP type and purpose are rejected before database access when invalid', async t => {
  const { service, calls } = makeService(t, await bcrypt.hash('4826', 4));
  await assert.rejects(service.createOtp('person@example.com', 'sms', 'signin'), /OTP type/);
  await assert.rejects(service.verifyOtp('person@example.com', '4826', 'email', 'admin'), /OTP purpose/);
  await assert.rejects(service.discardUndeliveredOtp('person@example.com', 'email', 'row', 'admin'), /OTP purpose/);
  assert.equal(calls.length, 0);
});

test('abuse-store marker cleanup failure does not undo successful OTP consumption', async t => {
  const { service, row } = makeService(
    t,
    await bcrypt.hash('4826', 4),
    Object.assign(new Error('cache unavailable'), { code: 'ECONNRESET' }),
  );
  const originalError = console.error;
  console.error = () => {};
  try {
    assert.deepEqual(await service.verifyOtp('+919876543210', '4826'), { ok: true });
  } finally {
    console.error = originalError;
  }
  assert.equal(row.consumed_at instanceof Date, true);
});

test('failed active marker claim propagates before any OTP row mutation', async t => {
  const storageError = Object.assign(new Error('storage unavailable'), { code: 'storage_unavailable' });
  const { service, calls, deleted, cleared } = makeService(
    t, await bcrypt.hash('4826', 4), null, 'signin', storageError,
  );
  await assert.rejects(service.createOtp('member@example.com', 'email', 'recovery'), error => error === storageError);
  assert.deepEqual(calls, []);
  assert.deepEqual(deleted, []);
  assert.deepEqual(cleared, []);
});

test('database failure after claim clears only the pre-generated request claim', async t => {
  const claims = [];
  const cleanup = [];
  const error = new Error('database unavailable');
  const db = { async query(sql) {
    if (sql.includes('UPDATE otp_requests') && sql.includes('SET deleted = TRUE')) throw error;
    throw new Error('unexpected SQL');
  } };
  const service = load('../src/services/otpService.js', {
    '../db': db,
    '../config': { isProduction: true },
    '../middleware/rateLimitMiddleware': {
      markActiveOtp: async (...args) => { claims.push(args); return true; },
      clearActiveOtp: async (...args) => cleanup.push(args),
    },
  });
  await assert.rejects(service.createOtp('member@example.com', 'email', 'recovery'), e => e === error);
  assert.equal(claims.length, 1);
  assert.match(claims[0][2], /^[0-9a-f-]{36}$/i);
  assert.deepEqual(claims[0], ['member@example.com', 120, claims[0][2], 'recovery']);
  assert.deepEqual(cleanup, [['member@example.com', claims[0][2], 'recovery']]);
});

test('OTP creation and verification failures never write the raw code to logs', async t => {
  const { service } = makeService(t, await bcrypt.hash('never-this-value', 4));
  const original = { log: console.log, warn: console.warn, error: console.error };
  const output = [];
  console.log = (...args) => output.push(args.join(' '));
  console.warn = (...args) => output.push(args.join(' '));
  console.error = (...args) => output.push(args.join(' '));
  try {
    await service.verifyOtp('+919876543210', '9182', 'phone');
  } finally {
    console.log = original.log; console.warn = original.warn; console.error = original.error;
  }
  assert.equal(output.some(line => line.includes('9182')), false);
});
