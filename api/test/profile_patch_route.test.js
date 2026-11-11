'use strict';
// PATCH /profile lives in index.js, which starts a server on require. So the real route
// source is sliced out of index.js and run against a fake app: the code under test is
// the shipped code, not a copy.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');
const { safeErrorCode } = require('../src/safeErrorCode');

const src = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8').replace(/\r\n/g, '\n');
const start = src.indexOf("app.patch('/profile'");
const end = src.indexOf('\n});\n', start) + 4;
assert.ok(start > 0 && end > start, 'PATCH /profile route not found');

async function patch(body, { found = true, raw, dbError } = {}) {
  const queries = [];
  let saved = null;
  const app = express();
  app.use(express.json());
  const requireAuth = (req, _res, next) => { req.userId = 'user-from-session'; next(); };
  const withUserClient = async (userId, fn) => fn({
    async query(sql, params) {
      queries.push({ userId, sql, params });
      // The write goes through a definer function (app_user has no UPDATE on profiles).
      if (/set_current_user_display_name/.test(sql)) {
        if (dbError) throw Object.assign(new Error('db'), { code: dbError });
        saved = params[0];
        return { rows: [{}] };
      }
      return { rows: found ? [{ id: params[0], display_name: saved }] : [] };
    },
  });
  new Function('app', 'requireAuth', 'withUserClient', 'safeErrorCode', 'console', src.slice(start, end))(app, requireAuth, withUserClient, safeErrorCode, { error() {} });
  const server = app.listen(0);
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/profile`, {
      method: 'PATCH', headers: { 'content-type': 'application/json' }, body: raw ?? JSON.stringify(body),
    });
    return { res, json: await res.json(), queries };
  } finally { server.close(); }
}

test('valid name is saved with whitespace collapsed, for the session user only', async () => {
  const { res, json, queries } = await patch({ display_name: '  Asha \t  K   Rao  ' });
  assert.equal(res.status, 200);
  assert.equal(json.profile.display_name, 'Asha K Rao');
  assert.equal(queries.length, 2);
  assert.ok(queries.every((q) => q.userId === 'user-from-session'));
  assert.match(queries[0].sql, /promotions\.set_current_user_display_name\(\$1::text\)/);
  assert.deepEqual(queries[0].params, ['Asha K Rao'], 'the function is given only the name; it finds the user itself');
  assert.deepEqual(queries[1].params, ['user-from-session']);
  assert.doesNotMatch(queries[0].sql + queries[1].sql, /UPDATE profiles/i, 'no direct UPDATE: app_user is not allowed one');
});

test('invalid names and bodies are 400 and never reach the database', async () => {
  const bad = [
    { display_name: '' }, { display_name: '   ' }, { display_name: 'a'.repeat(61) },
    { display_name: '<b>x</b>' }, { display_name: 'a>b' }, { display_name: 'bad\u0000name' },
    { display_name: 'bad\u007fname' }, { display_name: 'bad\u001bname' },
    { display_name: 'Asha', id: 'other-user' }, { display_name: 'Asha', extra: 1 },
    { display_name: 5 }, {}, { id: 'other' },
  ];
  for (const body of bad) {
    const { res, json, queries } = await patch(body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.deepEqual(json, { error: 'display_name_invalid' });
    assert.equal(queries.length, 0);
  }
  assert.equal((await patch(null, { raw: '[]' })).res.status, 400);
});

test('60 characters is the accepted maximum', async () => {
  assert.equal((await patch({ display_name: 'a'.repeat(60) })).res.status, 200);
});

test('404 when there is no profile row', async () => {
  const { res, json } = await patch({ display_name: 'Asha' }, { found: false });
  assert.equal(res.status, 404);
  assert.deepEqual(json, { error: 'profile_not_found' });
});

test('an id in the body is rejected, so the update can only target the session user', async () => {
  const { res, queries } = await patch({ display_name: 'Asha', id: 'victim', user_id: 'victim' });
  assert.equal(res.status, 400);
  assert.equal(queries.length, 0);
});

test('database refusals map to plain statuses; anything else is a 500 that leaks nothing', async () => {
  const invalid = await patch({ display_name: 'Asha' }, { dbError: '22023' });
  assert.equal(invalid.res.status, 400);
  assert.deepEqual(invalid.json, { error: 'display_name_invalid' });
  const missing = await patch({ display_name: 'Asha' }, { dbError: 'P0002' });
  assert.equal(missing.res.status, 404);
  assert.deepEqual(missing.json, { error: 'profile_not_found' });
  const other = await patch({ display_name: 'Asha' }, { dbError: '42501' });
  assert.equal(other.res.status, 500);
  assert.deepEqual(other.json, { error: 'internal_error' });
});
