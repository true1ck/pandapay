const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');

function load(relativePath, dependencies) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

async function harness(t) {
  let proof = {
    id: 'user-a', recovery_channel: 'email',
    recovery_verified_at: Math.floor(Date.now() / 1000),
  };
  let queries = 0;
  const router = load('../src/routes/userRoutes.js', {
    '../db': { async query(sql) {
      if (sql.includes('SELECT email, phone_number FROM users')) {
        queries++;
        return { rows: [{ email: 'user@example.com', phone_number: '+919876548102' }] };
      }
      throw new Error(`Unexpected SQL in recovery-contact-check test: ${sql}`);
    } },
    '../middleware/authMiddleware': (req, _res, next) => { req.user = proof; next(); },
    '../utils/fieldEncryption': { decryptPhoneNumber: value => value },
    '../utils/recoveryContacts': { maskEmail: () => '', maskPhone: () => '' },
    '../middleware/stepUpAuth': { requireRecentOtpOrReauth: (_req, _res, next) => next() },
    '../middleware/userRateLimit': {
      userRateLimitRead: (_req, _res, next) => next(),
      userRateLimitWrite: (_req, _res, next) => next(),
      userRateLimitSensitive: (_req, _res, next) => next(),
    },
    '../middleware/validation': {
      validateDeviceIdParam: (_req, _res, next) => next(),
      validateLogoutOthersBody: (_req, _res, next) => next(),
    },
  });
  const app = express(); app.use(express.json()); app.use('/users', router);
  const server = await new Promise(resolve => {
    const listener = app.listen(0, '127.0.0.1', () => resolve(listener));
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  return {
    setProof(value) { proof = value; },
    get queries() { return queries; },
    async post(body) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/users/me/recovery-contact-check`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    },
  };
}

test('second recovery check accepts only the linked contact suffix', async t => {
  const h = await harness(t);
  assert.equal((await h.post({ last_four: '8102' })).status, 200);
  assert.equal((await h.post({ last_four: '0000' })).status, 400);
  assert.equal((await h.post({ last_four: '99998102' })).status, 400);
});

test('normal or expired tokens cannot use the linked-contact check', async t => {
  const h = await harness(t);
  h.setProof({ id: 'user-a' });
  assert.equal((await h.post({ last_four: '8102' })).status, 403);
  h.setProof({
    id: 'user-a', recovery_channel: 'email', recovery_verified_at: 1,
  });
  assert.equal((await h.post({ last_four: '8102' })).status, 403);
  assert.equal(h.queries, 0);
});
