'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const test = require('node:test');
const {
  PORTABLE_SECTIONS,
  canonicalJson,
  exportSnapshot,
  sqlForSection,
} = require('../src/portable_backup');
const { registerPortableBackupRoutes } = require('../src/portable_backup/routes');

class ResponseStub extends EventEmitter {
  constructor() {
    super();
    this.chunks = [];
    this.headersSent = false;
    this.destroyed = false;
    this.statusCode = 200;
  }

  write(chunk) {
    this.headersSent = true;
    this.chunks.push(String(chunk));
    return true;
  }

  end() {
    this.ended = true;
  }

  destroy() {
    this.destroyed = true;
  }

  status(code) {
    this.statusCode = code;
    return this;
  }

  json(body) {
    this.body = body;
    this.headersSent = true;
    return this;
  }
}

function emptyClient() {
  const calls = [];
  return {
    calls,
    async query(query, values) {
      const captured = values ? { text: query, values } : query;
      calls.push(captured);
      if (typeof query === 'object' && query.text.includes('txid_current')) {
        return { rows: [{ snapshot_revision: '123', snapshot_at: '2026-10-23T00:00:00.000Z', account_id: '11111111-1111-4111-8111-111111111111' }] };
      }
      return { rows: [] };
    },
    release() { this.released = true; },
  };
}

test('canonical JSON sorts keys, excludes device secrets and normalizes decimals', () => {
  const json = canonicalJson({
    z: 1,
    amount_inr: 12.5,
    nested: { push_token: 'secret', b: true, a: null },
    a: 'first',
  });
  assert.equal(json, '{"a":"first","amount_inr":"12.5","nested":{"a":null,"b":true},"z":1}');
});

test('each section query has an explicit owner filter and bounded batch', () => {
  for (const section of PORTABLE_SECTIONS) {
    const query = sqlForSection(section, 17, null);
    assert.match(query.text, /LIMIT \$2/);
    assert.equal(query.values[0], null);
    assert.match(query.text, /profile_id|p\.id/);
  }
  const transactionSplit = PORTABLE_SECTIONS.find((section) => section.name === 'transaction_splits');
  assert.match(sqlForSection(transactionSplit, 17, null).text, /owner_txn\.profile_id = \$1/);
});

test('empty snapshot emits one header, all sections, and a complete footer', async () => {
  const client = emptyClient();
  const res = new ResponseStub();
  const result = await exportSnapshot({
    client,
    res,
    profileId: '11111111-1111-4111-8111-111111111111',
    batchSize: 17,
    backupId: '22222222-2222-4222-8222-222222222222',
  });
  const lines = res.chunks.join('').trim().split('\n').map((line) => JSON.parse(line));
  assert.equal(lines[0].type, 'header');
  assert.equal(lines[0].sections.length, PORTABLE_SECTIONS.length);
  assert.equal(lines.at(-1).type, 'footer');
  assert.equal(lines.at(-1).complete, true);
  assert.equal(lines.at(-1).total_records, 0);
  assert.equal(Object.keys(result.sections).length, PORTABLE_SECTIONS.length);
  assert.ok(client.calls.length >= PORTABLE_SECTIONS.length + 1);
  assert.equal(res.ended, true);
});

test('route mount uses repeatable read, app user context, rollback cleanup, and auth middleware', async () => {
  let mounted;
  const app = {
    get(path, middleware, handler) {
      mounted = { path, middleware, handler };
    },
  };
  const client = emptyClient();
  const pool = { async connect() { return client; } };
  const requireAuth = (_req, _res, next) => next();
  registerPortableBackupRoutes(app, { requireAuth, pool, batchSize: 17 });
  assert.equal(mounted.path, '/portable-backups/export-v1');
  assert.equal(mounted.middleware, requireAuth);

  const res = new ResponseStub();
  await mounted.handler({ userId: '11111111-1111-4111-8111-111111111111' }, res);
  assert.equal(client.calls[0], 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  assert.match(client.calls[1].text, /set_config\('statement_timeout'/);
  assert.deepEqual(client.calls[2], {
    text: "SELECT set_config('app.user_id', $1, true)",
    values: ['11111111-1111-4111-8111-111111111111'],
  });
  assert.equal(client.calls.at(-1), 'ROLLBACK');
  assert.equal(client.released, true);
  assert.equal(res.destroyed, false);
});

test('disconnect aborts before the next batch and leaves no successful footer', async () => {
  const client = emptyClient();
  const res = new ResponseStub();
  const pending = exportSnapshot({
    client,
    res,
    profileId: '11111111-1111-4111-8111-111111111111',
    batchSize: 1,
  });
  // The metadata query is synchronous from the stub's perspective; closing
  // immediately exercises the cancellation guard before section iteration.
  res.emit('close');
  await assert.rejects(pending, (error) => error.code === 'export_cancelled');
  assert.equal(res.chunks.some((chunk) => chunk.includes('"complete":true')), false);
});
