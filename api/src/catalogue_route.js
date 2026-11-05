'use strict';

const { safeErrorCode } = require('./safeErrorCode');

// GET /catalogue serves the v1 feed by default (exact shape installed apps
// parse; plan H1) and the v2 feed when ?schema=2 (plan C2).

const V1_SQL = 'SELECT * FROM v_card_catalogue_export ORDER BY name';
const V2_CARDS_SQL = 'SELECT * FROM v_card_catalogue_export_v2 ORDER BY name';
const V2_MERCHANTS_SQL =
  'SELECT slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc ' +
  'FROM merchant_brands WHERE is_active ORDER BY slug';
const V2_PLATFORMS_SQL =
  'SELECT slug, name, kind, issuer_slug, aliases ' +
  'FROM payment_platforms WHERE is_active ORDER BY slug';

function wantsV2(req) {
  const schema = req && req.query ? req.query.schema : undefined;
  return schema === '2';
}

function createCatalogueHandler({ withUserClient, logger = console }) {
  return async function catalogueHandler(req, res) {
    try {
      const user = req.user || null;
      if (wantsV2(req)) {
        const body = await withUserClient(user, async (client) => {
          const cards = await client.query(V2_CARDS_SQL);
          const merchants = await client.query(V2_MERCHANTS_SQL);
          const platforms = await client.query(V2_PLATFORMS_SQL);
          return { schema: 2, cards: cards.rows, merchants: merchants.rows, platforms: platforms.rows };
        });
        return res.json(body);
      }
      const result = await withUserClient(user, (client) => client.query(V1_SQL));
      return res.json({ cards: result.rows });
    } catch (err) {
      logger.error('GET /catalogue error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = { createCatalogueHandler, V1_SQL, V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL };
