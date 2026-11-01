'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

function probe({ mode = 'development', setting, blocked = '' } = {}) {
  const env = { ...process.env, NODE_ENV: mode, BLOCKED_IP_RANGES: blocked };
  delete env.AUTH_ALLOW_LOOPBACK_SIGNIN;
  if (setting !== undefined) env.AUTH_ALLOW_LOOPBACK_SIGNIN = setting;
  const dbPath = path.resolve(__dirname, '../src/db.js');
  const servicePath = path.resolve(__dirname, '../src/services/riskScoring.js');
  return spawnSync(process.execPath, ['-e', `
    require.cache[${JSON.stringify(dbPath)}] = { exports: {} };
    const { isIpBlocked } = require(${JSON.stringify(servicePath)});
    console.log(JSON.stringify(Object.fromEntries(
      ['127.0.0.1', '127.0.0.2', '::1', '::ffff:127.0.0.1', '10.1.2.3', '203.0.113.10']
        .map(ip => [ip, isIpBlocked(ip)])
    )));
  `], { env, encoding: 'utf8' });
}

test('ordinary auth keeps loopback blocked without the development opt-in', () => {
  for (const setting of [undefined, 'false']) {
    const result = probe({ setting });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout)['127.0.0.1'], true);
  }
});

test('the opt-in allows exact local addresses while retaining other private-range blocks', () => {
  for (const mode of ['development', 'test']) {
    const result = probe({ mode, setting: 'true' });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      '127.0.0.1': false, '127.0.0.2': true, '::1': false,
      '::ffff:127.0.0.1': false, '10.1.2.3': true, '203.0.113.10': false,
    });
  }
});

test('explicit operator IP blocks take precedence over the local opt-in', () => {
  const result = probe({ setting: 'true', blocked: '127.0.0.0/8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout)['127.0.0.1'], true);
});

test('hosted or unknown environments refuse the development opt-in', () => {
  for (const mode of ['production', 'staging', '']) {
    const result = probe({ mode, setting: 'true' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /restricted to development\/test/);
  }
});

test('malformed local sign-in configuration fails closed', () => {
  const result = probe({ setting: '1' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must be true or false/);
});
