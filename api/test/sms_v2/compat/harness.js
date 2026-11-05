'use strict';

// Lane D: boots the REAL api/src/index.js (or an older copy of it) as a child
// process against a scratch Postgres, with a stub of the auth service, so the
// routes the shipped Android app calls can be exercised over HTTP. Synthetic
// data only. Nothing here touches a network address other than loopback.

const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const jwt = require('jsonwebtoken');

const SECRET = 'lane-d-compat-secret-0123456789abcdef-synthetic';
const SERVICE_SECRET = 'lane-d-compat-internal-secret-0123456789-synthetic';
const REPO = path.resolve(__dirname, '../../../..');

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

// Auth service stub: POST /internal/session/verify. Trusts the signed token.
async function startAuthStub() {
  const server = http.createServer((req, res) => {
    const auth = String(req.headers.authorization || '').replace(/^Bearer /, '');
    let sub = null;
    try { sub = jwt.verify(auth, SECRET, { issuer: 'pandapay-auth', audience: 'mobile-app' }).sub; } catch (_) { /* invalid */ }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({
      token_valid: Boolean(sub), valid: Boolean(sub), subject: sub, guest: false,
      session: { active: Boolean(sub), revoked: false }, verified_contacts: {}, auth_proof: {},
    }));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: server.address().port };
}

/**
 * @param {object} o
 * @param {string} o.apiDir  directory containing src/index.js and node_modules
 * @param {string} o.databaseUrl  app_user URL of the scratch database
 * @param {string} [o.contractsDir]
 */
async function startStack({ apiDir, databaseUrl, contractsDir }) {
  const stub = await startAuthStub();
  const port = await freePort();
  const logs = [];
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: apiDir,
    env: {
      PATH: process.env.PATH, NODE_ENV: 'development', PORT: String(port), TRUST_PROXY_HOPS: '0',
      DATABASE_URL: databaseUrl, DB_SSL: 'false', JWT_ACCESS_SECRET: SECRET,
      AUTH_INTERNAL_BASE_URL: `http://127.0.0.1:${stub.port}`, AUTH_INTERNAL_SERVICE_SECRET: SERVICE_SECRET,
      ...(contractsDir ? { SMS_V2_CONTRACTS_DIR: contractsDir } : {}),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', (d) => logs.push(String(d)));
  child.stderr.on('data', (d) => logs.push(String(d)));
  const base = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 30_000;
  for (;;) {
    if (child.exitCode !== null) throw new Error(`api exited early: ${logs.join('').slice(-800)}`);
    try { const r = await fetch(`${base}/health`); if (r.ok) break; } catch (_) { /* not up yet */ }
    if (Date.now() > deadline) { child.kill(); throw new Error(`api did not start: ${logs.join('').slice(-800)}`); }
    await new Promise((r) => setTimeout(r, 150));
  }
  const token = (profileId) => jwt.sign({ sub: profileId }, SECRET, { algorithm: 'HS256', issuer: 'pandapay-auth', audience: 'mobile-app', expiresIn: '1h' });
  async function call(profileId, method, route, body, headers = {}) {
    const r = await fetch(base + route, {
      method,
      headers: { authorization: `Bearer ${token(profileId)}`, ...(body ? { 'content-type': 'application/json' } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await r.text();
    let json = null; try { json = JSON.parse(text); } catch (_) { /* not json */ }
    return { status: r.status, body: json, text };
  }
  async function stop() {
    child.kill('SIGTERM');
    await new Promise((r) => { child.once('exit', r); setTimeout(r, 3000); });
    stub.server.close();
  }
  return { base, call, stop, logs, token };
}

const uuid = () => crypto.randomUUID();
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');

// Replace volatile values so two servers' answers can be compared for equality.
function normalise(value, idMap = new Map()) {
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const walk = (v, key) => {
    if (Array.isArray(v)) return v.map((x) => walk(x, key));
    if (v && typeof v === 'object') {
      const out = {};
      for (const k of Object.keys(v).sort()) {
        if (/(^|_)(created_at|updated_at|granted_at|revoked_at|generated_at|served_at|now|server_time|serverTime|checkedAt|computed_at)$/i.test(k)) continue;
        out[k] = walk(v[k], k);
      }
      return out;
    }
    if (typeof v === 'string' && UUID.test(v)) {
      if (!idMap.has(v)) idMap.set(v, `<id${idMap.size + 1}>`);
      return idMap.get(v);
    }
    if (typeof v === 'string' && /^[A-Za-z0-9_-]{40,}$/.test(v) && /cursor|token|signature|page/i.test(String(key))) return '<opaque>';
    return v;
  };
  return walk(value, '');
}

module.exports = { startStack, uuid, sha, normalise, REPO };
