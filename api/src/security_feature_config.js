'use strict';

// These features add database capabilities. Merely setting a URL must not
// allocate a pool or activate an unfinished rollout.
function readSecurityFeatureConfig(env = process.env) {
  const flag = name => {
    const value = env[name];
    if (value === undefined || value === '') return false;
    if (!['true', 'false'].includes(value)) throw new Error(`${name} must be true or false`);
    return value === 'true';
  };
  const required = name => {
    if (typeof env[name] !== 'string' || !env[name].trim()) throw new Error(`${name} is required for its enabled feature`);
    return env[name];
  };
  const sharedFeedbackAdmissionEnabled = flag('SHARED_FEEDBACK_ADMISSION_ENABLED');
  const notificationOutboxEnabled = flag('NOTIFICATION_OUTBOX_ENABLED');
  const sharedFeedbackDatabaseUrl = sharedFeedbackAdmissionEnabled ? required('SHARED_FEEDBACK_DATABASE_URL') : null;
  const sharedFeedbackHmacKey = sharedFeedbackAdmissionEnabled ? required('SHARED_FEEDBACK_HMAC_KEY') : null;
  if (sharedFeedbackHmacKey && Buffer.byteLength(sharedFeedbackHmacKey) < 32) {
    throw new Error('SHARED_FEEDBACK_HMAC_KEY must contain at least 32 bytes');
  }
  const notificationOutboxDatabaseUrl = notificationOutboxEnabled ? required('NOTIFICATION_OUTBOX_DATABASE_URL') : null;
  if (notificationOutboxEnabled) {
    const providerUrl = env.NOTIFICATION_SERVICE_URL || env.NOVU_NOTIFICATION_URL || env.NOVU_API_URL;
    const providerKey = env.NOTIFICATION_SERVICE_API_KEY || env.NOVU_NOTIFICATION_API_KEY || env.NOVU_API_KEY;
    if (!providerUrl || !providerKey) throw new Error('Configured notification provider is required for notification outbox delivery');
    let validUrl = false;
    try { validUrl = ['http:', 'https:'].includes(new URL(providerUrl).protocol); } catch (_) {}
    if (!validUrl) throw new Error('Notification provider URL must use HTTP or HTTPS');
    const timeout = env.NOTIFICATION_SERVICE_TIMEOUT_MS === undefined || env.NOTIFICATION_SERVICE_TIMEOUT_MS === ''
      ? 4000 : Number(env.NOTIFICATION_SERVICE_TIMEOUT_MS);
    if (!Number.isSafeInteger(timeout) || timeout < 1000 || timeout > 10000) {
      throw new Error('Notification outbox requires provider timeout between 1000 and 10000 milliseconds');
    }
  }
  return { sharedFeedbackAdmissionEnabled, sharedFeedbackDatabaseUrl, sharedFeedbackHmacKey,
    notificationOutboxEnabled, notificationOutboxDatabaseUrl };
}

module.exports = { readSecurityFeatureConfig };
