const jwt = require('jsonwebtoken');
const config = require('./config');

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
      return jwt.verify(token, secret, {
        issuer: config.jwtIssuer,
        audience: config.jwtAudience,
      });
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError || new Error('Invalid access token');
}

/**
 * Verifies the access token issued by auth/ (same secret — that service is
 * the sole identity root). On success, req.userId is the auth service's
 * users.id, the same id the product schema expects at profiles.id (see
 * db/supabase/migrations/0004_user_domain.sql). Requests without a valid
 * token get req.userId = null, not a 401 here — individual routes decide
 * whether anonymous access makes sense (catalogue reads do, profile writes
 * don't; RLS is the actual enforcement either way).
 */
function optionalAuth(req, res, next) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    req.userId = null;
    return next();
  }
  try {
    const payload = verifyAccessToken(header.slice(7));
    req.userId = payload.sub;
  } catch (err) {
    req.userId = null;
  }
  next();
}

function requireAuth(req, res, next) {
  if (!req.userId) {
    return res.status(401).json({ error: 'Missing or invalid access token' });
  }
  next();
}

module.exports = { optionalAuth, requireAuth, verifyAccessToken };

