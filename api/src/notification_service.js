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

// Keep this identifier separate from the first draft workflow. The provider
// derives the v1 trigger identifier from the workflow name, so changing the
// name/identifier together also avoids reusing a malformed workflow created by
// an older adapter version.
const WORKFLOW_IDENTIFIER = 'pandapay-push-notification';
const WORKFLOW_NAME = 'PandaPay push notification';
const WORKFLOW_GROUP_NAME = 'PandaPay';
const REQUEST_TIMEOUT_MS = config.notificationServiceTimeoutMs;

let notificationGroupId = null;
let workflowReadyPromise = null;

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

async function readJson(response) {
  return response.json().catch(() => null);
}

async function ensureNotificationGroup() {
  if (notificationGroupId) return notificationGroupId;

  const listed = await request('/v1/notification-groups');
  if (!listed.ok) {
    throw new Error(`Notification group lookup failed: ${await readError(listed)}`);
  }

  const listedPayload = await readJson(listed);
  const groups = Array.isArray(listedPayload?.data)
    ? listedPayload.data
    : Array.isArray(listedPayload)
      ? listedPayload
      : [];
  const existing = groups.find((group) => group?.name === WORKFLOW_GROUP_NAME);
  const existingId = existing?._id || existing?.id;
  if (existingId) {
    notificationGroupId = existingId;
    return notificationGroupId;
  }

  const created = await request('/v1/notification-groups', {
    method: 'POST',
    body: JSON.stringify({ name: WORKFLOW_GROUP_NAME }),
  });
  if (!created.ok) {
    throw new Error(`Notification group creation failed: ${await readError(created)}`);
  }

  const createdPayload = await readJson(created);
  const createdId = createdPayload?.data?._id || createdPayload?.data?.id;
  if (!createdId) {
    throw new Error('Notification group creation returned no group id');
  }
  notificationGroupId = createdId;
  return notificationGroupId;
}

async function ensureWorkflow() {
  if (workflowReadyPromise) return workflowReadyPromise;

  workflowReadyPromise = (async () => {
    const existing = await request(`/v1/workflows/${WORKFLOW_IDENTIFIER}`);
    if (existing.ok) return;
    if (existing.status !== 404) {
      throw new Error(`Notification workflow lookup failed: ${await readError(existing)}`);
    }

    const groupId = await ensureNotificationGroup();
    const created = await request('/v1/workflows', {
      method: 'POST',
      body: JSON.stringify({
        name: WORKFLOW_NAME,
        notificationGroupId: groupId,
        description: 'Generic FCM notification bridge for PandaPay inbox events.',
        active: true,
        steps: [
          {
            active: true,
            template: {
              type: 'PUSH',
              title: '{{payload.title}}',
              content: '{{payload.body}}',
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
  })();

  try {
    await workflowReadyPromise;
  } catch (error) {
    // A transient provider failure should be retried by the next request,
    // rather than leaving a rejected promise cached for the process lifetime.
    workflowReadyPromise = null;
    throw error;
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
    }),
  });
  if (!response.ok) {
    throw new Error(`Notification device registration failed: ${await readError(response)}`);
  }

  // PATCH is the provider's idempotent append-credentials endpoint. Using it
  // instead of embedding channels in the deprecated subscriber upsert keeps
  // multiple phones for one account registered and avoids replacing an
  // already-registered device token.
  const credentials = await request(`/v1/subscribers/${encodeURIComponent(subscriberId)}/credentials`, {
    method: 'PATCH',
    body: JSON.stringify({
      providerId: 'fcm',
      credentials: { deviceTokens: [token] },
    }),
  });
  if (!credentials.ok) {
    throw new Error(`Notification device credential registration failed: ${await readError(credentials)}`);
  }
  return { configured: true, registered: true };
}

async function send({ subscriberId, title, body, category, severity, deepLink, dedupeKey }) {
  if (!isConfigured()) return { configured: false, status: 'disabled' };
  await ensureWorkflow();
  const response = await request('/v1/events/trigger', {
    method: 'POST',
    headers: dedupeKey ? { 'Idempotency-Key': dedupeKey } : undefined,
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
  const result = await response.json();
  // The provider can accept a syntactically valid trigger even when the
  // subscriber has no registered FCM device. That is not delivery and must
  // not be reported as a successful test notification.
  if (result?.status === 'no_devices') {
    const error = new Error('Notification provider has no registered devices for this subscriber');
    error.code = 'notification_no_devices';
    throw error;
  }
  return result;
}

/** Send one announcement to every registered notification-service subscriber. */
async function sendBroadcast({ title, body, category, severity, deepLink, dedupeKey }) {
  if (!isConfigured()) return { configured: false, status: 'disabled' };
  await ensureWorkflow();
  const response = await request('/v1/events/trigger/broadcast', {
    method: 'POST',
    headers: dedupeKey ? { 'Idempotency-Key': dedupeKey } : undefined,
    body: JSON.stringify({
      name: WORKFLOW_IDENTIFIER,
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
    throw new Error(`Notification broadcast request failed: ${await readError(response)}`);
  }
  return response.json();
}

module.exports = { isConfigured, registerDevice, send, sendBroadcast };
