const { safeErrorCode } = require('./safeErrorCode');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Validate before writing NUMERIC(…, 2): rounding each stored row after
// comparing an unrounded sum can otherwise create an over-allocation.
function validateSplits(splits) {
  if (!Array.isArray(splits)) return 'splits must be an array';
  if (splits.length > 20) return 'at most 20 splits per transaction';
  for (const split of splits) {
    if (!split || typeof split !== 'object' || Array.isArray(split)) return 'invalid split';
    const amount = split.amountInr;
    const paise = amount * 100;
    if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0 ||
        !Number.isSafeInteger(Math.round(paise)) || Math.round(paise) < 1 ||
        Math.abs(paise - Math.round(paise)) > 0.000001) {
      return 'each split needs a positive amountInr with at most two decimal places';
    }
    if (split.note != null && (typeof split.note !== 'string' || split.note.length > 2000)) {
      return 'split note must be a string of at most 2000 characters or null';
    }
    for (const key of ['userCardId', 'categoryId']) {
      if (split[key] != null && (typeof split[key] !== 'string' ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(split[key]))) {
        return `${key} must be a UUID or null`;
      }
    }
  }
  return null;
}

function splitTotalPaise(splits) {
  return splits.reduce((sum, split) => sum + Math.round(split.amountInr * 100), 0);
}

// A whole split is one document. Ignore generated IDs, labels and row order
// so a retry after a lost response is a no-op rather than a second rewrite.
function splitFingerprint(splits) {
  const rows = splits.map((s) => JSON.stringify([
    Math.round(Number(s.amountInr ?? s.amount_inr) * 100),
    s.userCardId ?? s.user_card_id ?? null,
    s.categoryId ?? s.category_id ?? null,
    s.note || null,
  ])).sort();
  return require('crypto').createHash('sha256').update(JSON.stringify(rows)).digest('hex');
}

function splitWriteDecision(current, desired, expectedFingerprint) {
  if (splitFingerprint(current) === splitFingerprint(desired)) return 'unchanged';
  if (expectedFingerprint != null && expectedFingerprint !== splitFingerprint(current)) return 'conflict';
  return 'write';
}

module.exports = { validateSplits, splitTotalPaise, splitFingerprint, splitWriteDecision };


function registerSplitRoutes(app, { requireAuth, withUserClient }) {
app.get('/transactions/:id/splits', requireAuth, async (req, res) => {
  if (typeof req.params.id !== 'string' || !UUID.test(req.params.id)) {
    return res.status(400).json({ error: 'invalid transaction id' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const owns = await client.query(`SELECT id FROM transactions WHERE id = $1 AND profile_id = $2`, [
        req.params.id,
        req.userId,
      ]);
      if (owns.rows.length === 0) return null;
      return client.query(
        `SELECT ts.id, ts.user_card_id, ts.category_id, ts.amount_inr, ts.note,
                sc.name AS category_name
           FROM transaction_splits ts
           LEFT JOIN spend_categories sc ON sc.id = ts.category_id
          WHERE ts.transaction_id = $1
          ORDER BY ts.amount_inr DESC`,
        [req.params.id]
      );
    });
    if (!result) return res.status(404).json({ error: 'transaction not found' });
    res.json({ splits: result.rows, fingerprint: splitFingerprint(result.rows) });
  } catch (err) {
    console.error('GET /transactions/:id/splits error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PUT /transactions/:id/splits — replace this transaction's whole split set.
 *
 * Replace, not append: a split is a partition of one amount, so the only
 * coherent unit of edit is the whole set. Appending would let a client
 * build a set summing to more than the transaction, and per-row PATCH would
 * make "move ₹100 from A to B" two writes with an invalid state in between.
 *
 * The sum is validated against the parent amount and rejected if it
 * exceeds it — over-splitting is always a bug. Splitting to *less* than the
 * full amount is allowed: partially splitting a bill ("₹400 of this ₹1,000
 * was Priya's") is a real thing users do, and the remainder is simply
 * unallocated.
 *
 * **These do not touch reward state.** Cap, milestone and points state were
 * computed from the transaction as a whole, on the card it was actually
 * paid with; splits record who owed what, not a second set of payments.
 * Recomputing state from splits would double-count the spend.
 */
app.put('/transactions/:id/splits', requireAuth, async (req, res) => {
  if (typeof req.params.id !== 'string' || !UUID.test(req.params.id)) {
    return res.status(400).json({ error: 'invalid transaction id' });
  }
  const splits = (req.body || {}).splits;
  const validationError = validateSplits(splits);
  if (validationError) return res.status(400).json({ error: validationError });
  const expectedFingerprint = req.body.expectedFingerprint;
  if (expectedFingerprint != null &&
      (typeof expectedFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(expectedFingerprint))) {
    return res.status(400).json({ error: 'invalid expectedFingerprint' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const parent = await client.query(
        `SELECT id, amount_inr FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (parent.rows.length === 0) return { status: 404, error: 'transaction not found' };

      const current = await client.query(
        `SELECT ts.id, ts.user_card_id, ts.category_id, ts.amount_inr, ts.note,
                sc.name AS category_name
           FROM transaction_splits ts
           LEFT JOIN spend_categories sc ON sc.id = ts.category_id
          WHERE ts.transaction_id = $1 ORDER BY ts.amount_inr DESC`, [req.params.id]
      );
      const decision = splitWriteDecision(current.rows, splits, expectedFingerprint);
      if (decision === 'unchanged') return { status: 200, splits: current.rows };
      if (decision === 'conflict') return { status: 409, error: 'split_conflict' };

      const total = splitTotalPaise(splits);
      // Compared in paise to avoid a float sum tripping the check on an
      // exact split (three ₹33.34 shares of ₹100.02, say).
      if (total > Math.round(Number(parent.rows[0].amount_inr) * 100)) {
        return { status: 400, error: 'splits total more than the transaction amount' };
      }

      for (const split of splits) {
        if (split.userCardId) {
          const card = await client.query(
            'SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2',
            [split.userCardId, req.userId]
          );
          if (!card.rows.length) return { status: 400, error: 'split card not found' };
        }
        if (split.categoryId) {
          const category = await client.query('SELECT id FROM spend_categories WHERE id = $1', [split.categoryId]);
          if (!category.rows.length) return { status: 400, error: 'split category not found' };
        }
      }
      await client.query(`DELETE FROM transaction_splits WHERE transaction_id = $1`, [req.params.id]);
      for (const split of splits) {
        await client.query(
          `INSERT INTO transaction_splits (transaction_id, user_card_id, category_id, amount_inr, note)
           VALUES ($1, $2, $3, $4, $5)`,
          [
            req.params.id,
            split.userCardId || null,
            split.categoryId || null,
            Number(split.amountInr),
            split.note || null,
          ]
        );
      }

      const saved = await client.query(
        `SELECT ts.id, ts.user_card_id, ts.category_id, ts.amount_inr, ts.note,
                sc.name AS category_name
           FROM transaction_splits ts
           LEFT JOIN spend_categories sc ON sc.id = ts.category_id
          WHERE ts.transaction_id = $1
          ORDER BY ts.amount_inr DESC`,
        [req.params.id]
      );
      return { status: 200, splits: saved.rows };
    });

    if (result.error) return res.status(result.status).json({ error: result.error });
    res.json({ splits: result.splits, fingerprint: splitFingerprint(result.splits) });
  } catch (err) {
    console.error('PUT /transactions/:id/splits error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

}
module.exports.registerSplitRoutes = registerSplitRoutes;
