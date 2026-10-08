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
  global.fetch = async (url) => {
    if (url.endsWith('/v1/workflows/pandapay-notification')) {
      return new Response('', { status: 200 });
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
  global.fetch = async (url) => {
    if (url.endsWith('/v1/workflows/pandapay-notification')) {
      return new Response('', { status: 200 });
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
    if (url.endsWith('/v1/workflows/pandapay-notification')) {
      return new Response('', { status: 200 });
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
    assert.equal(JSON.parse(broadcast.options.body).name, 'pandapay-notification');
  } finally {
    global.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.NOTIFICATION_SERVICE_URL;
    else process.env.NOTIFICATION_SERVICE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.NOTIFICATION_SERVICE_API_KEY;
    else process.env.NOTIFICATION_SERVICE_API_KEY = previousKey;
    restoreTestConfig(previous);
  }
});
