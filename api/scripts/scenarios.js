'use strict';

// Integration scenarios against a REAL API process and a SCRATCH Postgres: overload, outages, concurrency, replays,
// bad input. Synthetic data only; refuses non-local or non-scratch databases.
//
//   SCEN_DATABASE_URL=postgres://app_user:app_user_dev_pw@127.0.0.1:5440/scen_bench \
//   SCEN_DOCKER_CONTAINER=pp_scen   (optional: enables the database-outage scenario by stopping/starting that container)
//     node scripts/scenarios.js
//
// Seed first: scripts/bench_seed_users.sql (users=20). Exit code 1 when any check fails.

const { spawn, execSync } = require('node:child_process');
const http = require('node:http');
const path = require('node:path');
const jwt = require('jsonwebtoken');

const dbUrl = process.env.SCEN_DATABASE_URL;
if (!dbUrl) { console.error('SCEN_DATABASE_URL required'); process.exit(2); }
const u = new URL(dbUrl);
if (!['127.0.0.1', 'localhost'].includes(u.hostname) || !/bench|scratch|test|scen/i.test(u.pathname)) {
  console.error('refusing: DB must be local and named like a scratch database'); process.exit(2);
}
const CONTAINER = process.env.SCEN_DOCKER_CONTAINER || '';
const SECRET = 'scenario_only_not_a_real_secret';
const uid = (n) => `b0000001-0000-4000-8000-${String(n).padStart(12, '0')}`;
const tok = (n) => jwt.sign({ sub: uid(n) }, SECRET, { algorithm: 'HS256', issuer: 'pandapay-auth', audience: 'mobile-app', expiresIn: '1h' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let authMode = 'ok';
const auth = http.createServer((req, res) => {
  req.resume();
  if (authMode === 'down') { res.statusCode = 503; return res.end('{}'); }
  const sub = (jwt.decode(String(req.headers.authorization || '').slice(7)) || {}).sub;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ token_valid: true, valid: true, subject: sub, session: { active: true, revoked: false }, verified_contacts: {}, phone_gate: { required: false, satisfied: true } }));
});

let results = [];
function check(scenario, name, ok, detail = '') {
  results.push({ scenario, name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  [${scenario}] ${name}${ok || !detail ? '' : `  -> ${detail}`}`);
}

function request(port, { method = 'GET', pathname, token, body, headers = {}, abortAfterMs }) {
  return new Promise((resolve) => {
    const data = body === undefined ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = http.request({ host: '127.0.0.1', port, path: pathname, method, headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}), 'x-sms-pipeline': 'v2',
      ...(data !== null ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } : {}), ...headers } }, (res) => {
      let b = ''; res.on('data', (c) => { b += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: b, json: (() => { try { return JSON.parse(b); } catch (_) { return null; } })() }));
    });
    req.on('error', (e) => resolve({ status: 0, error: e.code || e.message, headers: {}, body: '' }));
    if (abortAfterMs) setTimeout(() => req.destroy(), abortAfterMs);
    if (data !== null) req.write(data);
    req.end();
  });
}

async function startApi(env = {}) {
  const port = 4600 + Math.floor(Math.random() * 300);
  const proc = spawn(process.execPath, ['src/index.js'], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, NODE_ENV: 'development', PORT: String(port), DATABASE_URL: dbUrl, DB_SSL: 'false', JWT_ACCESS_SECRET: SECRET,
      AUTH_INTERNAL_BASE_URL: `http://127.0.0.1:${auth.address().port}`, AUTH_INTERNAL_SERVICE_SECRET: 'scenario_internal_secret_32_bytes_xx', TRUST_PROXY_HOPS: '0',
      DB_CONNECTION_TIMEOUT_MS: '3000', ...env },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let err = ''; proc.stderr.on('data', (d) => { err += d; });
  let alive = true; proc.on('exit', () => { alive = false; });
  for (let i = 0; i < 100; i += 1) {
    if ((await request(port, { pathname: '/health' })).status === 200) return { port, proc, isAlive: () => alive, stop: () => proc.kill(), stderr: () => err };
    await sleep(200);
  }
  throw new Error(`API did not start\n${err.slice(-600)}`);
}

const retryAfterOk = (r) => /^\d+$/.test(String(r.headers['retry-after'] || '')) && Number(r.headers['retry-after']) >= 1 && Number(r.headers['retry-after']) <= 60;

const READS = ['/home-summary', '/transactions?pageSize=50', '/spend-report?period=month', '/spend-by-category', '/monthly-reports', '/user-cards',
  '/account-summaries', '/recurring', '/budgets', '/categories', '/duplicate-candidates', '/user-settings', '/profile'];

async function s1Baseline() {
  const api = await startApi();
  try {
    let bad = []; let n = 0;
    for (let v = 1; v <= 5; v += 1) for (const p of READS) { const r = await request(api.port, { pathname: p, token: tok(v) }); n += 1; if (r.status !== 200) bad.push(`${p}=${r.status}`); }
    check('S1 baseline', `${n} reads across 5 users all answer 200`, bad.length === 0, bad.slice(0, 4).join(' '));
  } finally { api.stop(); }
}

async function s2Overload() {
  const api = await startApi({ ADMISSION_MAX_CONCURRENT: '2', ADMISSION_HEAVY_MAX: '1', ADMISSION_MAX_WAIT_MS: '800' });
  try {
    const rs = await Promise.all(Array.from({ length: 80 }, (_, i) => request(api.port, { pathname: '/spend-report?period=year', token: tok((i % 20) + 1) })));
    const codes = {}; rs.forEach((r) => { codes[r.status] = (codes[r.status] || 0) + 1; });
    const shed = rs.filter((r) => r.status === 503);
    check('S2 overload', 'only 200 or 503 under overload (never 500)', Object.keys(codes).every((c) => c === '200' || c === '503'), JSON.stringify(codes));
    check('S2 overload', 'excess load is actually shed (some 503)', shed.length > 0, JSON.stringify(codes));
    check('S2 overload', 'every 503 has whole-second Retry-After and a small server_busy body', shed.every((r) => retryAfterOk(r) && r.json && r.json.error === 'server_busy' && r.body.length < 200), shed[0] && JSON.stringify(shed[0].headers));
    await sleep(1500);
    const t = Date.now(); const after = await request(api.port, { pathname: '/home-summary', token: tok(3) });
    check('S2 overload', 'recovers: normal request answers 200 quickly once load stops', after.status === 200 && Date.now() - t < 2000, `status=${after.status}`);
    check('S2 overload', 'liveness stays up', (await request(api.port, { pathname: '/health' })).status === 200);
  } finally { api.stop(); }
}

async function s3Abort() {
  const api = await startApi({ ADMISSION_MAX_CONCURRENT: '1', ADMISSION_MAX_WAIT_MS: '5000' });
  try {
    const aborted = Array.from({ length: 25 }, (_, i) => request(api.port, { pathname: '/spend-report?period=year', token: tok((i % 20) + 1), abortAfterMs: 40 }));
    await Promise.all(aborted);
    const t = Date.now();
    const rs = await Promise.all([1, 2, 3].map((n) => request(api.port, { pathname: '/home-summary', token: tok(n) })));
    check('S3 abandoned requests', 'line is not wedged after 25 abandoned requests: next 3 requests answer 200', rs.every((r) => r.status === 200), rs.map((r) => r.status).join(','));
    check('S3 abandoned requests', 'and they are served promptly (< 4 s)', Date.now() - t < 4000, `${Date.now() - t}ms`);
  } finally { api.stop(); }
}

async function s4AuthOutage() {
  const api = await startApi();
  try {
    authMode = 'down';
    const r = await request(api.port, { pathname: '/user-cards', token: tok(20) });
    check('S4 auth outage', 'private route answers 503 (not 500/401) when the auth service is down', r.status === 503, `status=${r.status}`);
    check('S4 auth outage', '...with Retry-After', retryAfterOk(r), JSON.stringify(r.headers['retry-after']));
    check('S4 auth outage', 'public/liveness routes keep working', (await request(api.port, { pathname: '/health' })).status === 200 && (await request(api.port, { pathname: '/categories' })).status === 200);
    authMode = 'ok';
    const back = await request(api.port, { pathname: '/user-cards', token: tok(20) });
    check('S4 auth outage', 'recovers immediately when the auth service is back (failures are not cached)', back.status === 200, `status=${back.status}`);
  } finally { authMode = 'ok'; api.stop(); }
}

async function s5DbOutage() {
  if (!CONTAINER) { console.log('SKIP  [S5 database outage] set SCEN_DOCKER_CONTAINER to enable'); return; }
  const api = await startApi();
  try {
    const base5 = await request(api.port, { pathname: '/home-summary', token: tok(6) });
    check('S5 database outage', 'baseline request OK', base5.status === 200, `status=${base5.status} ${base5.body.slice(0, 120)} ${base5.error || ''} stderr=${api.stderr().slice(-300)}`);
    execSync(`docker stop ${CONTAINER}`, { stdio: 'ignore' });
    const rs = await Promise.all([6, 7, 8, 9, 10, 11, 12, 13].map((n) => request(api.port, { pathname: n % 2 ? '/home-summary' : '/user-cards', token: tok(n) })));
    const codes = {}; rs.forEach((r) => { codes[r.status] = (codes[r.status] || 0) + 1; });
    check('S5 database outage', 'requests during the outage answer 503, never 500', rs.every((r) => r.status === 503), JSON.stringify(codes) + ' ' + rs.filter((r) => r.status !== 503).map((r) => `${r.status}:${r.error || r.body.slice(0, 80)}`).join(' | '));
    check('S5 database outage', '...each with Retry-After', rs.every(retryAfterOk), JSON.stringify(rs[0].headers['retry-after']));
    check('S5 database outage', 'liveness stays up and the process did not crash', (await request(api.port, { pathname: '/health' })).status === 200 && api.isAlive());
    execSync(`docker start ${CONTAINER}`, { stdio: 'ignore' });
    let ok = false; const t = Date.now();
    while (Date.now() - t < 45000) { await sleep(1000); const r = await request(api.port, { pathname: '/home-summary', token: tok(7) }); if (r.status === 200) { ok = true; break; } }
    check('S5 database outage', `API recovers by itself after the database returns (${Math.round((Date.now() - t) / 1000)}s)`, ok);
    check('S5 database outage', 'requests are normal again (all 200)', (await Promise.all([6, 7, 8].map((n) => request(api.port, { pathname: '/user-cards', token: tok(n) })))).every((r) => r.status === 200));
  } finally { try { execSync(`docker start ${CONTAINER}`, { stdio: 'ignore' }); } catch (_) { /* already up */ } api.stop(); }
}

async function s6Pushes() {
  const api = await startApi();
  try {
    const t = tok(2);
    const reg = await request(api.port, { method: 'POST', pathname: '/sync/register-device', token: t, body: { platform: 'android', appVersion: 'scenario' } });
    const deviceId = reg.json && reg.json.deviceId;
    check('S6 concurrent pushes', 'device registers (201)', reg.status === 201 && !!deviceId, `status=${reg.status}`);
    const list = await request(api.port, { pathname: '/transactions?pageSize=40', token: t });
    const ids = (list.json.transactions || []).slice(0, 40).map((x) => x.id);
    check('S6 concurrent pushes', 'has 40 transactions to edit', ids.length === 40);
    const stamp = Date.now(); let seq = 0;
    const mk = (start) => ids.slice(start, start + 8).map((entityId, i) => ({ entity: 'transactions', entityId, op: 'update', clientSeq: (seq += 1), payload: { note: `scen ${stamp} ${start + i}` }, fieldClocks: { note: stamp + start + i } }));
    const batches = [0, 8, 16, 24, 32].map(mk);
    const rs = await Promise.all(batches.map((changes) => request(api.port, { method: 'POST', pathname: '/sync/push', token: t, body: { deviceId, strict: true, changes } })));
    check('S6 concurrent pushes', '5 simultaneous pushes of one user all answer 200', rs.every((r) => r.status === 200), rs.map((r) => r.status).join(','));
    const applied = rs.reduce((a, r) => a + ((r.json && r.json.results) || []).filter((x) => x.applied).length, 0);
    check('S6 concurrent pushes', 'all 40 changes applied, none rejected', applied === 40, `applied=${applied}`);
    const after = await request(api.port, { pathname: '/transactions?pageSize=40', token: t });
    const notes = new Map((after.json.transactions || []).map((x) => [x.id, x.note]));
    check('S6 concurrent pushes', 'every edit is visible afterwards (no lost update)', ids.every((id, i) => notes.get(id) === `scen ${stamp} ${i}`), `sample=${notes.get(ids[0])}`);
    const replay = await Promise.all(batches.map((changes) => request(api.port, { method: 'POST', pathname: '/sync/push', token: t, body: { deviceId, strict: true, changes } })));
    check('S6 concurrent pushes', 'replaying the same pushes is accepted (200, nothing rejected)', replay.every((r) => r.status === 200 && ((r.json && r.json.results) || []).every((x) => x.reason !== 'rejected' && x.reason !== 'malformed')), replay.map((r) => r.status).join(','));
    const again = await request(api.port, { pathname: '/transactions?pageSize=40', token: t });
    const notes2 = new Map((again.json.transactions || []).map((x) => [x.id, x.note]));
    check('S6 concurrent pushes', 'state is unchanged after the replay', ids.every((id) => notes2.get(id) === notes.get(id)));
    const unknown = await request(api.port, { method: 'POST', pathname: '/sync/push', token: t, body: { deviceId: '00000000-0000-4000-8000-000000000999', strict: true, changes: mk(0) } });
    check('S6 concurrent pushes', 'unregistered device is refused with 409 (client can re-register)', unknown.status === 409, `status=${unknown.status}`);
  } finally { api.stop(); }
}

async function s9TwoDevices() {
  const api = await startApi();
  try {
    const t = tok(5);
    const reg = async () => (await request(api.port, { method: 'POST', pathname: '/sync/register-device', token: t, body: { platform: 'android', appVersion: 'scenario' } })).json.deviceId;
    const devA = await reg(); const devB = await reg();
    check('S9 two devices', 'two devices register with different ids', !!devA && !!devB && devA !== devB);
    const list = await request(api.port, { pathname: '/transactions?pageSize=5', token: t });
    const X = list.json.transactions[0].id;
    const T1 = Date.now(); const T0 = T1 - 60000;
    const push = (deviceId, note, clock, seq) => request(api.port, { method: 'POST', pathname: '/sync/push', token: t,
      body: { deviceId, strict: true, changes: [{ entity: 'transactions', entityId: X, op: 'update', clientSeq: seq, payload: { note }, fieldClocks: { note: clock } }] } });
    const a = await push(devA, 'from device A (newer)', T1, 1);
    check('S9 two devices', 'device A edit is applied', a.status === 200 && a.json.results[0].applied === true, JSON.stringify(a.json));
    const b = await push(devB, 'from device B (older clock)', T0, 1);
    const rb = b.json && b.json.results && b.json.results[0];
    check('S9 two devices', 'the older edit from device B loses (last-writer-wins by field clock) and is reported as a conflict', b.status === 200 && rb && (rb.applied === false || rb.conflicts > 0), JSON.stringify(b.json));
    const after = await request(api.port, { pathname: `/transactions/${X}`, token: t });
    const note = (after.json.transaction || after.json).note;
    check('S9 two devices', 'the newer edit is what everyone sees', note === 'from device A (newer)', `note=${note}`);
    const pull = await request(api.port, { pathname: `/sync/pull?deviceId=${devB}&since=0&limit=25`, token: t });
    const changes = (pull.json && pull.json.changes) || [];
    check('S9 two devices', 'device B pulls the change made by device A', pull.status === 200 && changes.some((c) => (c.entity_id || c.entityId) === X && c.entity === 'transactions'), JSON.stringify(pull.json).slice(0, 200));
    check('S9 two devices', 'device B does not receive its own change back', !changes.some((c) => (c.device_id || c.deviceId) === devB));
    const seq = pull.json.latestServerSeq;
    const ack = await request(api.port, { method: 'POST', pathname: '/sync/ack', token: t, body: { deviceId: devB, serverSeq: seq } });
    check('S9 two devices', 'ack is accepted', ack.status === 200 || ack.status === 204, `status=${ack.status}`);
    const again = await request(api.port, { pathname: `/sync/pull?deviceId=${devB}&since=${seq}&limit=25`, token: t });
    check('S9 two devices', 'nothing new after the cursor (hasMore=false, no changes)', again.status === 200 && (again.json.changes || []).length === 0 && !again.json.hasMore, JSON.stringify(again.json).slice(0, 160));
    const other = await request(api.port, { pathname: `/sync/pull?deviceId=${devA}&since=0&limit=25`, token: tok(6) });
    check('S9 two devices', 'another user cannot pull this device stream (409 or empty, never the data)', other.status === 409 || ((other.json.changes || []).length === 0), `status=${other.status}`);
  } finally { api.stop(); }
}

async function s7BadInput() {
  const api = await startApi();
  try {
    const t = tok(4); const codes = [];
    const rec = async (label, p, expected) => { const r = await request(api.port, p); codes.push(r.status); check('S7 bad input', `${label} -> ${expected.join('/')}`, expected.includes(r.status), `status=${r.status}`); return r; };
    await rec('no token', { pathname: '/user-cards' }, [401]);
    await rec('garbage token', { pathname: '/user-cards', token: 'not.a.token' }, [401]);
    await rec('unknown route', { pathname: '/nope', token: t }, [404]);
    await rec('invalid JSON body', { method: 'POST', pathname: '/sync/push', token: t, body: '{not json', headers: {} }, [400]);
    await rec('body over the 1 MiB push limit', { method: 'POST', pathname: '/sync/push', token: t, body: { deviceId: 'x', changes: [{ pad: 'y'.repeat(1100 * 1024) }] } }, [413]);
    await rec('too many changes', { method: 'POST', pathname: '/sync/push', token: t, body: { deviceId: '00000000-0000-4000-8000-000000000001', strict: true, changes: Array.from({ length: 201 }, (_, i) => ({ entity: 'transactions', entityId: '00000000-0000-4000-8000-000000000001', op: 'update', clientSeq: i, payload: {}, fieldClocks: {} })) } }, [413, 400]);
    await rec('unknown report period', { pathname: '/spend-report?period=bogus', token: t }, [400]);
    await rec('invalid time zone falls back', { pathname: '/home-summary?tz=Mars/Phobos', token: t }, [200]);
    await rec('quote/SQL-looking search text', { pathname: "/transactions?q=%27%3BDROP%20TABLE%20transactions%3B--&pageSize=5", token: t }, [200]);
    await rec('page size far too large', { pathname: '/transactions?pageSize=99999', token: t }, [400]);
    await rec('malformed uuid in path', { pathname: '/transactions/not-a-uuid', token: t }, [400, 404]);
    check('S7 bad input', 'no input produced a 500', !codes.includes(500), codes.join(','));
    check('S7 bad input', 'server is still healthy afterwards', (await request(api.port, { pathname: '/home-summary', token: t })).status === 200);
  } finally { api.stop(); }
}

async function s8Burst() {
  const api = await startApi();
  try {
    const vus = Array.from({ length: 100 }, (_, v) => (async () => {
      const out = [];
      for (const p of READS) { let r = await request(api.port, { pathname: p, token: tok((v % 20) + 1) }); let tries = 0;
        while (r.status === 503 && tries < 5) { tries += 1; await sleep((Number(r.headers['retry-after']) || 5) * 1000); r = await request(api.port, { pathname: p, token: tok((v % 20) + 1) }); }
        out.push(r.status); }
      return out;
    })());
    const t = Date.now(); const all = (await Promise.all(vus)).flat();
    const bad = all.filter((s) => s !== 200);
    check('S8 100-user burst', `1300 requests complete (retrying 503 like the app) in ${Math.round((Date.now() - t) / 1000)}s with every final answer 200`, bad.length === 0, `non-200: ${bad.length}`);
  } finally { api.stop(); }
}

(async () => {
  await new Promise((r) => auth.listen(0, '127.0.0.1', r));
  const only = (process.argv[2] || '').toLowerCase();
  const all = { s1: s1Baseline, s2: s2Overload, s3: s3Abort, s4: s4AuthOutage, s6: s6Pushes, s9: s9TwoDevices, s7: s7BadInput, s8: s8Burst, s5: s5DbOutage };
  for (const [k, fn] of Object.entries(all)) {
    if (only && only !== k) continue;
    try { await fn(); } catch (e) { check(k.toUpperCase(), 'scenario ran without an exception', false, e.message.slice(0, 300)); }
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  auth.close();
  process.exit(failed.length ? 1 : 0);
})();
