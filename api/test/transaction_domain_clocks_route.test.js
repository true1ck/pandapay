'use strict';
// Note, spend-exclusion, ignore and restore each carry their own edit time
// (note_edited_at, exclusion_edited_at, state_edited_at) and are compared only
// with themselves, so an edit-form change never makes a note look stale and an
// old delete never undoes a newer restore. index.js starts a server on require,
// so the real route source is sliced out of it and run against an in-memory
// fake of the table: the code under test is the shipped code. No database.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { safeErrorCode } = require('../src/safeErrorCode');
const editTime = require('../src/edit_time');

const src = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8').replace(/\r\n/g, '\n');
const slice = (marker) => {
  const start = src.indexOf(marker);
  assert.ok(start > 0, `route not found: ${marker}`);
  return src.slice(start, src.indexOf('\n});\n', start) + 4);
};
const declLine = (marker) => {
  const i = src.indexOf(marker);
  assert.ok(i > 0, `declaration not found: ${marker}`);
  return src.slice(i, src.indexOf('\n', i));
};
const uuidDecl = declLine('const UUID_RE =');
const ignoreReasonsDecl = src.slice(src.indexOf('const IGNORE_REASONS'), src.indexOf(';', src.indexOf('const IGNORE_REASONS')) + 1);

const ID = '3f6c1f0a-8b1e-4c52-9a53-0d6f7a1b2c3d';
const USER = '11111111-2222-4333-8444-555555555555';
const at = (s) => new Date(s);

// One transaction row; the fake applies the SQL the routes send, the way the
// database would, for the columns these routes touch.
function makeRow(over = {}) {
  return {
    id: ID, status: 'active', note: null, entry_kind: 'spend', exclude_from_spend: false,
    instrument: 'upi_bank', user_card_id: null, state_applied: false,
    edited_at: null, note_edited_at: null, exclusion_edited_at: null, state_edited_at: null, ...over,
  };
}

function load(method, marker, row) {
  const calls = { updates: 0, reversed: 0, applied: 0 };
  let handler = null;
  const app = new Proxy({}, { get: (_t, name) => (name === method ? (_route, _auth, fn) => { handler = fn; } : () => {}) });
  const bump = (cur, param) => {
    const base = cur ? new Date(cur) : new Date(0);
    const next = param || new Date();
    return next > base ? next : base;
  };
  const client = {
    query: async (sql, params = []) => {
      if (/pg_advisory_xact_lock/.test(sql)) return { rows: [] };
      if (!row) return { rows: [] };
      if (/^\s*UPDATE transactions SET note = \$1/.test(sql)) {
        const stale = params[3] && row.note_edited_at && params[3] < row.note_edited_at;
        if (stale) return { rows: [] };
        calls.updates += 1;
        row.note = params[0];
        row.note_edited_at = bump(row.note_edited_at, params[3]);
        return { rows: [{ id: row.id, note: row.note }] };
      }
      if (/^\s*SELECT id, note FROM transactions/.test(sql)) return { rows: [{ id: row.id, note: row.note }] };
      if (/^\s*SELECT entry_kind/.test(sql)) return { rows: [{ ...row }] };
      if (/UPDATE transactions SET exclude_from_spend/.test(sql)) {
        calls.updates += 1;
        row.exclude_from_spend = params[0];
        row.exclusion_edited_at = bump(row.exclusion_edited_at, params[3]);
        return { rows: [{ id: row.id, exclude_from_spend: row.exclude_from_spend }] };
      }
      if (/FROM transactions/.test(sql) && /FOR UPDATE/.test(sql)) {
        const wantsInactive = /status = 'deleted' OR status = 'ignored'/.test(sql);
        if (wantsInactive && row.status === 'active') return { rows: [] };
        return { rows: [{ ...row }] };
      }
      if (/UPDATE transactions SET status = \$1/.test(sql)) {
        calls.updates += 1;
        row.status = params[0];
        row.note = params[1];
        row.state_edited_at = bump(row.state_edited_at, params[3]);
        return { rows: [{ id: row.id, status: row.status, note: row.note }] };
      }
      if (/SET status = 'active'/.test(sql)) {
        calls.updates += 1;
        row.status = 'active';
        row.note = params[0];
        row.state_edited_at = bump(row.state_edited_at, params[3]);
        return { rows: [{ id: row.id, status: row.status, note: row.note }] };
      }
      throw new Error(`unexpected SQL: ${sql.slice(0, 80)}`);
    },
  };
  const withUserClient = async (_userId, fn) => fn(client);
  new Function(
    'app', 'requireAuth', 'withUserClient', 'safeErrorCode', 'parseEditTime', 'isStaleEdit', 'stampClockSql', 'notStaleSql',
    'loadUserCardForState', 'reverseTransactionState', 'applyTransactionState',
    `${uuidDecl}\n${ignoreReasonsDecl}\n${slice(marker)}`,
  )(
    app, () => {}, withUserClient, safeErrorCode, editTime.parseEditTime, editTime.isStaleEdit, editTime.stampClockSql, editTime.notStaleSql,
    async () => ({ id: 'card' }),
    async () => { calls.reversed += 1; },
    async () => { calls.applied += 1; },
  );
  return async (body) => {
    const res = {
      code: 200, body: null,
      status(c) { this.code = c; return this; },
      json(b) { this.body = b; return this; },
    };
    await handler({ userId: USER, params: { id: ID }, body }, res);
    return { res, row, calls };
  };
}

const note = (row) => load('patch', "app.patch('/transactions/:id/note'", row);
const exclusion = (row) => load('put', "app.put('/transactions/:id/spend-exclusion'", row);
const ignore = (row) => load('post', "app.post('/transactions/:id/ignore'", row);
const restore = (row) => load('post', "app.post('/transactions/:id/restore'", row);

// ---------------------------------------------------------------- note

test('note: a note with no time (an older app) always applies', async () => {
  const { res, row } = await note(makeRow({ note_edited_at: at('2026-11-20T10:00:00Z') }))({ note: 'old app' });
  assert.equal(res.code, 200);
  assert.equal(res.body.stale, undefined);
  assert.equal(row.note, 'old app');
});

test('note: a later note replaces an earlier one and moves only the note clock', async () => {
  const r = makeRow({ note: 'first', note_edited_at: at('2026-11-20T09:00:00Z') });
  const { res, row } = await note(r)({ note: 'second', editedAt: '2026-11-20T10:00:00Z' });
  assert.equal(res.body.stale, undefined);
  assert.equal(row.note, 'second');
  assert.equal(row.note_edited_at.toISOString(), '2026-11-20T10:00:00.000Z');
  assert.equal(row.exclusion_edited_at, null);
  assert.equal(row.state_edited_at, null);
});

test('note: an older note delivered late changes nothing and says so', async () => {
  const r = makeRow({ note: 'newer', note_edited_at: at('2026-11-20T10:00:00Z') });
  const { res, row } = await note(r)({ note: 'older', editedAt: '2026-11-20T09:00:00Z' });
  assert.equal(res.code, 200);
  assert.equal(res.body.stale, true);
  assert.equal(res.body.transaction.note, 'newer');
  assert.equal(row.note, 'newer');
  assert.equal(row.note_edited_at.toISOString(), '2026-11-20T10:00:00.000Z', 'the clock never moves backwards');
});

test('note: an edit-form change made later never makes a note look stale', async () => {
  // edited_at is the edit-form clock; the note has its own.
  const r = makeRow({ edited_at: at('2026-11-20T12:00:00Z') });
  const { res, row } = await note(r)({ note: 'queued earlier', editedAt: '2026-11-20T09:00:00Z' });
  assert.equal(res.body.stale, undefined);
  assert.equal(row.note, 'queued earlier');
  assert.equal(row.edited_at.toISOString(), '2026-11-20T12:00:00.000Z', 'the edit-form clock is untouched');
});

test('note: a time in the future is treated as now, and a bad time is a 400', async () => {
  const future = await note(makeRow())({ note: 'x', editedAt: '2099-01-01T00:00:00Z' });
  assert.equal(future.res.code, 200);
  assert.ok(future.row.note_edited_at.getTime() <= Date.now() + 1000, 'clamped to now');
  for (const editedAt of ['not a date', 12345, {}]) {
    const bad = await note(makeRow())({ note: 'x', editedAt });
    assert.equal(bad.res.code, 400, String(editedAt));
    assert.match(bad.res.body.error, /editedAt/);
    assert.equal(bad.calls.updates, 0);
  }
});

test('note: a missing transaction is a 404', async () => {
  const { res } = await note(null)({ note: 'x', editedAt: '2026-11-20T10:00:00Z' });
  assert.equal(res.code, 404);
});

// ---------------------------------------------------------------- spend exclusion

test('exclusion: a later choice wins, an older one is stale, no time always applies', async () => {
  const stored = () => makeRow({ exclude_from_spend: true, exclusion_edited_at: at('2026-11-20T10:00:00Z') });
  const older = await exclusion(stored())({ excluded: false, editedAt: '2026-11-20T09:00:00Z' });
  assert.equal(older.res.body.stale, true);
  assert.deepEqual(older.res.body.transaction, { id: ID, exclude_from_spend: true });
  assert.equal(older.row.exclude_from_spend, true);
  assert.equal(older.calls.updates, 0);

  const newer = await exclusion(stored())({ excluded: false, editedAt: '2026-11-20T11:00:00Z' });
  assert.equal(newer.res.body.stale, undefined);
  assert.equal(newer.row.exclude_from_spend, false);
  assert.equal(newer.row.exclusion_edited_at.toISOString(), '2026-11-20T11:00:00.000Z');

  const legacy = await exclusion(stored())({ excluded: false });
  assert.equal(legacy.row.exclude_from_spend, false);
});

test('exclusion: independent of the note and delete clocks', async () => {
  const r = makeRow({ note_edited_at: at('2026-11-20T12:00:00Z'), state_edited_at: at('2026-11-20T12:00:00Z') });
  const { res, row } = await exclusion(r)({ excluded: true, editedAt: '2026-11-20T09:00:00Z' });
  assert.equal(res.body.stale, undefined);
  assert.equal(row.exclude_from_spend, true);
});

test('exclusion: a bad time is a 400 before the database is read', async () => {
  const { res, calls } = await exclusion(makeRow())({ excluded: true, editedAt: 'nope' });
  assert.equal(res.code, 400);
  assert.equal(calls.updates, 0);
});

// ---------------------------------------------------------------- ignore / restore

test('ignore: an older delete after a later restore changes nothing and reverses no card state', async () => {
  const r = makeRow({ user_card_id: 'card', instrument: 'credit_card', state_applied: true, state_edited_at: at('2026-11-20T10:00:00Z') });
  const { res, row, calls } = await ignore(r)({ reason: 'refund', editedAt: '2026-11-20T09:00:00Z' });
  assert.equal(res.code, 200);
  assert.equal(res.body.stale, true);
  assert.equal(row.status, 'active');
  assert.equal(calls.reversed, 0);
  assert.equal(calls.updates, 0);
});

test('ignore: a later delete applies and moves only the state clock; no time always applies', async () => {
  const r = makeRow({ state_edited_at: at('2026-11-20T09:00:00Z'), note_edited_at: at('2026-11-20T12:00:00Z') });
  const fresh = await ignore(r)({ reason: 'refund', editedAt: '2026-11-20T10:00:00Z' });
  assert.equal(fresh.res.body.stale, undefined);
  assert.equal(fresh.row.status, 'ignored');
  assert.equal(fresh.row.state_edited_at.toISOString(), '2026-11-20T10:00:00.000Z');
  assert.equal(fresh.row.note_edited_at.toISOString(), '2026-11-20T12:00:00.000Z');

  const legacy = await ignore(makeRow({ state_edited_at: at('2026-11-20T10:00:00Z') }))({ reason: 'refund' });
  assert.equal(legacy.row.status, 'ignored');
});

test('ignore: a bad reason or bad time never reaches the database', async () => {
  const noReason = await ignore(makeRow())({ editedAt: '2026-11-20T10:00:00Z' });
  assert.equal(noReason.res.code, 400);
  const badTime = await ignore(makeRow())({ reason: 'refund', editedAt: 'nope' });
  assert.equal(badTime.res.code, 400);
  assert.match(badTime.res.body.error, /editedAt/);
  assert.equal(badTime.calls.updates, 0);
});

test('restore: an older restore after a later delete changes nothing and re-applies no card state', async () => {
  const r = makeRow({ status: 'ignored', user_card_id: 'card', instrument: 'credit_card', state_applied: false, state_edited_at: at('2026-11-20T10:00:00Z') });
  const { res, row, calls } = await restore(r)({ editedAt: '2026-11-20T09:00:00Z' });
  assert.equal(res.code, 200);
  assert.equal(res.body.stale, true);
  assert.equal(row.status, 'ignored');
  assert.equal(calls.applied, 0);
  assert.equal(calls.updates, 0);
});

test('restore: a later restore applies; no time always applies; a bad time is a 400', async () => {
  const fresh = await restore(makeRow({ status: 'ignored', state_edited_at: at('2026-11-20T09:00:00Z') }))({ editedAt: '2026-11-20T10:00:00Z' });
  assert.equal(fresh.res.body.stale, undefined);
  assert.equal(fresh.row.status, 'active');
  assert.equal(fresh.row.state_edited_at.toISOString(), '2026-11-20T10:00:00.000Z');

  const legacy = await restore(makeRow({ status: 'deleted', state_edited_at: at('2026-11-20T10:00:00Z') }))({});
  assert.equal(legacy.row.status, 'active');

  const bad = await restore(makeRow({ status: 'ignored' }))({ editedAt: 'nope' });
  assert.equal(bad.res.code, 400);
});

test('restore: nothing to restore is a 404', async () => {
  const { res } = await restore(makeRow({ status: 'active' }))({ editedAt: '2026-11-20T10:00:00Z' });
  assert.equal(res.code, 404);
});

// ---------------------------------------------------------------- helpers

test('edit-time helpers: parse, clamp, compare, and the SQL they build', () => {
  const now = Date.parse('2026-11-20T10:00:00Z');
  assert.deepEqual(editTime.parseEditTime(undefined, now), { time: null });
  assert.deepEqual(editTime.parseEditTime(null, now), { time: null });
  assert.equal(editTime.parseEditTime('2026-11-20T09:00:00Z', now).time.toISOString(), '2026-11-20T09:00:00.000Z');
  assert.equal(editTime.parseEditTime('2027-01-01T00:00:00Z', now).time.toISOString(), '2026-11-20T10:00:00.000Z');
  assert.ok(editTime.parseEditTime('garbage', now).error);
  assert.ok(editTime.parseEditTime(5, now).error);
  assert.equal(editTime.isStaleEdit(at('2026-11-20T09:00:00Z'), at('2026-11-20T10:00:00Z')), true);
  assert.equal(editTime.isStaleEdit(at('2026-11-20T10:00:00Z'), at('2026-11-20T10:00:00Z')), false);
  assert.equal(editTime.isStaleEdit(null, at('2026-11-20T10:00:00Z')), false);
  assert.equal(editTime.isStaleEdit(at('2026-11-20T09:00:00Z'), null), false);
  assert.match(editTime.stampClockSql('note_edited_at', '$4'), /GREATEST\(COALESCE\(note_edited_at, '-infinity'::timestamptz\), COALESCE\(\$4::timestamptz, now\(\)\)\)/);
  assert.match(editTime.notStaleSql('note_edited_at', '$4'), /\$4::timestamptz IS NULL OR note_edited_at IS NULL OR note_edited_at <= \$4::timestamptz/);
});
