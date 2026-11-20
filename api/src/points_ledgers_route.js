'use strict';

// GET /points-ledgers?userCardIds=a,b,c — every listed card's points ledger in one request.
//
// The app opened with one GET /user-cards/:id/points-ledger per card: about 10 at once on every app open, each taking
// a pool connection and 3.6-5 s on the 1 GB host (21 Nov 2026). This answers all of them with two queries. Each
// card's list is exactly what the per-card route returns (same columns, newest first); a card that is not the
// person's is left out, where the per-card route answers 404. The per-card route stays for older app builds.

const { safeErrorCode } = require('./safeErrorCode');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_CARDS = 50;

function parseIds(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') return null;
  const ids = [...new Set(raw.split(',').map((s) => s.trim()))];
  if (ids.length === 0 || ids.length > MAX_CARDS || !ids.every((id) => UUID_RE.test(id))) return null;
  return ids;
}

function registerPointsLedgersRoute(app, { requireAuth, withUserClient }) {
  app.get('/points-ledgers', requireAuth, async (req, res) => {
    const ids = parseIds(req.query.userCardIds);
    if (!ids) return res.status(400).json({ error: `userCardIds must be 1 to ${MAX_CARDS} card ids, comma separated` });
    try {
      const ledgers = await withUserClient(req.userId, async (client) => {
        const owned = (await client.query(
          'SELECT id FROM user_cards WHERE id = ANY($1::uuid[]) AND profile_id = $2',
          [ids, req.userId],
        )).rows.map((row) => String(row.id));
        const out = {};
        for (const id of owned) out[id] = [];
        if (owned.length === 0) return out;
        const rows = (await client.query(
          `SELECT p.user_card_id, p.id, p.delta_points, p.reason, p.state, p.expires_on, p.occurred_at
             FROM points_ledger p
            WHERE p.user_card_id = ANY($1::uuid[])
            ORDER BY p.user_card_id, p.occurred_at DESC`,
          [owned],
        )).rows;
        for (const { user_card_id: cardId, ...entry } of rows) out[String(cardId)].push(entry);
        return out;
      });
      res.json({ pointsLedgers: ledgers });
    } catch (err) {
      console.error('GET /points-ledgers error', safeErrorCode(err));
      res.status(500).json({ error: 'internal_error' });
    }
  });
}

module.exports = { registerPointsLedgersRoute, MAX_CARDS };
