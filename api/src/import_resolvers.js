const { normalizeMerchant } = require('./reward_math');

/**
 * Resolving the two things a parsed bank message does NOT tell us: which of
 * the user's cards it belongs to, and what kind of spend it was.
 *
 * Both gaps used to be filled by asking the user, once per message. That is
 * why no transaction was ever captured automatically — the import routes
 * required a caller-supplied `userCardId`, and every SMS and every
 * forwarded email needed a human to tap a card for it. An SMS backfill of a
 * few thousand messages was a few thousand taps, so in practice nobody
 * backfilled, and live capture only worked while the app was open and
 * someone was watching.
 *
 * Nothing here GUESSES. Each resolver returns a confident answer or null,
 * and a null routes the message to `needs_review_items` — the table that
 * already exists precisely so imported data is never silently dropped OR
 * silently invented. Attaching a transaction to the wrong card is worse
 * than attaching it to none: it corrupts that card's cap state, its reward
 * total, and every recommendation made against it afterwards.
 */

/**
 * Which of the user's cards a parsed message belongs to.
 *
 * Two signals, tried in order of how much they prove:
 *
 *   1. `last4`, when the parser extracted it and exactly ONE active card
 *      matches. Exactly one is the whole condition — two cards ending 4321
 *      is uncommon but entirely possible, and picking either would be a
 *      coin flip on data that then poisons cap state.
 *   2. The issuer behind the matched parser pattern, when the user holds
 *      exactly ONE active card from that issuer. An HDFC SMS for someone
 *      with a single HDFC card is unambiguous even with no last4; the same
 *      SMS for someone with three HDFC cards is not.
 *
 * Returns `{ userCardId, basis }` or null. `basis` is carried so the caller
 * can record HOW the match was made — a user who finds a mis-attributed
 * transaction deserves to see why the app thought it belonged there.
 */
async function resolveUserCardForImport(client, userId, { last4, patternIssuerId }) {
  if (last4 && /^[0-9]{4}$/.test(last4)) {
    const byLast4 = await client.query(
      `SELECT id FROM user_cards
        WHERE profile_id = $1 AND is_archived = false AND last4 = $2`,
      [userId, last4]
    );
    if (byLast4.rows.length === 1) {
      return { userCardId: byLast4.rows[0].id, basis: `last4:${last4}` };
    }
    // Two or more matches: ambiguous. Deliberately does NOT fall through to
    // the issuer heuristic — last4 is the stronger signal, and if it can't
    // decide, a weaker signal has no business overruling it.
    if (byLast4.rows.length > 1) return null;
  }

  if (patternIssuerId) {
    const byIssuer = await client.query(
      `SELECT uc.id FROM user_cards uc
         JOIN card_products cp ON cp.id = uc.card_product_id
        WHERE uc.profile_id = $1 AND uc.is_archived = false AND cp.issuer_id = $2`,
      [userId, patternIssuerId]
    );
    if (byIssuer.rows.length === 1) {
      return { userCardId: byIssuer.rows[0].id, basis: 'sole-card-for-issuer' };
    }
  }

  return null;
}

/**
 * What category a parsed merchant name belongs to.
 *
 * Four sources, best evidence first:
 *
 *   1. The user's OWN past choice for this merchant. If they have already
 *      told us that "SWIGGY*ORDER" is dining — by editing a transaction or
 *      quick-adding one — that is better evidence than any shipped table,
 *      and it means a correction sticks instead of being re-guessed wrong
 *      every month.
 *   2. `merchants` (VPA-keyed, crowdsourced), when the message carried a
 *      VPA and the record is published.
 *   3. `mcc_categories`, when the message carried an MCC. Rare from SMS,
 *      normal from a statement import.
 *   4. `merchant_category_rules` — the shipped name-keyed map (0039).
 *
 * Returns a category id or null. Null means uncategorized, which is honest:
 * the user can set it, and the reward math already treats an unknown
 * category as "no bonus rule matched" rather than assuming one.
 */
async function resolveCategoryForImport(client, userId, { merchantName, vpa, mcc }) {
  const normalized = normalizeMerchant(merchantName);

  // 1. The user's own history for this merchant.
  if (normalized) {
    const own = await client.query(
      `SELECT category_id, COUNT(*) AS n
         FROM transactions
        WHERE profile_id = $1
          AND category_id IS NOT NULL
          AND status = 'active'
          AND regexp_replace(lower(coalesce(merchant_name, '')), '[^a-z0-9]', '', 'g') = $2
        GROUP BY category_id
        ORDER BY n DESC
        LIMIT 1`,
      [userId, normalized]
    );
    if (own.rows[0]) return own.rows[0].category_id;
  }

  // 2. Crowdsourced VPA record.
  if (vpa) {
    const merchant = await client.query(
      `SELECT category_id FROM merchants
        WHERE vpa = $1 AND is_published AND category_id IS NOT NULL`,
      [vpa]
    );
    if (merchant.rows[0]) return merchant.rows[0].category_id;
  }

  // 3. MCC.
  if (mcc && /^[0-9]{4}$/.test(mcc)) {
    const byMcc = await client.query(
      `SELECT category_id FROM mcc_categories WHERE mcc = $1 AND category_id IS NOT NULL`,
      [mcc]
    );
    if (byMcc.rows[0]) return byMcc.rows[0].category_id;
  }

  // 4. Shipped name-keyed map. Patterns are stored already-normalized, so
  // this is a plain substring test against the normalized merchant, and
  // `priority` is what lets 'amazonpay' (wallet) beat 'amazon' (online).
  if (normalized) {
    const byName = await client.query(
      `SELECT category_id FROM merchant_category_rules
        WHERE is_active AND position(pattern in $1) > 0
        ORDER BY priority ASC, length(pattern) DESC
        LIMIT 1`,
      [normalized]
    );
    if (byName.rows[0]) return byName.rows[0].category_id;
  }

  return null;
}

/**
 * Files a message we could parse but could not confidently attribute to a
 * card, so it lands in the D4 review queue instead of being dropped or
 * guessed at.
 *
 * `needs_review_items` has existed since 0004 for exactly this, and its
 * `suggested_*` columns carry everything the parser DID work out, so the
 * review screen can show a one-tap "yes, that card" rather than making the
 * user re-enter an amount the app already knows.
 */
async function fileForReview(client, userId, { source, rawText, sender, parseError, amount, merchant, receivedAt }) {
  const inserted = await client.query(
    `INSERT INTO needs_review_items
       (profile_id, source, raw_text, sender, parse_error, suggested_amount, suggested_merchant, received_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, COALESCE($8, now()))
     RETURNING id`,
    [userId, source, rawText, sender || null, parseError || null, amount ?? null, merchant || null, receivedAt || null]
  );
  return inserted.rows[0].id;
}

module.exports = { resolveUserCardForImport, resolveCategoryForImport, fileForReview };
