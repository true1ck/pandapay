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

function listItems(payload, keys = []) {
  if (Array.isArray(payload)) return payload;
  for (const key of keys) {
    if (Array.isArray(payload?.[key])) return payload[key];
    if (Array.isArray(payload?.data?.[key])) return payload.data[key];
  }
  return Array.isArray(payload?.data) ? payload.data : [];
}

function isWorkflowForIdentifier(workflow) {
  return [workflow?.identifier, workflow?.slug, workflow?.workflowId].includes(WORKFLOW_IDENTIFIER)
    || workflow?.triggers?.some?.((trigger) => trigger?.identifier === WORKFLOW_IDENTIFIER);
}

function isUsablePushWorkflow(workflow) {
  const step = workflow?.steps?.[0];
  return Boolean(
    step?.template
      && typeof step.template.title === 'string'
      && typeof step.template.body === 'string',
  );
}

async function findWorkflow() {
  const response = await request('/v1/workflows');
  if (!response.ok) throw new Error(`Notification workflow list failed: ${await readError(response)}`);
  const payload = await readJson(response);
  return listItems(payload, ['workflows']).find(isWorkflowForIdentifier) || null;
}

async function ensureWorkflow() {
  if (workflowReadyPromise) return workflowReadyPromise;

  workflowReadyPromise = (async () => {
    const existing = await findWorkflow();
    const workflow = {
      identifier: WORKFLOW_IDENTIFIER,
      name: WORKFLOW_NAME,
      description: 'Generic FCM notification bridge for PandaPay inbox events.',
      active: true,
      steps: [{
        template: {
          title: '{{payload.title}}',
          body: '{{payload.body}}',
        },
      }],
    };

    if (existing && isUsablePushWorkflow(existing)) return;

    const response = await request(
      existing ? `/v1/workflows/${encodeURIComponent(WORKFLOW_IDENTIFIER)}` : '/v1/workflows',
      {
        method: existing ? 'PUT' : 'POST',
        headers: { 'Idempotency-Key': idempotencyKey('workflow', WORKFLOW_IDENTIFIER) },
        body: JSON.stringify(existing ? {
          name: workflow.name,
          description: workflow.description,
          active: workflow.active,
          steps: workflow.steps,
        } : workflow),
      },
    );
    if (!response.ok && response.status !== 409) {
      throw new Error(`Notification workflow ${existing ? 'update' : 'creation'} failed: ${await readError(response)}`);
    }
    if (!existing && response.status === 409 && !(await findWorkflow())) {
      throw new Error('Notification workflow already exists but could not be found');
    }
  })();

  try {
    await workflowReadyPromise;
  } catch (error) {
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
  const subscriberResponse = await request(`/v1/subscribers/${encodeURIComponent(subscriberId)}`, {
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
  if (!subscriberResponse.ok) {
    throw new Error(`Notification subscriber registration failed: ${await readError(subscriberResponse)}`);
  }

  const credentialsResponse = await request(`/v1/subscribers/${encodeURIComponent(subscriberId)}/credentials`, {
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
  if (!credentialsResponse.ok) {
    throw new Error(`Notification device credential registration failed: ${await readError(credentialsResponse)}`);
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
  return (await readJson(response)) || { status: 'accepted' };
}

module.exports = { isConfigured, registerDevice, send, sendBroadcast };
