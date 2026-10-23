'use strict';

const { safeErrorCode } = require('./safeErrorCode');

const HOLD_SCOPES = new Set(['admission', 'enrollment', 'fulfillment', 'redemption']);

function registerAdminReferralOperationsRoutes(app, { withUserClient, requireAdmin }) {
  app.get('/admin/referrals/operations', requireAdmin, async (req, res) => {
    try {
      const result = await withUserClient(req.userId, (client) =>
        client.query('SELECT promotions.get_admin_referral_operations() AS operations')
      );
      return res.json({ operations: result.rows[0].operations });
    } catch (err) {
      console.error('GET /admin/referrals/operations error', safeErrorCode(err));
      return res.status(500).json({ error: 'referral_operations_unavailable' });
    }
  });

  app.put('/admin/referrals/holds/:scope', requireAdmin, async (req, res) => {
    const { scope } = req.params;
    const body = req.body || {};
    const reason = typeof body.reason === 'string' ? body.reason.trim() : '';
    if (!HOLD_SCOPES.has(scope) || typeof body.paused !== 'boolean'
        || reason.length < 10 || reason.length > 500) {
      return res.status(400).json({ error: 'invalid_referral_hold_request' });
    }

    try {
      const result = await withUserClient(req.userId, (client) =>
        client.query(
          'SELECT promotions.set_admin_referral_hold($1, $2, $3) AS hold',
          [scope, body.paused, reason]
        )
      );
      return res.json({ hold: result.rows[0].hold });
    } catch (err) {
      if (err.code === 'P0001' && err.message === 'referral_hold_not_active') {
        return res.status(409).json({ error: 'referral_hold_not_active' });
      }
      if (err.code === 'P0001' && err.message === 'campaign_unavailable') {
        return res.status(409).json({ error: 'campaign_unavailable' });
      }
      console.error('PUT /admin/referrals/holds/:scope error', safeErrorCode(err));
      return res.status(500).json({ error: 'referral_hold_unavailable' });
    }
  });
}

module.exports = { HOLD_SCOPES, registerAdminReferralOperationsRoutes };
