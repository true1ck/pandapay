'use strict';

const { safeErrorCode } = require('../utils/safeErrorCode');

const CAPABILITY_SQL = `SELECT 1 FROM auth_private.security_admins a
  JOIN public.users u ON u.id = a.user_id
 WHERE a.user_id = $1 AND a.revoked_at IS NULL AND a.expires_at > now()
   AND u.is_active = true AND u.deleted = false
 LIMIT 1`;

function createAdminAuth({ query, logger = console } = {}) {
  if (typeof query !== 'function') throw new TypeError('An authorization query is required');
  return async function adminAuth(req, res, next) {
    if (!req.user?.id) return res.status(401).json({ error: 'Authentication required' });
    try {
      const result = await query(CAPABILITY_SQL, [req.user.id]);
      if (!result.rows?.length) {
        return res.status(403).json({ error: 'Forbidden', message: 'Admin access required' });
      }
      return next();
    } catch (error) {
      logger.error('Security dashboard authorization unavailable', safeErrorCode(error));
      return res.status(503).json({ error: 'authorization_unavailable' });
    }
  };
}

// authMiddleware validates the session first. Token role labels and product
// console membership do not grant this separately provisioned capability.
const adminAuth = createAdminAuth({ query: (...args) => require('../db').query(...args) });
module.exports = adminAuth;
module.exports.createAdminAuth = createAdminAuth;
module.exports.CAPABILITY_SQL = CAPABILITY_SQL;
