'use strict';

// HTTP latency benchmark against a SCRATCH database (see scripts/bench_seed.sql).
//
//   BENCH_DATABASE_URL=postgres://app_user:app_user_dev_pw@127.0.0.1:5434/pandapay_bench \
//     node scripts/bench_http.js [--out run.json] [--compare base.json] [--n 40]
//
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
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ token_valid: true, valid: true, subject: USER, session: { active: true, revoked: false }, verified_contacts: {}, phone_gate: { required: false, satisfied: true } }));
});

function get(port, path) {
  return new Promise((resolve, reject) => {
    const t = process.hrtime.bigint();
    http.get({ host: '127.0.0.1', port, path, headers: { authorization: `Bearer ${token}`, 'x-sms-pipeline': 'v2' } }, (res) => {
      let bytes = 0; let body = ''; res.on('data', (c) => { bytes += c.length; if (body.length < 200) body += c; });
      res.on('end', () => resolve({ status: res.statusCode, ms: Number(process.hrtime.bigint() - t) / 1e6, bytes, body, retryAfter: res.headers['retry-after'] }));
    }).on('error', reject);
  });
}


// Like the app: on 429/500/503 wait Retry-After (default 5 s, +0-25% jitter) and try again, up to `max` times.
async function getRetrying(port, path, max) {
  let r = await get(port, path);
  const started = process.hrtime.bigint();
  let tries = 0;
  while (max > 0 && tries < max && [429, 500, 503].includes(r.status)) {
    tries += 1;
    await new Promise((res) => setTimeout(res, (Number(r.retryAfter) || 5) * 1000 * (1 + Math.random() * 0.25)));
    r = await get(port, path);
  }
  r.tries = tries;
  r.ms = Number(process.hrtime.bigint() - started) / 1e6 + (tries ? 0 : r.ms);
  return r;
}

(async () => {
  await new Promise((r) => auth.listen(0, '127.0.0.1', r));
  const authPort = auth.address().port;
  const PORT = 4100 + Math.floor(Math.random() * 500);
  const api = spawn(process.execPath, ['src/index.js'], {
    cwd: require('node:path').join(__dirname, '..'),
    env: { ...process.env, NODE_ENV: 'development', PORT: String(PORT), DATABASE_URL: dbUrl, DB_SSL: 'false', JWT_ACCESS_SECRET: SECRET,
      AUTH_INTERNAL_BASE_URL: `http://127.0.0.1:${authPort}`, AUTH_INTERNAL_SERVICE_SECRET: 'bench_internal_secret_32_bytes_long_xx', TRUST_PROXY_HOPS: '0' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = ''; api.stderr.on('data', (d) => { stderr += d; });
  const stop = () => { api.kill(); auth.close(); };
  try {
    for (let i = 0; ; i += 1) {
      try { if ((await get(PORT, '/health')).status === 200) break; } catch (_) { /* not up yet */ }
      if (i > 100) throw new Error(`API did not start\n${stderr.slice(-800)}`);
      await new Promise((r) => setTimeout(r, 200));
    }
    if (flag('conc')) {
      // Concurrency mode: C virtual users each open the app (the routes below, in order) at the same moment.
      const C = Number(flag('conc'));
      const SCREEN = ROUTES.filter((r) => r !== '/health' && r !== '/catalogue'); // catalogue has its own per-IP limiter (a bench artifact: every virtual user shares one IP)
      const t0 = process.hrtime.bigint();
      const per = await Promise.all(Array.from({ length: C }, async () => {
        const lat = []; let bad = 0; const codes = {}; let retried = 0;
        for (const path of SCREEN) { const r = await getRetrying(PORT, path, retries); lat.push(r.ms); retried += r.tries || 0; if (r.status !== 200) { bad += 1; codes[`${r.status} ${r.body.slice(0, 60)}`] = (codes[`${r.status} ${r.body.slice(0, 60)}`] || 0) + 1; } }
        return { total: lat.reduce((a, b) => a + b, 0), lat, bad, codes, retried };
      }));
      const wall = Number(process.hrtime.bigint() - t0) / 1e6;
      const all = per.flatMap((x) => x.lat).sort((a, b) => a - b);
      const totals = per.map((x) => x.total).sort((a, b) => a - b);
      console.log(`${C} concurrent users x ${SCREEN.length} requests = ${all.length} requests in ${(wall / 1000).toFixed(1)}s (${(all.length / (wall / 1000)).toFixed(0)} req/s)`);
      console.log(`per request   p50 ${all[Math.floor(all.length * 0.5)].toFixed(0)}ms  p95 ${all[Math.floor(all.length * 0.95)].toFixed(0)}ms  max ${all[all.length - 1].toFixed(0)}ms`);
      console.log(`per user (all ${SCREEN.length} calls)  p50 ${(totals[Math.floor(C * 0.5)] / 1000).toFixed(1)}s  p95 ${(totals[Math.floor(C * 0.95)] / 1000).toFixed(1)}s  worst ${(totals[C - 1] / 1000).toFixed(1)}s`);
      console.log(`failed responses: ${per.reduce((a, x) => a + x.bad, 0)}${retries ? `  (after retrying; ${per.reduce((a, x) => a + x.retried, 0)} retries were needed)` : ''}`);
      const agg = {}; for (const x of per) for (const [k, v] of Object.entries(x.codes)) agg[k] = (agg[k] || 0) + v;
      console.log(agg);
      return;
    }
    const results = [];
    for (const path of ROUTES) {
      for (let i = 0; i < 5; i += 1) await get(PORT, path); // warm-up
      const s = []; let last;
      for (let i = 0; i < N; i += 1) { last = await get(PORT, path); s.push(last.ms); }
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
  } finally { stop(); }
})().catch((e) => { console.error(e); process.exit(1); });
