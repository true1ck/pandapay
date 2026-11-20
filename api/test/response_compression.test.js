'use strict';
// Every JSON answer is gzip-compressed for a client that asks (Accept-Encoding: gzip). Phones use dart:io, which
// always asks and inflates, so no app change is needed. Small answers, clients that do not ask and answers that are
// already compressed (rules, catalogue) are left as they are.
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const zlib = require('node:zlib');
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');
const { compressResponses } = require('../src/response_compression');

function server() {
  const app = express();
  app.use(compressResponses);
  const big = { rows: Array.from({ length: 400 }, (_, i) => ({ id: `row-${i}`, merchant: 'SWIGGY', amountMinor: 1000 + i })) };
  app.get('/big', (req, res) => res.json(big));
  app.get('/small', (req, res) => res.json({ ok: true }));
  app.get('/pre', (req, res) => {
    res.set({ 'Content-Type': 'application/json; charset=utf-8', 'Content-Encoding': 'gzip' });
    res.end(zlib.gzipSync(JSON.stringify(big)));
  });
  app.get('/no-transform', (req, res) => { res.set('Cache-Control', 'no-transform'); res.json(big); });
  return { app, big };
}

function get(app, url, headers = {}) {
  return new Promise((resolve, reject) => {
    const srv = app.listen(0, () => {
      const req = http.get({ port: srv.address().port, path: url, headers }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => { srv.close(); resolve({ res, body: Buffer.concat(chunks) }); });
      });
      req.on('error', (e) => { srv.close(); reject(e); });
    });
  });
}

test('a large JSON answer is gzipped for a client that asks, and inflates to the same JSON', async () => {
  const { app, big } = server();
  const { res, body } = await get(app, '/big', { 'Accept-Encoding': 'gzip' });
  assert.equal(res.headers['content-encoding'], 'gzip');
  assert.match(res.headers.vary || '', /Accept-Encoding/i);
  assert.deepEqual(JSON.parse(zlib.gunzipSync(body)), big);
  assert.ok(body.length < JSON.stringify(big).length / 3, `compressed ${body.length} bytes`);
});

test('a client that does not ask gets plain JSON', async () => {
  const { app, big } = server();
  const { res, body } = await get(app, '/big');
  assert.equal(res.headers['content-encoding'], undefined);
  assert.deepEqual(JSON.parse(body), big);
});

test('a tiny answer is not compressed (not worth it)', async () => {
  const { res, body } = await get(server().app, '/small', { 'Accept-Encoding': 'gzip' });
  assert.equal(res.headers['content-encoding'], undefined);
  assert.deepEqual(JSON.parse(body), { ok: true });
});

test('an answer that is already gzipped is not compressed twice', async () => {
  const { app, big } = server();
  const { res, body } = await get(app, '/pre', { 'Accept-Encoding': 'gzip' });
  assert.equal(res.headers['content-encoding'], 'gzip');
  assert.deepEqual(JSON.parse(zlib.gunzipSync(body)), big);
});

test('Cache-Control: no-transform is respected', async () => {
  const { res } = await get(server().app, '/no-transform', { 'Accept-Encoding': 'gzip' });
  assert.equal(res.headers['content-encoding'], undefined);
});

test('the API mounts it before its routes', () => {
  const src = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  const mounted = src.indexOf('app.use(compressResponses)');
  assert.ok(mounted > 0, 'compressResponses is mounted');
  assert.ok(mounted < src.indexOf("require('./sms_v2').registerSmsV2(app"), 'before the SMS v2 routes');
  assert.ok(mounted < src.indexOf("app.get('/health'"), 'before the first route');
});
