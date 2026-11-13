'use strict';

/**
 * Points the bank says it credited ("Reward Points Credited: 2500 To HDFC Bank
 * Credit Card 5678 ...", "We have credited 12 NeuCoins ...").
 *
 * The phone reads those messages as `reward` facts with a `points_earned`
 * amount. This writes each one to the card's points ledger as a CONFIRMED row
 * (reason 'issuer credit') so the points history shows what the bank really
 * paid, next to the estimates the app computes from spends.
 *
 * Rules that keep it honest:
 *   - Idempotent: the row's client_mutation_id is derived from the SMS identity
 *     (source key) and the amount, not from the fact id, so a re-upload, a
 *     replay, a rule update that re-reads the same message under a new rule
 *     (a new fact id) or the wallet-read sweep never adds it twice.
 *   - Only for a fact whose instrument is linked to one of the user's cards.
 *   - It never edits an estimated row and is left OUT of the card's
 *     total_points_earned (see index.js): a statement credit usually pays out
 *     the points that the spends already estimated, so adding both would count
 *     them twice. It is returned separately as credited_points.
 */

const ISSUER_CREDIT_REASON = 'issuer credit';

const CREDIT_SQL = `
  INSERT INTO points_ledger
    (profile_id, user_card_id, delta_points, reason, state, occurred_at, client_mutation_id)
  SELECT f.profile_id, i.user_card_id, (a.value->>'minor')::numeric, $3, 'confirmed',
         COALESCE(f.occurred_at, f.observed_at),
         md5('reward-credit:' || f.source_key || ':' || (a.value->>'minor'))::uuid
    FROM sms_v2_facts f
    JOIN sms_v2_instruments i ON i.profile_id = f.profile_id AND i.instrument_id = f.instrument_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(f.payload->'amounts', '[]'::jsonb)) AS a(value)
   WHERE f.profile_id = $1
     AND f.fact_type = 'reward'
     AND a.value->>'role' = 'points_earned'
     AND CASE WHEN (a.value->>'minor') ~ '^[0-9]+$' THEN (a.value->>'minor')::numeric > 0 ELSE false END
     AND i.user_card_id IS NOT NULL
     AND ($2::text[] IS NULL OR f.fact_id = ANY($2::text[]))
     AND ($4::uuid IS NULL OR i.user_card_id = $4::uuid)
  ON CONFLICT (profile_id, client_mutation_id) WHERE client_mutation_id IS NOT NULL DO NOTHING`;

/**
 * Writes the credits for `factIds` (or, with no ids, for every reward fact of
 * the profile, optionally narrowed to one card). Returns how many rows were
 * added. Never throws past its savepoint: a credit that cannot be written must
 * not fail the upload or the wallet read that triggered it.
 */
async function creditRewardFacts(client, profileId, { factIds = null, userCardId = null } = {}) {
  if (Array.isArray(factIds) && factIds.length === 0) return 0;
  await client.query('SAVEPOINT reward_credits');
  try {
    const result = await client.query(CREDIT_SQL, [
      profileId, factIds && factIds.length ? factIds : null, ISSUER_CREDIT_REASON, userCardId,
    ]);
    await client.query('RELEASE SAVEPOINT reward_credits');
    return result.rowCount || 0;
  } catch (err) {
    await client.query('ROLLBACK TO SAVEPOINT reward_credits');
    await client.query('RELEASE SAVEPOINT reward_credits');
    console.warn('reward credits deferred', err && err.code ? err.code : 'error');
    return 0;
  }
}

module.exports = { creditRewardFacts, ISSUER_CREDIT_REASON, CREDIT_SQL };
