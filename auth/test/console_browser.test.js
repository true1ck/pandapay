'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { randomBytes, createHash } = require('node:crypto');
const express = require('express');
const { createConsoleBrowserRouter, validateOrigin, upstream, cookie } = require('../src/services/consoleBrowser');

const ORIGIN = 'https://console.example.test';
const ACCESS = 'synthetic.private.access-jwt';
const REFRESH = 'synthetic-private-refresh-token';

function memoryStore() {
  const sessions = new Map();
  let cleanups = 0;
  return {
    sessions,
    get cleanups() { return cleanups; },
    async create(state) {
      const id = randomBytes(32).toString('base64url'), csrf = randomBytes(32).toString('base64url');
      sessions.set(id, { ...state, csrf });
      return { id, csrf };
    },
    async destroy(id) { sessions.delete(id); },
    async withSession(id, work) {
      if (!sessions.has(id)) return null;
      const state = sessions.get(id);
      const result = await work(state);
      if (result?.destroy) sessions.delete(id);
      return result;
    },
    async cleanup() { cleanups++; },
  };
}

async function server(t, app) {
  const instance = http.createServer(app);
  await new Promise((resolve, reject) => { instance.once('error', reject); instance.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { instance.closeAllConnections(); await new Promise(resolve => instance.close(resolve)); });
  return `http://127.0.0.1:${instance.address().port}`;
}

async function harness(t, { authHandler, apiHandler, fetchImpl, store = memoryStore(), origin = ORIGIN, local = false } = {}) {
  const calls = [], logs = [];
  let refreshes = 0;
  const auth = express(); auth.use(express.json());
  auth.use(async (req, res) => {
    calls.push({ source: 'auth', method: req.method, path: req.url, headers: req.headers, body: req.body });
    res.setHeader('X-Upstream-Secret', 'private-upstream-header');
    res.setHeader('Set-Cookie', 'private_auth=private-cookie; HttpOnly');
    if (authHandler && await authHandler(req, res, calls)) return;
    if (/\/verify-(?:email-)?otp$/.test(req.path)) return res.json({ access_token: ACCESS, refresh_token: REFRESH, user: { private: 'not-for-browser' } });
    if (req.path === '/auth/refresh') { refreshes++; return res.json({ access_token: ACCESS+'-'+refreshes, refresh_token: REFRESH+'-'+refreshes }); }
    res.json({ ok: true, private: 'not-for-browser' });
  });
  const api = express(); api.use(express.json());
  api.use(async (req, res) => {
    calls.push({ source: 'api', method: req.method, path: req.url, headers: req.headers, body: req.body });
    res.setHeader('X-Upstream-Secret', 'private-upstream-header');
    res.setHeader('Set-Cookie', 'private_api=private-cookie');
    if (apiHandler && await apiHandler(req, res, calls)) return;
    res.json(req.path === '/admin/me' ? { isAdmin: true } : { ok: true, cards: [] });
  });
  const authBase = await server(t, auth), apiBase = await server(t, api);
  const browser = express(); browser.set('trust proxy', false); browser.use(express.json());
  browser.use('/bff', createConsoleBrowserRouter({ origin, local, authUpstream: authBase, apiUpstream: apiBase, store, ...(fetchImpl ? { fetchImpl } : {}), logger: { error: value => logs.push(value) } }));
  const base = await server(t, browser);
  async function request(path, { method = 'GET', headers = {}, body, cookie: sessionCookie, csrf, raw = false } = {}) {
    const response = await fetch(base+'/bff'+path, {
      method, redirect: 'manual',
      headers: { Origin: origin, 'X-Console-Request': '1', 'Sec-Fetch-Site': 'same-origin', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(sessionCookie ? { Cookie: sessionCookie } : {}), ...(csrf ? { 'X-CSRF-Token': csrf } : {}), ...headers },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    let data; try { data = text ? JSON.parse(text) : {}; } catch { data = text; }
    return { status: response.status, headers: response.headers, data, text };
  }
  async function login() {
    const response = await request('/verify-email-otp', { method: 'POST', body: { email: 'operator@example.test', code: '4826' } });
    assert.equal(response.status, 200);
    const sessionCookie = response.headers.get('set-cookie').split(';')[0];
    return { ...response, sessionCookie, csrf: response.data.csrfToken };
  }
  return { calls, logs, store, request, login, authBase, apiBase };
}

test('console origin/upstream configuration rejects credentials, remote plaintext and noncanonical origins', () => {
  assert.equal(validateOrigin(ORIGIN), ORIGIN);
  assert.equal(validateOrigin('http://localhost:4000', { local: true }), 'http://localhost:4000');
  for (const value of ['http://console.example.test', ORIGIN+'/', ORIGIN+'/path', 'https://user:pass@console.example.test', 'null']) assert.throws(() => validateOrigin(value));
  for (const value of ['http://remote.example.test', 'https://example.test/path', 'https://user:pass@example.test', 'https://example.test/?secret=x']) assert.throws(() => upstream(value));
  assert.equal(upstream('http://auth:3000'), 'http://auth:3000');
});

test('duplicate cookies cannot select an ambiguous browser identity', () => {
  assert.equal(cookie({ headers: { cookie: 'x=1; __Host-pandapay_console=abc' } }, '__Host-pandapay_console'), 'abc');
  assert.equal(cookie({ headers: { cookie: '__Host-pandapay_console=a; __Host-pandapay_console=b' } }, '__Host-pandapay_console'), null);
});

test('browser requests require custom header, exact origin and non-cross-site fetch metadata', async t => {
  const h = await harness(t);
  for (const headers of [
    { 'X-Console-Request': '' }, { Origin: 'https://evil.example.test' }, { Origin: ORIGIN+'.evil.test' },
    { 'Sec-Fetch-Site': 'cross-site' }, { Origin: 'null' },
  ]) assert.equal((await h.request('/request-email-otp', { method: 'POST', body: { email: 'operator@example.test' }, headers })).status, 403);
  assert.equal((await h.request('/request-email-otp', { method: 'POST', body: {}, headers: { Origin: '' } })).status, 403);
  assert.equal(h.calls.length, 0);
});

test('OTP request and verification use bounded fields and forward trusted IP instead of raw XFF', async t => {
  const h = await harness(t);
  const requested = await h.request('/request-email-otp', { method: 'POST', headers: { 'X-Forwarded-For': '198.51.100.88, 203.0.113.10' }, body: { email: 'operator@example.test', is_signup: true, recovery_only: true, attacker: 'ignored' } });
  assert.equal(requested.status, 200); assert.deepEqual(requested.data, { success: true });
  assert.deepEqual(h.calls[0].body, { email: 'operator@example.test' });
  assert.equal(h.calls[0].headers['x-forwarded-for'], '127.0.0.1');
  assert.equal(requested.headers.get('x-upstream-secret'), null);
  assert.equal(requested.headers.get('set-cookie'), null);
  const login = await h.login();
  const verify = h.calls.find(row => row.path === '/auth/verify-email-otp');
  assert.deepEqual(Object.keys(verify.body).sort(), ['code', 'device_id', 'email']);
  assert.match(verify.body.device_id, /^console-[0-9a-f-]{36}$/);
  assert.equal(verify.headers['x-forwarded-for'], '127.0.0.1');
  assert.equal(login.data.authenticated, true);
});

test('secure login returns only CSRF state and sets a host-only HttpOnly Strict cookie', async t => {
  const h = await harness(t), login = await h.login();
  assert.deepEqual(Object.keys(login.data).sort(), ['authenticated', 'csrfToken']);
  const set = login.headers.get('set-cookie');
  assert.match(set, /^__Host-pandapay_console=[A-Za-z0-9_-]{43};/);
  for (const text of ['Path=/', 'HttpOnly', 'SameSite=Strict', 'Secure', 'Max-Age=43200']) assert.ok(set.includes(text));
  assert.doesNotMatch(set, /Domain=/i);
  assert.doesNotMatch(login.text, /access_token|refresh_token|synthetic|private|user/);
  assert.equal(login.headers.get('cache-control'), 'no-store');
  assert.equal(login.headers.get('pragma'), 'no-cache');
  assert.match(login.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal(login.headers.get('x-upstream-secret'), null);
  assert.equal(h.store.cleanups, 1);
});

test('explicit local development uses a distinct cookie without Secure', async t => {
  const h = await harness(t, { origin: 'http://localhost:4000', local: true }), login = await h.login();
  assert.match(login.headers.get('set-cookie'), /^pandapay_console_dev=/);
  assert.doesNotMatch(login.headers.get('set-cookie'), /; Secure/);
});

test('phone OTP and email OTP preserve their existing upstream method/path/field contracts', async t => {
  const h = await harness(t);
  assert.equal((await h.request('/request-otp', { method: 'POST', body: { phone_number: '+919000000001' } })).status, 200);
  assert.equal((await h.request('/verify-otp', { method: 'POST', body: { phone_number: '+919000000001', code: '4826' } })).status, 200);
  assert.equal(h.calls.find(row => row.path === '/auth/request-otp').body.phone_number, '+919000000001');
  assert.equal(h.calls.find(row => row.path === '/auth/verify-otp').body.code, '4826');
});

test('non-admin proof is refused, newly issued refresh is revoked and no browser session is created', async t => {
  const h = await harness(t, { apiHandler(req, res) { res.status(200).json({ isAdmin: false }); return true; } });
  const result = await h.request('/verify-email-otp', { method: 'POST', body: { email: 'user@example.test', code: '4826' } });
  assert.equal(result.status, 403); assert.deepEqual(result.data, { error: 'console_access_denied' });
  assert.equal(h.store.sessions.size, 0); assert.equal(result.headers.get('set-cookie'), null);
  assert.equal(h.calls.find(row => row.path === '/auth/logout').body.refresh_token, REFRESH);
  assert.doesNotMatch(result.text, /synthetic|access_token|refresh_token/);
});

test('failed OTP/provider responses are sanitized without upstream headers or raw details', async t => {
  const h = await harness(t, { authHandler(req, res) { res.status(429).json({ access_token: ACCESS, error: 'private-server-path-and-token' }); return true; } });
  const response = await h.request('/request-email-otp', { method: 'POST', body: { email: 'operator@example.test' } });
  assert.equal(response.status, 429); assert.deepEqual(response.data, { error: 'otp_request_failed' });
  assert.equal(response.headers.get('set-cookie'), null); assert.equal(response.headers.get('x-upstream-secret'), null);
  assert.doesNotMatch(response.text, /private|synthetic|access_token/);
});

test('proxy and logout require the matching per-session CSRF proof', async t => {
  const h = await harness(t), login = await h.login();
  for (const csrf of [undefined, 'bad-token']) {
    assert.equal((await h.request('/api/admin/cards', { cookie: login.sessionCookie, csrf })).status, 403);
    assert.equal((await h.request('/logout', { method: 'POST', cookie: login.sessionCookie, csrf })).status, 403);
  }
  assert.equal(h.calls.filter(row => row.path === '/admin/cards').length, 0);
  assert.equal(h.store.sessions.size, 1);
  assert.equal((await h.request('/api/admin/cards', { cookie: login.sessionCookie, csrf: login.csrf })).status, 200);
});

test('proxy permits fixed admin paths and categories GET while retaining encoded query values', async t => {
  const h = await harness(t), login = await h.login(), options = { cookie: login.sessionCookie, csrf: login.csrf };
  const response = await h.request('/api/admin/cards?q=a%2Fb%2Ec', options);
  assert.equal(response.status, 200);
  assert.equal(h.calls.at(-1).path, '/admin/cards?q=a%2Fb%2Ec');
  assert.equal(h.calls.at(-1).headers.authorization, 'Bearer '+ACCESS);
  assert.equal(response.headers.get('set-cookie'), null);
  assert.equal(response.headers.get('x-upstream-secret'), null);
  assert.equal((await h.request('/api/categories', options)).status, 200);
  for (const path of ['/api/categories/other', '/api/auth/refresh', '/api/users', '/api/adminish', '/api/admin/%2e%2e/users', '/api/admin/a%2fb', '/api//evil.example.test/admin']) {
    assert.equal((await h.request(path, options)).status, 404, path);
  }
  assert.equal((await h.request('/api/categories', { ...options, method: 'POST', body: {} })).status, 404);
});

test('proxy forwards mutations as JSON without exposing or accepting browser bearer credentials', async t => {
  const h = await harness(t), login = await h.login();
  const result = await h.request('/api/admin/cards', { method: 'PATCH', cookie: login.sessionCookie, csrf: login.csrf, headers: { Authorization: 'Bearer attacker-chosen' }, body: { name: 'synthetic card' } });
  assert.equal(result.status, 200);
  assert.equal(h.calls.at(-1).method, 'PATCH');
  assert.deepEqual(h.calls.at(-1).body, { name: 'synthetic card' });
  assert.equal(h.calls.at(-1).headers.authorization, 'Bearer '+ACCESS);
  assert.equal(h.calls.at(-1).headers.cookie, undefined);
});

test('session restoration rotates server credentials and rechecks current product-admin access', async t => {
  const h = await harness(t), login = await h.login();
  const response = await h.request('/session', { cookie: login.sessionCookie });
  assert.equal(response.status, 200); assert.equal(response.data.csrfToken, login.csrf);
  const refresh = h.calls.find(row => row.path === '/auth/refresh');
  assert.equal(refresh.body.refresh_token, REFRESH);
  assert.equal(refresh.headers['x-forwarded-for'], '127.0.0.1', 'refresh risk checks must retain the validated verification IP');
  assert.equal(refresh.body.refresh_request_id, createHash('sha256').update('console-refresh:'+REFRESH).digest('hex'));
  assert.equal(h.calls.at(-1).headers.authorization, 'Bearer '+ACCESS+'-1');
  assert.doesNotMatch(response.text, /synthetic|access_token|refresh_token/);
});

test('the same unconfirmed refresh retries with a stable idempotency request ID', async t => {
  const h = await harness(t, { authHandler(req, res) { if (req.path === '/auth/refresh') { res.status(503).json({ private: REFRESH }); return true; } return false; } }), login = await h.login();
  assert.equal((await h.request('/session', { cookie: login.sessionCookie })).status, 503);
  assert.equal((await h.request('/session', { cookie: login.sessionCookie })).status, 503);
  const refreshes = h.calls.filter(row => row.path === '/auth/refresh');
  assert.equal(refreshes.length, 2); assert.equal(refreshes[0].body.refresh_request_id, refreshes[1].body.refresh_request_id);
  assert.equal(refreshes[0].body.refresh_token, REFRESH);
});

test('confirmed refresh survives a later admission outage and the next request uses the new token', async t => {
  let admission = 0;
  const h = await harness(t, { apiHandler(req, res) { if (req.path === '/admin/me' && ++admission === 2) { res.status(503).json({ private: ACCESS }); return true; } return false; } }), login = await h.login();
  assert.equal((await h.request('/session', { cookie: login.sessionCookie })).status, 503);
  assert.equal((await h.request('/session', { cookie: login.sessionCookie })).status, 200);
  const refreshes = h.calls.filter(row => row.path === '/auth/refresh');
  assert.deepEqual(refreshes.map(row => row.body.refresh_token), [REFRESH, REFRESH+'-1']);
});

test('proxy retries an expired access token once using server-only refresh credentials', async t => {
  let cards = 0;
  const h = await harness(t, { apiHandler(req, res) { if (req.path === '/admin/cards' && ++cards === 1) { res.status(401).json({ error: 'expired' }); return true; } return false; } }), login = await h.login();
  assert.equal((await h.request('/api/admin/cards', { cookie: login.sessionCookie, csrf: login.csrf })).status, 200);
  assert.deepEqual(h.calls.filter(row => row.path === '/admin/cards').map(row => row.headers.authorization), ['Bearer '+ACCESS, 'Bearer '+ACCESS+'-1']);
  assert.equal(h.calls.filter(row => row.path === '/auth/refresh').length, 1);
});

test('invalid refresh destroys the session and clears the cookie', async t => {
  const h = await harness(t, { authHandler(req, res) { if (req.path === '/auth/refresh') { res.status(401).json({ error: 'invalid' }); return true; } return false; } }), login = await h.login();
  const response = await h.request('/session', { cookie: login.sessionCookie });
  assert.equal(response.status, 401); assert.equal(h.store.sessions.size, 0);
  assert.match(response.headers.get('set-cookie'), /Max-Age=0/);
});

test('refresh step-up returns to existing OTP sign-in instead of trapping the browser behind 503', async t => {
  const h = await harness(t, { authHandler(req, res) { if (req.path === '/auth/refresh') { res.status(403).json({ error: 'step_up_required' }); return true; } return false; } }), login = await h.login();
  const response = await h.request('/session', { cookie: login.sessionCookie });
  assert.equal(response.status, 401); assert.equal(h.store.sessions.size, 0);
  assert.match(response.headers.get('set-cookie'), /Max-Age=0/);
});

test('current product-admin revocation invalidates an already admitted browser session', async t => {
  let admission = 0;
  const h = await harness(t, { apiHandler(req, res) { if (req.path === '/admin/me' && ++admission > 1) { res.json({ isAdmin: false }); return true; } return false; } }), login = await h.login();
  const response = await h.request('/session', { cookie: login.sessionCookie });
  assert.equal(response.status, 401); assert.equal(h.store.sessions.size, 0);
  assert.match(response.headers.get('set-cookie'), /Max-Age=0/);
});

test('valid logout revokes upstream refresh, removes the browser session and is replay safe', async t => {
  const h = await harness(t), login = await h.login();
  const options = { method: 'POST', cookie: login.sessionCookie, csrf: login.csrf };
  const response = await h.request('/logout', options);
  assert.equal(response.status, 200); assert.deepEqual(response.data, { ok: true });
  assert.equal(h.calls.at(-1).path, '/auth/logout'); assert.equal(h.calls.at(-1).body.refresh_token, REFRESH);
  assert.equal(h.store.sessions.size, 0);
  assert.match(response.headers.get('set-cookie'), /Max-Age=0/);
  assert.equal((await h.request('/logout', options)).status, 200);
  assert.equal((await h.request('/api/admin/cards', { cookie: login.sessionCookie, csrf: login.csrf })).status, 401);
});

test('malformed, oversized and redirecting upstream responses produce a fixed safe 503', async t => {
  for (const mode of ['invalid', 'oversized', 'redirect']) {
    const h = await harness(t, { authHandler(req, res) {
      if (mode === 'redirect') res.redirect('/auth/must-never-follow');
      else res.status(200).type('text/plain').send(mode === 'invalid' ? 'private-database-url-and-token' : JSON.stringify({ private: 'x'.repeat(4*1024*1024) }));
      return true;
    } });
    const response = await h.request('/request-email-otp', { method: 'POST', body: { email: 'operator@example.test' } });
    assert.equal(response.status, 503); assert.deepEqual(response.data, { error: 'browser_service_unavailable' });
    assert.doesNotMatch(response.text, /private|token|database/);
    assert.deepEqual(h.logs, ['Console browser service unavailable']);
    if (mode === 'redirect') assert.equal(h.calls.length, 1, 'redirect must not replay credentials or provider sends');
  }
});

test('upstream fetch rejects redirects and has an actual ten-second abort boundary', { timeout: 15000 }, async t => {
  let observed;
  const started = Date.now();
  const h = await harness(t, { fetchImpl: async (url, options) => {
    observed = options;
    await new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true }));
  } });
  const response = await h.request('/request-email-otp', { method: 'POST', body: { email: 'operator@example.test' } });
  assert.equal(response.status, 503); assert.equal(observed.redirect, 'error'); assert.equal(observed.signal.aborted, true);
  assert.ok(Date.now()-started >= 9500);
  assert.doesNotMatch(response.text, /Timeout|private|operator/);
});

test('v2 console forwards stable device and challenge with recovery purpose, returns no credentials',async t=>{
 const id='bc3f590c-b3c9-412c-98eb-1be64946cb70';
 const h=await harness(t,{authHandler:async(req,res)=>{
  if(req.path==='/auth/v2/request-email-otp'){res.json({ok:true,version:2,challenge_id:id,code_length:6,expires_in:120,private:'hidden'});return true;}
 }});
 let r=await h.request('/v2/request-email-otp',{method:'POST',body:{email:'operator@example.test',device_id:'console-device'}});
 assert.equal(r.status,200);assert.deepEqual(r.data,{ok:true,version:2,challenge_id:id,code_length:6,expires_in:120});
 assert.deepEqual(h.calls[0].body,{email:'operator@example.test',device_id:'console-device',recovery_only:true});
 r=await h.request('/v2/verify-email-otp',{method:'POST',body:{email:'operator@example.test',device_id:'console-device',challenge_id:id,code:'819273'}});
 assert.equal(r.status,200);assert.equal(r.data.authenticated,true);assert.equal(r.text.includes(ACCESS),false);
 const verify=h.calls.find(x=>x.path==='/auth/v2/verify-email-otp');assert.deepEqual(verify.body,{email:'operator@example.test',device_id:'console-device',challenge_id:id,code:'819273',recovery_only:true});
});
test('v2 console refuses selectors, missing binding and malformed challenge without calling upstream',async t=>{
 const h=await harness(t);
 for(const body of [{email:'operator@example.test'},{email:'operator@example.test',device_id:'console-device',is_signup:true},{email:'operator@example.test',device_id:'console-device',phone_number:'+919999999999'}]){
  assert.equal((await h.request('/v2/request-email-otp',{method:'POST',body})).status,400);
 }
 for(const body of [{email:'operator@example.test',device_id:'console-device',code:'1234',challenge_id:'bc3f590c-b3c9-412c-98eb-1be64946cb70'},{email:'operator@example.test',device_id:'console-device',code:'819273',challenge_id:'bad'}]){
  assert.equal((await h.request('/v2/verify-email-otp',{method:'POST',body})).status,400);
 }
 assert.equal(h.calls.length,0);
});
