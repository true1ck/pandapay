'use strict';

// One narrow question for the sign-in service during account recovery: does this
// person have cards, and does one end in these four digits? The sign-in service
// cannot read cards (they belong to this service and sit behind row security), so it
// asks. The answer is two booleans. A card number, a nickname or a count never leaves.

const crypto = require('node:crypto');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function hasServiceSecret(suppliedValue, expectedValue) {
  if (typeof suppliedValue !== 'string' || typeof expectedValue !== 'string' || expectedValue.length < 32) return false;
  const supplied = crypto.createHash('sha256').update(suppliedValue).digest();
  const expected = crypto.createHash('sha256').update(expectedValue).digest();
  return crypto.timingSafeEqual(supplied, expected);
}

function normalizeRequest(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const keys = Object.keys(body);
  if (!keys.every(key => key === 'user_id' || key === 'last4')) return null;
  if (typeof body.user_id !== 'string' || !UUID.test(body.user_id)) return null;
  if (body.last4 !== null && body.last4 !== undefined &&
      !(typeof body.last4 === 'string' && /^\d{4}$/.test(body.last4))) return null;
  return { userId: body.user_id.toLowerCase(), last4: body.last4 || null };
}

function registerRecoveryInternalRoutes(app, { withUserClient, serviceSecret }) {
  app.post('/internal/recovery/card-fact', async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    const secret = typeof serviceSecret === 'function' ? serviceSecret() : serviceSecret;
    if (!hasServiceSecret(req.get('x-auth-service-secret'), secret)) {
      return res.status(secret ? 401 : 503).json({ error: 'service_auth_unavailable' });
    }
    const request = normalizeRequest(req.body);
    if (!request) return res.status(400).json({ error: 'invalid_request' });
    try {
      // Cards with no recorded last four cannot be asked about, so they do not count:
      // an account whose cards all lack one falls back to the sign-up month rule.
      const result = await withUserClient(request.userId, client => client.query(
        `SELECT EXISTS (SELECT 1 FROM user_cards WHERE profile_id = $1 AND last4 IS NOT NULL) AS has_cards,
                EXISTS (SELECT 1 FROM user_cards WHERE profile_id = $1 AND last4 = $2::text) AS matched`,
        [request.userId, request.last4],
      ));
      const row = result.rows[0] || {};
      return res.json({ has_cards: row.has_cards === true, matched: request.last4 ? row.matched === true : false });
    } catch (error) {
      console.error('[recovery] card fact failed', error?.code || error?.name);
      return res.status(500).json({ error: 'internal_error' });
    }
  });
}

module.exports = { registerRecoveryInternalRoutes, hasServiceSecret, normalizeRequest };
