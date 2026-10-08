const test = require('node:test');
const assert = require('node:assert/strict');

const originalFetch = global.fetch;

function loadService() {
  const path = require.resolve('../src/notification_service');
  delete require.cache[path];
  return require('../src/notification_service');
}

function setTestConfig(previous) {
  previous.databaseUrl = process.env.DATABASE_URL;
  previous.jwtAccessSecret = process.env.JWT_ACCESS_SECRET;
  process.env.DATABASE_URL = 'postgres://notification-test';
  process.env.JWT_ACCESS_SECRET = 'notification-test-secret';
}

function restoreTestConfig(previous) {
  if (previous.databaseUrl === undefined) delete process.env.DATABASE_URL;
  else process.env.DATABASE_URL = previous.databaseUrl;
  if (previous.jwtAccessSecret === undefined) delete process.env.JWT_ACCESS_SECRET;
  else process.env.JWT_ACCESS_SECRET = previous.jwtAccessSecret;
}

test('send rejects provider responses with no registered devices', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  global.fetch = async (url, options = {}) => {
    if (url.endsWith('/v1/workflows') && (!options.method || options.method === 'GET')) {
      return new Response(JSON.stringify({ data: [{ identifier: 'pandapay-push-notification' }] }), { status: 200 });
    }
    return new Response(JSON.stringify({ status: 'no_devices', queued: 0 }), {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  };

  try {
    const service = loadService();
    await assert.rejects(
      service.send({ subscriberId: 'user-1', title: 'Test', body: 'Body' }),
      (error) => error.code === 'notification_no_devices' && /no registered devices/.test(error.message),
    );
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('send returns a queued provider response', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  const requests = [];
  global.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    if (url.endsWith('/v1/workflows') && (!options.method || options.method === 'GET')) {
      return new Response(JSON.stringify({ data: [{ identifier: 'pandapay-push-notification' }] }), { status: 200 });
    }
    return new Response(JSON.stringify({ status: 'processed', queued: 1 }), {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  };

  try {
    const service = loadService();
    await assert.doesNotReject(
      service.send({ subscriberId: 'user-1', title: 'Test', body: 'Body' }),
    );
    const trigger = requests.find(({ url }) => url.endsWith('/v1/events/trigger'));
    assert.ok(trigger);
    assert.equal(JSON.parse(trigger.options.body).workflowId, 'pandapay-push-notification');
    assert.equal(JSON.parse(trigger.options.body).name, undefined);
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('send retries a transient provider response with the same idempotency key', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  let triggerAttempts = 0;
  const requests = [];
  global.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    if (url.endsWith('/v1/workflows') && (!options.method || options.method === 'GET')) {
      return new Response(JSON.stringify({ data: [{ identifier: 'pandapay-push-notification' }] }), { status: 200 });
    }
    if (url.endsWith('/v1/events/trigger')) {
      triggerAttempts += 1;
      if (triggerAttempts === 1) return new Response('', { status: 503 });
      return new Response(JSON.stringify({ status: 'processed', queued: 1 }), {
        status: 201,
        headers: { 'content-type': 'application/json' },
      });
    }
    return new Response(JSON.stringify({ status: 'processed' }), { status: 201 });
  };

  try {
    const service = loadService();
    await service.send({
      subscriberId: 'user-1',
      title: 'Test',
      body: 'Body',
      dedupeKey: 'test-retry-1',
    });
    const triggerRequests = requests.filter(({ url }) => url.endsWith('/v1/events/trigger'));
    assert.equal(triggerRequests.length, 2);
    assert.equal(
      triggerRequests[0].options.headers['Idempotency-Key'],
      'test-retry-1',
    );
    assert.equal(
      triggerRequests[1].options.headers['Idempotency-Key'],
      'test-retry-1',
    );
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('send treats an accepted provider response with an empty body as success', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  global.fetch = async (url, options = {}) => {
    if (url.endsWith('/v1/workflows') && (!options.method || options.method === 'GET')) {
      return new Response(JSON.stringify({ data: [{ identifier: 'pandapay-push-notification' }] }), { status: 200 });
    }
    return new Response('', { status: 202 });
  };

  try {
    const service = loadService();
    const result = await service.send({
      subscriberId: 'user-1',
      title: 'Test',
      body: 'Body',
      dedupeKey: 'test-empty-response-1',
    });
    assert.equal(result.status, 'accepted');
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('surfaces provider authentication failures without retrying', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'wrong-key';
  let requests = 0;
  global.fetch = async () => {
    requests += 1;
    return new Response('Unauthorized', { status: 401 });
  };

  try {
    const service = loadService();
    await assert.rejects(
      service.send({ subscriberId: 'user-1', title: 'Test', body: 'Body' }),
      (error) => error.code === 'notification_service_auth_failed',
    );
    assert.equal(requests, 1);
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('sendBroadcast uses the provider fan-out endpoint and idempotency key', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  const requests = [];
  global.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    if (url.endsWith('/v1/workflows') && (!options.method || options.method === 'GET')) {
      return new Response(JSON.stringify({ data: [{ identifier: 'pandapay-push-notification' }] }), { status: 200 });
    }
    return new Response(JSON.stringify({ status: 'processed', transactionId: 'broadcast-1' }), {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  };

  try {
    const service = loadService();
    const result = await service.sendBroadcast({
      title: 'Maintenance',
      body: 'The service is back.',
      category: 'general',
      dedupeKey: 'broadcast-1',
    });
    assert.equal(result.transactionId, 'broadcast-1');
    const broadcast = requests.find(({ url }) => url.endsWith('/v1/events/trigger/broadcast'));
    assert.ok(broadcast);
    assert.equal(broadcast.options.headers['Idempotency-Key'], 'broadcast-1');
    assert.equal(JSON.parse(broadcast.options.body).workflowId, 'pandapay-push-notification');
    assert.equal(JSON.parse(broadcast.options.body).name, undefined);
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('creates a valid push workflow through the deployed v1 workflow endpoint when missing', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  const requests = [];
  global.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    if (url.endsWith('/v1/workflows') && (!options.method || options.method === 'GET')) {
      return new Response(JSON.stringify({ data: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (url.endsWith('/v1/workflows') && options.method === 'POST') {
      return new Response(JSON.stringify({ data: { identifier: 'pandapay-push-notification' } }), {
        status: 201,
        headers: { 'content-type': 'application/json' },
      });
    }
    return new Response(JSON.stringify({ status: 'processed' }), {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  };

  try {
    const service = loadService();
    await service.send({ subscriberId: 'user-1', title: 'Test', body: 'Body' });
    const workflow = requests.find(({ url, options }) =>
      url.endsWith('/v1/workflows') && options.method === 'POST');
    assert.ok(workflow);
    const workflowBody = JSON.parse(workflow.options.body);
    assert.equal(workflowBody.workflowId, 'pandapay-push-notification');
    assert.equal(workflowBody.identifier, 'pandapay-push-notification');
    assert.equal(workflowBody.triggers[0].identifier, 'pandapay-push-notification');
    assert.equal(workflowBody.steps[0].template.type, 'push');
    assert.equal(workflowBody.steps[0].template.name, 'PandaPay push notification');
    assert.equal(workflowBody.steps[0].template.title, '{{payload.title}}');
    assert.equal(workflowBody.steps[0].template.content, '{{payload.body}}');
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});

test('registerDevice uses the deployed PUT credentials endpoint', async () => {
  const previousUrl = process.env.NOTIFICATION_SERVICE_URL;
  const previousKey = process.env.NOTIFICATION_SERVICE_API_KEY;
  const previous = {};
  setTestConfig(previous);
  process.env.NOTIFICATION_SERVICE_URL = 'http://notifications.test';
  process.env.NOTIFICATION_SERVICE_API_KEY = 'test-key';
  const requests = [];
  global.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    return new Response(JSON.stringify({ data: { subscriberId: 'user-1' } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  };

  try {
    const service = loadService();
    await service.registerDevice({
      subscriberId: 'user-1',
      token: 'fcm-token-1',
      platform: 'android',
      email: 'user@example.com',
      displayName: 'Test User',
      timezone: 'Asia/Kolkata',
    });
    assert.equal(requests.length, 2);
    assert.equal(requests[0].options.method, 'PUT');
    assert.equal(requests[1].url, 'http://notifications.test/v1/subscribers/user-1/credentials');
    assert.equal(requests[1].options.method, 'PUT');
    assert.deepEqual(JSON.parse(requests[1].options.body), {
      providerId: 'fcm',
      credentials: { deviceTokens: ['fcm-token-1'] },
    });
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});
