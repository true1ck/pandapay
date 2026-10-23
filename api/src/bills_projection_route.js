/**
 * Read-only central projections for the Bills & Commitments surface.
 *
 * The local commitments store remains the offline source of truth. This route
 * is an additive read path for server projections produced from typed SMS
 * facts, and deliberately never reads raw SMS bodies or writes user data.
 */

const PROJECTION_KINDS = Object.freeze([
  'bill_obligation',
  'bill_payment',
  'mandate',
]);
const centralProjection = require('./central_financial_projection');

const MAX_LIMIT = 200;

function parseLimit(value) {
  if (value === undefined) return 100;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_LIMIT) return null;
  return parsed;
}

function parseKinds(value) {
  if (value === undefined || value === '') return [...PROJECTION_KINDS];
  const requested = String(value)
    .split(',')
    .map((kind) => kind.trim())
    .filter(Boolean);
  const unknown = requested.filter((kind) => !PROJECTION_KINDS.includes(kind));
  if (requested.length === 0 || unknown.length > 0) return null;
  return [...new Set(requested)];
}

function serializeProjection(row) {
  return {
    id: row.id,
    projectionKind: row.projection_kind,
    projectionKey: row.projection_key,
    status: row.status,
    projection: row.projection || {},
    sourceKey: row.source_key || null,
    sourceFactIds: Array.isArray(row.source_fact_ids) ? row.source_fact_ids : [],
    projectionVersion: row.projection_version,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function registerBillsProjectionRoutes(app, { requireAuth, withUserClient }) {
  app.get('/bills/projections', requireAuth, async (req, res) => {
    const kinds = parseKinds(req.query?.kinds);
    const limit = parseLimit(req.query?.limit);
    if (!kinds) return res.status(400).json({ error: 'kinds contains an unsupported projection kind' });
    if (!limit) return res.status(400).json({ error: `limit must be an integer between 1 and ${MAX_LIMIT}` });

    const includeClosed = req.query?.includeClosed === 'true';
    try {
      const rows = await withUserClient(req.userId, async (client) => {
        await centralProjection.backfillFinancialProjections(client, req.userId);
        const result = await client.query(
          `SELECT id, projection_kind, projection_key, status, projection,
                  source_key, source_fact_ids, projection_version,
                  created_at, updated_at
             FROM financial_projections
            WHERE profile_id = $1
              AND projection_kind = ANY($2::text[])
              AND ($3::boolean OR status NOT IN ('cancelled', 'ended'))
            ORDER BY updated_at DESC, id DESC
            LIMIT $4`,
          [req.userId, kinds, includeClosed, limit],
        );
        return result.rows || [];
      });

      return res.json({
        available: true,
        projections: rows.map(serializeProjection),
      });
    } catch (error) {
      // The projection migration is additive. Keep older API instances and
      // the local/offline Bills screen usable until it has been applied.
      if (error?.code === '42P01' || error?.code === '42703') {
        console.warn('central bill projections unavailable: migration not applied');
        return res.json({ available: false, projections: [] });
      }
      console.error('GET /bills/projections error', error.message || error);
      return res.status(500).json({ error: 'bill projections unavailable' });
    }
  });
}

module.exports = {
  MAX_LIMIT,
  PROJECTION_KINDS,
  parseKinds,
  parseLimit,
  serializeProjection,
  registerBillsProjectionRoutes,
};
