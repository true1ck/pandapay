'use strict';
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const express = require('express');
const {
  createLegacyVersionGate, parseAppVersion, compareVersions, parseCutoff, parseFirstVersion,
} = require('../src/legacy_version_gate');

const CUTOFF = new Date('2027-01-01T00:00:00Z');
const BEFORE = Date.parse('2026-12-31T23:59:59Z');
const AFTER = Date.parse('2027-01-01T00:00:00Z');
const LEGACY_ROUTES = [
  ['POST', '/transactions/from-sms/batch'],
  ['POST', '/sms/facts'],
  ['POST', '/sms/facts/overrides'],
  ['POST', '/ai/jobs'],
  ['GET', '/ai/jobs/source/abc'],
  ['GET', '/sms/rules/active'],
];

async function serve(options) {
  const app = express();
  app.use(createLegacyVersionGate(options));
  app.use((_req, res) => res.json({ handled: true }));
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const call = (method, route, version) => fetch(`${origin}${route}`, { method, headers: version === undefined ? {} : { 'x-app-version': version } });
  return { call, close: () => { server.closeAllConnections(); return new Promise((resolve) => server.close(resolve)); } };
}

test('version parsing and ordering', () => {
  assert.deepEqual(parseAppVersion('1.0.16+105'), [1, 0, 16, 105]);
  assert.deepEqual(parseAppVersion('2.1'), [2, 1, 0, 0]);
  assert.deepEqual(parseAppVersion('v1.2.3-beta'), [1, 2, 3, 0]);
  for (const bad of ['', 'abc', '1.2.3.4', '1..2', undefined, null, 5]) assert.equal(parseAppVersion(bad), null);
  assert.equal(compareVersions([1, 0, 16, 105], [1, 1, 0, 0]), -1);
  assert.equal(compareVersions([1, 10, 0, 0], [1, 9, 0, 0]), 1);
  assert.equal(compareVersions([1, 1, 0, 0], [1, 1, 0, 0]), 0);
});

test('cutoff and first version settings are validated strictly', () => {
  assert.equal(parseCutoff(undefined), null);
  assert.equal(parseCutoff(''), null);
  assert.equal(parseCutoff('2027-01-01').toISOString(), '2027-01-01T00:00:00.000Z');
  assert.equal(parseCutoff('2027-01-01T05:30:00Z').toISOString(), '2027-01-01T05:30:00.000Z');
  for (const bad of ['01/01/2027', '2027-13-45', 'tomorrow', '2027-01-01T00:00:00+05:30']) assert.throws(() => parseCutoff(bad));
  assert.equal(parseFirstVersion(undefined), null);
  assert.equal(parseFirstVersion('1.1.0+110'), '1.1.0+110');
  assert.throws(() => parseFirstVersion('soon'));
  assert.throws(() => createLegacyVersionGate({ cutoffAt: CUTOFF, firstV2Version: null }), /SMS_V2_FIRST_APP_VERSION/);
});

test('disabled by default: old, missing and odd versions are untouched even far in the future', async () => {
  const gate = await serve({ now: () => Date.parse('2040-01-01T00:00:00Z') });
  try {
    for (const [method, route] of LEGACY_ROUTES) {
      for (const version of [undefined, '0.0.1', '1.0.16+105', 'garbage']) {
        const res = await gate.call(method, route, version);
        assert.equal(res.status, 200, `${method} ${route} ${version}`);
      }
    }
  } finally { await gate.close(); }
});

test('before the cutoff an old app is unaffected on every legacy route', async () => {
  const gate = await serve({ cutoffAt: CUTOFF, firstV2Version: '1.1.0', now: () => BEFORE });
  try {
    for (const [method, route] of LEGACY_ROUTES) {
      assert.equal((await gate.call(method, route, '1.0.16+105')).status, 200, route);
      assert.equal((await gate.call(method, route)).status, 200, `${route} without the header`);
    }
  } finally { await gate.close(); }
});

test('at the cutoff old and header-less apps get 426 on the legacy routes; new apps do not', async () => {
  const gate = await serve({ cutoffAt: CUTOFF, firstV2Version: '1.1.0', now: () => AFTER });
  try {
    for (const [method, route] of LEGACY_ROUTES) {
      for (const old of ['1.0.16+105', '1.0.99', '0.9', undefined, 'garbage']) {
        const res = await gate.call(method, route, old);
        assert.equal(res.status, 426, `${method} ${route} ${old}`);
        const body = await res.json();
        assert.equal(body.error, 'upgrade_required');
        assert.equal(body.minimumVersion, '1.1.0');
        assert.equal(res.headers.get('cache-control'), 'no-store');
      }
      for (const current of ['1.1.0', '1.1.0+1', '1.2.0', '2.0.0']) {
        assert.equal((await gate.call(method, route, current)).status, 200, `${route} ${current}`);
      }
    }
  } finally { await gate.close(); }
});

test('after the cutoff other routes, the v2 routes, the AI worker and preflights are untouched', async () => {
  const gate = await serve({ cutoffAt: CUTOFF, firstV2Version: '1.1.0', now: () => AFTER });
  try {
    for (const [method, route] of [
      ['GET', '/health'], ['GET', '/transactions'], ['POST', '/sms/v2/facts:batch'], ['GET', '/sms/v2/sync'],
      ['GET', '/sms/rules'], ['GET', '/sms/factsheet'], ['GET', '/ai/jobsx'], ['GET', '/admin/sms/v2/metrics'],
      ['POST', '/ai/jobs/lease'], ['POST', '/ai/jobs/7d2f/heartbeat'], ['POST', '/ai/jobs/7d2f/result'],
      ['POST', '/ai/jobs/7d2f/retry'], ['POST', '/ai/jobs/7d2f/fail'], ['OPTIONS', '/sms/facts'],
    ]) {
      assert.equal((await gate.call(method, route, '0.1.0')).status, 200, `${method} ${route}`);
    }
  } finally { await gate.close(); }
});

test('path tricks do not slip past the gate', async () => {
  const gate = await serve({ cutoffAt: CUTOFF, firstV2Version: '1.1.0', now: () => AFTER });
  try {
    for (const route of ['/SMS/Facts', '/sms/facts/', '//sms//facts', '/sms/facts?x=1', '/Transactions/From-SMS/batch']) {
      assert.equal((await gate.call('POST', route, '1.0.0')).status, 426, route);
    }
  } finally { await gate.close(); }
});

test('missing header can be allowed explicitly while an old explicit version is still blocked', async () => {
  const gate = await serve({ cutoffAt: CUTOFF, firstV2Version: '1.1.0', blockMissingVersion: false, now: () => AFTER });
  try {
    assert.equal((await gate.call('POST', '/sms/facts')).status, 200);
    assert.equal((await gate.call('POST', '/sms/facts', '1.0.0')).status, 426);
  } finally { await gate.close(); }
});

test('the cutoff moment is read per request, so it takes effect without a restart', async () => {
  let clock = BEFORE;
  const gate = await serve({ cutoffAt: CUTOFF, firstV2Version: '1.1.0', now: () => clock });
  try {
    assert.equal((await gate.call('POST', '/sms/facts', '1.0.0')).status, 200);
    clock = AFTER;
    assert.equal((await gate.call('POST', '/sms/facts', '1.0.0')).status, 426);
  } finally { await gate.close(); }
});

function loadConfig(env) {
  const script = "const c=require('./src/config');process.stdout.write('\\nRESULT '+JSON.stringify({a:c.legacySmsCutoffAt,v:c.smsV2FirstAppVersion,m:c.legacySmsBlockMissingVersion}))";
  const run = spawnSync(process.execPath, ['-e', script], {
    cwd: path.resolve(__dirname, '..'), encoding: 'utf8',
    env: { PATH: process.env.PATH, JWT_ACCESS_SECRET: 'ci_only_not_a_real_secret', DATABASE_URL: 'postgres://u:p@127.0.0.1/none', DB_SSL: 'false', ...env },
  });
  // dotenv may print a banner on stdout; the result is the marked line.
  const line = String(run.stdout).split('\n').find((l) => l.startsWith('RESULT '));
  return { status: run.status, stderr: run.stderr, stdout: line ? line.slice(7) : '' };
}

test('config.js: the setting is unset by default and misconfiguration fails at startup', () => {
  const off = loadConfig({});
  assert.equal(off.status, 0, off.stderr);
  assert.deepEqual(JSON.parse(off.stdout), { a: null, v: null, m: true });
  const on = loadConfig({ LEGACY_SMS_CUTOFF_DATE: '2027-01-01', SMS_V2_FIRST_APP_VERSION: '1.1.0' });
  assert.equal(on.status, 0, on.stderr);
  assert.equal(JSON.parse(on.stdout).a, '2027-01-01T00:00:00.000Z');
  assert.notEqual(loadConfig({ LEGACY_SMS_CUTOFF_DATE: '2027-01-01' }).status, 0, 'cutoff without a first version');
  assert.notEqual(loadConfig({ LEGACY_SMS_CUTOFF_DATE: 'next spring', SMS_V2_FIRST_APP_VERSION: '1.1.0' }).status, 0);
});
