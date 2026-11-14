'use strict';

// HTTP latency benchmark against a SCRATCH database (see scripts/bench_seed.sql).
//
//   BENCH_DATABASE_URL=postgres://app_user:app_user_dev_pw@127.0.0.1:5434/pandapay_bench \
//     node scripts/bench_http.js [--out run.json] [--compare base.json] [--n 40]
//
// WRITE benchmarks (--push N): on Docker Desktop (Windows/macOS) a committed write waits 250-400 ms for the disk flush, which
// swamps everything else. For a scratch bench database only: ALTER DATABASE pandapay_bench SET synchronous_commit = off;
// Real SSD-backed Postgres commits in a few ms, so read this as the application's cost, not the production latency.
// Starts a stub auth service and the real API (src/index.js) on loopback, then times each
// GET route sequentially (p50/p95) as the seeded bench user. Refuses non-local, non-bench DBs.

const { spawn } = require('node:child_process');
const http = require('node:http');
const fs = require('node:fs');
const jwt = require('jsonwebtoken');

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : d; };
const N = Number(flag('n', '40'));
const retries = Number(flag('retries', '0'));
const dbUrl = process.env.BENCH_DATABASE_URL;
if (!dbUrl) { console.error('BENCH_DATABASE_URL required'); process.exit(2); }
const u = new URL(dbUrl);
if (!['127.0.0.1', 'localhost'].includes(u.hostname) || !/bench|scratch|test/i.test(u.pathname)) {
  console.error('refusing: DB must be local and named *bench*/*scratch*/*test*'); process.exit(2);
}

const USER = 'b0000000-0000-4000-8000-000000000001';
const SECRET = 'bench_only_not_a_real_secret';
const token = jwt.sign({ sub: USER }, SECRET, { algorithm: 'HS256', issuer: 'pandapay-auth', audience: 'mobile-app', expiresIn: '1h' });
const ROUTES = process.env.BENCH_ROUTES ? process.env.BENCH_ROUTES.split(',') : [
  '/health', '/home-summary', '/transactions?pageSize=200', '/spend-report?period=month', '/spend-report?period=year',
  '/spend-by-category', '/monthly-reports', '/user-cards', '/account-summaries', '/recurring', '/budgets',
  '/catalogue', '/categories', '/duplicate-candidates', '/assistant/spending-summary',
];

const auth = http.createServer((req, res) => {
  req.resume();
  const sub = (jwt.decode(String(req.headers.authorization || '').slice(7)) || {}).sub || USER;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ token_valid: true, valid: true, subject: sub, session: { active: true, revoked: false }, verified_contacts: {}, phone_gate: { required: false, satisfied: true } }));
});

// --users N: virtual user v signs in as seeded user (v % N) + 1 (see bench_seed_users.sql) instead of the one big bench user.
const MULTI = Number(flag('users', '0'));
const userFor = (v) => (MULTI ? `b0000001-0000-4000-8000-${String((v % MULTI) + 1).padStart(12, '0')}` : USER);
const tokenFor = (v) => (MULTI ? jwt.sign({ sub: userFor(v) }, SECRET, { algorithm: 'HS256', issuer: 'pandapay-auth', audience: 'mobile-app', expiresIn: '1h' }) : token);

function get(port, path, tok = token) {
  return new Promise((resolve, reject) => {
    const t = process.hrtime.bigint();
    http.get({ host: '127.0.0.1', port, path, headers: { authorization: `Bearer ${tok}`, 'x-sms-pipeline': 'v2' } }, (res) => {
      let bytes = 0; let body = ''; res.on('data', (c) => { bytes += c.length; if (body.length < 200) body += c; });
      res.on('end', () => resolve({ status: res.statusCode, ms: Number(process.hrtime.bigint() - t) / 1e6, bytes, body, retryAfter: res.headers['retry-after'] }));
    }).on('error', reject);
  });
}


// Like the app: on 429/500/503 wait Retry-After (default 5 s, +0-25% jitter) and try again, up to `max` times.
async function getRetrying(port, path, max, tok) {
  let r = await get(port, path, tok);
  const started = process.hrtime.bigint();
  let tries = 0;
  while (max > 0 && tries < max && [429, 500, 503].includes(r.status)) {
    tries += 1;
    await new Promise((res) => setTimeout(res, (Number(r.retryAfter) || 5) * 1000 * (1 + Math.random() * 0.25)));
    r = await get(port, path, tok);
  }
  r.tries = tries;
  r.ms = Number(process.hrtime.bigint() - started) / 1e6 + (tries ? 0 : r.ms);
  return r;
}

const { execSync } = require('node:child_process');
// CPU seconds used so far by the API process and by the Postgres container (cgroup counter), to see what saturates.
function cpuSeconds(pid) {
  let api = NaN; let db = NaN;
  try { api = Number(execSync(`powershell -NoProfile -Command "(Get-Process -Id ${pid}).TotalProcessorTime.TotalSeconds"`, { encoding: 'utf8' }).trim()); } catch (_) { /* not on Windows */ }
  try { db = Number(/usage_usec (\d+)/.exec(execSync('docker exec pandapay-db-1 cat /sys/fs/cgroup/cpu.stat', { encoding: 'utf8' }))[1]) / 1e6; } catch (_) { /* no docker */ }
  return { api, db };
}

function post(port, path, body, tok = token, method = 'POST') {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body); const t = process.hrtime.bigint();
    const req = http.request({ host: '127.0.0.1', port, path, method, headers: { authorization: `Bearer ${tok}`, 'content-type': 'application/json', 'content-length': Buffer.byteLength(data), 'x-sms-pipeline': 'v2' } }, (res) => {
      let b = ''; res.on('data', (c) => { b += c; });
      res.on('end', () => resolve({ status: res.statusCode, ms: Number(process.hrtime.bigint() - t) / 1e6, json: (() => { try { return JSON.parse(b); } catch (_) { return null; } })(), body: b }));
    });
    req.on('error', reject); req.end(data);
  });
}

(async () => {
  await new Promise((r) => auth.listen(0, '127.0.0.1', r));
  const authPort = auth.address().port;
  // --instances K: K API processes (like K containers behind a load balancer); virtual user v talks to instance v % K.
  const INSTANCES = Number(flag('instances', '1'));
  const BASE = 4100 + Math.floor(Math.random() * 400) * 2;
  const nodeArgs = (process.env.BENCH_NODE_ARGS || '').split(' ').filter(Boolean);
  let stderr = '';
  const apis = Array.from({ length: INSTANCES }, (_, i) => {
    const proc = spawn(process.execPath, [...nodeArgs, 'src/index.js'], {
      cwd: require('node:path').join(__dirname, '..'),
      env: { ...process.env, NODE_ENV: 'development', PORT: String(BASE + i), DATABASE_URL: dbUrl, DB_SSL: 'false', JWT_ACCESS_SECRET: SECRET,
        AUTH_INTERNAL_BASE_URL: `http://127.0.0.1:${authPort}`, AUTH_INTERNAL_SERVICE_SECRET: 'bench_internal_secret_32_bytes_long_xx', TRUST_PROXY_HOPS: '0',
        BENCH_PROFILE_OUT: process.env.BENCH_PROFILE_OUT ? `${process.env.BENCH_PROFILE_OUT}.${i}` : '' },
      stdio: ['ignore', process.env.BENCH_STDOUT ? 'inherit' : 'ignore', 'pipe'],
    });
    proc.stderr.on('data', (d) => { stderr += d; });
    return { proc, port: BASE + i };
  });
  const PORT = apis[0].port;
  const api = apis[0].proc;
  const portFor = (v) => apis[v % INSTANCES].port;
  const cpuAll = () => { const c = apis.map((x) => cpuSeconds(x.proc.pid)); return { api: c.reduce((a, x) => a + x.api, 0), db: c[0].db }; };
  const stop = () => { apis.forEach((x) => x.proc.kill()); auth.close(); };
  try {
    for (const { port } of apis) {
      for (let i = 0; ; i += 1) {
        try { if ((await get(port, '/health')).status === 200) break; } catch (_) { /* not up yet */ }
        if (i > 100) throw new Error(`API did not start
${stderr.slice(-800)}`);
        await new Promise((r) => setTimeout(r, 200));
      }
    }
    if (flag('snapshot')) {
      // Equivalence proof: record every GET route's response (volatile fields blanked) for the first --snapusers
      // seeded users into DIR. Run before and after a change, then: node scripts/snapshot_diff.js DIR_A DIR_B
      const dir = flag('snapshot'); const K = Number(flag('snapusers', '4'));
      fs.mkdirSync(dir, { recursive: true });
      const SNAP = [...ROUTES.filter((r) => r !== '/health'), '/spend-report?period=week', '/spend-report?period=quarter',
        '/transactions?pageSize=50&status=deleted', '/transactions?q=SWIGGY&pageSize=50', '/transactions?pageSize=200',
        '/consents', '/user-settings', '/notifications', '/referrals', '/lounge-usage', '/notification-preferences', '/profile', '/home-summary?tz=America/New_York'];
      const strip = (a, b) => {
        if (JSON.stringify(a) === JSON.stringify(b)) return a;
        if (a && b && typeof a === 'object' && typeof b === 'object' && Array.isArray(a) === Array.isArray(b)) {
          if (Array.isArray(a)) return a.length === b.length ? a.map((x, i) => strip(x, b[i])) : '<volatile>';
          const out = {}; for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) out[k] = strip(a[k], b[k]); return out;
        }
        return '<volatile>';
      };
      const fetchBody = (path, tok) => new Promise((resolve, reject) => http.get({ host: '127.0.0.1', port: PORT, path, headers: { authorization: `Bearer ${tok}`, 'x-sms-pipeline': 'v2' } }, (r) => { let b = ''; r.on('data', (c) => { b += c; }); r.on('end', () => resolve({ status: r.statusCode, body: b })); }).on('error', reject));
      let files = 0;
      for (let v = 0; v < K; v += 1) {
        const tok = tokenFor(v);
        for (const path of SNAP) {
          await fetchBody(path, tok); // warm: GET /user-cards repairs state on its first call
          const a = await fetchBody(path, tok); const b = await fetchBody(path, tok);
          const parse = (x) => { try { return JSON.parse(x.body); } catch (_) { return x.body; } };
          const doc = { status: a.status, body: strip(parse(a), parse(b)) };
          fs.writeFileSync(`${dir}/u${v}__${path.replace(/[^a-z0-9]+/gi, '_')}.json`, JSON.stringify(doc, null, 1)); files += 1;
        }
      }
      console.log(`snapshot: ${files} responses (${K} users x ${SNAP.length} routes) written to ${dir}`);
      return;
    }
    if (flag('writes')) {
      // Common write endpoints, one user, R repetitions each: latency and SQL statements per call (use with
      // BENCH_NODE_ARGS="--require <count preload>" for the statement count; see scripts/bench_http.js header).
      const R = Number(flag('writes')); const tk = tokenFor(0); const stamp = Date.now();
      const J = async (p) => JSON.parse((await new Promise((res) => { let b = ''; http.get({ host: '127.0.0.1', port: PORT, path: p, headers: { authorization: `Bearer ${tk}`, 'x-sms-pipeline': 'v2' } }, (r) => { r.on('data', (c) => { b += c; }); r.on('end', () => res(b)); }); })));
      const cardId = (await J('/user-cards')).userCards[0].id;
      const count = (p) => new Promise((res) => http.get({ host: '127.0.0.1', port: PORT, path: p }, (r) => { let b = ''; r.on('data', (c) => { b += c; }); r.on('end', () => res(b)); }));
      const created = [];
      const ops = [
        ['POST /transactions', async (i) => { const r = await post(PORT, '/transactions', { userCardId: cardId, amountInr: 100 + i, merchantName: `BENCH WRITE ${i}`, occurredAt: new Date().toISOString(), clientMutationId: `bw-${stamp}-${i}` }, tk); if (r.json && r.json.transaction) created.push(r.json.transaction.id); else if (r.json && r.json.id) created.push(r.json.id); return r; }],
        ['POST /transactions/:id/ignore', async (i) => post(PORT, `/transactions/${created[i]}/ignore`, { reason: 'wrong_transaction' }, tk)],
        ['POST /transactions/:id/restore', async (i) => post(PORT, `/transactions/${created[i]}/restore`, {}, tk)],
        ['PATCH /transactions/:id/note', async (i) => post(PORT, `/transactions/${created[i]}/note`, { note: `n${i}` }, tk, 'PATCH')],
      ];
      for (const [name, fn] of ops) {
        const lat = []; let bad = 0; await count('/__bench_count_reset');
        for (let i = 0; i < R; i += 1) { const r = await fn(i); lat.push(r.ms); if (r.status >= 300) { bad += 1; if (bad === 1) console.log(`   first non-2xx: ${r.status} ${r.body.slice(0, 120)}`); } }
        lat.sort((a, b) => a - b); const sql = Number(await count('/__bench_count'));
        console.log(`${name.padEnd(34)} p50 ${lat[Math.floor(lat.length / 2)].toFixed(1).padStart(7)}ms  p95 ${lat[Math.floor(lat.length * 0.95)].toFixed(1).padStart(7)}ms  SQL/call ${(sql / R).toFixed(1)}  non-2xx ${bad}/${R}`);
      }
      if (args.includes('--stderr')) console.log(stderr.slice(-14000));
      return;
    }
    if (flag('push')) {
      // Write path: push N transaction `note` edits per request as one device (see sync_push_handlers.js), R requests.
      const N = Number(flag('push')); const R = Number(flag('reps', '10')); const tok = tokenFor(0);
      const reg = await post(PORT, '/sync/register-device', { platform: 'android', appVersion: 'bench' }, tok);
      const deviceId = reg.json && (reg.json.deviceId || reg.json.id);
      if (!deviceId) throw new Error(`register-device failed ${reg.status} ${reg.body.slice(0, 120)}`);
      const list = await get(PORT, `/transactions?pageSize=${Math.min(200, Math.max(N, 1))}`, tok);
      const ids = JSON.parse((await new Promise((res) => { let b = ''; http.get({ host: '127.0.0.1', port: PORT, path: `/transactions?pageSize=${Math.min(200, Math.max(N, 1))}`, headers: { authorization: `Bearer ${tok}`, 'x-sms-pipeline': 'v2' } }, (r) => { r.on('data', (c) => { b += c; }); r.on('end', () => res(b)); }); }))).transactions.map((t) => t.id);
      const lat = []; let applied = 0; let seq = 1;
      const count = async (p) => new Promise((res) => http.get({ host: '127.0.0.1', port: PORT, path: p }, (r) => { let b = ''; r.on('data', (c) => { b += c; }); r.on('end', () => res(b)); }));
      await count('/__bench_count_reset');
      const cpu0 = cpuAll();
      for (let r = 0; r < R; r += 1) {
        const changes = ids.slice(0, N).map((entityId, i) => ({ entity: 'transactions', entityId, op: 'update', clientSeq: seq += 1, payload: { note: `bench ${r}-${i}` }, fieldClocks: { note: Date.now() + seq } }));
        const res = await post(PORT, '/sync/push', { deviceId, strict: true, changes }, tok);
        if (res.status !== 200) throw new Error(`push failed ${res.status} ${res.body.slice(0, 200)}`);
        lat.push(res.ms); applied += res.json.results.filter((x) => x.applied).length;
      }
      const cpu1 = cpuAll();
      const sql = Number(await count('/__bench_count'));
      lat.sort((a, b) => a - b);
      console.log(`push N=${N} changes x ${R} requests: p50 ${lat[Math.floor(lat.length / 2)].toFixed(1)}ms (${(lat[Math.floor(lat.length / 2)] / N).toFixed(2)}ms/change)  applied ${applied}/${N * R}  SQL statements/change ${(sql / (N * R)).toFixed(1)}  Postgres CPU/change ${(((cpu1.db - cpu0.db) * 1000) / (N * R)).toFixed(2)}ms`);
      if (args.includes('--stderr')) console.log(stderr.slice(-12000));
      return;
    }
    if (flag('conc')) {
      // Concurrency mode: C virtual users each open the app (the routes below, in order) at the same moment.
      const C = Number(flag('conc'));
      const SCREEN = ROUTES.filter((r) => r !== '/health' && r !== '/catalogue'); // catalogue has its own per-IP limiter (a bench artifact: every virtual user shares one IP)
      const cpu0 = cpuAll();
      const t0 = process.hrtime.bigint();
      const per = await Promise.all(Array.from({ length: C }, async (_, v) => {
        const tok = tokenFor(v);
        const lat = []; let bad = 0; const codes = {}; let retried = 0;
        for (const path of SCREEN) { const r = await getRetrying(portFor(v), path, retries, tok); lat.push(r.ms); retried += r.tries || 0; if (r.status !== 200) { bad += 1; codes[`${r.status} ${r.body.slice(0, 60)}`] = (codes[`${r.status} ${r.body.slice(0, 60)}`] || 0) + 1; } }
        return { total: lat.reduce((a, b) => a + b, 0), lat, bad, codes, retried };
      }));
      const wall = Number(process.hrtime.bigint() - t0) / 1e6;
      const cpu1 = cpuAll();
      const all = per.flatMap((x) => x.lat).sort((a, b) => a - b);
      const totals = per.map((x) => x.total).sort((a, b) => a - b);
      console.log(`${C} concurrent users x ${SCREEN.length} requests = ${all.length} requests in ${(wall / 1000).toFixed(1)}s (${(all.length / (wall / 1000)).toFixed(0)} req/s)`);
      console.log(`per request   p50 ${all[Math.floor(all.length * 0.5)].toFixed(0)}ms  p95 ${all[Math.floor(all.length * 0.95)].toFixed(0)}ms  max ${all[all.length - 1].toFixed(0)}ms`);
      console.log(`per user (all ${SCREEN.length} calls)  p50 ${(totals[Math.floor(C * 0.5)] / 1000).toFixed(1)}s  p95 ${(totals[Math.floor(C * 0.95)] / 1000).toFixed(1)}s  worst ${(totals[C - 1] / 1000).toFixed(1)}s`);
      console.log(`CPU over ${(wall / 1000).toFixed(1)}s wall: API process${INSTANCES > 1 ? 'es (total)' : ''} ${((cpu1.api - cpu0.api) / (wall / 1000)).toFixed(2)} cores, Postgres container ${((cpu1.db - cpu0.db) / (wall / 1000)).toFixed(2)} cores  =>  per request: API ${(((cpu1.api - cpu0.api) * 1000) / all.length).toFixed(1)} ms CPU, Postgres ${(((cpu1.db - cpu0.db) * 1000) / all.length).toFixed(1)} ms CPU`);
      console.log(`failed responses: ${per.reduce((a, x) => a + x.bad, 0)}${retries ? `  (after retrying; ${per.reduce((a, x) => a + x.retried, 0)} retries were needed)` : ''}`);
      const agg = {}; for (const x of per) for (const [k, v] of Object.entries(x.codes)) agg[k] = (agg[k] || 0) + v;
      console.log(agg);
      return;
    }
    const results = [];
    for (const path of ROUTES) {
      for (let i = 0; i < 5; i += 1) await get(PORT, path, tokenFor(0)); // warm-up
      const s = []; let last;
      for (let i = 0; i < N; i += 1) { last = await get(PORT, path, tokenFor(0)); s.push(last.ms); }
      s.sort((a, b) => a - b);
      results.push({ name: path, status: last.status, bytes: last.bytes, ...(last.status >= 400 ? { body: last.body } : {}), p50: s[Math.floor(N * 0.5)], p95: s[Math.min(N - 1, Math.floor(N * 0.95))] });
    }
    const base = flag('compare') ? JSON.parse(fs.readFileSync(flag('compare'), 'utf8')) : null;
    for (const r of results) {
      const b = base && base.results.find((x) => x.name === r.name);
      console.log(`${r.name.padEnd(34)} ${String(r.status).padEnd(4)} ${String(r.bytes).padStart(8)}B  p50 ${r.p50.toFixed(1).padStart(8)}ms  p95 ${r.p95.toFixed(1).padStart(8)}ms${r.body ? `  ${r.body}` : ''}${b ? `  (base ${b.p50.toFixed(1)}ms, ${(b.p50 / r.p50).toFixed(2)}x)` : ''}`);
    }
    if (flag('out')) fs.writeFileSync(flag('out'), JSON.stringify({ n: N, results }, null, 2));
    if (args.includes('--stderr')) console.log(stderr.slice(-3000));
  } finally {
    if (process.env.BENCH_PROFILE_OUT) for (const x of apis) await get(x.port, '/__bench_profile').catch(() => {});
    stop();
  }
})().catch((e) => { console.error(e); process.exit(1); });
