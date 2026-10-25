'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const bcrypt = require('bcrypt');
const { DEFAULT_LIMITS, readAdmissionLimits, validateLimits, createOtpWorkAdmission, OtpCapacityError } = require('../src/services/otpWorkAdmission');
const wait = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
function load(relative, dependencies) {
  const filename = path.resolve(__dirname, relative), loaded = new Module(filename, module);
  loaded.filename = filename; loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request) ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename); return loaded.exports;
}
function otpFixture({ hash = bcrypt.hash, compare = bcrypt.compare, query = async () => ({ rows: [] }), maximum = 2 } = {}) {
  const admission = createOtpWorkAdmission({ ...DEFAULT_LIMITS, workMaxConcurrent: maximum });
  const calls = { queries: 0, claims: 0, clears: 0 };
  const service = load('../src/services/otpService.js', {
    bcrypt: { hash, compare }, '../config': { isProduction: true },
    './otpWorkAdmission': { getOtpWorkAdmission: () => admission },
    '../db': { query: async (...args) => { calls.queries++; return query(...args); } },
    '../middleware/rateLimitMiddleware': { markActiveOtp: async () => { calls.claims++; return true; }, clearActiveOtp: async () => { calls.clears++; } },
    '../utils/fieldEncryption': { encryptPhoneNumber: value => value },
    '../utils/encryptedPhoneSearch': { phoneLookupHash: () => 'synthetic-keyed-phone-lookup' },
  });
  return { service, admission, calls };
}
test('defaults are bounded and only strict integer spellings from 1 through 16 are accepted', () => {
  assert.deepEqual(readAdmissionLimits({}), DEFAULT_LIMITS);
  assert.equal(readAdmissionLimits({ OTP_WORK_MAX_CONCURRENT: '16' }).workMaxConcurrent, 16);
  for (const raw of ['0', '17', '-1', '1.5', 'Infinity', '2e0', ' 2', '02', 'true', null, 2]) assert.throws(() => readAdmissionLimits({ OTP_WORK_MAX_CONCURRENT: raw }));
  for (const limits of [{ ...DEFAULT_LIMITS, secret: 'private' }, { workMaxConcurrent: 2 }, { ...DEFAULT_LIMITS, smsMaxConcurrent: NaN }]) assert.throws(() => validateLimits(limits));
});
test('full stage rejects before running the callback and keeps no waiting work', async () => {
  const admission = createOtpWorkAdmission({ ...DEFAULT_LIMITS, workMaxConcurrent: 1 }), held = wait();
  const first = admission.run('work', () => held.promise); let called = false;
  const rejected = Array.from({ length: 100 }, () => admission.run('work', () => { called = true; }));
  const settled = await Promise.allSettled(rejected);
  assert.ok(settled.every(item => item.status === 'rejected' && item.reason instanceof OtpCapacityError));
  assert.equal(called, false); assert.deepEqual(admission.snapshot().work, { maximum: 1, active: 1, admitted: 1, rejected: 100, failed: 0 });
  held.resolve('done'); assert.equal(await first, 'done'); assert.equal(admission.snapshot().work.active, 0);
});
test('email, SMS and verification capacity are independent and observations cannot mutate limits', async () => {
  const admission = createOtpWorkAdmission({ workMaxConcurrent: 1, emailMaxConcurrent: 1, smsMaxConcurrent: 1 }), held = wait();
  const email = admission.run('email', () => held.promise);
  assert.equal(await admission.run('work', () => 7), 7); assert.equal(await admission.run('sms', () => 9), 9);
  admission.snapshot().email.active = 0;
  await assert.rejects(admission.run('email', () => null), OtpCapacityError);
  held.resolve(); await email;
});
test('sync throw and async rejection both release slots exactly once, preserving the original failure', async () => {
  const admission = createOtpWorkAdmission(), error = new Error('synthetic failure');
  await assert.rejects(admission.run('work', () => { throw error; }), value => value === error);
  await assert.rejects(admission.run('work', async () => { throw error; }), value => value === error);
  assert.equal(admission.snapshot().work.active, 0); assert.equal(admission.snapshot().work.failed, 2);
  await assert.rejects(admission.run('__proto__', () => null), TypeError);
});
test('abandoned caller does not free a slot before the underlying operation settles', async () => {
  const admission = createOtpWorkAdmission({ ...DEFAULT_LIMITS, workMaxConcurrent: 1 }), held = wait();
  const running = admission.run('work', () => held.promise);
  await Promise.race([running, Promise.resolve('client stopped waiting')]);
  await assert.rejects(admission.run('work', () => null), OtpCapacityError);
  held.resolve(); await running;
  assert.equal(await admission.run('work', () => 'retry'), 'retry');
});
test('issuance saturation rejects legacy/V2 verification and issuance before DB, claims, or native hashing', async () => {
  const held = wait(); let hashes = 0, compares = 0;
  const h = otpFixture({ maximum: 1, hash: async () => { hashes++; return held.promise; }, compare: async () => { compares++; return false; } });
  const first = h.service.createOtp('first@example.invalid', 'email');
  for (const operation of [
    () => h.service.createOtp('second@example.invalid', 'email', 'recovery'),
    () => h.service.verifyOtp('third@example.invalid', '1234', 'email'),
    () => h.service.createOtpV2('fourth@example.invalid', 'email', 'replacement', 'device-fixture'),
    () => h.service.verifyOtpV2('fifth@example.invalid', '123456', 'email', 'signin', 'device-fixture', '11111111-1111-4111-8111-111111111111'),
  ]) await assert.rejects(operation(), OtpCapacityError);
  assert.equal(hashes, 1); assert.equal(compares, 0); assert.equal(h.calls.queries, 0); assert.equal(h.calls.claims, 0);
  held.resolve('synthetic-bcrypt-hash'); await first;
  assert.equal(h.calls.claims, 1); assert.equal(h.admission.snapshot().work.active, 0);
});
test('concurrent unknown identifiers share one pending dummy hash then all compare', async () => {
  const started = wait(), held = wait(); let hashes = 0, compares = 0;
  const h = otpFixture({ hash: async () => { hashes++; started.resolve(); return held.promise; }, compare: async () => { compares++; return false; } });
  const first = h.service.verifyOtp('one@example.invalid', '1234', 'email');
  const second = h.service.verifyOtpV2('two@example.invalid', '123456', 'email', 'recovery', 'device-fixture', '11111111-1111-4111-8111-111111111111');
  await started.promise;
  await assert.rejects(h.service.verifyOtp('three@example.invalid', '1234', 'email'), OtpCapacityError);
  assert.equal(hashes, 1); held.resolve('dummy-hash');
  assert.deepEqual(await Promise.all([first, second]), [{ ok: false, reason: 'not_found' }, { ok: false, reason: 'not_found' }]);
  assert.equal(compares, 2); assert.equal(h.calls.claims, 0); assert.equal(h.calls.queries, 2);
});
test('failed dummy initialization is retryable and neither leaks nor permanently occupies capacity', async () => {
  const error = new Error('native-fixture-error'); let hashes = 0;
  const h = otpFixture({ hash: async () => { if (++hashes === 1) throw error; return 'dummy'; }, compare: async () => false });
  await assert.rejects(h.service.verifyOtp('one@example.invalid', '1234', 'email'), value => value === error);
  assert.equal(h.admission.snapshot().work.active, 0);
  assert.deepEqual(await h.service.verifyOtp('one@example.invalid', '1234', 'email'), { ok: false, reason: 'not_found' }); assert.equal(hashes, 2);
});
test('real installed bcrypt retains cost 10, shares dummy initialization and rejects overload before native work', async () => {
  const hashes = []; let compares = 0;
  const h = otpFixture({ hash: async (value, cost) => { const hash = await bcrypt.hash(value, cost); hashes.push(hash); return hash; }, compare: async (...args) => { compares++; return bcrypt.compare(...args); } });
  const results = await Promise.allSettled(Array.from({ length: 20 }, (_, i) => h.service.verifyOtp(`synthetic-${i}@example.invalid`, '9182', 'email')));
  assert.equal(results.filter(value => value.status === 'fulfilled').length, 2);
  assert.equal(results.filter(value => value.status === 'rejected' && value.reason instanceof OtpCapacityError).length, 18);
  assert.equal(hashes.length, 1); assert.equal(bcrypt.getRounds(hashes[0]), 10); assert.equal(compares, 2);
  assert.equal(h.admission.snapshot().work.active, 0);
});
