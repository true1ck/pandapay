'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  SETTINGS, validateSetting, listSettings, mergeSettings, readSettings, readPublicSettings,
  clearSettingsCache, intakeOpen,
} = require('../src/sms_v2/settings');
const { createSecurity } = require('../src/sms_v2/security');
const { createTemplateHandler } = require('../src/sms_v2/ai_templates');
const { submitCorrection } = require('../src/sms_v2/corrections_route');
const { evaluateAutoPause } = require('../src/sms_v2/rule_stats');

const throwsInvalid = (fn) => assert.throws(fn, (error) => error.status === 422 && error.code === 'setting_invalid');

test('validateSetting enforces ranges, types and ceilings', () => {
  throwsInvalid(() => validateSetting('signals_min_distinct_users', 0));
  assert.equal(validateSetting('signals_min_distinct_users', 1), 1, 'one person is allowed during the friends run');
  assert.equal(validateSetting('signals_min_distinct_users', 3), 3);
  assert.equal(validateSetting('signals_min_distinct_users', 20), 20);
  throwsInvalid(() => validateSetting('signals_min_distinct_users', 21));
  throwsInvalid(() => validateSetting('signals_min_distinct_users', 2.5));
  throwsInvalid(() => validateSetting('signals_min_distinct_users', '3'));
  throwsInvalid(() => validateSetting('not_a_setting', 1));
  throwsInvalid(() => validateSetting('__proto__', 1));
  throwsInvalid(() => validateSetting('intake_enabled', 'false'));
  assert.equal(validateSetting('intake_enabled', false), false);
  throwsInvalid(() => validateSetting('ai_temperature', 1.5));
  assert.equal(validateSetting('ai_temperature', 0), 0);
  throwsInvalid(() => validateSetting('ai_monthly_budget_usd', Number.NaN));
});

test('the environment is a hard ceiling for rate settings', () => {
  const env = { SMS_V2_AI_RPM: '20', SMS_V2_AI_TPM: '50000' };
  throwsInvalid(() => validateSetting('ai_rpm', 21, env));
  assert.equal(validateSetting('ai_rpm', 20, env), 20);
  throwsInvalid(() => validateSetting('ai_tpm', 60000, env));
  // A per-day cap the operator set in the environment is also a ceiling.
  throwsInvalid(() => validateSetting('templates_per_user_per_day', 60, { SMS_V2_UNKNOWN_TEMPLATES_PER_DAY: '50' }));
  assert.equal(validateSetting('templates_per_user_per_day', 500, {}), 500);
});

test('the model must be on the allow-list', () => {
  const env = { SMS_V2_AI_MODEL: 'model-a', SMS_V2_AI_MODELS_ALLOWED: 'model-a, model-b' };
  assert.equal(validateSetting('ai_model', 'model-b', env), 'model-b');
  assert.equal(validateSetting('ai_model', null, env), null);
  throwsInvalid(() => validateSetting('ai_model', 'model-c', env));
  // Without an allow-list only the configured model is allowed.
  assert.equal(validateSetting('ai_model', 'model-a', { SMS_V2_AI_MODEL: 'model-a' }), 'model-a');
  throwsInvalid(() => validateSetting('ai_model', 'model-b', { SMS_V2_AI_MODEL: 'model-a' }));
});

test('listSettings has a row for every setting, stored or not', () => {
  const stored = [{ key: 'signals_min_distinct_users', value: 5, updatedAt: '2026-11-06T00:00:00.000000Z', updatedBy: 'admin', reason: 'trial' }];
  const rows = listSettings(stored, {});
  assert.deepEqual(rows.map((row) => row.key).sort(), Object.keys(SETTINGS).sort());
  const k = rows.find((row) => row.key === 'signals_min_distinct_users');
  assert.equal(k.value, 5);
  assert.equal(k.default, 1);
  assert.equal(k.min, 1);
  assert.equal(k.max, 20);
  assert.equal(k.updatedAt, '2026-11-06T00:00:00.000000Z');
  const untouched = rows.find((row) => row.key === 'ai_enabled');
  assert.equal(untouched.value, true);
  assert.equal(untouched.updatedAt, null);
});

test('readSettings merges defaults, drops values that no longer validate and caches for 60 seconds', async () => {
  clearSettingsCache();
  let reads = 0;
  const client = { query: async () => {
    reads++;
    return { rows: [
      { key: 'signals_min_distinct_users', value: 4 },
      { key: 'ai_rpm', value: 999 }, // above the ceiling now
      { key: 'retired_key', value: 1 },
    ] };
  } };
  let clock = 1000;
  const options = { now: () => clock, env: { SMS_V2_AI_RPM: '10' } };
  const settings = await readSettings(client, options);
  assert.equal(settings.signals_min_distinct_users, 4);
  assert.equal(settings.ai_rpm, SETTINGS.ai_rpm.default);
  assert.equal(settings.retired_key, undefined);
  assert.equal(settings.ai_enabled, true);
  await readSettings(client, options);
  assert.equal(reads, 1);
  clock += 61000;
  await readSettings(client, options);
  assert.equal(reads, 2);
  clearSettingsCache();
});

test('mergeSettings keeps defaults for an empty table', () => {
  assert.equal(mergeSettings([]).intake_enabled, true);
  assert.equal(mergeSettings([]).signals_min_distinct_users, 1);
});

test('the public settings reader returns only the public keys that are stored', async () => {
  clearSettingsCache();
  const client = { query: async () => ({ rows: [{ settings: { intake_enabled: false, ai_model: 'leak' } }] }) };
  assert.deepEqual(await readPublicSettings(client), { intake_enabled: false });
  clearSettingsCache();
});

test('security limits follow the stored setting and never exceed the environment ceiling', async () => {
  const seen = [];
  const consume = async (_profile, _device, checks) => { seen.push(checks); return { allowed: true, retryAfterSeconds: 0 }; };
  const build = (env, stored) => createSecurity({
    env: { SMS_V2_ATTESTATION_MODE: 'monitor', SMS_V2_ATTESTATION_BINDING: 'off', ...env },
    consume,
    verifyToken: async () => ({ appId: 'app', expiresAt: Date.now() + 60000 }),
    readStoredSettings: async () => stored,
  });
  const req = () => ({ userId: 'u1', headers: { 'x-device-attestation': 'tok', 'x-sms-device-id': 'device-1234' } });
  // No stored value: the built-in default.
  await build({}, {}).checkRate(req(), 'unknown-templates', 3);
  assert.equal(seen.at(-1)[0].limit, 50);
  // A lowered setting applies.
  await build({}, { templates_per_user_per_day: 20 }).checkRate(req(), 'unknown-templates', 3);
  assert.equal(seen.at(-1)[0].limit, 20);
  // The environment value is a ceiling.
  await build({ SMS_V2_UNKNOWN_TEMPLATES_PER_DAY: '30' }, { templates_per_user_per_day: 400 }).checkRate(req(), 'unknown-templates', 3);
  assert.equal(seen.at(-1)[0].limit, 30);
  // Corrections and signals use their own settings.
  await build({}, { corrections_per_user_per_day: 7 }).checkRate(req(), 'corrections', 1);
  assert.equal(seen.at(-1)[0].limit, 7);
  await build({}, { signals_per_user_per_day: 11 }).checkRate(req(), 'learning-signals', 4);
  assert.equal(seen.at(-1)[0].limit, 11);
  assert.equal(seen.at(-1)[0].units, 4);
  // Routes without a setting are untouched.
  await build({}, { templates_per_user_per_day: 5 }).checkRate(req(), 'sync', 1);
  assert.equal(seen.at(-1)[0].limit, 120);
});

test('a settings read failure falls back to defaults instead of blocking phones', async () => {
  const seen = [];
  const security = createSecurity({
    env: { SMS_V2_ATTESTATION_MODE: 'monitor', SMS_V2_ATTESTATION_BINDING: 'off' },
    consume: async (_p, _d, checks) => { seen.push(checks); return { allowed: true, retryAfterSeconds: 0 }; },
    verifyToken: async () => ({ appId: 'app', expiresAt: Date.now() + 60000 }),
    readStoredSettings: async () => { throw new Error('db down'); },
  });
  const req = { userId: 'u1', headers: { 'x-device-attestation': 'tok', 'x-sms-device-id': 'device-1234' } };
  assert.equal(await security.checkRate(req, 'unknown-templates', 1), true);
  assert.equal(seen[0][0].limit, 50);
  assert.deepEqual(await security.storedSettings(req), {});
});

function fakeResponse() {
  return {
    statusCode: 200, headers: {}, body: null,
    status(code) { this.statusCode = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(body) { this.body = body; return this; },
  };
}
const unknownTemplatesBody = {
  items: [{ templateHash: 'a'.repeat(64), senderBrand: 'TESTBK', redactedBody: '<AMT> paid to <PARTY>.', observedAt: '2026-11-06T09:00:00Z' }],
};

test('with intake paused, layouts answer 503 learning_paused with a one hour retry', async () => {
  let submitted = 0;
  const security = {
    verifyAttestation: async () => true,
    checkRate: async () => true,
    storedSettings: async () => ({ intake_enabled: false }),
  };
  const handler = createTemplateHandler({ store: { submit: async () => { submitted++; return ['a']; } }, security });
  const res = fakeResponse();
  await handler({ body: unknownTemplatesBody, userId: 'u1', headers: {} }, res);
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { error: 'learning_paused' });
  assert.equal(res.headers['Retry-After'], '3600');
  assert.equal(submitted, 0);
  // Switched back on, the same request is accepted.
  security.storedSettings = async () => ({});
  const ok = fakeResponse();
  await handler({ body: unknownTemplatesBody, userId: 'u1', headers: {} }, ok);
  assert.equal(ok.statusCode, 202);
});

test('intakeOpen is true unless an admin switched it off', async () => {
  assert.equal(await intakeOpen({}, {}), true);
  assert.equal(await intakeOpen({ storedSettings: async () => ({}) }, {}), true);
  assert.equal(await intakeOpen({ storedSettings: async () => ({ intake_enabled: false }) }, {}), false);
  assert.equal(await intakeOpen({ storedSettings: async () => { throw new Error('x'); } }, {}), true);
});

test('with intake paused a correction is stored without its layout or shared fields', async () => {
  const crypto = require('node:crypto');
  const base = require('../../contracts/sms/v2/fixtures/valid/request.corrections/wrong_category.json');
  const redactedTemplate = 'Rs.<AMT> spent at <PARTY>';
  const hash = crypto.createHash('sha256').update('HDFCBK\n' + redactedTemplate).digest('hex');
  let inserted;
  const client = { query: async (sql, args) => {
    if (sql.includes('FROM sms_v2_facts')) return { rows: base.factIds.map((fact_id) => ({ fact_id, source_key: base.sourceKey })) };
    if (sql.includes('FROM sms_v2_events')) return { rows: [{ event_id: base.eventId }] };
    if (sql.includes('sms_shared_learning_granted')) return { rows: [{ shared: true }] };
    inserted = args; return { rows: [{ case_id: 'case' }] };
  } };
  const body = { ...base, redactedTemplate, corrected: {
    category: 'dining', merchantKey: 'SWIGGY',
    _template: { senderBrand: 'HDFCBK', hash, observedAt: '2026-11-01T12:00:00Z' },
  } };
  await submitCorrection(client, 'profile', body, { sharedLearningEligible: true });
  assert.deepEqual(inserted[7], { category: 'dining', merchantKey: 'SWIGGY' });
  await submitCorrection(client, 'profile', body, { sharedLearningEligible: true, intakeEnabled: false });
  assert.deepEqual(inserted[7], {});
  assert.equal(inserted[8], null); // template_hash
  assert.equal(inserted[10], null); // redacted_template
  assert.equal(inserted[11], false); // shared_learning_eligible
});

test('auto-pause thresholds come from the settings', () => {
  const rules = [{ ruleId: 'R', version: 1 }];
  const cohorts = [{ ruleId: 'R', version: 1, cohort: 'testers', pausedAt: null }];
  const stats = [{ ruleId: 'R', version: 1, hits: 20, corrected: 2, devices: 5 }];
  assert.equal(evaluateAutoPause({ rules, cohorts, stats }).length, 0, 'below the default 50 hits');
  assert.equal(evaluateAutoPause({ rules, cohorts, stats, minHits: 10, minRate: 0.05 }).length, 1);
  assert.equal(evaluateAutoPause({ rules, cohorts, stats, minHits: 10, minRate: 0.2 }).length, 0);
});

const { runTemplateWorkerOnce, applyWorkerSettings } = require('../src/sms_v2/template_worker');
const { config: fixtureConfig } = require('./sms_v2/fixtures/template_draft');

function workerStore(settings, spent = 0) {
  const calls = { claim: 0 };
  return {
    calls,
    settings: async () => ({ ...mergeSettings([]), ...settings }),
    monthSpend: async () => spent,
    claim: async () => { calls.claim++; return null; },
  };
}

test('the worker idles when an admin switched AI drafting off', async () => {
  const store = workerStore({ ai_enabled: false });
  assert.deepEqual(await runTemplateWorkerOnce({ store, provider: {}, config: fixtureConfig }), { status: 'disabled' });
  assert.equal(store.calls.claim, 0, 'nothing is claimed while disabled');
});

test('the worker stops when this month spend reaches the budget', async () => {
  const store = workerStore({ ai_monthly_budget_usd: 0.01 }, 0.02);
  assert.deepEqual(await runTemplateWorkerOnce({ store, provider: {}, config: fixtureConfig }), { status: 'budget' });
  assert.equal(store.calls.claim, 0);
  const raised = workerStore({ ai_monthly_budget_usd: 1 }, 0.02);
  assert.equal((await runTemplateWorkerOnce({ store: raised, provider: {}, config: fixtureConfig })).status, 'idle');
  assert.equal(raised.calls.claim, 1, 'raising the budget lets the next run claim work');
});

test('a blank environment value is no ceiling, never zero (compose passes an unset variable as "")', () => {
  // Production passed SMS_V2_AI_TPM as "": the worker's token ceiling became 0 and it
  // answered "capacity" to every layout, so nothing was ever drafted.
  const blank = { SMS_V2_AI_RPM: '60', SMS_V2_AI_TPM: '', SMS_V2_UNKNOWN_TEMPLATES_PER_DAY: ' ' };
  const settings = mergeSettings([]);
  const applied = applyWorkerSettings({ ...fixtureConfig, model: 'model-a' }, settings, blank);
  assert.equal(applied.tpm, 100000, 'blank SMS_V2_AI_TPM leaves the setting as it is');
  assert.equal(applied.rpm, 30, 'a real ceiling still caps (30 is under 60)');
  assert.equal(applyWorkerSettings({ ...fixtureConfig, model: 'model-a' }, { ...settings, ai_rpm: 90 }, blank).rpm, 60);
  // The console can still save a value, and shows no ceiling for the blank one.
  assert.equal(validateSetting('ai_tpm', 120000, blank), 120000);
  assert.equal(validateSetting('templates_per_user_per_day', 500, blank), 500);
  const row = (key) => listSettings([], blank).find((r) => r.key === key);
  assert.equal(row('ai_tpm').ceiling, null);
  assert.equal(row('ai_rpm').ceiling, 60);
  // A word that is not a number is no ceiling either.
  assert.equal(applyWorkerSettings({ ...fixtureConfig, model: 'model-a' }, settings, { SMS_V2_AI_TPM: 'abc' }).tpm, 100000);
});

test('settings override the model, limits and generation values, with the environment as ceiling', () => {
  const settings = { ...mergeSettings([]), ai_model: 'model-b', ai_rpm: 40, ai_tpm: 90000, ai_temperature: 0.3, ai_max_output_tokens: 2048 };
  const applied = applyWorkerSettings({ ...fixtureConfig, model: 'model-a' }, settings, { SMS_V2_AI_RPM: '25', SMS_V2_AI_TPM: '200000' });
  assert.equal(applied.model, 'model-b');
  assert.equal(applied.rpm, 25, 'capped by SMS_V2_AI_RPM');
  assert.equal(applied.tpm, 90000);
  assert.equal(applied.temperature, 0.3);
  assert.equal(applied.maxOutputTokens, 2048);
  assert.equal(applyWorkerSettings({ ...fixtureConfig, model: 'model-a' }, mergeSettings([]), {}).model, 'model-a', 'null model setting keeps the configured model');
});
