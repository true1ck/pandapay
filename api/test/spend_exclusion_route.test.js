'use strict';
// PUT /transactions/:id/spend-exclusion lives in index.js, which starts a server on
// require. So the real route source is sliced out of index.js and run against a fake
// app: the code under test is the shipped code, not a copy. No database is needed.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { safeErrorCode } = require('../src/safeErrorCode');

const src = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8').replace(/\r\n/g, '\n');
const start = src.indexOf("app.put('/transactions/:id/spend-exclusion'");
const end = src.indexOf('\n});\n', start) + 4;
assert.ok(start > 0 && end > start, 'PUT /transactions/:id/spend-exclusion route not found');
const uuidStart = src.indexOf('const UUID_RE =');
assert.ok(uuidStart > 0, 'UUID_RE not found');
const uuidDecl = src.slice(uuidStart, src.indexOf('\n', uuidStart));

const ID = '3f6c1f0a-8b1e-4c52-9a53-0d6f7a1b2c3d';
const USER = '11111111-2222-4333-8444-555555555555';

function load({ entryKind = 'spend', found = true, dbError = false } = {}) {
  const queries = [];
  let handler = null;
  const app = { put: (route, _auth, fn) => { handler = fn; } };
  const withUserClient = async (_userId, fn) => {
    if (dbError) throw Object.assign(new Error('boom'), { code: '22P02' });
    return fn({
      query: async (sql, params) => {
        queries.push({ sql, params });
        if (/^\s*SELECT entry_kind/.test(sql)) {
          return { rows: found ? [{ entry_kind: entryKind }] : [] };
        }
        return { rows: [{ id: params[1], exclude_from_spend: params[0] }] };
      },
    });
  };
  new Function(
    'app', 'requireAuth', 'withUserClient', 'safeErrorCode',
    `${uuidDecl}\n${src.slice(start, end)}`,
  )(app, () => {}, withUserClient, safeErrorCode);
  return async (params, body) => {
    const res = {
      code: 200, body: null,
      status(c) { this.code = c; return this; },
      json(b) { this.body = b; return this; },
    };
    await handler({ userId: USER, params, body }, res);
    return { res, queries };
  };
}

test('a malformed id is a 400, not a 500, and never reaches the database', async () => {
  const call = load();
  for (const id of ['not-a-uuid', '1', "' OR 1=1 --", '', '3f6c1f0a-8b1e-4c52-9a53-0d6f7a1b2c3', undefined]) {
    const { res, queries } = await call({ id }, { excluded: true });
    assert.equal(res.code, 400, String(id));
    assert.match(res.body.error, /valid UUID/);
    assert.equal(queries.length, 0, String(id));
  }
});

test('excluded must still be a boolean', async () => {
  const call = load();
  for (const excluded of ['true', 1, null, undefined]) {
    const { res, queries } = await call({ id: ID }, { excluded });
    assert.equal(res.code, 400);
    assert.match(res.body.error, /excluded must be true or false/);
    assert.equal(queries.length, 0);
  }
});

test('a valid id sets the value, never toggles', async () => {
  const call = load();
  for (const excluded of [true, false]) {
    const { res, queries } = await call({ id: ID }, { excluded });
    assert.equal(res.code, 200);
    assert.deepEqual(res.body.transaction, { id: ID, exclude_from_spend: excluded });
    assert.equal(queries.at(-1).params[0], excluded);
  }
});

test('unknown transaction is 404 and a non-spend row is 409', async () => {
  assert.equal((await load({ found: false })({ id: ID }, { excluded: true })).res.code, 404);
  const { res } = await load({ entryKind: 'investment_return' })({ id: ID }, { excluded: true });
  assert.equal(res.code, 409);
});

test('a database failure is still a generic 500', async () => {
  const { res } = await load({ dbError: true })({ id: ID }, { excluded: true });
  assert.equal(res.code, 500);
  assert.deepEqual(res.body, { error: 'internal_error' });
});
