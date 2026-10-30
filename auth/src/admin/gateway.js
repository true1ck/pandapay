'use strict';

const crypto = require('node:crypto');
const express = require('express');

const COOKIE = '__Host-pandapay_console';
const PREAUTH = '__Host-pandapay_admin_pre';
const LIMITS = Object.freeze({ accessMs: 300_000, preauthMs: 120_000, idleMs: 900_000, absoluteMs: 28_800_000, stepUpMs: 300_000 });
const assurance = 'email+webauthn-uv';

function digest(value, key) {
  return crypto.createHmac('sha256', key).update(value).digest('hex');
}
function randomToken(bytes = 32) { return crypto.randomBytes(bytes).toString('base64url'); }
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const aa = Buffer.from(a); const bb = Buffer.from(b);
  return aa.length === bb.length && crypto.timingSafeEqual(aa, bb);
}
function encrypt(value, key) {
  const iv = crypto.randomBytes(12); const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64url');
}
function decrypt(value, key) {
  const packed = Buffer.from(value, 'base64url');
  if (packed.length < 29) throw new Error('invalid encrypted access token');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, packed.subarray(0, 12));
  decipher.setAuthTag(packed.subarray(12, 28));
  return Buffer.concat([decipher.update(packed.subarray(28)), decipher.final()]).toString('utf8');
}
function cookieValue(header, name) {
  for (const part of String(header || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
}
function clientChallenge(credential) {
  try {
    const raw = credential?.response?.clientDataJSON;
    if (typeof raw !== 'string' || raw.length > 16_384) return null;
    const data = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    return typeof data.challenge === 'string' ? data.challenge : null;
  } catch { return null; }
}
function setCookie(res, name, value, maxAge) {
  res.append('Set-Cookie', `${name}=${value}; Path=/; Max-Age=${maxAge}; Secure; HttpOnly; SameSite=Strict`);
}
function clearCookie(res, name) {
  res.append('Set-Cookie', `${name}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict`);
}
function fail(res, status, code) { return res.status(status).set('Cache-Control', 'no-store').json({ error: code, version: 1 }); }
function assertDeps(deps) {
  const { repository, emailClient, membershipClient, config, webauthn } = deps;
  if (!repository || !emailClient || typeof emailClient.sendAdminOtp !== 'function' || !membershipClient || typeof membershipClient.getAdminMembership !== 'function') throw new Error('admin gateway dependencies are incomplete');
  const required = ['findVerifiedPrincipalByEmail','createLoginChallenge','consumeEmailChallenge','createWebAuthnChallenge','consumeWebAuthnChallenge','getWebAuthnChallenge','listCredentials','getEnrollmentGrant','createEnrollmentGrant','consumeEnrollmentGrant','addCredential','createAdminSession','resolveAdminSessionByToken','loadSession','touchAdminSession','revokeAdminSession','revokeAllAdminSessions','updateAdminSessionVerification','rateLimit','rotateAccessToken','updateCredentialCounter'];
  for (const method of required) if (typeof repository[method] !== 'function') throw new Error(`admin repository missing ${method}`);
  if (!config || config.enabled !== true || config.origin !== 'https://localhost:8443' || config.rpId !== 'localhost' || typeof config.tokenLookupKey !== 'string' || Buffer.byteLength(config.tokenLookupKey) < 32 || typeof config.introspectionSecret !== 'string' || Buffer.byteLength(config.introspectionSecret) < 32 || !Buffer.isBuffer(config.sessionEncryptionKey) || config.sessionEncryptionKey.length !== 32) throw new Error('admin gateway configuration is incomplete or unsafe');
  if (!webauthn || typeof webauthn.registrationOptions !== 'function' || typeof webauthn.verifyRegistration !== 'function' || typeof webauthn.authenticationOptions !== 'function' || typeof webauthn.verifyAuthentication !== 'function') throw new Error('WebAuthn implementation is required');
  if (!Array.isArray(deps.routeManifest) || deps.routeManifest.length === 0 || !deps.privateApi || typeof deps.privateApi.request !== 'function') throw new Error('private API route manifest/client is required');
}

/** Create an unmounted, side-effect-free private admin gateway app. */
function createAdminGatewayApp(deps) {
  assertDeps(deps);
  const { repository: repo, emailClient, membershipClient, privateApi, routeManifest, config, webauthn } = deps;
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', false);
  app.use((req, res, next) => {
    res.set('Cache-Control', 'no-store');
    res.set('Pragma', 'no-cache');
    if (req.headers['x-forwarded-host'] || req.headers['x-forwarded-proto'] || req.headers['forwarded']) return fail(res, 400, 'invalid_request');
    const isInternal = req.path === '/internal/admin/session/introspect' || (req.path === '/ready' && ['127.0.0.1','::1','::ffff:127.0.0.1'].includes(req.socket.remoteAddress));
    const rawPath = String(req.originalUrl || '').split('?')[0];
    if (/%2f|%5c/i.test(rawPath) || rawPath.includes('\\') || rawPath.split('/').some(part => part === '.' || part === '..') || rawPath.includes('//')) return fail(res, 400, 'invalid_request');
    const cookieParts = String(req.headers.cookie || '').split(';').map(part => part.trim()).filter(Boolean);
    const cookieNames = cookieParts.map(part => part.slice(0, part.indexOf('=')));
    if (new Set(cookieNames).size !== cookieNames.length) return fail(res, 400, 'invalid_request');
    if (!isInternal && req.get('host') !== 'localhost:8443') return fail(res, 421, 'invalid_host');
    if (!isInternal) {
      if (req.protocol !== 'http' && req.protocol !== 'https') return fail(res, 400, 'invalid_protocol');
      if (req.method !== 'GET' && req.get('origin') !== config.origin) return fail(res, 403, 'invalid_origin');
      if (req.get('origin') && req.get('origin') !== config.origin) return fail(res, 403, 'invalid_origin');
      if (req.method !== 'GET' && (req.get('x-admin-protocol') !== '1' || req.get('x-console-request') !== '1')) return fail(res, 426, 'upgrade_required');
      if (req.path.startsWith('/browser/') && (req.get('x-console-request') !== '1' || req.get('x-admin-protocol') !== '1' || (req.get('sec-fetch-site') && !['same-origin','none'].includes(req.get('sec-fetch-site'))))) return fail(res, 403, 'preauth_required');
    }
    next();
  });
  app.use(express.json({ limit: '256kb', strict: true, type: 'application/json' }));
  app.get('/ready', async (_req,res) => {
    try { await repo.readiness(); return res.json({ok:true,environment:config.environment}); }
    catch { return fail(res,503,'temporarily_unavailable'); }
  });

  async function limited(req, key, limit, windowMs) {
    const source = req.ip || 'unknown';
    return repo.rateLimit({ key: `${key}:${source}`, now: new Date(), limit, windowMs });
  }
  function preauth(req, res) {
    if (req.get('sec-fetch-site') && !['same-origin', 'none'].includes(req.get('sec-fetch-site'))) return null;
    if (req.get('x-console-request') !== '1') return null;
    return cookieValue(req.headers.cookie, PREAUTH);
  }
  async function createChallenge(loginId, userId, purpose, credentialIds, challenge, sessionId, preauthCookieDigest) {
    await repo.createWebAuthnChallenge({ loginId, userId, sessionId, purpose, challengeValue: challenge, challengeDigest: digest(challenge, config.tokenLookupKey), preauthCookieDigest, expiresAt: new Date(Date.now() + LIMITS.preauthMs), origin: config.origin, rpId: config.rpId, credentialIds });
  }
  async function createSession(res, principal, credential) {
    const now = new Date();
    const cookie = randomToken(); const access = randomToken(); const csrf = randomToken();
    const stored = await repo.createAdminSession({ userId: principal.userId, credentialId: credential.credentialId, verifiedAt: now, cookieDigest: digest(cookie, config.tokenLookupKey), accessTokenDigest: digest(access, config.tokenLookupKey), encryptedUpstreamToken: encrypt(access, config.sessionEncryptionKey), accessTokenExpiresAt: new Date(+now + LIMITS.accessMs), csrfDigest: digest(csrf, config.tokenLookupKey), absoluteExpiresAt: new Date(+now + LIMITS.absoluteMs), idleExpiresAt: new Date(+now + LIMITS.idleMs) });
    if (!stored) return fail(res, 403, 'admin_access_denied');
    setCookie(res, COOKIE, cookie, Math.ceil(LIMITS.absoluteMs / 1000));
    clearCookie(res, PREAUTH);
    const membership = await membershipClient.getAdminMembership({ userId: principal.userId, accessToken: access });
    if (!membership || membership.active !== true) {
      await repo.revokeAdminSession({ sessionId: stored.sessionId, reason: 'membership_denied' }); clearCookie(res, COOKIE);
      return fail(res, 403, 'admin_access_denied');
    }
    return res.json({ version: 1, authenticated: true, admin: { email: membership.email, role: membership.role, permissions: membership.permissions, environment:config.environment }, csrfToken: csrf, expiresAt: stored.expiresAt });
  }
  async function session(req, res, next) {
    const raw = cookieValue(req.headers.cookie, COOKIE);
    if (!raw) return fail(res, 401, 'unauthorized');
    const state = await repo.loadSession(digest(raw, config.tokenLookupKey));
    if (!state) return fail(res, 401, 'unauthorized');
    if (!Number.isFinite(new Date(state.absolute_expires_at).getTime()) || !Number.isFinite(new Date(state.access_token_expires_at).getTime())) return fail(res, 401, 'unauthorized');
    const csrf = req.get('x-csrf-token');
    if (req.method !== 'GET' && !safeEqual(digest(csrf || '', config.tokenLookupKey), state.csrf_digest)) return fail(res, 403, 'csrf_failed');
    req.adminSession = { actorId: state.user_id, sessionId: state.id, mfaVerifiedAt: state.verified_at, expiresAt: state.absolute_expires_at, csrfDigest: state.csrf_digest, encryptedUpstreamToken: state.encrypted_upstream_token, accessTokenExpiresAt: state.access_token_expires_at };
    if (new Date(state.access_token_expires_at).getTime() <= Date.now() + 5_000) {
      const oldToken = decrypt(state.encrypted_upstream_token, config.sessionEncryptionKey);
      const nextToken = randomToken();
      const rotated = await repo.rotateAccessToken({ sessionId: state.id, oldTokenDigest: digest(oldToken, config.tokenLookupKey), newTokenDigest: digest(nextToken, config.tokenLookupKey), newEncryptedUpstreamToken: encrypt(nextToken, config.sessionEncryptionKey), expiresAt: new Date(Date.now() + LIMITS.accessMs), now: new Date() });
      if (!rotated) return fail(res, 401, 'unauthorized');
      req.adminSession.encryptedUpstreamToken = encrypt(nextToken, config.sessionEncryptionKey);
    }
    req.adminCookie = raw;
    const bucket = await repo.rateLimit({key:'api:'+state.user_id,limit:120,windowMs:60000});
    if(!bucket.allowed) return res.set('Retry-After',String(bucket.retryAfterSeconds)).status(429).json({version:1,error:'rate_limited'});
    if(req.method!=='GET') {
      const writeBucket=await repo.rateLimit({key:'mutations:'+state.user_id,limit:20,windowMs:60000});
      if(!writeBucket.allowed) return res.set('Retry-After',String(writeBucket.retryAfterSeconds)).status(429).json({version:1,error:'rate_limited'});
    }
    const activity = await repo.touchAdminSession({
      sessionId: state.id, cookieDigest: digest(raw, config.tokenLookupKey),
      now: new Date(), idleExpiresAt: new Date(Date.now() + LIMITS.idleMs),
    });
    if (!activity) return fail(res, 401, 'unauthorized');
    next();
  }

  app.post('/browser/login/start', async (req, res) => {
    try {
      const allowed = await limited(req, 'admin-login-source', 20, 600_000);
      if (!allowed.allowed) return res.set('Retry-After', String(allowed.retryAfterSeconds)).status(429).json({ error: 'rate_limited', version: 1 });
      const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
      if (!email || email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return fail(res, 400, 'invalid_request');
      const loginId = crypto.randomUUID(); const preCookie = randomToken();
      const principal = await repo.findVerifiedPrincipalByEmail(email);
      const recipient = await repo.rateLimit({key: 'email:' + digest(email, config.tokenLookupKey), limit: 5, windowMs: 900000});
      const global = await repo.rateLimit({key:'admin-mail-global', limit:20, windowMs:900000});
      if (!recipient.allowed || !global.allowed) return fail(res,429,'rate_limited');
      const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
      await repo.createLoginChallenge({ loginId, email, codeDigest: digest(`${loginId}:${code}`, config.tokenLookupKey), preauthCookieDigest: digest(preCookie, config.tokenLookupKey), expiresAt: new Date(Date.now() + LIMITS.preauthMs), sourceKey: digest(req.ip || 'unknown', config.tokenLookupKey), origin: config.origin, rpId: config.rpId });
      if (principal?.accountActive && principal.emailVerified && principal.principalStatus !== 'revoked') await emailClient.sendAdminOtp({ email, code });
      setCookie(res, PREAUTH, preCookie, 120);
      return res.status(202).json({ version: 1, loginId, expiresIn: 120 });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.post('/browser/login/verify-email', async (req, res) => {
    try {
      if (!preauth(req, res)) return fail(res, 403, 'preauth_required');
      const preCookie = cookieValue(req.headers.cookie, PREAUTH);
      const result = await repo.consumeEmailChallenge({ loginId: req.body?.loginId, codeDigest: digest(`${req.body?.loginId}:${req.body?.code}`, config.tokenLookupKey), preauthCookieDigest: digest(preCookie, config.tokenLookupKey) });
      if (!result?.ok || !result.principal || !result.principal.accountActive || !result.principal.emailVerified || result.principal.principalStatus === 'revoked') return fail(res, 401, 'invalid_credentials');
      const p = result.principal;
      if (p.principalStatus === 'pending') return res.json({ version: 1, next: 'enrollment' });
      if (p.principalStatus !== 'enabled') return fail(res, 401, 'invalid_credentials');
      const creds = await repo.listCredentials(p.userId);
      if (!creds?.length) return fail(res, 403, 'admin_access_denied');
      const options = await webauthn.authenticationOptions({ rpID: config.rpId, userVerification: 'required', allowCredentials: creds.map(c => ({ id: c.credentialId, transports: c.transports })) });
      await createChallenge(req.body.loginId, p.userId, 'login', creds.map(c => c.credentialId), options.challenge, undefined, digest(preCookie, config.tokenLookupKey));
      return res.json({ version: 1, next: 'webauthn', options });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.post('/browser/login/verify-passkey', async (req, res) => {
    try {
      const loginId = req.body?.loginId;
      if (!preauth(req, res)) return fail(res, 403, 'preauth_required');
      const challengeValue = clientChallenge(req.body?.credential);
      if (!challengeValue) return fail(res, 401, 'invalid_credentials');
      const preCookie = cookieValue(req.headers.cookie, PREAUTH);
      const challenge = await repo.consumeWebAuthnChallenge({ loginId, purpose: 'login', challengeDigest: digest(challengeValue, config.tokenLookupKey), preauthCookieDigest: digest(preCookie, config.tokenLookupKey) });
      if (!challenge) return fail(res, 401, 'invalid_credentials');
      const credential = (await repo.listCredentials(challenge.userId)).find(c => c.credentialId === req.body?.credential?.id);
      if (!credential) return fail(res, 401, 'invalid_credentials');
      const verified = await webauthn.verifyAuthentication({ response: req.body.credential, expectedChallenge: challengeValue, expectedOrigin: config.origin, expectedRPID: config.rpId, credential, requireUserVerification: true });
      if (!verified?.verified) return fail(res, 401, 'invalid_credentials');
      await repo.updateCredentialCounter({credentialId:credential.credentialId,userId:challenge.userId,oldCounter:credential.counter,newCounter:verified.authenticationInfo.newCounter});
      return createSession(res, { userId: challenge.userId, email: challenge.email }, credential);
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.post('/browser/enrollment/options', async (req, res) => {
    try {
      if (!preauth(req, res)) return fail(res, 403, 'preauth_required');
      const grantDigest = crypto.createHash('sha256').update(String(req.body?.grant || '')).digest('hex');
      const grant = await repo.getEnrollmentGrant({ grantDigest, preauthCookieDigest: digest(cookieValue(req.headers.cookie, PREAUTH), config.tokenLookupKey), loginId: req.body?.loginId, environment: config.environment, origin: config.origin, rpId: config.rpId, now: new Date() });
      if (!grant) return fail(res, 403, 'enrollment_denied');
      const options = await webauthn.registrationOptions({ rpName: 'PandaPay Admin', rpID: config.rpId, userID: Buffer.from(grant.userId), userName: grant.userId, attestationType: 'none', authenticatorSelection: { userVerification: 'required', residentKey: 'preferred' }, excludeCredentials: (await repo.listCredentials(grant.userId)).map(c => ({ id: c.credentialId, transports: c.transports })) });
      await repo.createWebAuthnChallenge({ loginId: req.body.loginId, userId: grant.userId, purpose: 'enrollment', challengeValue: options.challenge, challengeDigest: digest(options.challenge, config.tokenLookupKey), grantDigest: grantDigest, preauthCookieDigest: digest(cookieValue(req.headers.cookie, PREAUTH), config.tokenLookupKey), expiresAt: new Date(Date.now() + LIMITS.preauthMs), origin: config.origin, rpId: config.rpId, credentialIds: [] });
      return res.json({ version: 1, options });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.post('/browser/enrollment/verify', async (req, res) => {
    try {
      if (!preauth(req, res)) return fail(res, 403, 'preauth_required');
      const challengeValue = clientChallenge(req.body?.credential);
      if (!challengeValue) return fail(res, 401, 'invalid_credentials');
      const c = await repo.getWebAuthnChallenge({ loginId: req.body?.loginId, purpose: 'enrollment', challengeDigest: digest(challengeValue, config.tokenLookupKey), preauthCookieDigest: digest(cookieValue(req.headers.cookie, PREAUTH), config.tokenLookupKey) });
      if (!c) return fail(res, 401, 'invalid_credentials');
      const verified = await webauthn.verifyRegistration({ response: req.body.credential, expectedChallenge: challengeValue, expectedOrigin: config.origin, expectedRPID: config.rpId, requireUserVerification: true });
      if (!verified?.verified || !verified.registrationInfo) return fail(res, 401, 'invalid_credentials');
      const info = verified.registrationInfo;
      const added = await repo.addCredential({ loginId: req.body.loginId, challengeDigest: digest(challengeValue, config.tokenLookupKey), preauthCookieDigest: digest(cookieValue(req.headers.cookie, PREAUTH), config.tokenLookupKey), credentialId: info.credential.id, publicKey: info.credential.publicKey, counter: info.credential.counter, transports: req.body.credential.response?.transports || [], deviceType: info.credentialDeviceType, backedUp: info.credentialBackedUp, origin: config.origin, rpId: config.rpId, now: new Date(), environment: config.environment });
      if (!added) return fail(res, 403, 'enrollment_denied');
      return res.json({ version: 1, enrolled: true, next: 'login' });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.get('/browser/session', session, async (req, res) => {
    try {
      const access = decrypt(req.adminSession.encryptedUpstreamToken, config.sessionEncryptionKey);
      const membership = await membershipClient.getAdminMembership({ userId: req.adminSession.actorId, accessToken: access });
      if (!membership?.active) { await repo.revokeAdminSession({ sessionId: req.adminSession.sessionId, reason: 'membership_denied' }); clearCookie(res, COOKIE); return fail(res, 401, 'unauthorized'); }
      const csrf = randomToken();
      const touched = await repo.touchAdminSession({ sessionId: req.adminSession.sessionId, cookieDigest: digest(req.adminCookie, config.tokenLookupKey), csrfDigest: digest(csrf, config.tokenLookupKey), now: new Date(), idleExpiresAt: new Date(Date.now() + LIMITS.idleMs) });
      if (!touched) { clearCookie(res, COOKIE); return fail(res, 401, 'unauthorized'); }
      return res.json({ version: 1, authenticated: true, admin: { email: membership.email, role: membership.role, permissions: membership.permissions, environment:config.environment }, csrfToken: csrf, expiresAt: req.adminSession.expiresAt });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.post('/browser/step-up/options', session, async (req, res) => {
    try {
      const credentials = await repo.listCredentials(req.adminSession.actorId);
      const options = await webauthn.authenticationOptions({ rpID: config.rpId, userVerification: 'required', allowCredentials: credentials.map(c => ({ id: c.credentialId, transports: c.transports })) });
      await repo.createWebAuthnChallenge({ loginId: req.adminSession.sessionId, sessionId: req.adminSession.sessionId, userId: req.adminSession.actorId, preauthCookieDigest: digest(req.adminCookie, config.tokenLookupKey), purpose: 'step_up', challengeValue: options.challenge, challengeDigest: digest(options.challenge, config.tokenLookupKey), expiresAt: new Date(Date.now() + LIMITS.stepUpMs), origin: config.origin, rpId: config.rpId, credentialIds: credentials.map(c => c.credentialId) });
      return res.json({ version: 1, options });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });
  app.post('/browser/step-up/verify', session, async (req, res) => {
    try {
      const challengeValue = clientChallenge(req.body?.credential);
      if (!challengeValue) return fail(res, 401, 'invalid_credentials');
      const challenge = await repo.consumeWebAuthnChallenge({ loginId: req.adminSession.sessionId, purpose: 'step_up', preauthCookieDigest: digest(req.adminCookie, config.tokenLookupKey), userId: req.adminSession.actorId, challengeDigest: digest(challengeValue, config.tokenLookupKey) });
      if (!challenge) return fail(res, 401, 'invalid_credentials');
      const credential = (await repo.listCredentials(req.adminSession.actorId)).find(c => c.credentialId === req.body?.credential?.id);
      if (!credential) return fail(res, 401, 'invalid_credentials');
      const verified = await webauthn.verifyAuthentication({ response: req.body.credential, expectedChallenge: challengeValue, expectedOrigin: config.origin, expectedRPID: config.rpId, credential, requireUserVerification: true });
      if (!verified?.verified) return fail(res, 401, 'invalid_credentials');
      await repo.updateCredentialCounter({credentialId:credential.credentialId,userId:req.adminSession.actorId,oldCounter:credential.counter,newCounter:verified.authenticationInfo.newCounter});
      const at = new Date(); await repo.updateAdminSessionVerification({ sessionId: req.adminSession.sessionId, userId: req.adminSession.actorId, verifiedAt: at });
      return res.json({ version: 1, verified: true, mfaVerifiedAt: at });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });
  app.post('/browser/logout', session, async (req, res) => {
    try { await repo.revokeAdminSession({ sessionId: req.adminSession.sessionId, reason: 'logout' }); clearCookie(res, COOKIE); return res.json({ version: 1, loggedOut: true }); }
    catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.all('/browser/api/admin/*path', session, async (req, res) => {
    if (!privateApi || typeof privateApi.request !== 'function') return fail(res, 503, 'temporarily_unavailable');
    const suffix = Array.isArray(req.params.path) ? req.params.path.join('/') : String(req.params.path || '');
    const path = `/admin/${suffix}`;
    const method = req.method.toUpperCase();
    const matched = Array.isArray(routeManifest) && routeManifest.find(entry => entry.method === method && entry.path.split('/').length === path.split('/').length && entry.path.split('/').every((p, i) => p.startsWith(':') || p === path.split('/')[i]));
    if (!matched) return fail(res, 404, 'not_found');
    if (!['GET','POST','PUT','PATCH','DELETE'].includes(method)) return fail(res, 405, 'method_not_allowed');
    if (matched.freshMfa && Date.now() - new Date(req.adminSession.mfaVerifiedAt).getTime() > LIMITS.stepUpMs) return fail(res, 403, 'step_up_required');
    try {
      const accessToken = decrypt(req.adminSession.encryptedUpstreamToken, config.sessionEncryptionKey);
      const query = String(req.originalUrl || '').split('?')[1];
      const result = await privateApi.request({ method, path: query ? `${path}?${query}` : path, body: req.body, accessToken, timeoutMs: 10_000, maxResponseBytes: 4 * 1024 * 1024, redirect: 'error' });
      if (!result || !Number.isInteger(result.status) || result.status < 200 || result.status > 599 || result.body === undefined) return fail(res, 503, 'temporarily_unavailable');
      return res.status(result.status).json(result.body);
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });

  app.post('/internal/admin/session/introspect', async (req, res) => {
    if (!safeEqual(req.get('x-admin-service-secret') || '', config.introspectionSecret)) return fail(res, 401, 'unauthorized');
    const token = req.body?.token;
    if (typeof token !== 'string' || token.length < 40 || token.length > 256) return res.json({ active: false });
    try {
      const result = await repo.resolveAdminSessionByToken(digest(token, config.tokenLookupKey));
      if (!result?.active) return res.json({ active: false });
      return res.json({ active: true, userId: result.actorId, sessionId: result.sessionId, assurance, mfaVerifiedAt: new Date(result.verifiedAt).toISOString(), expiresAt: new Date(result.expiresAt).toISOString() });
    } catch { return fail(res, 503, 'temporarily_unavailable'); }
  });
  app.use((_req, res) => fail(res, 404, 'not_found'));
  app.use((err, _req, res, _next) => fail(res, 400, err?.type === 'entity.too.large' ? 'request_too_large' : 'invalid_request'));
  return app;
}

module.exports = { createAdminGatewayApp, COOKIE, PREAUTH, LIMITS, digest };
