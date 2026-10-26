'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { readSecurityFeatureConfig } = require('../src/security_feature_config');

test('new security capabilities remain off without URLs or keys being read', () => {
  assert.deepEqual(readSecurityFeatureConfig({}), {
    sharedFeedbackAdmissionEnabled: false, sharedFeedbackDatabaseUrl: null, sharedFeedbackHmacKey: null,
    notificationOutboxEnabled: false, notificationOutboxDatabaseUrl: null,
    statementImportReceiptsEnabled: false,
  });
  assert.equal(readSecurityFeatureConfig({ SHARED_FEEDBACK_DATABASE_URL: 'unused', NOTIFICATION_OUTBOX_DATABASE_URL: 'unused' }).sharedFeedbackDatabaseUrl, null);
});
test('optional security flags reject ambiguous values without printing them', () => {
  for (const name of ['SHARED_FEEDBACK_ADMISSION_ENABLED', 'NOTIFICATION_OUTBOX_ENABLED', 'STATEMENT_IMPORT_RECEIPTS_ENABLED']) {
    for (const value of ['1', 'TRUE', ' false ', 'sensitive-invalid-value']) {
      assert.throws(() => readSecurityFeatureConfig({ [name]: value }), error => error.message.includes(name) && !error.message.includes(value));
    }
  }
});
test('enabled shared admission requires a dedicated URL and strong identity digest key', () => {
  const env = { SHARED_FEEDBACK_ADMISSION_ENABLED: 'true' };
  assert.throws(() => readSecurityFeatureConfig(env), /SHARED_FEEDBACK_DATABASE_URL/);
  env.SHARED_FEEDBACK_DATABASE_URL = 'synthetic-scoped-url';
  assert.throws(() => readSecurityFeatureConfig(env), /SHARED_FEEDBACK_HMAC_KEY/);
  env.SHARED_FEEDBACK_HMAC_KEY = 'short';
  assert.throws(() => readSecurityFeatureConfig(env), /at least 32 bytes/);
  env.SHARED_FEEDBACK_HMAC_KEY = 'x'.repeat(32);
  assert.equal(readSecurityFeatureConfig(env).sharedFeedbackDatabaseUrl, env.SHARED_FEEDBACK_DATABASE_URL);
});
test('enabled outbox cannot silently acknowledge delivery without a configured provider', () => {
  const env = { NOTIFICATION_OUTBOX_ENABLED: 'true', NOTIFICATION_OUTBOX_DATABASE_URL: 'synthetic-scoped-url' };
  assert.throws(() => readSecurityFeatureConfig({ NOTIFICATION_OUTBOX_ENABLED: 'true' }), /NOTIFICATION_OUTBOX_DATABASE_URL/);
  assert.throws(() => readSecurityFeatureConfig(env), /provider/);
  env.NOVU_API_URL = 'http://synthetic-provider.invalid';env.NOVU_API_KEY = 'synthetic';
  assert.equal(readSecurityFeatureConfig(env).notificationOutboxEnabled, true);
  assert.throws(() => readSecurityFeatureConfig({ ...env, NOTIFICATION_SERVICE_TIMEOUT_MS: '60000' }), /timeout/);
  assert.throws(() => readSecurityFeatureConfig({ ...env, NOVU_API_URL: 'invalid-private-value' }), /HTTP or HTTPS/);
});
