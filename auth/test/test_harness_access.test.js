const test = require('node:test');
const assert = require('node:assert/strict');
const { mountTestHarness, testHarnessAllowed } = require('../src/utils/testHarnessAccess');

test('test harness is disabled in production and staging', () => {
  for (const NODE_ENV of ['production', 'staging', 'Production', ' STAGING ']) {
    assert.equal(testHarnessAllowed({ NODE_ENV }), false);
  }
});

test('test harness remains available in local and test environments', () => {
  for (const NODE_ENV of ['development', 'test', '']) {
    assert.equal(testHarnessAllowed({ NODE_ENV }), true);
  }
});

test('hosted environments do not mount public static assets or test aliases', () => {
  for (const NODE_ENV of ['production', 'staging']) {
    const calls = [];
    const app = {
      use: (...args) => calls.push(['use', ...args]),
      get: (...args) => calls.push(['get', ...args]),
    };
    const express = { static: path => ({ staticRoot: path }) };

    assert.equal(mountTestHarness(app, express, { NODE_ENV }), false);
    assert.deepEqual(calls, []);
  }
});

test('local environments retain the existing static mount and test aliases', () => {
  const calls = [];
  const app = {
    use: (...args) => calls.push(['use', ...args]),
    get: (...args) => calls.push(['get', ...args]),
  };
  const express = { static: path => ({ staticRoot: path }) };

  assert.equal(mountTestHarness(app, express, { NODE_ENV: 'development' }), true);
  assert.equal(calls.length, 3);
  assert.equal(calls[0][0], 'use');
  assert.deepEqual(calls[0][1], { staticRoot: 'public' });
  assert.deepEqual(calls.slice(1).map(call => call.slice(0, 2)), [
    ['get', '/test'],
    ['get', '/testpage'],
  ]);
});
