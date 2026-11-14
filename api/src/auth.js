'use strict';

const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const config = require('./config');
const { withUserClient } = require('./db');

const SESSION_CACHE_TTL_MS = 5_000;
const SESSION_CACHE_MAX_ENTRIES = 1_000;
const sessionCache = new Map();

// jsonwebtoken first tries to parse a string secret as a public key (which throws) on every verify, ~9% of the
// API's CPU under load. A KeyObject skips that; HS256 with the same bytes verifies identically.
const hmacKeys = new Map();
function hmacKey(secret) {
  let key = hmacKeys.get(secret);
  if (!key) {
    key = crypto.createSecretKey(Buffer.from(secret));
    hmacKeys.set(secret, key);
  }
  return key;
}

function verifyAccessToken(token) {
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded || !decoded.header) throw new Error('Invalid token format');

  const keyId = decoded.header.kid;
  if (keyId && !config.jwtKeys[keyId]) {
    throw new Error('Unknown access token key id');
  }
  const keyedSecret = keyId ? config.jwtKeys[keyId] : null;
  const secrets = keyedSecret ? [keyedSecret] : Object.values(config.jwtKeys);
  let lastError = null;

  for (const secret of secrets) {
    try {
      const claims = jwt.verify(token, hmacKey(secret), {
        algorithms: ['HS256'],
        issuer: config.jwtIssuer,
        audience: config.jwtAudience,
      });
      // Guest sessions no longer exist; refuse any guest token still in the wild.
      if (claims.is_guest === true) throw new Error('Guest tokens are not accepted');
      return claims;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError || new Error('Invalid access token');
}

/**
 * Local signature verification is only a fast rejection. Product access also
 * checks the auth service's current account/device/token-version state below.
 */
function optionalAuth(req, _res, next) {
  const header = req.headers.authorization;
  req.accessToken = null;
  req.authClaims = null;
  req.userId = null;
  if (!header || !header.startsWith('Bearer ')) return next();

  const token = header.slice(7);
  try {
    const payload = verifyAccessToken(token);
    req.accessToken = token;
    req.authClaims = payload;
    req.userId = payload.sub;
  } catch (_) {
    // Public routes can remain public; every private route performs the
    // authoritative verification and returns an authentication error.
  }
  return next();
}

class SessionVerificationError extends Error {
  constructor(code, status = 401) {
    super(code);
    this.name = 'SessionVerificationError';
    this.code = code;
    this.status = status;
  }
}

function cacheSession(key, value) {
  if (sessionCache.size >= SESSION_CACHE_MAX_ENTRIES) {
    const now = Date.now();
    for (const [entryKey, entry] of sessionCache) {
      if (entry.expiresAt <= now) {
        sessionCache.delete(entryKey);
      }
    }
  }
  while (sessionCache.size >= SESSION_CACHE_MAX_ENTRIES) {
    const oldestKey = sessionCache.keys().next().value;
    if (oldestKey === undefined) break;
    sessionCache.delete(oldestKey);
  }
  sessionCache.set(key, { value, expiresAt: Date.now() + SESSION_CACHE_TTL_MS });
}

// Requests for one session that arrive while the auth service is still answering the first one share
// that answer. A phone opening a screen sends several requests at once; without this each one called
// the auth service itself (the 5 s cache is only filled after the reply), which multiplied the load on
// it and turned its slow replies into 503s for every page, not just that screen.
const sessionInFlight = new Map();
async function fetchCurrentSession(token, fetchImpl = globalThis.fetch) {
  const key = crypto.createHash('sha256').update(String(token)).digest('hex');
  const shared = sessionInFlight.get(key);
  if (shared && shared.fetchImpl === fetchImpl) return shared.promise;
  const promise = fetchCurrentSessionOnce(token, fetchImpl);
  sessionInFlight.set(key, { fetchImpl, promise });
  try {
    return await promise;
  } finally {
    if (sessionInFlight.get(key)?.promise === promise) sessionInFlight.delete(key);
  }
}

async function fetchCurrentSessionOnce(token, fetchImpl) {
  if (!config.authInternalBaseUrl || !config.authInternalServiceSecret) {
    throw new SessionVerificationError('auth_service_unavailable', 503);
  }
  if (typeof fetchImpl !== 'function') {
    throw new SessionVerificationError('auth_service_unavailable', 503);
  }

  const cacheKey = crypto.createHash('sha256').update(token).digest('hex');
  const cached = sessionCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) return cached.value;
  if (cached) sessionCache.delete(cacheKey);

  let response;
  try {
    response = await fetchImpl(`${config.authInternalBaseUrl}/internal/session/verify`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'x-auth-service-secret': config.authInternalServiceSecret,
        'content-type': 'application/json',
      },
      body: '{}',
      signal: AbortSignal.timeout(4_000),
    });
  } catch (_) {
    throw new SessionVerificationError('auth_service_unavailable', 503);
  }
  if (!response.ok) {
    // 401 from the private endpoint means the two backend secrets disagree;
    // do not misrepresent that infrastructure failure as an expired user.
    throw new SessionVerificationError('auth_service_unavailable', 503);
  }

  let result;
  try {
    result = await response.json();
  } catch (_) {
    throw new SessionVerificationError('auth_service_unavailable', 503);
  }
  const session = {
    tokenValid: result?.token_valid === true,
    valid: result?.valid === true,
    subject: typeof result?.subject === 'string' ? result.subject : null,
    active: result?.session?.active === true,
    revoked: result?.session?.revoked === true,
    verifiedContacts: result?.verified_contacts || {},
    // A phone the person typed in. Not verified, so it is kept apart from verifiedContacts.
    claimedContacts: {
      phone: result?.claimed_contacts?.phone?.claimed === true
        && typeof result.claimed_contacts.phone.value === 'string'
        ? { claimed: true, value: result.claimed_contacts.phone.value }
        : { claimed: false, value: null },
    },
    // The number held for the account, verified or not. Older auth/ sends nothing (no number).
    phoneOnFile: typeof result?.phone_on_file?.value === 'string' && result.phone_on_file.value
      ? { value: result.phone_on_file.value }
      : { value: null },
    // Set by auth/ when the phone lock is switched on. An older auth/ sends nothing,
    // which means "not required", so deploy order does not matter.
    phoneGate: {
      required: result?.phone_gate?.required === true,
      satisfied: result?.phone_gate?.satisfied === true,
    },
    authProof: result?.auth_proof || {},
  };
  cacheSession(cacheKey, session);
  return session;
}

async function verifyRequestSession(req) {
  if (!req.accessToken || !req.userId) {
    throw new SessionVerificationError('session_invalid', 401);
  }
  let session;
  try {
    session = await fetchCurrentSession(req.accessToken);
  } catch (error) {
    if (error instanceof SessionVerificationError) throw error;
    throw new SessionVerificationError('auth_service_unavailable', 503);
  }
  if (!session.tokenValid || !session.valid || !session.active || session.revoked
      || session.subject !== req.userId) {
    throw new SessionVerificationError('session_invalid', 401);
  }
  req.verifiedSession = session;
  runVerifiedSessionHooks(req);
  return session;
}

// Called for every request whose session was just verified. Lets a feature keep
// per-person state current (for example the split phone directory) without the
// person having to open that feature first.
const verifiedSessionHooks = [];
function runVerifiedSessionHooks(req) {
  for (const hook of verifiedSessionHooks) {
    // Best effort and never awaited: a hook can never slow or fail a request.
    try { hook(req); } catch (_) { /* ignored */ }
  }
}
function onVerifiedSession(hook) {
  if (typeof hook === 'function') verifiedSessionHooks.push(hook);
}

function sendSessionError(res, error) {
  if (error instanceof SessionVerificationError) {
    if (error.status === 503) res.set('Retry-After', String(5 + Math.floor(Math.random() * 4)));
    return res.status(error.status).json({ error: error.code });
  }
  res.set('Retry-After', String(5 + Math.floor(Math.random() * 4)));
  return res.status(503).json({ error: 'access_check_unavailable' });
}

async function requireVerifiedSession(req, res, next) {
  try {
    await verifyRequestSession(req);
    return next();
  } catch (error) {
    return sendSessionError(res, error);
  }
}

// Membership was one extra database transaction on every request. A positive answer is reused for a few
// seconds; a negative or failed one is never cached, so a new member is let in at once and only a removal
// can lag by up to MEMBERSHIP_CACHE_TTL_MS (account deletion is enforced separately in withUserClient).
const MEMBERSHIP_CACHE_TTL_MS = 10_000;
const MEMBERSHIP_CACHE_MAX_ENTRIES = 5_000;
const membershipCache = new Map();

async function getProductMembership(userId) {
  const cached = membershipCache.get(userId);
  if (cached && cached > Date.now()) return true;
  const isMember = await withUserClient(userId, async (client) => {
    const result = await client.query(
      'SELECT promotions.current_user_is_member() AS is_member',
    );
    return result.rows[0]?.is_member === true;
  });
  if (isMember) {
    if (membershipCache.size >= MEMBERSHIP_CACHE_MAX_ENTRIES) membershipCache.delete(membershipCache.keys().next().value);
    membershipCache.set(userId, Date.now() + MEMBERSHIP_CACHE_TTL_MS);
  } else {
    membershipCache.delete(userId);
  }
  return isMember;
}

/** With the phone lock on, an account that has no phone can do nothing but add one. */
function requirePhoneIfLocked(session) {
  if (session.phoneGate?.required === true && session.phoneGate.satisfied !== true) {
    throw new SessionVerificationError('phone_required', 403);
  }
}

async function verifyMemberRequest(req) {
  const session = await verifyRequestSession(req);
  requirePhoneIfLocked(session);
  let isMember;
  try {
    isMember = await getProductMembership(req.userId);
  } catch (_) {
    throw new SessionVerificationError('access_check_unavailable', 503);
  }
  if (!isMember) throw new SessionVerificationError('membership_required', 403);
  return session;
}

async function requireAuth(req, res, next) {
  try {
    await verifyMemberRequest(req);
    return next();
  } catch (error) {
    return sendSessionError(res, error);
  }
}


function requireValidJwt(req, res, next) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid access token' });
  }
  try {
    const payload = verifyAccessToken(header.slice(7));
    req.accessToken = header.slice(7);
    req.authClaims = payload;
    req.userId = payload.sub;
    return next();
  } catch (_) {
    return res.status(401).json({ error: 'Missing or invalid access token' });
  }
}
module.exports = {
  optionalAuth,
  requireAuth,
  requireValidJwt,
  requireVerifiedSession,
  verifyAccessToken,
  verifyRequestSession,
  onVerifiedSession,
  _runVerifiedSessionHooks: runVerifiedSessionHooks,
  verifyMemberRequest,
  requirePhoneIfLocked,
  fetchCurrentSession,
  SessionVerificationError,
  _sessionCache: sessionCache,
  _membershipCache: membershipCache,
};
