'use strict';

// WP-08 benchmark: a 500-item facts:batch in under 1 second p95 with 1 million
// stored facts.
//
//   SMS_V2_BENCH_DATABASE_URL=postgres://postgres:pw@127.0.0.1:5548/some_scratch_db \
//     node scripts/bench_sms_v2_facts.js [--facts 1000000] [--runs 30] [--keep]
//
// LOCAL SCRATCH DATABASES ONLY. The script refuses any host other than
// localhost / 127.0.0.1 / ::1 and any database whose name does not contain
// "scratch", "bench" or "test". It needs the product migrations plus
// 20261111120000_sms_v2_core and a role named app_user. It creates its own
// profiles, seeds the facts with one set-based INSERT and removes everything
// again unless --keep is given.
//
// Each timed run is one realistic upload: gunzip + JSON.parse + contract
// validation + the whole database transaction (500 items with 2 facts each, 500
// events, 500 ledger entries and 5 instruments, all new, spends on a bank
// account, so no reward-state calls). Card-state updates run the existing
// per-transaction reward machinery (about a dozen queries per new card spend) and
// are therefore not part of this budget; a bulk upload sets ?backfill=true, which
// skips them.

process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'bench_only_not_a_real_secret';
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { Pool } = require('pg');

const args = process.argv.slice(2);
const flag = (name, dflt) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : dflt; };
const FACTS = Number(flag('facts', '1000000'));
const RUNS = Number(flag('runs', '30'));
const KEEP = args.includes('--keep');
const BUDGET_MS = 1000;

const url = process.env.SMS_V2_BENCH_DATABASE_URL;
if (!url) { console.error('SMS_V2_BENCH_DATABASE_URL is required (a local scratch database)'); process.exit(2); }
const parsed = new URL(url);
if (!['localhost', '127.0.0.1', '[::1]', '::1'].includes(parsed.hostname)) { console.error(`refusing non-local host ${parsed.hostname}`); process.exit(2); }
if (!/scratch|bench|test/i.test(parsed.pathname)) { console.error('refusing a database whose name does not contain scratch, bench or test'); process.exit(2); }

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const T = '2026-11-01T07:00:11Z';

function makeBatch(run, bankId) {
  const items = []; const events = []; const ledger = [];
  for (let i = 0; i < 500; i += 1) {
    const sourceKey = `bench:${run}:${i}`;
    const mk = (idx, role, minor, type) => ({
      contractVersion: '2.0', factId: sha(`${sourceKey}|BENCH|${idx}`), sourceKey, factType: type, observedAt: T, occurredAt: T,
      instrument: { kind: 'credit_card', issuerSlug: 'hdfc', maskDigits: '5678', maskLength: 16, productName: null, raw: null },
      counterparty: type === 'movement' ? { name: 'BENCH SHOP', vpa: null, kind: 'merchant', accountMask: null } : null,
      amounts: [{ role, minor, unit: 'INR' }], references: {},
      attrs: type === 'movement' ? { direction: 'debit', purpose: 'purchase', rail: 'card' } : { asOf: T },
      provenance: { engine: 'rules', ruleId: 'BENCH', ruleVersion: 1, bundleVersion: 1, engineVersion: '2.0.0', appVersion: '1.0.0+1' },
      evidence: [], confidence: 0.99,
    });
    const move = mk(0, 'posted', 10000 + i, 'movement');
    const bal = mk(1, 'available_credit', 5000000 - i, 'balance_snapshot');
    items.push({ sourceKey, senderBrand: 'HDFCBK', observedAt: T, bodyHash: sha(sourceKey), facts: [move, bal] });
    const event = { eventId: move.factId, type: 'purchase', status: 'complete', legs: [{ factId: move.factId, role: 'debit_leg' }], linkRuleId: null, confidence: 0.95, occurredAt: T, amountMinor: 10000 + i };
    events.push(event);
    ledger.push({
      entryId: sha(`${event.eventId}|0`), eventId: event.eventId, from: { instrumentId: bankId }, to: { external: 'BENCH SHOP' },
      amountMinor: event.amountMinor, unit: 'INR', occurredAt: T, category: 'food', categorySource: 'catalogue', countsAsTransaction: true, isSpend: true, isIncome: false, isInvestment: false,
    });
  }
  return { items, events, ledger };
}

(async () => {
  const pool = new Pool({ connectionString: url });
  const storage = require('../src/sms_v2/storage');
  const contracts = require('../src/sms_v2/contracts');
  const profile = crypto.randomUUID();
  const withUserClient = async (userId, fn) => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE app_user');
      await c.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      const out = await fn(c);
      await c.query('COMMIT');
      return out;
    } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
  };
  try {
    await pool.query('INSERT INTO profiles(id) VALUES ($1)', [profile]);
    const seeded = Date.now();
    await pool.query(
      `INSERT INTO sms_v2_facts (fact_id, profile_id, source_key, fact_type, contract_version, observed_at, occurred_at, payload, provenance)
       SELECT encode(sha256(('seed-' || g)::bytea), 'hex'), $1, 'seed:' || g, 'movement', '2.0',
              timestamptz '2026-01-01' + (g * interval '20 seconds'), timestamptz '2026-01-01' + (g * interval '20 seconds'),
              jsonb_build_object('amounts', jsonb_build_array(jsonb_build_object('role','posted','minor',10000+g % 5000,'unit','INR')),
                                 'attrs', jsonb_build_object('direction','debit','purpose','purchase','rail','card'), 'senderBrand', 'HDFCBK'),
              '{"engine":"rules"}'::jsonb
         FROM generate_series(1, $2::int) g`,
      [profile, FACTS],
    );
    await pool.query('ANALYZE sms_v2_facts');
    console.log(`seeded ${FACTS} facts in ${Date.now() - seeded} ms`);

    const bank = { instrumentId: crypto.randomUUID(), kind: 'bank_account', issuerSlug: 'bench', maskDigits: '4321' };
    const card = { instrumentId: crypto.randomUUID(), kind: 'credit_card', issuerSlug: 'hdfc', maskDigits: '5678' };
    const mkInst = (i) => ({
      ...i, maskLength: 16, displayName: 'Bench', status: 'detected', userCardId: null, parentInstrumentId: null,
      aliases: { senders: [], vpas: [], productNames: [] }, creditLimitMinor: null, creditLimitSource: null, creditLimitAt: null,
      availableMinor: null, availableAt: null, pointsBalance: null, pointsAt: null, firstSeenAt: T, lastSeenAt: T, evidenceCount: 1,
    });
    const extra = Array.from({ length: 3 }, (_, k) => mkInst({ instrumentId: crypto.randomUUID(), kind: 'wallet', issuerSlug: `bench${k}`, maskDigits: null }));
    const deps = { loadUserCardForState: async () => ({ id: 'stub' }), applyTransactionState: async () => ({}), reverseTransactionState: async () => ({}) };
    const hooks = { afterEventsStored: async () => {} };

    const times = [];
    for (let run = 0; run < RUNS + 2; run += 1) {
      const body = { contractVersion: '2.0', appVersion: '1.0.0+1', deviceId: 'bench-device', ...makeBatch(run, bank.instrumentId), instruments: run === 0 ? [mkInst(bank), mkInst(card), ...extra] : [] };
      const gz = zlib.gzipSync(Buffer.from(JSON.stringify(body)));
      const start = process.hrtime.bigint();
      const parsedBody = JSON.parse(zlib.gunzipSync(gz).toString('utf8'));
      const check = contracts.validateRequest('facts_batch', parsedBody);
      if (!check.ok) throw new Error(`bench batch is invalid: ${JSON.stringify(check.errors.slice(0, 3))}`);
      const out = await withUserClient(profile, (client) => storage.ingestBatch(client, profile, parsedBody, { deps, hooks }));
      const ms = Number(process.hrtime.bigint() - start) / 1e6;
      if (out.results.some((r) => r.status === 'rejected')) throw new Error(`rejected: ${JSON.stringify(out.results.find((r) => r.status === 'rejected'))}`);
      if (run >= 2) times.push(ms); // two warm-up runs
      if (run === 0) console.log(`batch gzip size ${(gz.length / 1024).toFixed(0)} KiB, ${parsedBody.items.length} items`);
    }
    times.sort((a, b) => a - b);
    const q = (p) => times[Math.min(times.length - 1, Math.ceil(p * times.length) - 1)];
    const report = { facts: FACTS, runs: times.length, p50_ms: +q(0.5).toFixed(1), p95_ms: +q(0.95).toFixed(1), max_ms: +times[times.length - 1].toFixed(1), budget_ms: BUDGET_MS };
    console.log(JSON.stringify(report));
    if (report.p95_ms >= BUDGET_MS) { console.error(`FAIL: p95 ${report.p95_ms} ms is over the ${BUDGET_MS} ms budget`); process.exitCode = 1; } else console.log('PASS');
  } finally {
    if (!KEEP) await pool.query('DELETE FROM profiles WHERE id = $1', [profile]); // cascades facts, events, ledger, instruments, transactions
    await pool.end();
  }
})().catch((e) => { console.error(e); process.exit(1); });
