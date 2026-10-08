/**
 * Thin server-to-server client for the private notification service.
 *
 * The project API key never belongs in Flutter. The app authenticates to
 * PandaPay as usual; PandaPay then registers the user's FCM token and sends
 * notification events to the private notification service from this module.
 *
 * This integration is deliberately optional. When NOTIFICATION_SERVICE_URL or
 * NOTIFICATION_SERVICE_API_KEY is absent, PandaPay keeps its existing inbox
 * and local-notification behaviour and simply skips remote delivery.
 */

const crypto = require('node:crypto');

const config = require('./config');

const REQUEST_TIMEOUT_MS = config.notificationServiceTimeoutMs;
const PROVIDER_RETRY_DELAY_MS = 100;

function isConfigured() {
  if (!config.notificationServiceUrl || !config.notificationServiceApiKey) return false;
  try {
    const url = new URL(config.notificationServiceUrl);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch (_) {
    return false;
  }
}

function serviceUrl(path) {
  return `${config.notificationServiceUrl.replace(/\/$/, '')}${path}`;
}

function headers() {
  return {
    'X-App-Id': config.notificationServiceAppId,
    'X-Api-Key': config.notificationServiceApiKey,
    'Content-Type': 'application/json',
  };
}

async function request(path, options = {}) {
  const method = String(options.method || 'GET').toUpperCase();
  const requestHeaders = { ...headers(), ...(options.headers || {}) };
  // Every write issued by PandaPay has a stable idempotency key. This makes
  // a single retry safe even when the provider accepted the request but the
  // response was lost to a timeout.
  const canRetry = Boolean(requestHeaders['Idempotency-Key']);

  for (let attempt = 0; ; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const response = await fetch(serviceUrl(path), {
        ...options,
        headers: requestHeaders,
        signal: controller.signal,
      });
      if (response.status === 401 || response.status === 403) {
        const error = new Error('Notification provider rejected the configured API credentials');
        error.code = 'notification_service_auth_failed';
        error.providerStatus = response.status;
        error.cause = await readError(response);
        throw error;
      }
      if (canRetry && attempt === 0 && isRetryableStatus(response.status)) {
        await delay(PROVIDER_RETRY_DELAY_MS);
        continue;
      }
      return response;
    } catch (error) {
      if (error?.code === 'notification_service_auth_failed') {
        throw error;
      }
      if (!canRetry || attempt > 0) {
        const timeout = error?.name === 'AbortError';
        const wrapped = new Error(
          timeout
            ? 'Notification provider request timed out'
            : 'Notification provider request failed',
        );
        wrapped.code = timeout
          ? 'notification_service_timeout'
          : 'notification_service_unavailable';
        wrapped.cause = error;
        throw wrapped;
      }
      await delay(PROVIDER_RETRY_DELAY_MS);
    } finally {
      clearTimeout(timer);
    }
  }
}

function isRetryableStatus(status) {
  return [408, 425, 429, 500, 502, 503, 504].includes(status);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function idempotencyKey(prefix, value) {
  const digest = crypto.createHash('sha256').update(String(value)).digest('hex');
  return `pandapay-${prefix}-${digest.slice(0, 32)}`;
}

async function readError(response) {
  const body = await response.text().catch(() => '');
  return `${response.status} ${body.slice(0, 500)}`.trim();
}

async function readJson(response) {
  return response.json().catch(() => null);
}

async function registerDevice({ subscriberId, token, platform, email, displayName, timezone }) {
  if (!isConfigured()) return { configured: false, registered: false };
  if (!subscriberId || !token) throw new Error('subscriberId and token are required');

  const normalizedPlatform = String(platform || 'ANDROID').toUpperCase();
  const providerPlatform = ['ANDROID', 'IOS', 'WEB'].includes(normalizedPlatform)
    ? normalizedPlatform
    : 'ANDROID';
  const deviceId = `pandapay:${subscriberId}:${providerPlatform}`;
  const response = await request('/v1/devices', {
    method: 'POST',
    headers: { 'Idempotency-Key': idempotencyKey('device', `${subscriberId}:${providerPlatform}`) },
    body: JSON.stringify({
      user_id: subscriberId,
      device_id: deviceId,
      platform: providerPlatform,
      target_type: 'TOKEN',
      target_value: token,
    }),
  });
  if (!response.ok) {
    throw new Error(`Notification device registration failed: ${await readError(response)}`);
  }
  return { configured: true, registered: true };
}

async function send({ subscriberId, title, body, category, severity, deepLink, dedupeKey }) {
  if (!isConfigured()) return { configured: false, status: 'disabled' };
  const response = await request('/v1/notifications', {
    method: 'POST',
    headers: dedupeKey ? { 'Idempotency-Key': dedupeKey } : undefined,
    body: JSON.stringify({
      user_id: subscriberId,
      type: 'PANDAPAY_PUSH',
      title,
      body: body || '',
      data: {
        title,
        body: body || '',
        category,
        severity: severity || 'info',
        deepLink: deepLink || '',
      },
      idempotency_key: dedupeKey || undefined,
    }),
  });
  if (!response.ok) {
    throw new Error(`Notification delivery request failed: ${await readError(response)}`);
  }
  const result = await readJson(response) || { status: 'accepted' };
  if (result?.status === 'no_devices') {
    const error = new Error('Notification provider has no registered devices for this user');
    error.code = 'notification_no_devices';
    throw error;
  }
  return result;
}

/** Send one announcement to every registered notification-service subscriber. */
async function sendBroadcast({ title, body, category, severity, deepLink, dedupeKey }) {
  if (!isConfigured()) return { configured: false, status: 'disabled' };
  throw new Error('Notification broadcast is not supported by the deployed notification service');
}

module.exports = { isConfigured, registerDevice, send, sendBroadcast };
