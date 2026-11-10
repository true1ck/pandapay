'use strict';

const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const config = require('./config');
const { withUserClient } = require('./db');

const SESSION_CACHE_TTL_MS = 5_000;
const SESSION_CACHE_MAX_ENTRIES = 1_000;
const sessionCache = new Map();

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
      const claims = jwt.verify(token, secret, {
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

async function fetchCurrentSession(token, fetchImpl = globalThis.fetch) {
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
    return res.status(error.status).json({ error: error.code });
  }
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

async function getProductMembership(userId) {
  return withUserClient(userId, async (client) => {
    const result = await client.query(
      'SELECT promotions.current_user_is_member() AS is_member',
    );
    return result.rows[0]?.is_member === true;
  });
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
};
