'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { createTelemetry, createMetrics, createReporter, parseDsn, parseMetricsConfig } = require('../src/telemetry');

const DSN = 'https://0123456789abcdef0123456789abcdef@errors.example.test/3';

function recorder({ ok = true } = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push({ url, init }); return { ok, body: { cancel() {} } }; };
  return { calls, fetchImpl };
}

function payload(call) {
  const [header, item, event] = call.init.body.trim().split('\n').map(line => JSON.parse(line));
  return { header, item, event };
}

test('DSN must be https (or loopback http) with a public key and numeric project', () => {
  assert.deepEqual(parseDsn(DSN), {
    envelopeUrl: 'https://errors.example.test/api/3/envelope/',
    auth: 'Sentry sentry_version=7, sentry_client=pandapay-telemetry/1.0, sentry_key=0123456789abcdef0123456789abcdef',
  });
  assert.equal(parseDsn(''), null);
  assert.ok(parseDsn('http://0123456789abcdef0123456789abcdef@127.0.0.1:8000/1'));
  for (const bad of [
    'http://0123456789abcdef0123456789abcdef@errors.example.test/3',
    'https://0123456789abcdef0123456789abcdef:secret@errors.example.test/3',
    'https://short@errors.example.test/3',
    'https://0123456789abcdef0123456789abcdef@errors.example.test/abc',
    'https://0123456789abcdef0123456789abcdef@errors.example.test/3?x=1',
  ]) assert.throws(() => parseDsn(bad), /ERROR_REPORTING_DSN/, bad);
});

test('an exception report carries type, safe code and code locations, never the message', async () => {
  const { calls, fetchImpl } = recorder();
  const reporter = createReporter({ dsn: DSN, service: 'api', release: 'abc1234', environment: 'production',
    fetchImpl, appRoot: path.resolve(__dirname, '..') });
  const error = new Error('duplicate key for phone 9876543210: "Rs 500 debited from A/c XX1234"');
  error.code = '23505';
  reporter.captureException(error, { kind: 'unhandled_request', method: 'POST', route: '/transactions/:id' });
  await reporter.flush();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://errors.example.test/api/3/envelope/');
  assert.equal(calls[0].init.redirect, 'error');
  assert.match(calls[0].init.headers['x-sentry-auth'], /sentry_key=0123456789abcdef/);
  const raw = calls[0].init.body;
  for (const secret of ['9876543210', 'debited', 'XX1234', 'duplicate key']) assert.ok(!raw.includes(secret), secret);

  const { item, event } = payload(calls[0]);
  assert.equal(item.type, 'event');
  assert.equal(event.release, 'abc1234');
  assert.equal(event.environment, 'production');
  assert.deepEqual(event.tags, { service: 'api', kind: 'unhandled_request', method: 'POST', route: '/transactions/:id' });
  const [exception] = event.exception.values;
  assert.equal(exception.type, 'Error');
  assert.equal(exception.value, '23505');
  const own = exception.stacktrace.frames.filter(f => f.in_app);
  assert.ok(own.some(f => f.filename === path.join('test', 'telemetry.test.js')), 'frames are relative to the app root');
  assert.ok(!raw.includes(path.resolve(__dirname, '..')), 'absolute server paths are not sent');
  assert.equal(event.user, undefined);
  assert.equal(event.request, undefined);
});

test('repeats are de-duplicated and bursts are capped', async () => {
  const { calls, fetchImpl } = recorder();
  const metrics = createMetrics();
  let now = 1_000_000;
  const reporter = createReporter({ dsn: DSN, service: 'auth', fetchImpl, metrics, maxPerMinute: 2, clock: () => now });
  reporter.captureServerError({ method: 'GET', route: '/me', status: 503 });
  reporter.captureServerError({ method: 'GET', route: '/me', status: 503 });
  reporter.captureServerError({ method: 'GET', route: '/otp', status: 500 });
  reporter.captureServerError({ method: 'GET', route: '/x', status: 500 });
  await reporter.flush();
  assert.equal(calls.length, 2);
  assert.equal(payload(calls[0]).event.message.formatted, 'GET /me returned 503');
  now += 61_000;
  reporter.captureServerError({ method: 'GET', route: '/me', status: 503 });
  await reporter.flush();
  assert.equal(calls.length, 3, 'the same problem reports again after a minute');
  assert.match(metrics.render(), /error_reports_total\{outcome="dropped"\} 2/);
  assert.match(metrics.render(), /error_reports_total\{outcome="sent"\} 3/);
  metrics.close();
});

test('reporting is a no-op without a DSN and never throws on delivery failure', async () => {
  const off = createReporter({ dsn: undefined, service: 'api', fetchImpl: () => { throw new Error('must not call'); } });
  off.captureException(new Error('x'));
  assert.equal(off.enabled, false);
  const failing = createReporter({ dsn: DSN, service: 'api', fetchImpl: async () => { throw new Error('down'); } });
  failing.captureException(new TypeError('boom'));
  await failing.flush();
});

test('metrics render Prometheus text with bounded, escaped labels', () => {
  const metrics = createMetrics();
  metrics.observeRequest('GET', '/cards/:id', 200, 0.04);
  metrics.observeRequest('GET', '/cards/:id', 200, 0.3);
  metrics.observeRequest('POST', '/weird"route', 503, 2);
  const text = metrics.render();
  assert.match(text, /http_requests_total\{method="GET",route="\/cards\/:id",status="2xx"\} 2/);
  assert.match(text, /http_requests_total\{method="POST",route="\/weird\\"route",status="5xx"\} 1/);
  assert.match(text, /http_request_duration_seconds_bucket\{method="GET",route="\/cards\/:id",le="0.05"\} 1/);
  assert.match(text, /http_request_duration_seconds_bucket\{method="GET",route="\/cards\/:id",le="0.5"\} 2/);
  assert.match(text, /http_request_duration_seconds_count\{method="GET",route="\/cards\/:id"\} 2/);
  assert.match(text, /process_resident_memory_bytes \d+/);
  for (let i = 0; i < 600; i++) metrics.observeRequest('GET', `/r${i}`, 200, 0.01);
  assert.ok((metrics.render().match(/^http_requests_total\{/gm) || []).length <= 502, 'series are capped');
  assert.match(metrics.render(), /route="\[other\]"/);
  metrics.close();
});

test('metrics port is private, separate from the public port, and serves only /metrics', async () => {
  assert.equal(parseMetricsConfig({}), null);
  assert.throws(() => parseMetricsConfig({ METRICS_PORT: '4000', PORT: '4000' }), /differ/);
  assert.throws(() => parseMetricsConfig({ METRICS_PORT: '9464', METRICS_HOST: '192.168.1.10' }), /loopback/);
  assert.throws(() => parseMetricsConfig({ METRICS_PORT: '80' }), /1024/);

  const port = 20000 + Math.floor(Math.random() * 20000);
  const telemetry = createTelemetry({ service: 'api', env: { METRICS_PORT: String(port) } });
  telemetry.start();
  await new Promise(resolve => setTimeout(resolve, 50));
  telemetry.metrics.observeRequest('GET', '/health', 200, 0.001);
  const ok = await fetch(`http://127.0.0.1:${port}/metrics`);
  assert.equal(ok.status, 200);
  assert.match(await ok.text(), /route="\/health"/);
  assert.equal((await fetch(`http://127.0.0.1:${port}/`)).status, 404);
  assert.equal((await fetch(`http://127.0.0.1:${port}/metrics`, { method: 'POST' })).status, 404);
  await telemetry.stop();
  assert.equal(telemetry.reporter.enabled, false);
});

test('request pipeline reports a crashed route once and a handled 5xx once, with route templates', async () => {
  const express = require('express');
  const { requestLogger, errorHandler, telemetry } = require('../src/observability');
  const seen = [];
  const original = { ...telemetry.reporter };
  telemetry.reporter.captureException = (_e, ctx) => seen.push(['exception', ctx.route]);
  telemetry.reporter.captureServerError = ctx => seen.push(['http', ctx.route, ctx.status]);
  try {
    const app = express();
    app.use(requestLogger);
    app.get('/boom/:id', () => { throw new Error('secret 9876543210'); });
    app.get('/down/:id', (_req, res) => res.status(503).json({ error: 'unavailable' }));
    app.get('/fine', (_req, res) => res.json({ ok: true }));
    app.use(errorHandler);
    const server = app.listen(0);
    await new Promise(resolve => server.once('listening', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    try {
      await fetch(`${base}/boom/123`); await fetch(`${base}/down/456`); await fetch(`${base}/fine`);
      await new Promise(resolve => setTimeout(resolve, 20));
    } finally { server.close(); }
    assert.deepEqual(seen, [['exception', '/boom/:id'], ['http', '/down/:id', 503]]);
    assert.match(telemetry.metrics.render(), /http_requests_total\{method="GET",route="\/boom\/:id",status="5xx"\} 1/);
  } finally {
    Object.assign(telemetry.reporter, original);
  }
});
