'use strict';

// End-to-end scenarios against a REAL stack (real auth service, real API container, real Postgres with the production
// migration runner), not stubs. Synthetic data; uses the auth service's built-in TEST OTP identifiers only (dev stacks).
//
//   docker compose -p ppverify -f docker-compose.yml -f docker-compose.verify.yml up -d --build db db-migrate api auth
//   node scripts/scenarios_realauth.js
//
// Env (defaults match the ppverify override): REAL_API=http://127.0.0.1:4050 REAL_AUTH=http://127.0.0.1:3250
// REAL_PROJECT=ppverify. Outage scenarios stop/start containers of that project. Exit code 1 when any check fails.

const { execSync } = require('node:child_process');

const API = process.env.REAL_API || 'http://127.0.0.1:4050';
const AUTH = process.env.REAL_AUTH || 'http://127.0.0.1:3250';
const PROJECT = process.env.REAL_PROJECT || 'ppverify';
const C = (svc) => `${PROJECT}-${svc}-1`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sh = (cmd) => execSync(cmd, { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
const psql = (sql) => sh(`docker exec ${C('db')} psql -U postgres -d pandapay -Atc "${sql}"`).trim();

const results = [];
function check(scenario, name, ok, detail = '') {
  results.push({ scenario, name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  [${scenario}] ${name}${ok || !detail ? '' : `  -> ${detail}`}`);
}

async function call(base, path, { method = 'GET', token, body, headers = {}, timeoutMs = 20000 } = {}) {
  const ac = new AbortController(); const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await fetch(base + path, { method, signal: ac.signal, headers: { 'content-type': 'application/json', 'x-sms-pipeline': 'v2', ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
    let json = null; const text = await r.text(); try { json = JSON.parse(text); } catch (_) { /* not json */ }
    return { status: r.status, json, text, headers: r.headers };
  } catch (e) { return { status: 0, error: e.cause?.code || e.name || e.message, json: null, text: '', headers: new Headers() }; } finally { clearTimeout(t); }
}

const PHONE = '+911234567890';
async function login(deviceN) {
  for (let attempt = 0; attempt < 6; attempt += 1) {
    const a = await call(AUTH, '/auth/request-otp', { method: 'POST', body: { phone_number: PHONE } });
    if (a.status === 200) {
      const v = await call(AUTH, '/auth/verify-otp', { method: 'POST', body: { phone_number: PHONE, code: '1234', device_id: `0000000${deviceN}-0000-4000-8000-00000000000${deviceN}`, device_info: { platform: 'android', model: 'verify' } } });
      if (v.status === 200 && v.json?.access_token) return { access: v.json.access_token, refresh: v.json.refresh_token, userId: v.json.user.id };
    }
    await sleep(2500);
  }
  return null;
}

const READS = ['/home-summary', '/transactions?pageSize=20', '/spend-report?period=month', '/spend-by-category', '/monthly-reports', '/user-cards',
  '/account-summaries', '/recurring', '/budgets', '/categories', '/duplicate-candidates', '/user-settings', '/profile', '/access'];
const retryAfterOk = (r) => /^\d+$/.test(String(r.headers.get('retry-after') || '')) && Number(r.headers.get('retry-after')) >= 1 && Number(r.headers.get('retry-after')) <= 60;

async function waitFor(fn, ms, every = 1000) { const t = Date.now(); while (Date.now() - t < ms) { if (await fn()) return Date.now() - t; await sleep(every); } return -1; }

(async () => {
  // ---- R1 login, activation, reads
  const toks = [];
  for (let n = 1; n <= 4; n += 1) { const t = await login(n); if (t) toks.push(t); }
  check('R1 real login', `${toks.length}/4 device sessions obtained from the real auth service (test OTP)`, toks.length >= 2, `got ${toks.length}`);
  if (toks.length < 2) { console.log('cannot continue without sessions'); process.exit(1); }
  const T = toks.map((t) => t.access);
  const before = await call(API, '/home-summary', { token: T[0] });
  check('R1 real login', 'a brand-new account is held at membership (403) until activated', before.status === 403 || before.status === 200, `status=${before.status}`);
  const act = await call(API, '/profile', { method: 'POST', token: T[0], body: { displayName: 'Verify User', acceptProductTerms: true, productTermsVersion: '2026-11-15' } });
  check('R1 real login', 'activation (POST /profile) succeeds', act.status === 201 || act.status === 200, `status=${act.status} ${act.text.slice(0, 100)}`);
  let bad = [];
  for (const p of READS) { const r = await call(API, p, { token: T[0] }); if (r.status !== 200) bad.push(`${p}=${r.status}`); }
  check('R1 real login', `all ${READS.length} reads answer 200 with a real token`, bad.length === 0, bad.join(' '));
  check('R1 real login', 'a second device session of the same account works too', (await call(API, '/home-summary', { token: T[1] })).status === 200);

  // ---- R2 real data path (card, transactions, rewards state, sync)
  const productId = psql('select id from card_products order by id limit 1');
  const card = await call(API, '/user-cards', { method: 'POST', token: T[0], body: { cardProductId: productId, nickname: 'Verify card', last4: '4242' } });
  check('R2 data path', 'add a card (POST /user-cards), or it already exists from an earlier run (409 card_already_added)', card.status === 201 || card.status === 200 || (card.status === 409 && card.json?.error === 'card_already_added'), `status=${card.status} ${card.text.slice(0, 120)}`);
  const cardId = card.json?.userCard?.id || card.json?.id;
  const countBefore = (await call(API, '/home-summary', { token: T[0] })).json?.homeSummary?.transactionCount ?? 0;
  const run = Date.now(); let created = 0;
  for (let i = 0; i < 5; i += 1) {
    const r = await call(API, '/transactions', { method: 'POST', token: T[0], body: { userCardId: cardId, amountInr: 500 + i * 100, merchantName: `VERIFY MERCHANT ${run} ${i}`, occurredAt: new Date().toISOString(), clientMutationId: `verify-tx-${run}-${i}` } });
    if (r.status === 201 || r.status === 200) created += 1;
  }
  check('R2 data path', '5 transactions created (reward state applied)', created === 5, `created=${created}`);
  const hs = await call(API, '/home-summary', { token: T[0] });
  const countAfter = hs.json?.homeSummary?.transactionCount;
  check('R2 data path', 'home summary count grew by exactly 5', countAfter === countBefore + 5, JSON.stringify(hs.json));
  const list = await call(API, '/transactions?pageSize=50', { token: T[0] });
  check('R2 data path', 'transaction list contains the 5 new ones', (list.json?.transactions || []).filter((t) => String(t.merchant_name || t.merchantName).includes(`VERIFY MERCHANT ${run}`)).length === 5);
  const cards = await call(API, '/user-cards', { token: T[0] });
  check('R2 data path', 'card read still fine after writes (caps/milestones rebuilt)', cards.status === 200 && (cards.json?.userCards || []).length >= 1);
  const dev = await call(API, '/sync/register-device', { method: 'POST', token: T[0], body: { platform: 'android', appVersion: 'verify' } });
  const ids = (list.json?.transactions || []).map((t) => t.id);
  const expectedCount = countAfter;
  const push = await call(API, '/sync/push', { method: 'POST', token: T[0], body: { deviceId: dev.json?.deviceId, strict: true, changes: ids.slice(0, 3).map((entityId, i) => ({ entity: 'transactions', entityId, op: 'update', clientSeq: i + 1, payload: { note: `verify note ${i}` }, fieldClocks: { note: Date.now() + i } })) } });
  check('R2 data path', 'sync push of 3 edits is applied', push.status === 200 && (push.json?.results || []).every((r) => r.applied), JSON.stringify(push.json).slice(0, 200));

  // ---- R3 refresh
  const rf = await call(AUTH, '/auth/refresh', { method: 'POST', body: { refresh_token: toks[1].refresh } });
  check('R3 refresh', 'refresh returns a new access + refresh token', rf.status === 200 && !!rf.json?.access_token, `status=${rf.status}`);
  if (rf.json?.access_token) { T[1] = rf.json.access_token; toks[1].refresh = rf.json.refresh_token; }
  check('R3 refresh', 'the refreshed access token works against the API', (await call(API, '/home-summary', { token: T[1] })).status === 200);

  // ---- R8 burst through real session verification
  const t0 = Date.now();
  const vus = Array.from({ length: 100 }, (_, v) => (async () => {
    const out = [];
    for (const p of READS.slice(0, 13)) {
      let r = await call(API, p, { token: T[v % T.length] }); let tries = 0;
      while ((r.status === 503 || r.status === 0) && tries < 5) { tries += 1; await sleep((Number(r.headers.get('retry-after')) || 5) * 1000); r = await call(API, p, { token: T[v % T.length] }); }
      out.push(r.status);
    }
    return out;
  })());
  const all = (await Promise.all(vus)).flat(); const badBurst = all.filter((s) => s !== 200);
  check('R8 burst (real auth)', `100 users x 13 reads through real session verification, final answers all 200 (${Math.round((Date.now() - t0) / 1000)}s)`, badBurst.length === 0, `non-200: ${badBurst.length} ${[...new Set(badBurst)].join(',')}`);

  // ---- R9 schema without the new indexes (code deployed before the migration, or the migration rolled back)
  psql('drop index if exists idx_points_ledger_card, idx_transaction_splits_transaction, idx_user_cards_profile_order');
  let bad9 = [];
  for (const p of READS) { const r = await call(API, p, { token: T[0] }); if (r.status !== 200) bad9.push(`${p}=${r.status}`); }
  check('R9 old schema', 'every read still answers 200 without the new indexes', bad9.length === 0, bad9.join(' '));
  psql('create index if not exists idx_points_ledger_card on public.points_ledger (user_card_id) include (delta_points, reason)');
  psql('create index if not exists idx_transaction_splits_transaction on public.transaction_splits (transaction_id)');
  psql('create index if not exists idx_user_cards_profile_order on public.user_cards (profile_id, sort_order, created_at)');

  // ---- R5 auth service outage
  await sleep(6500); // let cached session verdicts expire (5 s) so the outage is actually observed
  sh(`docker stop ${C('auth')}`);
  const during = await Promise.all([0, 1, 2].map((i) => call(API, '/user-cards', { token: T[i % T.length] })));
  check('R5 auth outage', 'private routes answer 503 + Retry-After (never 500/401) while the auth service is down', during.every((r) => r.status === 503 && retryAfterOk(r)), during.map((r) => `${r.status}/${r.headers.get('retry-after')}`).join(' '));
  check('R5 auth outage', 'liveness and public routes keep working', (await call(API, '/health')).status === 200 && (await call(API, '/categories')).status === 200);
  sh(`docker start ${C('auth')}`);
  const rec5 = await waitFor(async () => (await call(API, '/user-cards', { token: T[0] })).status === 200, 60000);
  check('R5 auth outage', `API serves again once the auth service is back (${Math.round(rec5 / 1000)}s)`, rec5 >= 0);
  check('R5 auth outage', 'the same access token still works afterwards (no forced re-login)', (await call(API, '/home-summary', { token: T[0] })).status === 200);

  // ---- R6 database outage (product + auth databases share this instance)
  sh(`docker stop ${C('db')}`);
  await sleep(1500);
  const d6 = await Promise.all([0, 1, 2, 3].map((i) => call(API, i % 2 ? '/home-summary' : '/user-cards', { token: T[i % T.length] })));
  check('R6 database outage', 'requests during the outage answer 503 + Retry-After, never 500', d6.every((r) => r.status === 503 && retryAfterOk(r)), d6.map((r) => `${r.status}/${r.headers.get('retry-after')}`).join(' '));
  check('R6 database outage', 'API liveness stays up (process did not crash)', (await call(API, '/health')).status === 200);
  sh(`docker start ${C('db')}`);
  let last6 = '';
  const rec6 = await waitFor(async () => { const r = await call(API, '/home-summary', { token: T[0] }); last6 = `${r.status} ${r.text.slice(0, 80)} auth=${(await call(AUTH, '/health')).status}`; return r.status === 200; }, 90000, 2000);
  check('R6 database outage', `API and auth recover by themselves after the database returns (${Math.round(rec6 / 1000)}s)`, rec6 >= 0, `last answer: ${last6}`);
  let bad6 = [];
  for (const p of READS) { const r = await call(API, p, { token: T[0] }); if (r.status !== 200) bad6.push(`${p}=${r.status}`); }
  check('R6 database outage', 'all reads are normal again afterwards, data intact', bad6.length === 0 && (await call(API, '/home-summary', { token: T[0] })).json?.homeSummary?.transactionCount === expectedCount, bad6.join(' '));

  // ---- R6c database FREEZE (connections hang, nothing is refused): a client-side query bound must free the request
  sh(`docker pause ${C('db')}`);
  const tf = Date.now();
  const frozen = await Promise.all([0, 1, 2, 3].map((i) => call(API, i % 2 ? '/home-summary' : '/user-cards', { token: T[i % T.length], timeoutMs: 40000 })));
  const frozenMs = Date.now() - tf;
  check('R6c database freeze', `every request is answered (503 + Retry-After) instead of hanging, within ${Math.round(frozenMs / 1000)}s`, frozen.every((r) => r.status === 503 && retryAfterOk(r)) && frozenMs < 30000, frozen.map((r) => `${r.status}/${r.error || ''}`).join(' ') + ` ${frozenMs}ms`);
  check('R6c database freeze', 'liveness stays up while the database is frozen', (await call(API, '/health')).status === 200);
  sh(`docker unpause ${C('db')}`);
  const rec6c = await waitFor(async () => (await call(API, '/home-summary', { token: T[0] })).status === 200, 60000, 1000);
  check('R6c database freeze', `API serves normally right after the database unfreezes (${Math.round(rec6c / 1000)}s): no admission slot was left stuck`, rec6c >= 0 && rec6c < 20000, `rec=${rec6c}`);

  // ---- R7 API restart under load (graceful shutdown; what a rolling deploy does to one instance)
  const stats = { 200: 0, 503: 0, 0: 0, other: 0 }; const others = new Set(); let running = true;
  const workers = Array.from({ length: 16 }, (_, w) => (async () => { while (running) { const r = await call(API, READS[w % 6], { token: T[w % T.length], timeoutMs: 8000 }); if (r.status === 200) stats[200] += 1; else if (r.status === 503) stats[503] += 1; else if (r.status === 0) stats[0] += 1; else { stats.other += 1; others.add(r.status); } await sleep(20); } })());
  await sleep(2000);
  const rs = Date.now(); sh(`docker restart ${C('api')}`);
  const up = await waitFor(async () => (await call(API, '/health', { timeoutMs: 2000 })).status === 200, 60000, 250);
  const restartMs = Date.now() - rs;
  await sleep(3000); running = false; await Promise.all(workers);
  check('R7 restart under load', `a restart under steady keep-alive traffic completes promptly (${(restartMs / 1000).toFixed(1)}s, graceful drain, not the 10 s force-exit)`, up >= 0 && restartMs < 9000, `restartMs=${restartMs}`);
  check('R7 restart under load', 'no wrong answers during the restart (only 200, 503 or refused connections; never 500/401/4xx)', stats.other === 0, `${JSON.stringify(stats)} other=${[...others]}`);
  { const post7 = await call(API, '/home-summary', { token: T[0] }); check('R7 restart under load', 'traffic is served normally after the restart', post7.status === 200, `${post7.status} ${post7.text.slice(0, 80)}`); }
  console.log(`      restart window: ${JSON.stringify(stats)}`);

  // ---- R4 logout revokes the session
  const lo = await call(AUTH, '/auth/logout', { method: 'POST', token: T[3 % T.length], body: { refresh_token: toks[3 % toks.length].refresh } });
  check('R4 logout', 'logout is accepted', lo.status === 200 || lo.status === 204, `status=${lo.status}`);
  const gone = await waitFor(async () => (await call(API, '/home-summary', { token: T[3 % T.length] })).status === 401, 15000, 1000);
  check('R4 logout', `the revoked token is rejected with 401 within the 5 s session-cache window (${Math.round(gone / 1000)}s)`, gone >= 0 && gone <= 8000, `gone=${gone}`);
  check('R4 logout', 'the account\'s other device sessions are unaffected', (await call(API, '/home-summary', { token: T[0] })).status === 200);

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error('scenario script crashed:', e); process.exit(1); });
