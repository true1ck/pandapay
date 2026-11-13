'use strict';
// WP-S3: POST /budgets and DELETE /budgets/:id with an optional client edit
// clock. Without `id` / `clientEditedAt` / `X-Client-Edited-At` the behaviour is
// the pre-existing replace-the-active-budget semantics.
const { safeErrorCode } = require('./safeErrorCode');
const { isUuid, rejectInvalidUuid, respondDbError } = require('./http_db_errors');

const COLS = 'id, scope, scope_ref_id, period, amount_inr, starts_on, rollover, is_active';

function parseClock(v) {
  if (v === undefined || v === null || v === '') return { ok: true, value: null };
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(v) || Number.isNaN(Date.parse(v))) return { ok: false };
  return { ok: true, value: new Date(v).toISOString() };
}

function createBudgetPostHandler({ withUserClient, BUDGET_SCOPES, BUDGET_PERIODS }) {
  return async (req, res) => {
    const { scope, scopeRefId, period, amountInr, startsOn, rollover, id, clientEditedAt } = req.body || {};
    if (!BUDGET_SCOPES.includes(scope)) {
      return res.status(400).json({ error: `scope must be one of ${BUDGET_SCOPES.join(', ')}` });
    }
    if (!BUDGET_PERIODS.includes(period)) {
      return res.status(400).json({ error: `period must be one of ${BUDGET_PERIODS.join(', ')}` });
    }
    const amount = Number(amountInr);
    if (!Number.isFinite(amount) || amount <= 0) {
      return res.status(400).json({ error: 'amountInr must be a positive number' });
    }
    if (scope === 'overall' && scopeRefId) {
      return res.status(400).json({ error: 'an overall budget takes no scopeRefId' });
    }
    if (scope !== 'overall' && (!scopeRefId || typeof scopeRefId !== 'string')) {
      return res.status(400).json({ error: 'scopeRefId is required for a category or card budget' });
    }
    if (id !== undefined && id !== null && !isUuid(id)) return res.status(400).json({ error: 'invalid_id' });
    const clock = parseClock(clientEditedAt);
    if (!clock.ok) return res.status(400).json({ error: 'invalid_client_edited_at' });
    const newId = id || null;
    const edited = clock.value;
    const target = [req.userId, scope, period, scopeRefId || null];

    try {
      const result = await withUserClient(req.userId, async (client) => {
        // Serialise writers of one target so replay/supersede decisions and the
        // one-active-per-target index cannot race.
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
          [`budget:${req.userId}:${scope}:${scopeRefId || ''}:${period}`]);
        if (newId) {
          const same = await client.query(`SELECT ${COLS} FROM budgets WHERE id = $1 AND profile_id = $2`, [newId, req.userId]);
          if (same.rows.length) return { status: 200, body: { budget: same.rows[0], replayed: true } };
        }
        if (scope === 'category') {
          const found = await client.query(
            `SELECT id FROM spend_categories WHERE id = $1
             UNION ALL
             SELECT id FROM user_categories WHERE id = $1 AND profile_id = $2`,
            [scopeRefId, req.userId],
          );
          if (found.rows.length === 0) return { status: 404, body: { error: 'category not found' } };
        } else if (scope === 'tag') {
          const found = await client.query('SELECT id FROM transaction_tags WHERE id=$1 AND profile_id=$2 AND archived_at IS NULL', [scopeRefId, req.userId]);
          if (!found.rows.length) return { status: 422, body: { error: 'tag_unknown' } };
        } else if (scope === 'card') {
          const found = await client.query(
            `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
            [scopeRefId, req.userId],
          );
          if (found.rows.length === 0) return { status: 404, body: { error: 'card not found' } };
        }

        let active = true;
        if (edited) {
          // Newest edit ever made to this target (active, replaced or deleted).
          const newer = await client.query(
            `SELECT 1 FROM budgets
              WHERE profile_id = $1 AND scope = $2 AND period = $3
                AND scope_ref_id IS NOT DISTINCT FROM $4 AND client_edited_at > $5::timestamptz
              LIMIT 1`,
            [req.userId, scope, period, scopeRefId || null, edited]);
          if (newer.rows.length) active = false;
        }
        if (active) {
          await client.query(
            `UPDATE budgets SET is_active = false
              WHERE profile_id = $1 AND is_active AND scope = $2 AND period = $3
                AND scope_ref_id IS NOT DISTINCT FROM $4`,
            target);
        }
        const inserted = await client.query(
          `INSERT INTO budgets (id, profile_id, scope, scope_ref_id, period, amount_inr, starts_on, rollover, is_active, client_edited_at)
           VALUES (COALESCE($1::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, COALESCE($7::date, CURRENT_DATE), COALESCE($8, false), $9, $10::timestamptz)
           RETURNING ${COLS}`,
          [newId, req.userId, scope, scopeRefId || null, period, amount, startsOn || null, rollover, active, edited]);
        return active
          ? { status: 201, body: { budget: inserted.rows[0] } }
          : { status: 200, body: { budget: inserted.rows[0], superseded: true } };
      });
      return res.status(result.status).json(result.body);
    } catch (err) {
      if (err && (err.code === '23505' || err.code === '22P02')) return respondDbError(res, err);
      console.error('POST /budgets error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

function createBudgetDeleteHandler({ withUserClient }) {
  return async (req, res) => {
    if (rejectInvalidUuid(res, req.params.id)) return;
    const clock = parseClock(req.get ? req.get('x-client-edited-at') : req.headers?.['x-client-edited-at']);
    if (!clock.ok) return res.status(400).json({ error: 'invalid_client_edited_at' });
    try {
      const result = await withUserClient(req.userId, async (client) => {
        if (clock.value) {
          const row = await client.query(
            `SELECT client_edited_at > $3::timestamptz AS newer FROM budgets
              WHERE id = $1 AND profile_id = $2 AND is_active FOR UPDATE`,
            [req.params.id, req.userId, clock.value]);
          if (row.rows[0]?.newer) return { superseded: true };
        }
        const upd = await client.query(
          `UPDATE budgets SET is_active = false,
                  client_edited_at = COALESCE($3::timestamptz, client_edited_at)
            WHERE id = $1 AND profile_id = $2 AND is_active
            RETURNING id`,
          [req.params.id, req.userId, clock.value]);
        return { found: upd.rows.length > 0 };
      });
      if (result.superseded) return res.json({ superseded: true });
      if (!result.found) return res.status(404).json({ error: 'budget not found' });
      return res.json({ ok: true });
    } catch (err) {
      console.error('DELETE /budgets/:id error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = { createBudgetPostHandler, createBudgetDeleteHandler };
