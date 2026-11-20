'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/pandapay';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Measured on production 21 Nov 2026: a new TLS connection to the database pooler costs 150-225 ms, a query on an open
// one 20 ms. With no minimum the pool fell back to one connection 10 s after each burst, so every app open paid for up
// to nine new connections before its first answer. A few connections now stay open between bursts.

function loadConfig(env) {
  const saved = {};
  for (const [k, v] of Object.entries(env)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k]; else process.env[k] = v;
  }
  delete require.cache[require.resolve('../src/config')];
  try {
    const mod = require('../src/config');
    return mod.config || mod;
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
    delete require.cache[require.resolve('../src/config')];
  }
}

test('without DB_POOL_MIN the pool keeps nothing idle, as before', () => {
  assert.equal(loadConfig({ DB_POOL_MIN: undefined, DB_POOL_MAX: undefined }).dbPoolMin, 0);
});

test('the minimum follows DB_POOL_MIN, allows 0, and never exceeds the maximum', () => {
  assert.equal(loadConfig({ DB_POOL_MIN: '2', DB_POOL_MAX: undefined }).dbPoolMin, 2);
  assert.equal(loadConfig({ DB_POOL_MIN: '0', DB_POOL_MAX: undefined }).dbPoolMin, 0);
  assert.equal(loadConfig({ DB_POOL_MIN: '50', DB_POOL_MAX: '6' }).dbPoolMin, 6);
  assert.equal(loadConfig({ DB_POOL_MIN: 'junk', DB_POOL_MAX: undefined }).dbPoolMin, 0);
  assert.equal(loadConfig({ DB_POOL_MIN: '-3', DB_POOL_MAX: undefined }).dbPoolMin, 0);
});

test('the request pool is created with that minimum', () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/db.js'), 'utf8');
  const poolBlock = source.slice(source.indexOf('const pool = new Pool({'), source.indexOf('});', source.indexOf('const pool = new Pool({')));
  assert.match(poolBlock, /min: config\.dbPoolMin,/);
});

test('production compose keeps 4 warm for the API service only', () => {
  const compose = fs.readFileSync(path.join(__dirname, '../../docker-compose.prod.yml'), 'utf8');
  const service = (name) => {
    const start = compose.indexOf(`\n  ${name}:\n`);
    const next = compose.slice(start + 1).search(/\n  [a-z0-9-]+:\n/);
    return compose.slice(start, next < 0 ? undefined : start + 1 + next);
  };
  assert.match(service('api'), /DB_POOL_MIN: "\$\{DB_POOL_MIN:-4\}"/);
  assert.doesNotMatch(service('rewards-worker'), /DB_POOL_MIN/);
});
