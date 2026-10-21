const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'session-state-access-secret';
process.env.JWT_KEYS_JSON = JSON.stringify({ current: process.env.JWT_ACCESS_SECRET });
process.env.JWT_ACTIVE_KEY_ID = 'current';
process.env.JWT_ISSUER = 'pandapay-auth';
process.env.JWT_AUDIENCE = 'mobile-app';

function loadAuthMiddleware(db) {
  const filename = path.resolve(__dirname, '../src/middleware/authMiddleware.js');
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => request === '../db' ? db : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

function response() {
  return {
    statusCode: null, body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

function accessToken(deviceId) {
  return jwt.sign({ sub: 'user-1', token_version: 4, ...(deviceId ? { device_id: deviceId } : {}) },
    process.env.JWT_ACCESS_SECRET, {
      keyid: 'current', issuer: process.env.JWT_ISSUER, audience: process.env.JWT_AUDIENCE,
      expiresIn: '5m',
    });
}

test('auth middleware rejects disabled/deleted accounts and revoked device sessions', async () => {
  const db = { async query(sql) {
    if (sql.includes('FROM users')) return { rows: [{ token_version: 4, is_active: false, deleted: false }] };
    throw new Error('A disabled account must not reach device lookup');
  } };
  const middleware = loadAuthMiddleware(db);
  const res = response();
  await middleware({ headers: { authorization: `Bearer ${accessToken('device-1')}` } }, res, () => assert.fail());
  assert.equal(res.statusCode, 401);

  db.query = async sql => {
    if (sql.includes('FROM users')) return { rows: [{ token_version: 4, is_active: true, deleted: false }] };
    if (sql.includes('FROM user_devices')) return { rows: [] };
    throw new Error('Unexpected query');
  };
  const deviceRes = response();
  await middleware({ headers: { authorization: `Bearer ${accessToken('device-1')}` } }, deviceRes, () => assert.fail());
  assert.equal(deviceRes.statusCode, 401);
});

test('auth middleware admits an active account and active bound device', async () => {
  const db = { async query(sql) {
    if (sql.includes('FROM users')) return { rows: [{ token_version: 4, is_active: true, deleted: false }] };
    if (sql.includes('FROM user_devices')) return { rows: [{ id: 'device-row' }] };
    throw new Error('Unexpected query');
  } };
  const middleware = loadAuthMiddleware(db);
  const req = { headers: { authorization: `Bearer ${accessToken('device-1')}` } };
  const res = response();
  let passed = false;
  await middleware(req, res, () => { passed = true; });
  assert.equal(passed, true);
  assert.equal(req.user.id, 'user-1');
});
