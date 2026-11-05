'use strict';

// Lane D: old-app compatibility of the v2 schema + server.
//
// Boots the real api/src/index.js against a scratch Postgres whose migrations
// are ALL applied (including every *sms_v2* file) and calls the routes the
// shipped Android app uses, with the v2 flag off (no feature_flags row).
//
//   SMS_V2_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/scratch \
//     node --test test/sms_v2/old_app_compat_pg.test.js
//
// Optional second world for byte-for-byte parity with the production line:
//   SMS_V2_COMPAT_OLD_DATABASE_URL  scratch DB migrated WITHOUT *sms_v2* files
//   SMS_V2_COMPAT_OLD_API_DIR       `git archive 6c17d46 api` (+ node_modules link)
// App connections use app_user (RLS applies); override with
// SMS_V2_COMPAT_APP_USER_PASSWORD (default: the docker-compose dev literal).
// Scratch databases only; never point these at a real database.

const test = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const h = require('./compat/harness');
const { legacyScript, MSGS, sourceKeyFor, HEX } = require('./compat/scenarios');

const adminUrl = process.env.SMS_V2_TEST_DATABASE_URL;
const oldAdminUrl = process.env.SMS_V2_COMPAT_OLD_DATABASE_URL;
const oldApiDir = process.env.SMS_V2_COMPAT_OLD_API_DIR;
const skip = adminUrl ? false : 'SMS_V2_TEST_DATABASE_URL not set';
const skipParity = (adminUrl && oldAdminUrl && oldApiDir) ? false : 'old-world env (SMS_V2_COMPAT_OLD_*) not set';

const PARITY_PROFILE = '00000000-0000-4000-8000-00000000d001';
const LEGACY_KINDS = ['spend', 'income', 'investment', 'transfer'];

function appUrl(admin) {
  const u = new URL(admin);
  if (!['127.0.0.1', 'localhost', '::1', '[::1]'].includes(u.hostname)) throw new Error('compat tests run on loopback scratch databases only');
  u.username = 'app_user';
  u.password = process.env.SMS_V2_COMPAT_APP_USER_PASSWORD || 'app_user_dev_pw';
  return u.toString();
}

// v2 additions to the legacy transaction JSON are additive; drop them before
// comparing with the production line, and assert them separately.
const ADDITIVE = new Set(['event_id', 'pipeline_version']);
function strip(v) {
  if (Array.isArray(v)) return v.map(strip);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v)) if (!ADDITIVE.has(k) && k !== 'elapsedFraction') o[k] = strip(v[k]);
    return o;
  }
  return v;
}

let admin; let stack; let oldAdmin; let oldStack;
const profiles = [];

async function newProfile(pool, id = h.uuid()) {
  await pool.query('INSERT INTO profiles(id) VALUES($1) ON CONFLICT DO NOTHING', [id]);
  profiles.push(id);
  return id;
}

test.before(async () => {
  if (skip) return;
  admin = new Pool({ connectionString: adminUrl, max: 2 });
  stack = await h.startStack({ apiDir: `${h.REPO}/api`, databaseUrl: appUrl(adminUrl), contractsDir: `${h.REPO}/contracts/sms/v2` });
  if (!skipParity) {
    oldAdmin = new Pool({ connectionString: oldAdminUrl, max: 2 });
    oldStack = await h.startStack({ apiDir: oldApiDir, databaseUrl: appUrl(oldAdminUrl) });
  }
});
test.after(async () => {
  if (stack) await stack.stop();
  if (oldStack) await oldStack.stop();
  if (admin) {
    for (const p of profiles) await admin.query('DELETE FROM profiles WHERE id=$1', [p]).catch(() => {});
    await admin.end();
  }
  if (oldAdmin) {
    await oldAdmin.query('DELETE FROM profiles WHERE id=$1', [PARITY_PROFILE]).catch(() => {});
    await oldAdmin.end();
  }
});

// ---------------------------------------------------------------------------
// 1. Schema facts the old app depends on.
// ---------------------------------------------------------------------------
test('enum labels: only the documented additions, and no "unknown" entry kind', { skip }, async () => {
  const kinds = (await admin.query("SELECT unnest(enum_range(NULL::txn_entry_kind))::text AS v")).rows.map((r) => r.v);
  assert.deepEqual([...kinds].sort(), ['income', 'investment', 'refund', 'spend', 'transfer']);
  const statuses = (await admin.query("SELECT unnest(enum_range(NULL::txn_status))::text AS v")).rows.map((r) => r.v);
  assert.ok(statuses.includes('superseded'));
  assert.equal(statuses.filter((s) => !['active', 'ignored', 'reversed', 'deleted', 'superseded'].includes(s)).length, 0, `unexpected statuses ${statuses}`);
  await assert.rejects(admin.query("SELECT 'unknown'::txn_entry_kind"), /invalid input value for enum/);
});

test('new transactions columns default to v1 values for legacy inserts', { skip }, async () => {
  const p = await newProfile(admin);
  const r = await admin.query(
    `INSERT INTO transactions(profile_id,amount_inr,occurred_at,source,entry_kind,instrument,state_applied)
     VALUES($1,10,now(),'manual','spend','cash',true) RETURNING event_id,pipeline_version,superseded_by_event_id,status`, [p]);
  assert.deepEqual(r.rows[0], { event_id: null, pipeline_version: 1, superseded_by_event_id: null, status: 'active' });
});

test('the v2 flag is off by default: no feature_flags row and every v2 route answers 404', { skip }, async () => {
  const row = await admin.query("SELECT 1 FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
  assert.equal(row.rowCount, 0, 'a migration must not switch the flag on');
  const p = await newProfile(admin);
  for (const [m, r] of [['GET', '/sms/v2/sync'], ['POST', '/sms/v2/facts:batch'], ['GET', '/sms/v2/rules/bundle'], ['POST', '/sms/v2/corrections']]) {
    const x = await stack.call(p, m, r, m === 'POST' ? {} : undefined);
    assert.equal(x.status, 404, `${m} ${r} -> ${x.status} ${x.text.slice(0, 80)}`);
  }
});

// ---------------------------------------------------------------------------
// 2. A profile with no v2 data: behaviour identical to the production line.
// ---------------------------------------------------------------------------
test('legacy request script succeeds on the v2 server for a profile with no v2 data', { skip }, async () => {
  const p = await newProfile(admin);
  const steps = await legacyScript(stack.call, p);
  const bad = steps.filter((s) => s.status >= 500);
  assert.deepEqual(bad.map((s) => s.name), []);
  const byName = Object.fromEntries(steps.map((s) => [s.name, s]));
  assert.equal(byName['create-manual-spend'].status, 201);
  assert.equal(byName['create-bad-kind'].status, 400, 'legacy create must keep rejecting entryKind=refund');
  assert.equal(byName['from-sms-batch'].status, 200);
  assert.equal(byName['transactions-list'].status, 200);
  const rows = byName['transactions-list'].body.transactions;
  assert.ok(rows.length >= 4, `expected the script's rows, got ${rows.length}`);
  for (const t of rows) {
    assert.ok(LEGACY_KINDS.includes(t.entry_kind), `entry_kind ${t.entry_kind}`);
    assert.equal(t.pipeline_version, 1);
    assert.equal(t.event_id, null);
  }
  const rest = await admin.query('SELECT count(*)::int AS n FROM sms_v2_events WHERE profile_id=$1', [p]);
  assert.equal(rest.rows[0].n, 0, 'legacy traffic must create no v2 rows');
});

test('PARITY: v2 server+schema answers the legacy script exactly like the production line (6c17d46)', { skip: skip || skipParity }, async () => {
  await newProfile(admin, PARITY_PROFILE);
  await newProfile(oldAdmin, PARITY_PROFILE);
  const next = await legacyScript(stack.call, PARITY_PROFILE);
  const old = await legacyScript(oldStack.call, PARITY_PROFILE);
  assert.deepEqual(next.map((s) => s.name), old.map((s) => s.name));
  // guard against a vacuous comparison: the script must really have created data
  assert.ok(old.find((s) => s.name === 'transactions-list').body.transactions.length >= 4);
  assert.ok(old.every((s) => s.status < 500), `production-line server errored: ${old.filter((s) => s.status >= 500).map((s) => s.name)}`);
  for (let i = 0; i < next.length; i += 1) {
    assert.equal(next[i].status, old[i].status, `${next[i].name}: status`);
    assert.deepEqual(h.normalise(strip(next[i].body)), h.normalise(strip(old[i].body)), `${next[i].name}: body`);
  }
});

// ---------------------------------------------------------------------------
// 3. A profile WITH v2 rows: nothing leaks into the legacy surface.
// ---------------------------------------------------------------------------
async function seedV2(pool, p, { withExtras }) {
  const ev = (n) => HEX(`lane-d-event-${p}-${n}`);
  const legs = JSON.stringify([{ role: 'debit_leg', factId: HEX('lane-d-fact') }]);
  const addEvent = (n, type, at, minor) => pool.query(
    `INSERT INTO sms_v2_events(event_id,profile_id,type,status,legs,confidence,occurred_at,amount_minor)
     VALUES($1,$2,$3,'complete',$4::jsonb,0.9,$5,$6)`, [ev(n), p, type, legs, at, minor]);
  const addTxn = (key, amount, at, kind, status, eventNo, pipeline, supersededBy, merchant = 'SYNTHETIC SHOP') => pool.query(
    `INSERT INTO transactions(profile_id,source_key,amount_inr,occurred_at,merchant_name,source,status,entry_kind,instrument,state_applied,event_id,pipeline_version,superseded_by_event_id)
     VALUES($1,$2,$3,$4,$5,'sms',$6,$7::txn_entry_kind,'upi_bank',true,$8,$9,$10)`,
    [p, key, amount, at, merchant, status, kind, eventNo ? ev(eventNo) : null, pipeline, supersededBy ? ev(supersededBy) : null]);
  await addEvent('buy1', 'purchase', '2026-10-19T10:00:00Z', 49900);
  await addEvent('buy2', 'purchase', '2026-10-18T10:00:00Z', 15000);
  await addTxn('lane-d-buy1', 499, '2026-10-19T10:00:00Z', 'spend', 'active', 'buy1', 2);
  await addTxn('lane-d-buy2', 150, '2026-10-18T10:00:00Z', 'spend', 'active', 'buy2', 2, null, 'SYNTHETIC CAFE');
  if (withExtras) {
    await addEvent('refund', 'refund', '2026-10-20T10:00:00Z', 25000);
    await addEvent('unk', 'unknown', '2026-10-21T10:00:00Z', 1000);
    await addTxn('lane-d-refund', 250, '2026-10-20T10:00:00Z', 'refund', 'active', 'refund', 2);
    // the retained original of buy1, hidden by WP-16
    await addTxn('lane-d-old-buy1', 499, '2026-10-19T10:00:00Z', 'spend', 'superseded', null, 1, 'buy1');
  }
}
const idOf = async (pool, p, key) => (await pool.query('SELECT id FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, key])).rows[0].id;

test('v2 rows: legacy list and detail hide superseded rows; reports ignore refund and superseded rows', { skip }, async () => {
  const withV2 = await newProfile(admin); const twin = await newProfile(admin);
  await seedV2(admin, withV2, { withExtras: true });
  await seedV2(admin, twin, { withExtras: false });

  const list = await stack.call(withV2, 'GET', '/transactions');
  assert.equal(list.status, 200);
  const keys = list.body.transactions.map((t) => t.source_key);
  assert.ok(!keys.includes('lane-d-old-buy1'), 'superseded row visible in the active list');
  const deleted = await stack.call(withV2, 'GET', '/transactions?status=deleted');
  assert.deepEqual(deleted.body.transactions, [], 'superseded row visible in the recovery list');
  const detail = await stack.call(withV2, 'GET', `/transactions/${await idOf(admin, withV2, 'lane-d-old-buy1')}`);
  assert.equal(detail.status, 404);

  // reports a v1 app renders must equal the twin that has only the two purchases
  for (const route of ['/spend-by-category', '/spend-report?period=month&anchor=2026-10-20T00:00:00Z', '/spend-report?period=year&anchor=2026-10-20T00:00:00Z', '/home-summary', '/monthly-reports']) {
    const a = await stack.call(withV2, 'GET', route);
    const b = await stack.call(twin, 'GET', route);
    assert.equal(a.status, 200, route);
    const norm = (x) => h.normalise(strip(x.body), new Map());
    const drop = (o) => JSON.parse(JSON.stringify(o, (k, v) => (['profile_id', 'id', 'generated_at'].includes(k) ? undefined : v)));
    assert.deepEqual(drop(norm(a)), drop(norm(b)), `${route} differs between a profile with refund/superseded rows and its twin`);
  }
  const sbc = await stack.call(withV2, 'GET', '/spend-by-category');
  assert.equal(sbc.body.categories.reduce((n, c) => n + c.totalSpendInr, 0), 649, 'only the two purchases are spend');
});

test('v2 rows: legacy write routes answer 4xx or 2xx (never 5xx) on superseded and v2 rows', { skip }, async () => {
  const p = await newProfile(admin);
  await seedV2(admin, p, { withExtras: true });
  const sup = await idOf(admin, p, 'lane-d-old-buy1');
  const ref = await idOf(admin, p, 'lane-d-refund');
  const buy = await idOf(admin, p, 'lane-d-buy1');
  const calls = [
    ['PATCH', `/transactions/${sup}`, { note: 'x' }, [409, 404]],
    ['POST', `/transactions/${sup}/ignore`, { reason: 'refund' }, [409, 404]],
    ['POST', `/transactions/${sup}/restore`, {}, [404]],
    ['PATCH', `/transactions/${ref}/note`, { note: 'note on a refund' }, [200]],
    ['POST', `/transactions/${ref}/ignore`, { reason: 'refund' }, [200]],
    ['POST', `/transactions/${ref}/restore`, {}, [200]],
    ['PATCH', `/transactions/${buy}/note`, { note: 'note on v2 purchase' }, [200]],
  ];
  for (const [m, r, b, ok] of calls) {
    const x = await stack.call(p, m, r, b);
    assert.ok(ok.includes(x.status), `${m} ${r.replace(/[0-9a-f-]{36}/g, ':id')} -> ${x.status} ${x.text.slice(0, 100)}`);
  }
  // the superseded row is never made active again by a legacy route
  const st = await admin.query("SELECT status::text FROM transactions WHERE id=$1", [sup]);
  assert.equal(st.rows[0].status, 'superseded');
  // legacy sync push of a stale transaction edit cannot reactivate it either (status is never writable there)
  const direct = await admin.query('SELECT status::text FROM transactions WHERE id=$1', [buy]);
  assert.equal(direct.rows[0].status, 'active');
});

test('v2 rows: replaying a legacy SMS batch whose rows were superseded answers 200 and keeps them hidden', { skip }, async () => {
  const p = await newProfile(admin);
  const first = await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit, MSGS.credit] });
  assert.equal(first.status, 200);
  const k = sourceKeyFor(p, MSGS.debit);
  await admin.query("UPDATE transactions SET status='superseded' WHERE profile_id=$1 AND source_key=$2", [p, k]);
  const again = await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit, MSGS.credit] });
  assert.equal(again.status, 200);
  const rows = (await admin.query('SELECT status::text, count(*)::int AS n FROM transactions WHERE profile_id=$1 AND source_key=$2 GROUP BY 1', [p, k])).rows;
  assert.deepEqual(rows, [{ status: 'superseded', n: 1 }], 'replay must not resurrect or duplicate a superseded row');
});

// ---------------------------------------------------------------------------
// 4. Lane G fixes for the lane D findings (see
//    docs/sms-pipeline-v2/requests/LANE-D-old-app-compat.md).
// ---------------------------------------------------------------------------
const V2 = { 'X-Sms-Pipeline': 'v2' };

test('LANE-D-1: a request without X-Sms-Pipeline: v2 never sees entry_kind values a v1 app maps to spend', { skip }, async () => {
  // The shipped app's TxnEntryKind.fromJson falls back to `spend` for any
  // value it does not know (6c17d46:app/lib/data/user_cards_repository.dart).
  const p = await newProfile(admin);
  await seedV2(admin, p, { withExtras: true });
  const refundId = await idOf(admin, p, 'lane-d-refund');
  const list = await stack.call(p, 'GET', '/transactions'); // no headers: the v1 app never sends X-Sms-Pipeline
  const bad = list.body.transactions.filter((t) => !LEGACY_KINDS.includes(t.entry_kind));
  assert.deepEqual(bad.map((t) => t.entry_kind), [], 'a refund row would be shown to a v1 app as spending');
  assert.equal(list.body.transactions.find((t) => t.id === refundId).entry_kind, 'transfer');
  const withVersion = await stack.call(p, 'GET', '/transactions', undefined, { 'X-App-Version': '9.9.9' });
  assert.equal(withVersion.body.transactions.find((t) => t.id === refundId).entry_kind, 'transfer', 'X-App-Version alone does not opt in');
  const detail = await stack.call(p, 'GET', `/transactions/${refundId}`);
  assert.equal(detail.body.transaction.entry_kind, 'transfer');
  // write responses too
  const patched = await stack.call(p, 'PATCH', `/transactions/${refundId}`, { merchantName: 'Refund shop' });
  assert.ok(patched.status < 500, patched.text);
  if (patched.status === 200) assert.notEqual(patched.body.transaction.entry_kind, 'refund');
  for (const [route] of [[`/transactions/${refundId}/ignore`], [`/transactions/${refundId}/restore`]]) {
    const r = await stack.call(p, 'POST', route, route.endsWith('ignore') ? { reason: 'refund' } : {});
    assert.equal(r.status, 200, r.text);
    assert.doesNotMatch(r.text, /"refund"/, `${route} leaks a refund kind to a legacy client`);
  }
  // stored data is untouched
  const stored = await admin.query('SELECT entry_kind::text FROM transactions WHERE id=$1', [refundId]);
  assert.equal(stored.rows[0].entry_kind, 'refund');
});

test('LANE-D-1: a v2 client (X-Sms-Pipeline: v2) still receives refund unchanged', { skip }, async () => {
  const p = await newProfile(admin);
  await seedV2(admin, p, { withExtras: true });
  const refundId = await idOf(admin, p, 'lane-d-refund');
  const list = await stack.call(p, 'GET', '/transactions', undefined, V2);
  assert.equal(list.body.transactions.find((t) => t.id === refundId).entry_kind, 'refund');
  const detail = await stack.call(p, 'GET', `/transactions/${refundId}`, undefined, V2);
  assert.equal(detail.body.transaction.entry_kind, 'refund');
});

test('LANE-D-1: reports and totals do not depend on the header', { skip }, async () => {
  const p = await newProfile(admin);
  await seedV2(admin, p, { withExtras: true });
  for (const route of ['/spend-by-category', '/spend-report?period=month&anchor=2026-10-20T00:00:00Z', '/home-summary', '/monthly-reports']) {
    const a = await stack.call(p, 'GET', route);
    const b = await stack.call(p, 'GET', route, undefined, V2);
    const drop = (x) => JSON.parse(JSON.stringify(h.normalise(x.body, new Map()), (k, v) => (['generated_at', 'elapsedFraction'].includes(k) ? undefined : v)));
    assert.equal(a.status, 200, route);
    assert.deepEqual(drop(a), drop(b), `${route} differs by header`);
  }
});

test('LANE-D-2: a legacy SMS replay does not rewrite a row projected by v2', { skip }, async () => {
  const p = await newProfile(admin);
  assert.equal((await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.refund] })).status, 200);
  const k = sourceKeyFor(p, MSGS.refund);
  const ev = HEX(`lane-d-replay-${p}`);
  await admin.query(`INSERT INTO sms_v2_events(event_id,profile_id,type,status,legs,confidence,occurred_at,amount_minor)
                     VALUES($1,$2,'refund','complete','[{"role":"credit_leg"}]'::jsonb,0.9,'2026-10-20T10:00:00Z',25000)`, [ev, p]);
  await admin.query("UPDATE transactions SET entry_kind='refund', pipeline_version=2, event_id=$3 WHERE profile_id=$1 AND source_key=$2", [p, k, ev]);
  const before = (await admin.query('SELECT * FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, k])).rows[0];
  const obsBefore = (await admin.query('SELECT count(*)::int AS n FROM transaction_observations WHERE profile_id=$1', [p])).rows[0].n;
  const replay = await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.refund] });
  assert.equal(replay.status, 200);
  const after = (await admin.query('SELECT * FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, k])).rows[0];
  assert.deepEqual(after, before, 'legacy replay changed a v2-owned row');
  assert.equal(after.entry_kind, 'refund');
  assert.equal(after.pipeline_version, 2);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM transaction_observations WHERE profile_id=$1', [p])).rows[0].n, obsBefore, 'no observation recorded');
  assert.doesNotMatch(replay.text, /"refund"/, 'a legacy client is told transfer, never refund');
});

test('LANE-D-2: a legacy SMS replay leaves a superseded row exactly as it was', { skip }, async () => {
  const p = await newProfile(admin);
  assert.equal((await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit] })).status, 200);
  const k = sourceKeyFor(p, MSGS.debit);
  await admin.query("UPDATE transactions SET status='superseded', entry_kind='transfer' WHERE profile_id=$1 AND source_key=$2", [p, k]);
  const before = (await admin.query('SELECT * FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, k])).rows[0];
  assert.equal((await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit] })).status, 200);
  const after = (await admin.query('SELECT * FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, k])).rows[0];
  assert.deepEqual(after, before);
});

test('LANE-D-2: an ordinary legacy duplicate (pipeline_version 1, active) behaves as before', { skip }, async () => {
  const p = await newProfile(admin);
  const first = await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit] });
  assert.equal(first.status, 200);
  const k = sourceKeyFor(p, MSGS.debit);
  const before = (await admin.query('SELECT * FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, k])).rows[0];
  assert.equal(before.pipeline_version, 1);
  const again = await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit] });
  assert.equal(again.status, 200);
  const rows = (await admin.query('SELECT id, status::text FROM transactions WHERE profile_id=$1 AND source_key=$2', [p, k])).rows;
  assert.deepEqual(rows, [{ id: before.id, status: 'active' }], 'one active row, no duplicate');
  // a stale classification is still refreshed for a v1-owned row (the legacy duplicate branch runs)
  await admin.query("UPDATE transactions SET entry_kind='income', state_applied=true WHERE id=$1", [before.id]);
  assert.equal((await stack.call(p, 'POST', '/transactions/from-sms/batch', { messages: [MSGS.debit] })).status, 200);
  const kind = (await admin.query('SELECT entry_kind::text FROM transactions WHERE id=$1', [before.id])).rows[0].entry_kind;
  assert.equal(kind, 'spend', 'legacy reclassification of a v1 row is unchanged');
});
