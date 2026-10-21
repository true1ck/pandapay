'use strict';

const jwt = require('jsonwebtoken');
const {
  getKeySecret,
  getAllKeys,
  getIssuer,
  getAudience,
  validateTokenClaims,
} = require('./jwtKeys');

function verifyAccessToken(token) {
  if (typeof token !== 'string' || token.length === 0 || token.length > 8192) {
    throw new Error('invalid_token');
  }
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded?.header || decoded.header.alg !== 'HS256') throw new Error('invalid_token');

  const keyId = decoded.header.kid;
  if (keyId && !getKeySecret(keyId)) throw new Error('invalid_token');
  const secrets = keyId ? [getKeySecret(keyId)] : Object.values(getAllKeys());
  let payload;
  for (const secret of secrets) {
    try {
      payload = jwt.verify(token, secret, {
        algorithms: ['HS256'],
        issuer: getIssuer(),
        audience: getAudience(),
      });
      break;
    } catch (_) {
      // Try the remaining configured rotation keys only when the token has no kid.
    }
  }
  if (!payload || typeof payload.sub !== 'string') throw new Error('invalid_token');
  if (!validateTokenClaims(payload).valid) throw new Error('invalid_token');
  return payload;
}

module.exports = { verifyAccessToken };
