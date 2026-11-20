'use strict';

// GET /user-cards rebuilt every card's cap and milestone state, and swept the bank's points credits, on EVERY read,
// holding the same per-account lock as an SMS upload. For the owner's 10 cards that was 4-6 s of database work per
// wallet read (measured 20 Nov 2026 on production), and a read had to wait for any upload in progress.
//
// The rebuild is a pure function of its inputs: the card row, the card product's rules (data_version), the card's
// transactions, the day (periods are keyed on the India day for v2 cards and on CURRENT_DATE for v1), and it writes
// cap_states / milestone_states. This gate fingerprints exactly those inputs AND the stored results, and lets the
// read skip a card only when nothing changed since that card was last rebuilt on this server. Any change, including
// one written by another code path (an upload, an edit, a remap, a hand repair), changes the fingerprint, so the card
// is rebuilt on that read exactly as before. The answer is therefore the same as rebuilding every time; only work
// whose result would be identical is skipped.
//
// The credit sweep is gated the same way on what it reads: the profile's reward facts, which card each account is
// linked to, and the credit rows already written (a removed credit row is put back, as before).
//
// Marks live in this process only. A restart, another API instance or an evicted entry just means one full rebuild,
// which is what every read did before. A mark is recorded only after the read's transaction committed.

const CARD_FINGERPRINT_SQL = `
  SELECT uc.id::text AS id,
         concat_ws('|',
           uc.updated_at::text, cp.updated_at::text, cp.data_version::text,
           t.n, t.h, cs.n, cs.h, ms.n, ms.h,
           to_char(clock_timestamp() AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD'),
           CURRENT_DATE::text) AS fp
    FROM user_cards uc
    JOIN card_products cp ON cp.id = uc.card_product_id
    LEFT JOIN LATERAL (
      SELECT count(*)::text AS n, coalesce(sum(hashtextextended(x.id::text || '@' || x.updated_at::text, 0)), 0)::text AS h
        FROM transactions x WHERE x.profile_id = uc.profile_id AND x.user_card_id = uc.id) t ON true
    LEFT JOIN LATERAL (
      SELECT count(*)::text AS n, coalesce(sum(hashtextextended(c::text, 0)), 0)::text AS h
        FROM cap_states c WHERE c.user_card_id = uc.id) cs ON true
    LEFT JOIN LATERAL (
      SELECT count(*)::text AS n, coalesce(sum(hashtextextended(m::text, 0)), 0)::text AS h
        FROM milestone_states m WHERE m.user_card_id = uc.id) ms ON true
   WHERE uc.profile_id = $1 AND uc.is_archived = false`;

const CREDIT_FINGERPRINT_SQL = `
  SELECT concat_ws('|',
    (SELECT count(*)::text || ':' || coalesce(sum(hashtextextended(f.fact_id, 0)), 0)::text
       FROM sms_v2_facts f WHERE f.profile_id = $1 AND f.fact_type = 'reward'),
    (SELECT count(*)::text || ':' || coalesce(sum(hashtextextended(i.instrument_id::text || ':' || coalesce(i.user_card_id::text, ''), 0)), 0)::text
       FROM sms_v2_instruments i WHERE i.profile_id = $1),
    (SELECT count(*)::text || ':' || coalesce(sum(hashtextextended(coalesce(p.client_mutation_id::text, p.id::text), 0)), 0)::text
       FROM points_ledger p WHERE p.profile_id = $1 AND p.reason = $2)) AS fp`;

/** Map of active card id -> fingerprint of everything its rebuild reads and writes. */
async function cardFingerprints(client, profileId) {
  const r = await client.query(CARD_FINGERPRINT_SQL, [profileId]);
  return new Map(r.rows.map((row) => [row.id, row.fp]));
}

/** Fingerprint of everything the bank-credit sweep reads and writes for the profile. */
async function creditFingerprint(client, profileId, creditReason) {
  const r = await client.query(CREDIT_FINGERPRINT_SQL, [profileId, creditReason]);
  return r.rows[0] ? r.rows[0].fp : null;
}

function createReadGate({ maxEntries = 50000 } = {}) {
  const marks = new Map();
  const remember = (key, value) => {
    marks.delete(key);
    marks.set(key, value);
    while (marks.size > maxEntries) marks.delete(marks.keys().next().value);
  };
  return {
    /** The cards whose fingerprint differs from the last rebuild here (all of them the first time). */
    staleCards(profileId, fingerprints) {
      return [...fingerprints].filter(([id, fp]) => marks.get(`c|${profileId}|${id}`) !== fp).map(([id]) => id);
    },
    creditsStale(profileId, fp) {
      return fp == null || marks.get(`r|${profileId}`) !== fp;
    },
    /** Call only after the transaction that did (or confirmed) the work committed. */
    commit(profileId, { cards = null, credits = null } = {}) {
      if (cards) for (const [id, fp] of cards) remember(`c|${profileId}|${id}`, fp);
      if (credits != null) remember(`r|${profileId}`, credits);
    },
    forget(profileId) {
      for (const key of [...marks.keys()]) if (key.includes(`|${profileId}`)) marks.delete(key);
    },
    get size() { return marks.size; },
  };
}

module.exports = { cardFingerprints, creditFingerprint, createReadGate, CARD_FINGERPRINT_SQL, CREDIT_FINGERPRINT_SQL };
