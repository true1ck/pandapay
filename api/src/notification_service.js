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

const config = require('./config');

const WORKFLOW_IDENTIFIER = 'pandapay-notification';
const REQUEST_TIMEOUT_MS = config.notificationServiceTimeoutMs;

function isConfigured() {
  return Boolean(config.notificationServiceUrl && config.notificationServiceApiKey);
}

function serviceUrl(path) {
  return `${config.notificationServiceUrl.replace(/\/$/, '')}${path}`;
}

function headers() {
  return {
    Authorization: `ApiKey ${config.notificationServiceApiKey}`,
    'Content-Type': 'application/json',
  };
}

async function request(path, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    return await fetch(serviceUrl(path), {
      ...options,
      headers: { ...headers(), ...(options.headers || {}) },
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

async function readError(response) {
  const body = await response.text().catch(() => '');
  return `${response.status} ${body.slice(0, 500)}`.trim();
}

async function ensureWorkflow() {
  const existing = await request(`/v1/workflows/${WORKFLOW_IDENTIFIER}`);
  if (existing.ok) return;
  if (existing.status !== 404) {
    throw new Error(`Notification workflow lookup failed: ${await readError(existing)}`);
  }

  const created = await request('/v1/workflows', {
    method: 'POST',
    body: JSON.stringify({
      identifier: WORKFLOW_IDENTIFIER,
      name: 'PandaPay notification',
      description: 'Generic FCM notification bridge for PandaPay inbox events.',
      active: true,
      steps: [
        {
          template: {
            title: '{{payload.title}}',
            body: '{{payload.body}}',
            data: {
              category: '{{payload.category}}',
              severity: '{{payload.severity}}',
              deepLink: '{{payload.deepLink}}',
            },
          },
        },
      ],
    }),
  });
  // A second API instance can create the workflow at the same time. A 409
  // means the desired workflow already exists, so it is safe to continue.
  if (!created.ok && created.status !== 409) {
    throw new Error(`Notification workflow creation failed: ${await readError(created)}`);
  }
}

async function registerDevice({ subscriberId, token, platform, email, displayName, timezone }) {
  if (!isConfigured()) return { configured: false, registered: false };
  if (!subscriberId || !token) throw new Error('subscriberId and token are required');

  const nameParts = typeof displayName === 'string'
    ? displayName.trim().split(/\s+/).filter(Boolean)
    : [];
  const response = await request(`/v1/subscribers/${encodeURIComponent(subscriberId)}`, {
    method: 'PUT',
    body: JSON.stringify({
      subscriberId,
      firstName: nameParts[0] || null,
      lastName: nameParts.slice(1).join(' ') || null,
      email: email || null,
      timezone: timezone || null,
      data: { platform: platform || 'unknown' },
      channels: [{ providerId: 'fcm', credentials: { deviceTokens: [token] } }],
    }),
  });
  if (!response.ok) {
    throw new Error(`Notification device registration failed: ${await readError(response)}`);
  }
  return { configured: true, registered: true };
}

async function send({ subscriberId, title, body, category, severity, deepLink, dedupeKey }) {
  if (!isConfigured()) return { configured: false, status: 'disabled' };
  await ensureWorkflow();
  const response = await request('/v1/events/trigger', {
    method: 'POST',
    body: JSON.stringify({
      name: WORKFLOW_IDENTIFIER,
      to: { subscriberId },
      payload: {
        title,
        body: body || '',
        category,
        severity: severity || 'info',
        deepLink: deepLink || '',
      },
      transactionId: dedupeKey || undefined,
    }),
  });
  if (!response.ok) {
    throw new Error(`Notification delivery request failed: ${await readError(response)}`);
  }
  return response.json();
}

module.exports = { isConfigured, registerDevice, send };
