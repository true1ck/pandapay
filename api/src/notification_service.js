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

// Keep provider identifiers configurable so one Novu deployment can serve
// multiple PandaPay applications without changing source code.
const WORKFLOW_IDENTIFIER = config.notificationServiceWorkflowIdentifier;
const WORKFLOW_NAME = config.notificationServiceWorkflowName;
const REQUEST_TIMEOUT_MS = config.notificationServiceTimeoutMs;
const PROVIDER_RETRY_DELAY_MS = 100;

let workflowReadyPromise = null;

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
    Authorization: `ApiKey ${config.notificationServiceApiKey}`,
    // The deployed multi-application notification service authenticates
    // project-scoped requests with this explicit header. Keep Authorization
    // too for compatibility with standard Novu deployments.
    'x-project-key': config.notificationServiceApiKey,
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
        const error = new Error('Notification provider rejected the configured API key');
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

function listItems(payload, keys = []) {
  if (Array.isArray(payload)) return payload;
  for (const key of keys) {
    if (Array.isArray(payload?.[key])) return payload[key];
    if (Array.isArray(payload?.data?.[key])) return payload.data[key];
  }
  if (Array.isArray(payload?.data)) return payload.data;
  return [];
}

function isWorkflowForIdentifier(workflow) {
  if (!workflow || typeof workflow !== 'object') return false;
  if ([workflow.identifier, workflow.slug, workflow.workflowId].includes(WORKFLOW_IDENTIFIER)) {
    return true;
  }
  return Array.isArray(workflow.triggers)
    && workflow.triggers.some((trigger) => trigger?.identifier === WORKFLOW_IDENTIFIER);
}

async function findWorkflow() {
  const response = await request('/v1/workflows');
  if (!response.ok) {
    throw new Error(`Notification workflow list failed: ${await readError(response)}`);
  }
  const payload = await readJson(response);
  return listItems(payload, ['workflows']).find(isWorkflowForIdentifier) || null;
}

async function ensureWorkflow() {
  if (workflowReadyPromise) return workflowReadyPromise;

  workflowReadyPromise = (async () => {
    if (await findWorkflow()) return;

    const workflow = {
      name: WORKFLOW_NAME,
      workflowId: WORKFLOW_IDENTIFIER,
      __source: 'editor',
      description: 'Generic FCM notification bridge for PandaPay inbox events.',
      active: true,
      triggers: [
        { type: 'event', identifier: WORKFLOW_IDENTIFIER, variables: [] },
      ],
      steps: [
        {
          active: true,
          name: WORKFLOW_NAME,
          type: 'push',
          controlValues: {
            subject: '{{payload.title}}',
            body: '{{payload.body}}',
          },
        },
      ],
    };
    if (process.env.NOTIFICATION_SERVICE_WORKFLOW_GROUP_ID) {
      workflow.notificationGroupId = process.env.NOTIFICATION_SERVICE_WORKFLOW_GROUP_ID;
    }
    const created = await request('/v1/workflows', {
      method: 'POST',
      headers: { 'Idempotency-Key': idempotencyKey('workflow', WORKFLOW_IDENTIFIER) },
      body: JSON.stringify(workflow),
    });
    // A second API instance can create the workflow at the same time. A 409
    // means the desired workflow already exists, so it is safe to continue.
    if (!created.ok && created.status !== 409) {
      throw new Error(`Notification workflow creation failed: ${await readError(created)}`);
    }
    if (created.status === 409 && !(await findWorkflow())) {
      throw new Error('Notification workflow already exists but could not be found');
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
    headers: { 'Idempotency-Key': idempotencyKey('subscriber', subscriberId) },
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

  // The deployed notification service exposes PUT for credentials. Keep the
  // device token in the dedicated credentials endpoint rather than embedding
  // it in the subscriber upsert, so subscriber profile updates cannot erase
  // push credentials accidentally.
  const credentials = await request(`/v1/subscribers/${encodeURIComponent(subscriberId)}/credentials`, {
    method: 'PUT',
    headers: { 'Idempotency-Key': idempotencyKey('device', `${subscriberId}:${token}`) },
    body: JSON.stringify({
      providerId: 'fcm',
      ...(config.notificationServiceFcmIntegrationIdentifier
        ? { integrationIdentifier: config.notificationServiceFcmIntegrationIdentifier }
        : {}),
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
      // Novu's trigger contract uses workflowId. Keep the identifier stable
      // across all PandaPay notification events so the provider can route the
      // event to the configured workflow. The v1 API calls this field `name`;
      // workflowId is retained for the deployed project adapter's compatibility.
      name: WORKFLOW_IDENTIFIER,
      workflowId: WORKFLOW_IDENTIFIER,
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
  const result = await readJson(response) || { status: 'accepted' };
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
      // Novu's v1 broadcast contract also calls the workflow identifier `name`.
      name: WORKFLOW_IDENTIFIER,
      workflowId: WORKFLOW_IDENTIFIER,
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
  return (await readJson(response)) || { status: 'accepted' };
}

module.exports = { isConfigured, registerDevice, send, sendBroadcast };
