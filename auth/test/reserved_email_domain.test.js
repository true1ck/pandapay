'use strict';

const assert = require('node:assert/strict');
const net = require('node:net');
const Module = require('node:module');
const { test } = require('node:test');
const { isReservedTestEmail } = require('../src/utils/reservedEmailDomain');

test('reserved test domains are recognised, real and look-alike domains are not', () => {
  for (const email of [
    'testuser@example.com', 'A@EXAMPLE.COM', 'x@sub.example.org', 'x@example.net.', 'x@foo.test',
    'x@bar.example', 'x@a.invalid', 'x@h.localhost', ' x@example.com ',
  ]) assert.equal(isReservedTestEmail(email), true, email);
  for (const email of [
    'x@gmail.com', 'x@example.co', 'x@notexample.com', 'x@example.com.evil.in', 'x@myexample.org',
    'x@test.com', 'x@invalid.com', '', 'nodomain', '@example.com', 'x@', null, undefined, 42, {},
  ]) assert.equal(isReservedTestEmail(email), false, String(email));
});

// A mail server that only counts how many times anyone connects to it.
function countingServer() {
  const state = { connections: 0 };
  const server = net.createServer(socket => { state.connections++; socket.destroy(); });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve({ server, state, port: server.address().port }));
  });
}

function loadEmailService(config) {
  const configPath = require.resolve('../src/config');
  const servicePath = require.resolve('../src/services/emailService');
  const priorConfig = require.cache[configPath];
  const priorService = require.cache[servicePath];
  const mock = new Module(configPath);
  mock.filename = configPath;
  mock.loaded = true;
  mock.exports = config;
  require.cache[configPath] = mock;
  delete require.cache[servicePath];
  const service = require(servicePath);
  return {
    service,
    restore() {
      delete require.cache[servicePath];
      if (priorService) require.cache[servicePath] = priorService;
      if (priorConfig) require.cache[configPath] = priorConfig;
      else delete require.cache[configPath];
    },
  };
}

const configFor = (port, suppressReservedEmailDomains) => ({
  emailHost: '127.0.0.1', emailPort: String(port), emailUser: 'synthetic-user',
  emailPass: 'synthetic-password', emailFrom: 'noreply@pandapay.invalid', isProduction: false, suppressReservedEmailDomains,
});

async function withService(suppress, run) {
  const fixture = await countingServer();
  const loaded = loadEmailService(configFor(fixture.port, suppress));
  const silenced = { info: console.info, error: console.error, warn: console.warn };
  const lines = [];
  console.info = (...a) => lines.push(a.join(' '));
  console.error = () => {};
  console.warn = () => {};
  try {
    await run(loaded.service, fixture.state, lines);
  } finally {
    Object.assign(console, silenced);
    loaded.restore();
    await new Promise(resolve => fixture.server.close(resolve));
  }
}

test('with the guard on, a code for a reserved test domain sends nothing and says it worked', { timeout: 30000 }, async () => {
  await withService(true, async (service, state, lines) => {
    const code = await service.sendOtpEmail('testuser@example.com', '123456');
    assert.deepEqual(code, { success: true, suppressed: true });
    const recovery = await service.sendOtpEmail('someone@x.example.net', '123456', { purpose: 'recovery-code' });
    assert.deepEqual(recovery, { success: true, suppressed: true });
    const notice = await service.sendSecurityNotice({ to: 'testuser@example.com', subject: 'Notice', text: 'A recovery email was added' });
    assert.equal(notice.success, true);
    assert.equal(state.connections, 0, 'the mail server was never contacted');
    assert.ok(lines.some(line => /not sent: reserved test domain/.test(line)), 'it is logged');
    assert.ok(!lines.some(line => line.includes('example.com')), 'the address is never logged');
  });
});

test('with the guard on, an ordinary address still goes to the mail server', { timeout: 30000 }, async () => {
  await withService(true, async (service, state) => {
    const result = await service.sendOtpEmail('person@gmail.com', '123456');
    assert.equal(result.suppressed, undefined);
    assert.ok(state.connections >= 1, 'the mail server was contacted');
  });
});

test('with the guard off (tests, or EMAIL_SEND_TO_RESERVED_DOMAINS=true) example addresses are sent as before', { timeout: 30000 }, async () => {
  for (const flag of [false, undefined]) {
    await withService(flag, async (service, state) => {
      const result = await service.sendOtpEmail('testuser@example.com', '123456');
      assert.equal(result.suppressed, undefined);
      assert.ok(state.connections >= 1);
    });
  }
});

test('the real config turns the guard on only in hosted environments, and the switch turns it off', () => {
  const configPath = require.resolve('../src/config');
  const keep = { ...process.env };
  const load = env => {
    for (const key of ['NODE_ENV', 'EMAIL_SEND_TO_RESERVED_DOMAINS']) delete process.env[key];
    Object.assign(process.env, { JWT_ACCESS_SECRET: 'synthetic-access-secret-for-tests-only-32', JWT_REFRESH_SECRET: 'synthetic-refresh-secret-for-tests-only-32', DATABASE_URL: 'postgresql://x:x@127.0.0.1:1/x', ...env });
    delete require.cache[configPath];
    try { return require(configPath).suppressReservedEmailDomains; } finally { delete require.cache[configPath]; }
  };
  try {
    assert.equal(load({ NODE_ENV: 'test' }), false);
    assert.equal(load({}), false);
    assert.equal(load({ NODE_ENV: 'staging' }), true);
    assert.equal(load({ NODE_ENV: 'staging', EMAIL_SEND_TO_RESERVED_DOMAINS: 'true' }), false);
  } finally {
    for (const key of Object.keys(process.env)) if (!(key in keep)) delete process.env[key];
    Object.assign(process.env, keep);
  }
});
