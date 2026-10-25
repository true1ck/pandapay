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
const {
  createPortableBackupExportHandler,
  registerPortableBackupRoutes,
} = require('../src/portable_backup/routes');

class ResponseStub extends EventEmitter {
  constructor() {
    super();
    this.chunks = [];
    this.headersSent = false;
    this.destroyed = false;
    this.statusCode = 200;
    this.headers = {};
  }

  setHeader(name, value) {
    this.headers[name] = value;
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
    assert.equal(query.values.length, section.cursor ? 2 : 3);
    assert.match(query.text, /profile_id|p\.id/);
  }
  const transactionSplit = PORTABLE_SECTIONS.find((section) => section.name === 'transaction_splits');
  assert.match(sqlForSection(transactionSplit, 17, null).text, /owner_txn\.profile_id = \$1/);
});

test('settings pagination advances on profile_id and cursor parameters match SQL placeholders', async () => {
  const profileId = '11111111-1111-4111-8111-111111111111';
  const settingsQueries = [];
  const client = {
    async query(query) {
      if (typeof query === 'object' && query.text.includes('txid_current')) {
        return { rows: [{ snapshot_revision: '123', snapshot_at: '2026-10-23T00:00:00.000Z', account_id: profileId }] };
      }
      if (typeof query === 'object' && query.text.includes('FROM public.user_settings')) {
        settingsQueries.push(query);
        return settingsQueries.length === 1
          ? { rows: [{ record: { profile_id: profileId, settings: {} } }] }
          : { rows: [] };
      }
      return { rows: [] };
    },
  };
  await exportSnapshot({ client, res: new ResponseStub(), profileId, batchSize: 1 });
  assert.deepEqual(settingsQueries[0].values, [profileId, 1]);
  assert.deepEqual(settingsQueries[1].values, [profileId, 1, profileId]);
  assert.match(settingsQueries[1].text, /t\.profile_id > \$3/);
});

test('cursor pages bind and advance the declared cursor column', async () => {
  const settings = PORTABLE_SECTIONS.find((section) => section.name === 'settings');
  const first = sqlForSection(settings, 1, null);
  const next = sqlForSection(settings, 1, '11111111-1111-4111-8111-111111111111');
  assert.equal(first.values.length, 2);
  assert.match(next.text, /t\.profile_id > \$3/);
  assert.equal(next.values[2], '11111111-1111-4111-8111-111111111111');
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

test('pre-stream failures use JSON content type and never reflect database error text', async () => {
  let handler;
  const app = { get(_path, _middleware, mountedHandler) { handler = mountedHandler; } };
  registerPortableBackupRoutes(app, {
    requireAuth: (_req, _res, next) => next(),
    pool: { async connect() { throw new Error('sensitive SQL and contact text'); } },
  });
  const res = new ResponseStub();
  await handler({ userId: '11111111-1111-4111-8111-111111111111' }, res);
  assert.equal(res.headers['Content-Type'], 'application/json; charset=utf-8');
  assert.deepEqual(res.body, { error: 'export_failed' });
});

test('only one export runs at a time and the admission slot releases on completion', async () => {
  let releaseFirstConnection;
  let connectCount = 0;
  const pool = {
    connect() {
      connectCount += 1;
      if (connectCount === 1) return new Promise((resolve) => { releaseFirstConnection = resolve; });
      return Promise.resolve(emptyClient());
    },
  };
  const handler = createPortableBackupExportHandler({ pool });
  const firstResponse = new ResponseStub();
  const first = handler({ userId: '11111111-1111-4111-8111-111111111111' }, firstResponse);
  const busyResponse = new ResponseStub();
  await handler({ userId: '22222222-2222-4222-8222-222222222222' }, busyResponse);
  assert.equal(busyResponse.statusCode, 503);
  assert.deepEqual(busyResponse.body, { error: 'export_busy' });
  assert.equal(connectCount, 1, 'busy request must be refused before pool.connect');

  releaseFirstConnection(emptyClient());
  await first;
  const nextResponse = new ResponseStub();
  await handler({ userId: '22222222-2222-4222-8222-222222222222' }, nextResponse);
  assert.equal(nextResponse.ended, true, 'admission slot must be released after completion');
  assert.equal(connectCount, 2);
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

test('stalled response backpressure times out and fails the export', async () => {
  const client = emptyClient();
  const res = new ResponseStub();
  res.write = () => false;
  await assert.rejects(exportSnapshot({
    client,
    res,
    profileId: '11111111-1111-4111-8111-111111111111',
    backpressureTimeoutMs: 5,
  }), (error) => error.code === 'export_backpressure_timeout');
  assert.equal(res.listenerCount('drain'), 0);
  assert.equal(res.listenerCount('close'), 0);
});

test('overall export deadline is checked between snapshot queries', async () => {
  const profileId = '11111111-1111-4111-8111-111111111111';
  const client = emptyClient();
  const times = [0, 0, 11];
  await assert.rejects(exportSnapshot({
    client,
    res: new ResponseStub(),
    profileId,
    maxDurationMs: 10,
    now: () => times.shift() ?? 11,
  }), (error) => error.code === 'export_timeout');
  assert.equal(client.calls.length, 1, 'expired export must not begin section queries');
});

test('record and byte caps abort without writing a complete footer', async () => {
  const profileId = '11111111-1111-4111-8111-111111111111';
  const recordsClient = {
    async query(query) {
      if (typeof query === 'object' && query.text.includes('txid_current')) {
        return { rows: [{ snapshot_revision: '123', snapshot_at: '2026-10-23T00:00:00.000Z', account_id: profileId }] };
      }
      if (typeof query === 'object' && query.text.includes('FROM public.profiles')) {
        return { rows: [
          { record: { id: profileId, note: 'first' } },
          { record: { id: '33333333-3333-4333-8333-333333333333', note: 'second' } },
        ] };
      }
      return { rows: [] };
    },
  };

  const recordResponse = new ResponseStub();
  await assert.rejects(exportSnapshot({
    client: recordsClient,
    res: recordResponse,
    profileId,
    batchSize: 2,
    maxRecords: 1,
  }), (error) => error.code === 'export_limit_exceeded');
  assert.equal(recordResponse.chunks.some((chunk) => chunk.includes('"complete":true')), false);

  const byteClient = {
    async query(query) {
      if (typeof query === 'object' && query.text.includes('txid_current')) {
        return { rows: [{ snapshot_revision: '123', snapshot_at: '2026-10-23T00:00:00.000Z', account_id: profileId }] };
      }
      if (typeof query === 'object' && query.text.includes('FROM public.profiles')) {
        return { rows: [
          { record: { id: profileId, note: 'x'.repeat(600) } },
          { record: { id: '33333333-3333-4333-8333-333333333333', note: 'y'.repeat(600) } },
        ] };
      }
      return { rows: [] };
    },
  };
  const byteResponse = new ResponseStub();
  // The header grows when master adds portable sections. Measure its actual
  // serialized size so this regression tests a partially streamed record,
  // rather than accidentally exhausting the limit on the header itself.
  const sampleResponse = new ResponseStub();
  await exportSnapshot({ client: emptyClient(), res: sampleResponse, profileId });
  const firstRecordLine = `${canonicalJson({ type: 'record', section: 'profile', record: { id: profileId, note: 'x'.repeat(600) } })}\n`;
  const byteLimit = Buffer.byteLength(sampleResponse.chunks[0]) + Buffer.byteLength(firstRecordLine);
  await assert.rejects(exportSnapshot({
    client: byteClient,
    res: byteResponse,
    profileId,
    batchSize: 2,
    maxOutputBytes: byteLimit,
  }), (error) => error.code === 'export_limit_exceeded');
  assert.ok(byteResponse.chunks.length >= 2, 'first record should be streamed before the cap is reached');
  assert.ok(Buffer.byteLength(byteResponse.chunks.join('')) <= byteLimit);
  assert.equal(byteResponse.chunks.some((chunk) => chunk.includes('"complete":true')), false);
  assert.equal(byteResponse.ended, undefined);
});

test('account lifecycle export fence precedes repeatable-read snapshot and is released after rollback',async()=>{
 const client=emptyClient(),events=[];const original=client.query.bind(client);
 client.query=async(...args)=>{events.push(args[0]);return original(...args);};
 const pool={connect:async()=>client,acquireAccountSnapshotFence:async()=>{events.push('acquire');return async()=>{events.push('unlock');};},accountAccessFence:async()=>events.push('account-check')};
 const handler=createPortableBackupExportHandler({pool}),res=new ResponseStub();await handler({userId:'11111111-1111-4111-8111-111111111111'},res);
 assert.ok(events.indexOf('acquire')<events.indexOf('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'));
 assert.ok(events.indexOf('ROLLBACK')<events.indexOf('unlock'));assert.ok(client.released);
});
test('uncertain account export lock destroys pooled session and emits no archive',async()=>{
 const client=emptyClient();let destroyed;
 client.release=error=>{destroyed=error;};
 const handler=createPortableBackupExportHandler({pool:{connect:async()=>client,acquireAccountSnapshotFence:async()=>{throw Error('uncertain');}}}),res=new ResponseStub();
 await handler({userId:'11111111-1111-4111-8111-111111111111'},res);assert.ok(destroyed);assert.equal(res.statusCode,503);assert.equal(res.chunks.length,0);
});
