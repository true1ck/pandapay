'use strict';

/**
 * POST /user-cards, extracted from index.js (WP-S2). Optional body `id`
 * (client-generated UUID) makes the add idempotent for the offline outbox:
 * a replay returns 200 {userCard, replayed:true} and does nothing else.
 * Without `id` the behaviour is unchanged.
 */

const { findCardAddConflict, normalizeCardLast4 } = require('./card_identity');
const { isUuid } = require('./http_db_errors');

const COLS = 'id, card_product_id, nickname, last4, is_default, sort_order, created_at';

function createUserCardsAddHandler({ withUserClient, scheduleSmsRepair, safeErrorCode }) {
  return async function userCardsAdd(req, res) {
    const { cardProductId, nickname, last4, id } = req.body || {};
    const normalizedLast4 = normalizeCardLast4(last4);
    if (!cardProductId || typeof cardProductId !== 'string') {
      return res.status(400).json({ error: 'cardProductId is required' });
    }
    if (normalizedLast4 !== null && !/^[0-9]{4}$/.test(normalizedLast4)) {
      return res.status(400).json({ error: 'last4 must be exactly 4 digits' });
    }
    const hasId = id !== undefined && id !== null;
    if (hasId && !isUuid(id)) return res.status(400).json({ error: 'invalid_id' });
    const clientId = hasId ? id.toLowerCase() : undefined;
    const echo = hasId ? { clientId: id } : {};

    let deferredRepair = null;
    try {
      const result = await withUserClient(req.userId, async (client) => {
        await client.query('SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))', [req.userId, cardProductId]);
        if (hasId) {
          const mine = await client.query(
            `SELECT ${COLS} FROM user_cards WHERE id = $1 AND profile_id = $2`,
            [clientId, req.userId],
          );
          if (mine.rows.length > 0) return { replayed: true, userCard: mine.rows[0] };
        }
        const card = await client.query(
          `SELECT id, issuer_id, card_type
             FROM card_products
            WHERE id = $1 AND status = 'published'`,
          [cardProductId]
        );
        if (card.rows.length === 0) return null;

        await client.query(`SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, [
          `card-identity:${req.userId}:${card.rows[0].issuer_id || ''}:${card.rows[0].card_type || ''}:${normalizedLast4 || ''}`,
        ]);

        const existing = await client.query(
          `SELECT uc.id, uc.card_product_id, uc.nickname, uc.last4,
                  uc.is_default, uc.sort_order, uc.created_at,
                   uc.is_archived, cp.name AS card_name,
                   cp.issuer_id, cp.card_type
             FROM user_cards uc
             JOIN card_products cp ON cp.id = uc.card_product_id
            WHERE uc.profile_id = $1 AND uc.is_archived = false
            ORDER BY uc.created_at ASC, uc.id ASC`,
          [req.userId],
        );
        const conflict = findCardAddConflict(existing.rows, {
          cardProductId,
          last4: normalizedLast4,
          issuerId: card.rows[0].issuer_id,
          cardType: card.rows[0].card_type,
        });
        if (conflict?.kind === 'already_present') {
          return { alreadyPresent: true, userCard: conflict.userCard };
        }
        if (conflict?.kind === 'link_existing') {
          const linked = await client.query(
            `UPDATE user_cards
                SET last4 = $1,
                    nickname = COALESCE(NULLIF($2, ''), nickname)
              WHERE id = $3 AND profile_id = $4 AND is_archived = false
              RETURNING ${COLS}`,
            [normalizedLast4, nickname || null, conflict.userCard.id, req.userId],
          );
          if (linked.rows.length > 0) {
            deferredRepair = { reviewCrossSource: true, reviewCardId: linked.rows[0].id };
            return { linkedExisting: true, userCard: linked.rows[0] };
          }
        }

        const inserted = hasId
          ? await client.query(
              `INSERT INTO user_cards (id, profile_id, card_product_id, nickname, last4)
               VALUES ($1, $2, $3, $4, $5)
               RETURNING ${COLS}`,
              [clientId, req.userId, cardProductId, nickname || null, normalizedLast4],
            )
          : await client.query(
              `INSERT INTO user_cards (profile_id, card_product_id, nickname, last4)
               VALUES ($1, $2, $3, $4)
               RETURNING ${COLS}`,
              [req.userId, cardProductId, nickname || null, normalizedLast4],
            );
        if (inserted.rows.length > 0 && normalizedLast4) {
          deferredRepair = { reviewCrossSource: true, reviewCardId: inserted.rows[0].id };
        }
        return inserted.rows[0];
      });

      if (!result) return res.status(404).json({ error: 'card_product not found or not published' });
      if (result.replayed) return res.status(200).json({ userCard: result.userCard, replayed: true });
      if (result.alreadyPresent) {
        return res.status(409).json({
          error: 'card_already_added',
          message: 'This card is already in your wallet.',
          userCard: result.userCard,
          ...echo,
        });
      }
      if (result.linkedExisting) {
        res.status(200).json({ userCard: result.userCard, linkedExisting: true, ...echo });
        if (deferredRepair) scheduleSmsRepair(req.userId, deferredRepair, 'POST /user-cards');
        return;
      }
      res.status(201).json({ userCard: result });
      if (deferredRepair) scheduleSmsRepair(req.userId, deferredRepair, 'POST /user-cards');
    } catch (err) {
      if (err && err.code === '23505' && err.constraint === 'uq_user_cards_active_identity') {
        return res.status(409).json({
          error: 'card_already_added',
          message: 'This physical card is already in your wallet.',
          ...echo,
        });
      }
      // Primary key taken by another profile's row: never reveal ownership.
      if (hasId && err && err.code === '23505') return res.status(409).json({ error: 'id_conflict' });
      console.error('POST /user-cards error', safeErrorCode(err));
      res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = { createUserCardsAddHandler };
