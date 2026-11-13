'use strict';
// WP-S4: POST /recurring and PATCH /recurring/:id with an optional client edit
// clock. Without `id` / `clientEditedAt` the behaviour is unchanged (201 {id}).
const { safeErrorCode } = require('./safeErrorCode');
const { isUuid, rejectInvalidUuid, respondDbError, parseClientClock: parseClock } = require('./http_db_errors');
const { merchantSeriesKey, isUsableSubscriptionName } = require('./recurring');

const SERIES_COLS = `id, merchant_key, display_name, typical_amount_inr, cadence_days,
  next_expected_on, autopay_status, is_active, dismissed_at`;

function createRecurringPostHandler({ withUserClient }) {
  return async (req, res) => {
    const { displayName, typicalAmountInr, cadenceDays, nextExpectedOn, id, clientEditedAt } = req.body || {};
    const autopayStatus = req.body?.autopayStatus || 'unknown';
    const name = typeof displayName === 'string' ? displayName.trim() : '';
    const amount = Number(typicalAmountInr);
    const cadence = Number(cadenceDays);
    const dateIsValid = typeof nextExpectedOn === 'string'
      && /^\d{4}-\d{2}-\d{2}$/.test(nextExpectedOn)
      && !Number.isNaN(Date.parse(`${nextExpectedOn}T00:00:00Z`))
      && new Date(`${nextExpectedOn}T00:00:00Z`).toISOString().slice(0, 10) === nextExpectedOn;

    if (!isUsableSubscriptionName(name) || name.length > 80 ||
        !Number.isFinite(amount) || amount <= 0 || amount > 10000000 ||
        ![30, 365].includes(cadence) ||
        !['active', 'cancelled', 'unknown'].includes(autopayStatus) ||
        !dateIsValid) {
      return res.status(400).json({ error: 'invalid_subscription' });
    }
    const merchantKey = merchantSeriesKey(name);
    if (!merchantKey) return res.status(400).json({ error: 'invalid_subscription' });
    if (id !== undefined && id !== null && !isUuid(id)) return res.status(400).json({ error: 'invalid_id' });
    const clock = parseClock(clientEditedAt);
    if (!clock.ok) return res.status(400).json({ error: 'invalid_client_edited_at' });
    const extended = Boolean(id) || clientEditedAt !== undefined;

    try {
      const result = await withUserClient(req.userId, async (client) => {
        if (extended) {
          await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
            [`recurring:${req.userId}:${merchantKey}`]);
          if (id) {
            const same = await client.query(`SELECT ${SERIES_COLS} FROM recurring_series WHERE id = $1 AND profile_id = $2`, [id, req.userId]);
            if (same.rows.length) return { status: 200, body: { series: same.rows[0], replayed: true } };
          }
          if (clock.value) {
            const cur = await client.query(
              `SELECT ${SERIES_COLS} FROM recurring_series
                WHERE profile_id = $1 AND merchant_key = $2
                  AND (dismissed_at > $3::timestamptz OR client_edited_at > $3::timestamptz)`,
              [req.userId, merchantKey, clock.value]);
            if (cur.rows.length) return { status: 200, body: { series: cur.rows[0], superseded: true } };
          }
        }
        const inserted = await client.query(
          `INSERT INTO recurring_series
             (id, profile_id, merchant_key, display_name, typical_amount_inr,
              cadence_days, occurrence_count, first_seen_on, last_seen_on,
              next_expected_on, detection_source, user_edited, autopay_status, client_edited_at)
           VALUES (COALESCE($8::uuid, gen_random_uuid()), $1, $2, $3, $4, $5, 0, NULL, NULL, $6, 'manual', true, $7, $9::timestamptz)
           ON CONFLICT (profile_id, merchant_key) DO UPDATE SET
             display_name = EXCLUDED.display_name,
             typical_amount_inr = EXCLUDED.typical_amount_inr,
             cadence_days = EXCLUDED.cadence_days,
             next_expected_on = EXCLUDED.next_expected_on,
             detection_source = 'manual',
             user_edited = true,
             lifecycle_status = 'active',
             autopay_status = EXCLUDED.autopay_status,
             mandate_reference = NULL,
             mandate_started_on = NULL,
             mandate_cancelled_at = NULL,
             is_active = true,
             dismissed_at = NULL,
             client_edited_at = COALESCE(EXCLUDED.client_edited_at, recurring_series.client_edited_at),
             updated_at = now()
           RETURNING ${SERIES_COLS}`,
          [req.userId, merchantKey, name, amount, cadence, nextExpectedOn, autopayStatus, id || null, clock.value]);
        const row = inserted.rows[0];
        return { status: 201, body: extended ? { id: row.id, series: row } : { id: row.id } };
      });
      return res.status(result.status).json(result.body);
    } catch (err) {
      if (err && (err.code === '23505' || err.code === '22P02')) return respondDbError(res, err);
      console.error('POST /recurring error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

function createRecurringPatchHandler({ withUserClient }) {
  return async (req, res) => {
    if (rejectInvalidUuid(res, req.params.id)) return;
    const { displayName, typicalAmountInr, cadenceDays, nextExpectedOn, clientEditedAt } = req.body || {};
    const autopayStatus = req.body?.autopayStatus;
    if (typeof displayName !== 'string' || displayName.trim().length < 2 || displayName.trim().length > 80 ||
        !Number.isFinite(Number(typicalAmountInr)) || Number(typicalAmountInr) <= 0 || Number(typicalAmountInr) > 10000000 ||
        !Number.isInteger(Number(cadenceDays)) || Number(cadenceDays) < 1 || Number(cadenceDays) > 3650 ||
        (autopayStatus !== undefined && !['active', 'cancelled', 'unknown'].includes(autopayStatus)) ||
        typeof nextExpectedOn !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(nextExpectedOn) || Number.isNaN(Date.parse(`${nextExpectedOn}T00:00:00Z`))) {
      return res.status(400).json({ error: 'invalid_subscription' });
    }
    const clock = parseClock(clientEditedAt);
    if (!clock.ok) return res.status(400).json({ error: 'invalid_client_edited_at' });
    try {
      const out = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `UPDATE recurring_series SET display_name = $1, typical_amount_inr = $2,
                  cadence_days = $3, next_expected_on = $4,
                  autopay_status = COALESCE($5, autopay_status), user_edited = true,
                  cadence_confirmed = true,
                  client_edited_at = COALESCE($8::timestamptz, client_edited_at)
            WHERE id = $6 AND profile_id = $7 AND dismissed_at IS NULL
              AND ($8::timestamptz IS NULL OR client_edited_at IS NULL OR client_edited_at <= $8::timestamptz)
            RETURNING id`,
          [displayName.trim(), Number(typicalAmountInr), Number(cadenceDays), nextExpectedOn, autopayStatus ?? null, req.params.id, req.userId, clock.value]);
        if (result.rows.length) return 'ok';
        if (clock.value) {
          const cur = await client.query(
            `SELECT 1 FROM recurring_series WHERE id = $1 AND profile_id = $2
                AND (dismissed_at > $3::timestamptz OR client_edited_at > $3::timestamptz)`,
            [req.params.id, req.userId, clock.value]);
          if (cur.rows.length) return 'superseded';
        }
        return 'missing';
      });
      if (out === 'missing') return res.status(404).json({ error: 'not_found' });
      return res.json(out === 'superseded' ? { superseded: true } : { ok: true });
    } catch (err) {
      console.error('PATCH /recurring error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = { createRecurringPostHandler, createRecurringPatchHandler };
