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
      res.on('end', () => resolve({ status: res.statusCode, ms: Number(process.hrtime.bigint() - t) / 1e6, bytes, body }));
    }).on('error', reject);
  });
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
