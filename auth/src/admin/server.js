'use strict';

const { createServer } = require('node:http');
const crypto = require('node:crypto');
const net = require('node:net');
const { Pool } = require('pg');
const nodemailer = require('nodemailer');
const { createAdminGatewayApp } = require('./gateway');
const { createAdminRepository } = require('./repository');
const { resolveDatabaseTls } = require('../utils/dbTls');

function readRequired(env, name) {
  const value = env[name];
  if (!value) throw new Error(`${name} is required for the private admin gateway`);
  return value;
}
function key32(env, name) {
  const raw = readRequired(env, name);
  const key = Buffer.from(raw, 'base64');
  if (key.length !== 32 || key.toString('base64') !== raw) throw new Error(`${name} must be a base64-encoded 32-byte key`);
  return key;
}
function fixedBaseUrl(env, name) {
  const raw = readRequired(env, name);
  const url = new URL(raw);
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error(`${name} must be a fixed service origin without credentials, path, query, or fragment`);
  if (url.protocol === 'http:' && !['localhost','127.0.0.1','::1','admin-api'].includes(url.hostname)) throw new Error(`${name} requires verified HTTPS except on the isolated local admin network`);
  return url;
}
function createSimpleWebAuthn() {
  const library = require('@simplewebauthn/server');
  return {
    registrationOptions: options => library.generateRegistrationOptions(options),
    authenticationOptions: options => library.generateAuthenticationOptions(options),
    async verifyRegistration({ response, expectedChallenge, expectedOrigin, expectedRPID, requireUserVerification }) {
      return library.verifyRegistrationResponse({ response, expectedChallenge, expectedOrigin, expectedRPID, requireUserVerification: Boolean(requireUserVerification) });
    },
    async verifyAuthentication({ response, expectedChallenge, expectedOrigin, expectedRPID, credential, requireUserVerification }) {
      return library.verifyAuthenticationResponse({ response, expectedChallenge, expectedOrigin, expectedRPID, credential: { id: credential.credentialId, publicKey: Buffer.from(credential.publicKey), counter: credential.counter, transports: credential.transports }, requireUserVerification: Boolean(requireUserVerification) });
    },
  };
}
function createPrivateApiClient(baseUrl) {
  return {
    async request({ method, path, body, accessToken, timeoutMs = 10_000, maxResponseBytes = 4 * 1024 * 1024 }) {
      const routePath = path.split('?')[0];
      if (!/^\/admin\/[a-zA-Z0-9_./:-]*$/.test(routePath) || routePath.includes('..') || routePath.includes('//')) throw new Error('invalid fixed private API path');
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), Math.min(10_000, timeoutMs));
      try {
        const target = new URL(path, baseUrl);
        if (target.origin !== baseUrl.origin || !target.pathname.startsWith('/admin/')) throw new Error('private API redirect/path rejected');
        const response = await fetch(target, { method, redirect: 'error', signal: controller.signal, headers: { accept: 'application/json', 'content-type': 'application/json', authorization: `Bearer ${accessToken}` }, body: ['GET','HEAD'].includes(method) ? undefined : JSON.stringify(body ?? {}) });
        const chunks=[];let total=0;
        for await (const chunk of response.body) {
          total+=chunk.length;
          if(total>maxResponseBytes) { controller.abort();throw new Error('private API response exceeded limit'); }
          chunks.push(chunk);
        }
        const text = Buffer.concat(chunks).toString('utf8');
        let parsed;
        try { parsed = text ? JSON.parse(text) : null; } catch { throw new Error('private API returned invalid JSON'); }
        return { status: response.status, body: parsed };
      } finally { clearTimeout(timer); }
    },
  };
}
function createSmtpClient(env) {
  const host = readRequired(env, 'ADMIN_SMTP_HOST');
  const user = readRequired(env, 'ADMIN_SMTP_USER');
  const pass = readRequired(env, 'ADMIN_SMTP_PASSWORD');
  const from = readRequired(env, 'ADMIN_SMTP_FROM');
  const port = Number(env.ADMIN_SMTP_PORT || 587);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid ADMIN_SMTP_PORT');
  const transporter = nodemailer.createTransport({ host, port, secure: port === 465, requireTLS: port !== 465, connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 15000, tls: { rejectUnauthorized: true, ...(net.isIP(host) ? {} : { servername: host }) }, auth: { user, pass } });
  return { async sendAdminOtp({ email, code }) {
    const sent = await transporter.sendMail({ from, to: email, subject: 'Your PandaPay admin sign-in code', disableFileAccess: true, disableUrlAccess: true, text: `Your PandaPay admin sign-in code is ${code}. It expires in 2 minutes. Do not share it.` });
    if (!sent.accepted?.some(x => String(x).toLowerCase() === email.toLowerCase())) throw new Error('admin OTP delivery rejected');
  } };
}

async function createAdminGatewayRuntime({ env = process.env, routeManifest, listen = false } = {}) {
  if (env.ADMIN_GATEWAY_ENABLED !== 'true') throw new Error('ADMIN_GATEWAY_ENABLED must be true for the private admin gateway');
  const origin = readRequired(env, 'ADMIN_BROWSER_ORIGIN');
  const rpId = readRequired(env, 'ADMIN_WEBAUTHN_RP_ID');
  if (origin !== 'https://localhost:8443' || rpId !== 'localhost') throw new Error('admin browser origin/RP configuration does not match the v1 contract');
  const connection = readRequired(env, 'ADMIN_AUTH_DATABASE_URL');
  const resolved = resolveDatabaseTls(connection);
  const pool = new Pool({ connectionString: resolved.connectionString, ssl: resolved.ssl, options: '-c role=pandapay_admin_gateway', max: 3, connectionTimeoutMillis: 5000, idleTimeoutMillis: 10000, statement_timeout: 5000, query_timeout: 7000 });
  try {
    const identity = (await pool.query("SELECT session_user AS name, r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolinherit AS unsafe FROM pg_roles r WHERE r.rolname=session_user")).rows[0];
    if(identity?.name !== 'admin_gateway_runtime' || identity.unsafe !== false) throw new Error('Unsafe private gateway database identity');
    const repository = createAdminRepository({ pool, environment: readRequired(env, 'ADMIN_ENVIRONMENT'), sessionEpoch: readRequired(env,'ADMIN_SESSION_EPOCH') });
    const privateApiUrl = fixedBaseUrl(env, 'ADMIN_API_BASE_URL');
    const apiSecret = readRequired(env, 'ADMIN_INTROSPECTION_SERVICE_SECRET');
    const privateApi = createPrivateApiClient(privateApiUrl);
    const membershipClient = { async getAdminMembership({ userId, accessToken }) {
      const response = await privateApi.request({ method: 'GET', path: '/admin/me', accessToken, timeoutMs: 5000, maxResponseBytes: 32 * 1024 });
      if (response.status !== 200 || response.body?.isAdmin !== true || !Array.isArray(response.body?.permissions)) return null;
      return { active: true, email: response.body.email, role: response.body.role, permissions: response.body.permissions };
    } };
    const config = { enabled: true, environment: readRequired(env, 'ADMIN_ENVIRONMENT'), origin, rpId, tokenLookupKey: readRequired(env, 'ADMIN_TOKEN_LOOKUP_KEY'), introspectionSecret: apiSecret, sessionEncryptionKey: key32(env, 'CONSOLE_SESSION_ENCRYPTION_KEY') };
    const app = createAdminGatewayApp({ repository, emailClient: createSmtpClient(env), membershipClient, privateApi, routeManifest, config, webauthn: createSimpleWebAuthn() });
    if (!listen) return { app, pool, repository, privateApi };
    const host = env.ADMIN_GATEWAY_HOST || '127.0.0.1';
    if (!['127.0.0.1', '::1', '0.0.0.0', '::'].includes(host)) throw new Error('invalid ADMIN_GATEWAY_HOST');
    if (['0.0.0.0','::'].includes(host) && env.ADMIN_CONTAINER_NETWORK !== 'true') throw new Error('wildcard bind requires explicit isolated admin container network');
    const port = Number(env.ADMIN_GATEWAY_PORT || 4321);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid ADMIN_GATEWAY_PORT');
    const server = createServer(app);
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
    return { app, pool, repository, privateApi, server };
  } catch (error) {
    await pool.end().catch(() => {});
    throw error;
  }
}

if (require.main === module) {
  const routeManifest = require('../admin_route_manifest.json');
  createAdminGatewayRuntime({ routeManifest, listen: true }).then(({ server, pool }) => {
    const close = () => server.close(() => pool.end().then(() => process.exit(0), () => process.exit(1)));
    process.once('SIGTERM', close); process.once('SIGINT', close);
  }).catch(error => { console.error('Private admin gateway failed closed:', error.name); process.exitCode = 1; });
}
module.exports = { createAdminGatewayRuntime, createPrivateApiClient, createSmtpClient, createSimpleWebAuthn };
