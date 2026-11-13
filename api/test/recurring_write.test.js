'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createRecurringPostHandler, createRecurringPatchHandler } = require('../src/recurring_write');

const ID1 = '11111111-1111-4111-8111-111111111111';
const ID2 = '22222222-2222-4222-8222-222222222222';
const ms = (v) => new Date(v).getTime();
const BODY = { displayName: 'Synthetic Stream', typicalAmountInr: 199, cadenceDays: 30, nextExpectedOn: '2027-01-01', autopayStatus: 'active' };

// Stateful fake of recurring_series keyed on the emitted SQL.
function fixture() {
  const rows = [];
  const client = { query: async (rawSql, p) => {
    const sql = rawSql.replace(/\s+/g, ' ').trim();
    const pub = (r) => ({ id: r.id, merchant_key: r.merchant_key, display_name: r.display_name, dismissed_at: r.dismissed_at ? new Date(r.dismissed_at).toISOString() : null, is_active: r.is_active });
    if (/pg_advisory_xact_lock/.test(sql)) return { rows: [] };
    if (/^SELECT .* FROM recurring_series WHERE id = \$1 AND profile_id = \$2$/.test(sql)) return { rows: rows.filter((r) => r.id === p[0]).map(pub) };
    if (/^SELECT .* FROM recurring_series WHERE profile_id = \$1 AND merchant_key = \$2 AND/.test(sql)) {
      return { rows: rows.filter((r) => r.merchant_key === p[1] && ((r.dismissed_at && r.dismissed_at > ms(p[2])) || (r.client_edited_at && r.client_edited_at > ms(p[2])))).map(pub) };
    }
    if (/^INSERT INTO recurring_series/.test(sql)) {
      let r = rows.find((x) => x.merchant_key === p[1]);
      const clock = p[8] ? ms(p[8]) : null;
      if (r) { Object.assign(r, { display_name: p[2], is_active: true, dismissed_at: null, client_edited_at: clock ?? r.client_edited_at }); }
      else { r = { id: p[7] || `gen-${rows.length + 1}`, merchant_key: p[1], display_name: p[2], is_active: true, dismissed_at: null, client_edited_at: clock }; rows.push(r); }
      return { rows: [pub(r)] };
    }
    if (/^UPDATE recurring_series SET display_name/.test(sql)) {
      const clock = p[7] ? ms(p[7]) : null;
      const r = rows.find((x) => x.id === p[5] && !x.dismissed_at && (!clock || !x.client_edited_at || x.client_edited_at <= clock));
      if (!r) return { rows: [] };
      r.display_name = p[0]; if (clock) r.client_edited_at = clock;
      return { rows: [{ id: r.id }] };
    }
    if (/^SELECT 1 FROM recurring_series WHERE id/.test(sql)) {
      const c = ms(p[2]);
      return { rows: rows.some((x) => x.id === p[0] && ((x.dismissed_at && x.dismissed_at > c) || (x.client_edited_at && x.client_edited_at > c))) ? [{ one: 1 }] : [] };
    }
    throw new Error(`unexpected sql ${sql}`);
  } };
  const withUserClient = async (_u, fn) => fn(client);
  return { rows, post: createRecurringPostHandler({ withUserClient }), patch: createRecurringPatchHandler({ withUserClient }) };
}
function res() { return { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } }; }
const post = async (f, body) => { const r = res(); await f.post({ userId: 'u', body }, r); return r; };
const patch = async (f, id, body) => { const r = res(); await f.patch({ userId: 'u', params: { id }, body }, r); return r; };

test('no new fields: 201 {id} only (byte-identical shape)', async () => {
  const f = fixture();
  const r = await post(f, BODY);
  assert.equal(r.code, 201); assert.deepEqual(Object.keys(r.body), ['id']);
});

test('id + clientEditedAt: 201 with series; same id replays 200 replayed:true', async () => {
  const f = fixture();
  const a = await post(f, { ...BODY, id: ID1, clientEditedAt: '2026-11-01T10:00:00Z' });
  assert.equal(a.code, 201); assert.equal(a.body.id, ID1); assert.equal(a.body.series.id, ID1);
  const b = await post(f, { ...BODY, id: ID1, clientEditedAt: '2026-11-01T10:00:00Z' });
  assert.equal(b.code, 200); assert.equal(b.body.replayed, true); assert.equal(f.rows.length, 1);
});

test('a series dismissed after clientEditedAt is not resurrected', async () => {
  const f = fixture();
  await post(f, { ...BODY, id: ID1, clientEditedAt: '2026-11-01T10:00:00Z' });
  f.rows[0].dismissed_at = ms('2026-11-05T10:00:00Z'); f.rows[0].is_active = false;
  const r = await post(f, { ...BODY, id: ID2, clientEditedAt: '2026-11-02T10:00:00Z' });
  assert.equal(r.code, 200); assert.equal(r.body.superseded, true);
  assert.equal(f.rows[0].dismissed_at !== null, true);
  // A genuinely later re-add does resurrect, as before.
  const again = await post(f, { ...BODY, id: ID2, clientEditedAt: '2026-11-09T10:00:00Z' });
  assert.equal(again.code, 201); assert.equal(f.rows[0].dismissed_at, null);
});

test('old client (no fields) still resurrects a dismissed series as before', async () => {
  const f = fixture();
  await post(f, BODY);
  f.rows[0].dismissed_at = ms('2026-11-05T10:00:00Z');
  assert.equal((await post(f, BODY)).code, 201);
  assert.equal(f.rows[0].dismissed_at, null);
});

test('POST validation: bad id / clock / body are 400', async () => {
  const f = fixture();
  assert.equal((await post(f, { ...BODY, id: 'v2:abc' })).code, 400);
  assert.equal((await post(f, { ...BODY, clientEditedAt: 'nope' })).code, 400);
  assert.deepEqual((await post(f, { ...BODY, cadenceDays: 7 })).body, { error: 'invalid_subscription' });
});

test('PATCH rejects non-uuid ids (v2:abc, projection:x) with 400 and never queries', async () => {
  const f = fixture();
  for (const bad of ['v2:abc', 'projection:x']) {
    const r = await patch(f, bad, BODY);
    assert.equal(r.code, 400); assert.deepEqual(r.body, { error: 'invalid_id' });
  }
});

test('PATCH: older clientEditedAt cannot clobber a newer edit; newer wins', async () => {
  const f = fixture();
  await post(f, { ...BODY, id: ID1, clientEditedAt: '2026-11-02T10:00:00Z' });
  const stale = await patch(f, ID1, { ...BODY, displayName: 'Old Name', clientEditedAt: '2026-11-01T10:00:00Z' });
  assert.equal(stale.code, 200); assert.deepEqual(stale.body, { superseded: true });
  assert.equal(f.rows[0].display_name, 'Synthetic Stream');
  const fresh = await patch(f, ID1, { ...BODY, displayName: 'New Name', clientEditedAt: '2026-11-03T10:00:00Z' });
  assert.deepEqual(fresh.body, { ok: true }); assert.equal(f.rows[0].display_name, 'New Name');
});

test('PATCH without clientEditedAt keeps {ok:true} / 404 (dismissed or unknown)', async () => {
  const f = fixture();
  await post(f, { ...BODY, id: ID1 });
  assert.deepEqual((await patch(f, ID1, BODY)).body, { ok: true });
  f.rows[0].dismissed_at = ms('2026-11-05T10:00:00Z');
  assert.equal((await patch(f, ID1, BODY)).code, 404);
  assert.equal((await patch(f, ID2, BODY)).code, 404);
});

test('PATCH: edit older than a dismissal is superseded (200), newer than it still 404', async () => {
  const f = fixture();
  await post(f, { ...BODY, id: ID1 });
  f.rows[0].dismissed_at = ms('2026-11-05T10:00:00Z');
  assert.deepEqual((await patch(f, ID1, { ...BODY, clientEditedAt: '2026-11-01T10:00:00Z' })).body, { superseded: true });
  assert.equal((await patch(f, ID1, { ...BODY, clientEditedAt: '2026-11-09T10:00:00Z' })).code, 404);
});
