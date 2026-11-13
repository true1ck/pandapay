'use strict';

/**
 * POST /card-overrides (WP-S2). Optional body `id` (client UUID) makes the
 * create idempotent: INSERT ... ON CONFLICT (id) DO NOTHING, and a replay
 * returns the stored row untouched (never overwrites a newer edit).
 */

const { isUuid, respondDbError } = require('./http_db_errors');

const COLS = 'id, user_card_id, scope, vpa, merchant_name, category_id, reason_note, is_enabled, created_at';

function createCardOverridesPostHandler({ withUserClient, safeErrorCode }) {
  return async function cardOverridesPost(req, res) {
    const { userCardId, scope, vpa, merchantName, categoryId, reasonNote, id } = req.body || {};
    if (!userCardId || typeof userCardId !== 'string') {
      return res.status(400).json({ error: 'userCardId is required' });
    }
    if (!['vpa', 'merchant_name', 'category'].includes(scope)) {
      return res.status(400).json({ error: "scope must be 'vpa', 'merchant_name', or 'category'" });
    }
    if (scope === 'vpa' && !vpa) return res.status(400).json({ error: 'vpa is required when scope is vpa' });
    if (scope === 'merchant_name' && !merchantName) {
      return res.status(400).json({ error: 'merchantName is required when scope is merchant_name' });
    }
    if (scope === 'category' && !categoryId) {
      return res.status(400).json({ error: 'categoryId is required when scope is category' });
    }
    const hasId = id !== undefined && id !== null;
    if (hasId && !isUuid(id)) return res.status(400).json({ error: 'invalid_id' });
    if (!isUuid(userCardId) || (categoryId && !isUuid(categoryId))) {
      return res.status(400).json({ error: 'invalid_id' });
    }

    try {
      const result = await withUserClient(req.userId, async (client) => {
        if (hasId) {
          const mine = await client.query(
            `SELECT ${COLS} FROM card_overrides WHERE id = $1 AND profile_id = $2`,
            [id.toLowerCase(), req.userId],
          );
          if (mine.rows.length > 0) return { replayed: true, override: mine.rows[0] };
        }
        const owns = await client.query(
          `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
          [userCardId, req.userId]
        );
        if (owns.rows.length === 0) return null;

        const values = [req.userId, userCardId, scope, vpa || null, merchantName || null, categoryId || null, reasonNote || null];
        if (hasId) values.push(id.toLowerCase());
        const inserted = await client.query(
          `INSERT INTO card_overrides (profile_id, user_card_id, scope, vpa, merchant_name, category_id, reason_note${hasId ? ', id' : ''})
           VALUES ($1, $2, $3, $4, $5, $6, $7${hasId ? ', $8' : ''})${hasId ? ' ON CONFLICT (id) DO NOTHING' : ''}
           RETURNING ${COLS}`,
          values
        );
        // ON CONFLICT swallowed it: the id belongs to someone else (ours was checked above).
        if (inserted.rows.length === 0) return { idConflict: true };
        return { override: inserted.rows[0] };
      });

      if (!result) return res.status(404).json({ error: 'user_card not found or not owned by you' });
      if (result.idConflict) return res.status(409).json({ error: 'id_conflict' });
      if (result.replayed) return res.status(200).json({ override: result.override, replayed: true });
      res.status(201).json({ override: result.override });
    } catch (err) {
      if (respondDbError(res, err)) return;
      console.error('POST /card-overrides error', safeErrorCode(err));
      res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = { createCardOverridesPostHandler };
