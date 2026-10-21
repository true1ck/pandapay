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

function makeService(t, otpHash, clearError = null) {
  const row = {
    id: 'otp-row', otp_hash: otpHash, expires_at: new Date(Date.now() + 60_000),
    attempt_count: 0, consumed_at: null, deleted: false, type: 'phone', created_at: new Date(),
  };
  const calls = [];
  const cleared = [];
  const db = {
    async query(sql, args) {
      calls.push({ sql, args });
      if (sql.startsWith('SELECT') && sql.includes('FROM otp_requests')) {
        return row.consumed_at || row.deleted ? { rows: [] } : { rows: [{ ...row }] };
      }
      if (sql.includes('SET consumed_at = NOW()') && sql.includes('RETURNING id')) {
        if (row.consumed_at || row.deleted || row.expires_at <= new Date() || row.attempt_count >= args[1]) {
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
      markActiveOtp: async () => {},
      clearActiveOtp: async (...args) => {
        cleared.push(args);
        if (clearError) throw clearError;
      },
    },
  });
  t.after(() => calls.length = 0);
  return { service, row, calls, cleared };
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
  const { service, cleared } = makeService(t, await bcrypt.hash('4826', 4));
  assert.deepEqual(await service.verifyOtp('member@example.com', '4826', 'email', 'recovery'), { ok: true });
  assert.deepEqual(cleared, [['member@example.com', 'otp-row', 'recovery']]);
});

test('resend-marker cleanup failure does not undo successful OTP consumption', async t => {
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
