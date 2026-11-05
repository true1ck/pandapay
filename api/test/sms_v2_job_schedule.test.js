'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { nextRunDelayMs, runRuleJobsLoop } = require('../src/sms_v2/jobs/schedule');

test('next run is minute 7 of this hour while it is still ahead', () => {
  assert.equal(nextRunDelayMs(new Date('2026-11-20T10:05:00Z')), 2 * 60_000);
});

test('next run is minute 7 of the next hour once it has passed', () => {
  assert.equal(nextRunDelayMs(new Date('2026-11-20T10:07:00Z')), 60 * 60_000);
  assert.equal(nextRunDelayMs(new Date('2026-11-20T10:30:00Z')), 37 * 60_000);
});

test('loop runs at start-up, survives a failed run and stops when asked', async () => {
  const outcomes = [new Error('db down'), { refreshed: [] }];
  const logs = [];
  let calls = 0;
  let stop = false;
  await runRuleJobsLoop({
    runOnce: async () => {
      const next = outcomes[calls++];
      if (next instanceof Error) throw next;
      stop = true;
      return next;
    },
    now: () => new Date('2026-11-20T10:30:00Z'),
    sleep: async () => {},
    log: (entry) => logs.push(entry),
    stopped: () => stop,
  });
  assert.equal(calls, 2);
  assert.deepEqual(logs.map((entry) => entry.status), ['failed', 'ok']);
  assert.ok(logs.every((entry) => entry.event === 'sms_v2_rule_jobs'));
});

test('loop sleeps until minute 7 of the next hour between runs', async () => {
  const sleeps = [];
  let calls = 0;
  await runRuleJobsLoop({
    runOnce: async () => { calls++; return { refreshed: [{ cohort: 'all' }], paused: [] }; },
    now: () => new Date('2026-11-20T10:30:00Z'),
    sleep: async (ms) => { sleeps.push(ms); },
    log: () => {},
    stopped: () => calls >= 2,
  });
  assert.equal(calls, 2);
  assert.deepEqual(sleeps, [37 * 60_000]);
});

test('loop logs metadata only, never bundle bodies, rules or keys', async () => {
  const logs = [];
  let calls = 0;
  const secret = 'PRIVATE KEY MATERIAL';
  await runRuleJobsLoop({
    runOnce: async () => {
      calls++;
      if (calls === 1) throw Object.assign(new Error(secret), { code: 'bundle_corrupt' });
      return { refreshed: [{ bundleVersion: 4, cohort: 'all', body: secret }], paused: [], rolledUp: secret };
    },
    sleep: async () => {},
    log: (entry) => logs.push(entry),
    stopped: () => calls >= 2,
  });
  assert.equal(JSON.stringify(logs).includes(secret), false);
  assert.equal(logs[0].code, 'bundle_corrupt');
  assert.equal(logs[1].refreshed, 1);
  assert.equal(logs[1].paused, 0);
});

test('job entry points ship in the image (src/), not only in scripts/', () => {
  assert.equal(typeof require('../src/sms_v2/jobs/rule_jobs_main').main, 'function');
  assert.equal(typeof require('../src/sms_v2/jobs/template_worker_main').main, 'function');
});

test('rule job settings refuse to start without an admin id or signing key', () => {
  const { settings } = require('../src/sms_v2/jobs/rule_jobs_main');
  const codeOf = (fn) => { try { fn(); return null; } catch (error) { return [error.code, error.exitCode]; } };
  assert.deepEqual(codeOf(() => settings(['node', 'x'], {})), ['SMS_V2_JOB_ADMIN_ID_required', 2]);
  assert.deepEqual(codeOf(() => settings(['node', 'x', '--admin-id', 'a'], {})), ['SMS_RULES_SIGNING_KEY_required', 2]);
  assert.deepEqual(codeOf(() => settings(['node', 'x'], { SMS_V2_JOB_ADMIN_ID: 'a', NODE_ENV: 'production' })),
    ['SMS_RULES_SIGNING_KEY_required', 2]);
  assert.deepEqual(codeOf(() => settings(['node', 'x'], { SMS_V2_JOB_ADMIN_ID: 'a', SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS: '500' })),
    ['SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS_invalid', 2]);
});

test('rule job settings read the admin id from the flag or the environment', () => {
  const crypto = require('node:crypto');
  const { settings } = require('../src/sms_v2/jobs/rule_jobs_main');
  const pem = crypto.generateKeyPairSync('ed25519').privateKey.export({ type: 'pkcs8', format: 'pem' });
  const env = { SMS_RULES_SIGNING_KEY: pem, SMS_RULES_KEY_ID: 'test-key', SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS: '72' };
  const fromFlag = settings(['node', 'x', '--admin-id', 'flag-admin', '--loop'], { ...env, SMS_V2_JOB_ADMIN_ID: 'env-admin' });
  assert.equal(fromFlag.adminId, 'flag-admin');
  assert.equal(fromFlag.refreshBeforeMs, 72 * 3_600_000);
  assert.equal(fromFlag.signer.keyId, 'test-key');
  assert.equal(settings(['node', 'x', '--loop'], { ...env, SMS_V2_JOB_ADMIN_ID: 'env-admin' }).adminId, 'env-admin');
  assert.equal(settings(['node', 'x'], { SMS_V2_JOB_ADMIN_ID: 'a', SMS_RULES_SIGNING_KEY: pem, SMS_RULES_KEY_ID: 'k' }).refreshBeforeMs, undefined);
});
