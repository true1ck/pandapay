const jwt = require('jsonwebtoken');

const ACCESS_SECRET = process.env.JWT_ACCESS_SECRET;

if (!ACCESS_SECRET) {
  throw new Error('JWT_ACCESS_SECRET must be set — must match auth/\'s signing secret exactly.');
}

// auth/src/services/tokenService.js signs with jwt.sign(payload, ACCESS_SECRET,
// { expiresIn }) and no `issuer` option — despite payload.aud being the literal
// string 'authenticated' (a leftover Supabase-shaped claim, not a verified JWT
// `aud` registered claim), jsonwebtoken's `issuer`/`audience` verify options
// check the real `iss`/`aud` claims, which were never set at sign time. So
// this API intentionally does NOT pass issuer/audience to jwt.verify — doing
// so silently rejects every real token auth/ issues. Trust boundary here is
// "signed with our shared secret", full stop; add issuer/audience back only
// if tokenService.js is changed to actually set them.

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
    const payload = jwt.verify(header.slice(7), ACCESS_SECRET);
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

module.exports = { optionalAuth, requireAuth };
