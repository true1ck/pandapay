'use strict';

// GET /admin/sms/v2/audit?limit=50 (learning-loop B7): who changed which
// setting, limit, rule, decision or draft, when and why. Read-only; the
// database function returns only the columns shown (no before or after bodies).
const { HttpError } = require('./rules_admin_route');

const DEFAULT_LIMIT = 50;

function parseLimit(raw) {
  if (raw === undefined) return DEFAULT_LIMIT;
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!/^[0-9]{1,3}$/.test(String(text))) throw new HttpError(400, 'audit_limit_invalid');
  const limit = Number(text);
  if (limit < 1 || limit > 200) throw new HttpError(400, 'audit_limit_invalid');
  return limit;
}

function registerPrivateAuditRoutes(api) {
  api.route('GET', '/admin/sms/v2/audit', async (req, res, ctx) => {
    try {
      const limit = parseLimit(req.query.limit);
      const rows = await ctx.withAdminClient((client) =>
        client.query('SELECT * FROM pandapay.sms_v2_audit_feed($1)', [limit]));
      return res.json({
        entries: rows.rows.map((row) => ({
          at: row.at, adminId: row.admin_id, action: row.action, entity: row.entity,
          entityId: row.entity_id, reason: row.reason,
        })),
      });
    } catch (error) {
      if (error instanceof HttpError) return res.status(error.status).json({ error: error.code });
      if (error.code === '42501' || error.code === 'ADMIN_PERMISSION_DENIED') return res.status(403).json({ error: 'admin_permission_required' });
      console.error('sms_v2 audit failed', error.code || error.name);
      return res.status(500).json({ error: 'audit_unavailable' });
    }
  });
}

module.exports = { registerPrivateAuditRoutes, parseLimit };
