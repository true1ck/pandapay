#!/usr/bin/env node
'use strict';

// A disposable, synthetic-only rig. It never reads hosted configuration.
const assert = require('node:assert/strict');
const { spawn, execFileSync } = require('node:child_process');
const { randomBytes, randomUUID, generateKeyPairSync } = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const { gunzipSync } = require('node:zlib');
const os = require('node:os');
const path = require('node:path');
const { parseArgs } = require('node:util');
const root = path.resolve(__dirname, '..');
const { Client, Pool } = require('../api/node_modules/pg');
const { runProductMigrations } = require('../db/scripts/product_migrate');
const { configureAdminApiRuntime } = require('../db/scripts/admin_permissions');
const { runMigrations } = require('../auth/scripts/migrate');
const { canonicalBundleBytes } = require('../api/src/sms_v2/signer');

const { values } = parseArgs({ options: {
  'lan-ip': { type: 'string' },
  'check-only': { type: 'boolean' },
} });
const host = values['lan-ip'] || '127.0.0.1';
const privateIpv4 = /^(?:10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.)/;
if (values['lan-ip'] && (!privateIpv4.test(host) ||
    !Object.values(os.networkInterfaces()).flat().some(row => row.address === host))) {
  throw new Error('--lan-ip must be a private IPv4 address assigned to this Mac');
}
process.umask(0o077);
const dir = fs.mkdtempSync('/tmp/pandapay-sms-rig.');
const env = { PATH: process.env.PATH, HOME: process.env.HOME, NODE_ENV: 'development', DB_SSL: 'false', LC_ALL: 'C',
  DOTENV_CONFIG_PATH: path.join(dir, 'empty.env'), DOTENV_CONFIG_QUIET: 'true' };
fs.writeFileSync(env.DOTENV_CONFIG_PATH, '');
const secret = () => randomBytes(32).toString('hex');
const children = [];
const servers = [];
let pgStarted = false;
function run(command, args, options = {}) {
  return execFileSync(command, args, { cwd: root, env, encoding: 'utf8', stdio: ['ignore','pipe','pipe'], ...options });
}
function close() {
  for (const server of servers) {
    server.close();
    server.closeAllConnections();
  }
  for (const child of children) child.kill();
  if (pgStarted) {
    pgStarted = false;
    try { run('pg_ctl', ['-D', path.join(dir, 'pg'), '-m', 'fast', 'stop']); }
    catch { console.error('Could not stop scratch Postgres at', dir); }
  }
}
process.once('SIGINT', () => { close(); process.exitCode = 130; });
process.once('SIGTERM', () => { close(); process.exitCode = 143; });

async function listen(server, bindHost) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, bindHost, resolve);
  });
  return server.address().port;
}
async function freePort() {
  const server = net.createServer();
  const port = await listen(server, '127.0.0.1');
  await new Promise(resolve => server.close(resolve));
  return port;
}
function service(name, port, extraEnv) {
  // The app servers normally listen on all interfaces. Keep their HTTP ports
  // on loopback so the only LAN entry points are the two HTTPS listeners.
  const entry = path.join(root, name, 'src/index.js');
  const script = `
    const net = require('node:net');
    const listen = net.Server.prototype.listen;
    net.Server.prototype.listen = function(port, ...args) {
      return typeof port === 'number' || /^\\d+$/.test(port)
        ? listen.call(this, Number(port), '127.0.0.1', ...args)
        : listen.call(this, port, ...args);
    };
    require(process.argv[1]);
  `;
  const log = fs.openSync(path.join(dir, name + '.log'), 'w');
  try {
    const child = spawn(process.execPath, ['-e', script, entry], {
      cwd: dir, env: { ...env, ...extraEnv, PORT: String(port) },
      stdio: ['ignore', log, log],
    });
    children.push(child);
    return child;
  } finally { fs.closeSync(log); }
}
async function waitReady(port, child) {
  for (let i = 0; i < 60; i++) {
    if (child.exitCode != null) throw new Error('Service exited before readiness');
    try {
      if ((await fetch(`http://127.0.0.1:${port}/ready`, { signal: AbortSignal.timeout(1000) })).ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  throw new Error('Service did not become ready');
}
function gateway(target, tls) {
  const server = https.createServer(tls, (req, res) => {
    // Never forward the internal service, administrator, or webhook routes.
    let url, pathname;
    try {
      if (!req.url.startsWith('/') || req.url.startsWith('//')) throw new Error();
      url = new URL(req.url, 'https://local.invalid');
      pathname = decodeURIComponent(url.pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    if (/^\/(?:internal|admin|webhooks?)(?:\/|$)/i.test(pathname)) {
      res.writeHead(404).end();
      return;
    }
    const headers = { ...req.headers, host: `127.0.0.1:${target}` };
    for (const key of ['forwarded', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto']) delete headers[key];
    const upstream = http.request({ hostname: '127.0.0.1', port: target, path: url.pathname + url.search,
      method: req.method, headers }, reply => {
      res.writeHead(reply.statusCode, reply.headers);
      reply.pipe(res);
    });
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
    upstream.setTimeout(30000, () => upstream.destroy());
    res.on('close', () => upstream.destroy());
    req.pipe(upstream);
  });
  servers.push(server);
  return server;
}
async function request(base, route, ca, { body, token, method } = {}) {
  const payload = body === undefined ? null : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = https.request(base + route, {
      ca, method: method || (payload == null ? 'GET' : 'POST'),
      headers: { ...(payload == null ? {} : { 'Content-Type': 'application/json' }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`${route} returned ${res.statusCode}`));
          return;
        }
        try {
          const bytes = Buffer.concat(chunks);
          const decoded = res.headers['content-encoding'] === 'gzip' ? gunzipSync(bytes) : bytes;
          resolve(JSON.parse(decoded.toString('utf8')));
        } catch (error) { reject(error); }
      });
    });
    req.setTimeout(10000, () => req.destroy(new Error('HTTPS request timed out')));
    req.on('error', reject);
    req.end(payload);
  });
}

async function main() {
  console.log('Scratch rig directory:', dir);
  const pgPort = await freePort();
  const pgData = path.join(dir, 'pg');
  run('initdb', ['-D', pgData, '-U', 'postgres', '--auth-local=trust', '--auth-host=scram-sha-256', '--no-locale']);
  run('pg_ctl', ['-D', pgData, '-l', path.join(dir, 'postgres.log'), '-o', `-k ${dir} -p ${pgPort} -h 127.0.0.1`, 'start']);
  pgStarted = true;
  const connection = { host: dir, port: pgPort, user: 'postgres' };
  const product = new Client({ ...connection, database: 'postgres' });
  const auth = new Pool({ ...connection, database: 'sms_rig_auth', max: 1 });
  const appPassword = secret(), authPassword = secret(), adminPassword = secret(), phoneKey = secret();
  const actor = randomUUID();
  const dbUrl = (role, password, database) => `postgresql://${role}:${password}@127.0.0.1:${pgPort}/${database}`;
  await product.connect();
  try {
    await product.query('CREATE DATABASE sms_rig_auth');
    // Auth's local rehearsal uses a database owner without cluster privileges.
    await product.query(`CREATE ROLE sms_rig_auth LOGIN PASSWORD '${authPassword}'`);
    await product.query('ALTER DATABASE sms_rig_auth OWNER TO sms_rig_auth');
    await runMigrations(auth, { env: { ...env, ENCRYPTION_ENABLED: 'false', PHONE_LOOKUP_HMAC_KEY: phoneKey,
      ADMIN_GATEWAY_DB_PASSWORD: secret(), AUTH_RUNTIME_ROLE: 'sms_rig_auth' } });
    await auth.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON
      users, otp_requests, otp_codes, user_devices, refresh_tokens, auth_audit
      TO sms_rig_auth`);
    await auth.query('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sms_rig_auth');

    await runProductMigrations(product, { runRoleSetup: () => run('psql', [
      '-h', dir, '-p', String(pgPort), '-U', 'postgres', '-d', 'postgres', '-Xq', '-v', 'ON_ERROR_STOP=1',
      '-f', 'db/setup_app_role.sql',
    ], { env: { ...env, APP_USER_PASSWORD: appPassword, REWARD_WORKER_DB_PASSWORD: secret() } }) });
    await configureAdminApiRuntime(product, { ADMIN_API_DB_PASSWORD: adminPassword });
    await product.query("INSERT INTO admin_users(id,email,role) VALUES($1,'rig-owner@example.invalid','owner')", [actor]);
    await product.query(`INSERT INTO feature_flags(key,is_enabled,rollout_percent)
      VALUES('sms_pipeline_v2_enabled',true,100)
      ON CONFLICT(key) DO UPDATE SET is_enabled=true,rollout_percent=100`);
    const pair = generateKeyPairSync('ed25519');
    const keyId = 'local-rig';
    const publicKey = pair.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
    const signing = { SMS_RULES_KEY_ID: keyId, SMS_RULES_SIGNING_KEY: pair.privateKey.export({ type:'pkcs8', format:'pem' }) };
    const cli = path.join(root, 'tools/sms_rules_cli');
    run('dart', ['pub', 'get', '--offline'], { cwd: cli });
    console.log(run('dart', ['run', 'bin/sms_rules.dart', 'build', '--rules', '../../rules/sms/v2',
      '--bundle-version', '0', '--out', path.join(dir, 'input.json')], { cwd: cli }).trim());
    console.log(run(process.execPath, ['api/scripts/import_sms_v2_rules.js', '--input', path.join(dir, 'input.json'), '--admin-id', actor], {
      env: { ...env, ...signing, ADMIN_API_DATABASE_URL: dbUrl('admin_api_runtime', adminPassword, 'postgres') },
    }).trim());

    const authPort = await freePort(), apiPort = await freePort();
    const jwt = secret(), internal = secret();
    const identity = { JWT_ACCESS_SECRET: jwt, AUTH_INTERNAL_SERVICE_SECRET: internal };
    const authChild = service('auth', authPort, { ...identity, JWT_REFRESH_SECRET: secret(),
      DATABASE_URL: dbUrl('sms_rig_auth', authPassword, 'sms_rig_auth'), PHONE_LOOKUP_HMAC_KEY: phoneKey,
      ALLOW_TEST_OTP: 'true', AUTH_ALLOW_LOOPBACK_SIGNIN: 'true', REDIS_PORT: String(await freePort()), ENCRYPTION_ENABLED: 'false', ENABLE_EMAIL_OTP: 'true' });
    await waitReady(authPort, authChild);
    const apiChild = service('api', apiPort, { ...identity, ...signing,
      DATABASE_URL: dbUrl('app_user', appPassword, 'postgres'), AUTH_INTERNAL_BASE_URL: `http://127.0.0.1:${authPort}` });
    await waitReady(apiPort, apiChild);

    const tlsDir = path.join(dir, 'tls');
    fs.mkdirSync(tlsDir);
    const cert = path.join(tlsDir,'server.pem'), key = path.join(tlsDir,'server-key.pem');
    run('mkcert', ['-cert-file', cert, '-key-file', key, host], { env: { ...env, CAROOT: tlsDir } });
    const caPath = path.join(tlsDir,'rootCA.pem'), ca = fs.readFileSync(caPath);
    const tls = { cert: fs.readFileSync(cert), key: fs.readFileSync(key) };
    const authBase = `https://${host}:${await listen(gateway(authPort, tls), host)}`;
    const apiBase = `https://${host}:${await listen(gateway(apiPort, tls), host)}`;
    const email = 'test@example.com';
    await request(authBase, '/auth/request-email-otp', ca, { body: { email, is_signup: true } });
    const login = await request(authBase, '/auth/verify-email-otp', ca, {
      body: { email, code:'1234', device_id:randomUUID() },
    });
    assert.ok(login.access_token, 'OTP login must produce an access token');
    const { sub } = JSON.parse(Buffer.from(login.access_token.split('.')[1], 'base64url'));
    await product.query('INSERT INTO profiles(id,email,display_name) VALUES($1,$2,$3) ON CONFLICT(id) DO NOTHING',
      [sub,email,'Synthetic SMS tester']);
    const authz = { token: login.access_token };
    const signed = await request(apiBase, '/sms/v2/rules?since=0', ca, authz);
    const bundle = signed.bundle || signed;
    assert.equal(bundle.signature.keyId, keyId);
    const verify = (b) => require('node:crypto').verify(null, canonicalBundleBytes(b), pair.publicKey,
      Buffer.from(b.signature.value, 'base64'));
    assert.equal(verify(bundle), true);
    assert.equal(verify({ ...bundle, bundleVersion: bundle.bundleVersion + 1 }), false);
    const fixture = JSON.parse(fs.readFileSync(path.join(root,
      'contracts/sms/v2/fixtures/valid/request.facts_batch/full.json'), 'utf8'));
    const source = fixture.items[0];
    const fact = source.facts[0];
    const [entry] = fixture.ledger;
    const instrument = fixture.instruments.find(row => row.instrumentId === entry.from.instrumentId);
    assert.ok(instrument);
    const batch = { ...fixture, items: [{ ...source, facts: [fact] }], instruments: [{ ...instrument, userCardId: null }],
      events: [{ ...fixture.events[0], type: 'purchase', amountMinor: entry.amountMinor,
        legs: [{ factId: fact.factId, role: 'debit_leg' }] }], ledger: [entry] };
    const saved = await request(apiBase, '/sms/v2/facts:batch?backfill=true', ca, { ...authz, body: batch });
    assert.equal(saved.results.length, 4);
    assert.ok(saved.results.every(result => result.status === 'accepted'));
    const synced = await request(apiBase, '/sms/v2/sync', ca, authz);
    assert.ok(synced.events.some(row => row.eventId === entry.eventId));
    assert.ok(synced.ledger.some(row => row.entryId === entry.entryId));

    const defines = path.join(dir, 'flutter-defines.json');
    fs.writeFileSync(defines, JSON.stringify({
      PANDAPAY_ENV: 'dev', PANDAPAY_API_BASE_URL: apiBase, PANDAPAY_AUTH_BASE_URL: authBase,
      PANDAPAY_LEGAL_BASE_URL: apiBase + '/legal/', SMS_PIPELINE_V2: 'true',
      SMS_V2_LOCAL_RULE_PUBLIC_KEY: publicKey,
    }, null, 2));
    console.log('HTTPS OTP login, signed rules fetch, tamper rejection, fact upload and sync passed.');
    console.log('API:', apiBase, '\nAuth:', authBase, '\nTest login:', email, '(OTP 1234)');
    console.log('Test CA:', caPath, '\nFlutter defines:', defines);
    if (!values['check-only']) {
      console.log('Running until Ctrl-C. Use synthetic SMS only.');
      await Promise.race([authChild, apiChild].map(child => new Promise(resolve => child.once('exit', resolve))));
    }
  } finally {
    await Promise.allSettled([product.end(), auth.end()]);
  }
}
main().catch(error => {
  console.error(error.message);
  if (error.stderr) console.error(String(error.stderr).slice(-2000));
  console.error('Scratch logs:', dir);
  process.exitCode = 1;
}).finally(close);
