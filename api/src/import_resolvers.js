const { normalizeMerchant } = require('./reward_math');
const { inferBuiltinCategory } = require('./merchant_category');
const { extractCreditLimit } = require('./card_limit_parser');
const { extractDueDate, extractLast4 } = require('./due_date_parser');

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
 * Nothing here GUESSES a card. The card resolver returns a confident answer
 * or null; the SMS import path deliberately keeps an unresolved cardless
 * transaction rather than blocking the user's spending history behind a
 * review queue. Category resolution is separate: it uses the strongest
 * available merchant evidence and falls back to the explicit `other`
 * category when no specific category can be proven. Attaching a transaction
 * to the wrong card is worse than attaching it to none: it corrupts that
 * card's cap state, reward total, and recommendations.
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
function cardTypeForInstrument(instrument) {
  if (instrument === 'credit_card') return 'credit';
  if (instrument === 'debit_card') return 'debit';
  return null;
}

/**
 * Resolve only a card whose catalogue type agrees with the payment evidence.
 *
 * The last four digits are not globally unique across a wallet. In
 * particular, a debit card and a credit card can share them. Matching only on
 * issuer + last4 therefore lets a debit-card SMS land on a credit card (or
 * vice versa), which then poisons the wrong card's history. The parser's
 * instrument is the authoritative discriminator whenever it is known.
 */
async function resolveUserCardForImport(client, userId, {
  last4,
  patternIssuerId,
  instrument,
  messageText,
}) {
  const cardType = cardTypeForInstrument(instrument);
  if (last4 && /^[0-9]{4}$/.test(last4)) {
    const byLast4 = await client.query(
      `SELECT uc.id
         FROM user_cards uc
         JOIN card_products cp ON cp.id = uc.card_product_id
        WHERE uc.profile_id = $1 AND uc.is_archived = false AND uc.last4 = $2
          AND ($3::uuid IS NULL OR cp.issuer_id = $3::uuid)
          AND ($4::text IS NULL OR cp.card_type::text = $4::text)`,
      [userId, last4, patternIssuerId || null, cardType]
    );
    if (byLast4.rows.length === 1) {
      return {
        userCardId: byLast4.rows[0].id,
        basis: patternIssuerId ? `issuer+last4:${last4}` : `last4:${last4}`,
      };
    }
    // Two or more matches: ambiguous. Deliberately does NOT fall through to
    // the issuer-only heuristic — last4 is the stronger signal, and if it
    // can't decide, a weaker signal has no business overruling it.
    if (byLast4.rows.length > 1) return null;
    // If the parser pattern had no issuer, a unique last4 is still useful.
    // When an issuer is known and no card of that issuer has this last4,
    // don't attach the SMS to a same-number card from another bank. A
    // product-name match below is still allowed: historical statement SMS
    // often omit the suffix, while a named product such as MoneyBack+ is
    // strong evidence when it resolves to exactly one owned card.
  }

  // Historical statement reminders are not always parser-pattern matches,
  // and some omit the last four digits entirely. When the SMS names a
  // distinctive product, use it as a second independent card signal. The
  // query deliberately requires one matching owned card and ignores generic
  // words (bank/card/credit/network) so an issuer-wide reminder cannot be
  // attached to an arbitrary card.
  if (messageText) {
    const byProduct = await client.query(
      `SELECT uc.id
         FROM user_cards uc
         JOIN card_products cp ON cp.id = uc.card_product_id
        WHERE uc.profile_id = $1
          AND uc.is_archived = false
          AND ($2::text IS NULL OR cp.card_type::text = $2::text)
          AND ($3::uuid IS NULL OR cp.issuer_id = $3::uuid)
          AND EXISTS (
            SELECT 1
              FROM regexp_split_to_table(lower(cp.name), '[^a-z0-9]+') AS tokens(product_token)
             WHERE length(product_token) >= 5
               AND product_token NOT IN ('credit', 'debit', 'cards', 'card', 'bank', 'visa', 'rupay', 'mastercard')
               AND position(product_token in regexp_replace(lower($4), '[^a-z0-9]', '', 'g')) > 0
          )`,
      [userId, cardType, patternIssuerId || null, messageText]
    );
    if (byProduct.rows.length === 1) {
      return { userCardId: byProduct.rows[0].id, basis: 'product-name' };
    }
  }

  // If a suffix was present but did not resolve, do not weaken the evidence
  // to issuer-only matching. A same-issuer card without that suffix may be a
  // different physical card.
  if (last4 && /^[0-9]{4}$/.test(last4) && patternIssuerId) return null;

  if (patternIssuerId) {
    const byIssuer = await client.query(
      `SELECT uc.id FROM user_cards uc
         JOIN card_products cp ON cp.id = uc.card_product_id
        WHERE uc.profile_id = $1 AND uc.is_archived = false AND cp.issuer_id = $2
          AND ($3::text IS NULL OR cp.card_type::text = $3::text)`,
      [userId, patternIssuerId, cardType]
    );
    if (byIssuer.rows.length === 1) {
      return { userCardId: byIssuer.rows[0].id, basis: 'sole-card-for-issuer' };
    }
  }

  return null;
}

/**
 * Validate a caller-supplied card override before it reaches the transaction
 * writer. The import endpoint accepts an override for backup imports and for
 * an already-selected card in the UI, but it must not be allowed to cross the
 * credit/debit boundary established by the SMS itself.
 */
async function userCardMatchesInstrument(client, userId, userCardId, instrument) {
  const cardType = cardTypeForInstrument(instrument);
  if (!cardType || !userCardId) return true;
  const result = await client.query(
    `SELECT uc.id
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.id = $1 AND uc.profile_id = $2 AND uc.is_archived = false
        AND cp.card_type::text = $3::text`,
    [userCardId, userId, cardType]
  );
  return result.rows.length === 1;
}

/**
 * Fill a missing card limit from an explicit bank SMS.
 *
 * This is deliberately additive only: a value entered by the user, or one
 * already learned from an earlier alert, is never silently overwritten. The
 * card must also resolve unambiguously by last4/issuer; a limit from an
 * issuer-wide alert must not be assigned to the wrong card.
 */
async function syncCreditLimitFromSms(client, userId, { body, patternIssuerId }) {
  const detected = extractCreditLimit(body);
  if (!detected) return null;

  const card = await resolveUserCardForImport(client, userId, {
    last4: detected.last4,
    patternIssuerId,
    instrument: 'credit_card',
  });
  if (!card) {
    return { detected, updated: false, reason: 'card_not_unambiguous' };
  }

  const updated = await client.query(
    `UPDATE user_cards
        SET credit_limit_inr = $1
      WHERE id = $2
        AND profile_id = $3
        AND is_archived = false
        AND credit_limit_inr IS NULL
      RETURNING id`,
    [detected.amountInr, card.userCardId, userId],
  );

  return {
    detected,
    updated: updated.rowCount > 0,
    userCardId: card.userCardId,
    basis: card.basis,
  };
}

/**
 * Learn a card's recurring payment due day from an explicit issuer alert.
 *
 * This is additive and conservative: it requires both an explicit due-date
 * phrase and an unambiguous card match. Existing user-entered data is not
 * overwritten by a later alert.
 */
async function syncDueDayFromSms(client, userId, { body, patternIssuerId }) {
  const detected = extractDueDate(body);
  if (!detected) return null;

  const card = await resolveUserCardForImport(client, userId, {
    last4: extractLast4(body),
    patternIssuerId,
    instrument: 'credit_card',
    messageText: body,
  });
  if (!card) return { detected, updated: false, reason: 'card_not_unambiguous' };

  const updated = await client.query(
    `UPDATE user_cards
        SET due_day = $1
      WHERE id = $2
        AND profile_id = $3
        AND is_archived = false
        AND due_day IS NULL
      RETURNING id`,
    [detected.day, card.userCardId, userId],
  );

  return {
    detected,
    updated: updated.rowCount > 0,
    userCardId: card.userCardId,
    basis: card.basis,
  };
}

/**
 * What category a parsed merchant name belongs to.
 *
 * Six sources, best evidence first:
 *
 *   1. `merchants` (VPA-keyed, verified), when the message carried a
 *      VPA and the record is published.
 *   2. `mcc_categories`, when the message carried an MCC. Rare from SMS,
 *      normal from a statement import.
 *   3. The user's own non-Other history for this merchant. This stabilizes
 *      repeated local businesses without allowing an earlier unknown
 *      fallback to become a permanent misclassification.
 *   4. `merchant_category_rules` — the shipped name-keyed map (0039).
 *   5. A high-confidence built-in India-focused fallback map.
 *   6. The explicit `other` category, so a successful spend is never left
 *      uncategorized merely because its merchant is new.
 *
 * Returns a category id or null only when the reference data itself is
 * unavailable. An unknown merchant resolves to the explicit `other` bucket;
 * it is better to show honest "Other" than to show an empty category or to
 * invent a specific category.
 */
async function resolveCategoryForImport(client, userId, { merchantName, vpa, mcc, messageText }) {
  const normalized = normalizeMerchant(merchantName);

  // 1. Verified VPA record.
  if (vpa) {
    const merchant = await client.query(
      `SELECT category_id FROM merchants
        WHERE vpa = $1 AND is_published AND category_id IS NOT NULL`,
      [vpa]
    );
    if (merchant.rows[0]) return merchant.rows[0].category_id;
  }

  // 2. MCC.
  if (mcc && /^[0-9]{4}$/.test(mcc)) {
    const byMcc = await client.query(
      `SELECT category_id FROM mcc_categories WHERE mcc = $1 AND category_id IS NOT NULL`,
      [mcc]
    );
    if (byMcc.rows[0]) return byMcc.rows[0].category_id;
  }

  // 3. The user's own non-Other history for this VPA. This keeps a personal
  // merchant stable even when banks vary the display name in their SMS.
  if (vpa) {
    const ownVpa = await client.query(
      `SELECT t.category_id, COUNT(*) AS n
         FROM transactions t
         JOIN spend_categories prior_category ON prior_category.id = t.category_id
        WHERE t.profile_id = $1
          AND t.merchant_vpa = $2
          AND prior_category.slug <> 'other'
          AND t.status = 'active'
        GROUP BY t.category_id
        ORDER BY n DESC
        LIMIT 1`,
      [userId, vpa]
    );
    if (ownVpa.rows[0]) return ownVpa.rows[0].category_id;
  }

  // 4. The user's own non-Other history for this merchant. A prior fallback
  // to `Other` is intentionally excluded so it cannot permanently block a
  // later verified VPA/MCC or merchant-rule match.
  if (normalized) {
    const own = await client.query(
      `SELECT t.category_id, COUNT(*) AS n
         FROM transactions t
         JOIN spend_categories prior_category ON prior_category.id = t.category_id
        WHERE t.profile_id = $1
          AND t.category_id IS NOT NULL
          AND prior_category.slug <> 'other'
          AND t.status = 'active'
          AND regexp_replace(lower(coalesce(t.merchant_name, '')), '[^a-z0-9]', '', 'g') = $2
        GROUP BY t.category_id
        ORDER BY n DESC
        LIMIT 1`,
      [userId, normalized]
    );
    if (own.rows[0]) return own.rows[0].category_id;
  }

  // 5. Shipped name-keyed map. Patterns are stored already-normalized, so
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

    const builtinHint = inferBuiltinCategory(merchantName);
    if (builtinHint) {
      const builtin = await client.query(
        `SELECT id FROM spend_categories WHERE slug = $1 LIMIT 1`,
        [builtinHint.slug]
      );
      if (builtin.rows[0]) return builtin.rows[0].id;
    }
  }

  // Some bank templates parse the amount/card/date but omit a merchant
  // capture even though the merchant is plainly present in the SMS body.
  // Use the body only for the conservative built-in rules; do not use it for
  // the user's history, VPA lookup, or admin rules because those require a
  // real merchant key and must never learn from unrelated bank wording.
  if (!inferBuiltinCategory(merchantName) && messageText) {
    const builtinFromBody = inferBuiltinCategory(messageText);
    if (builtinFromBody) {
      const builtin = await client.query(
        `SELECT id FROM spend_categories WHERE slug = $1 LIMIT 1`,
        [builtinFromBody.slug]
      );
      if (builtin.rows[0]) return builtin.rows[0].id;
    }
  }

  // Every successful spend belongs somewhere in the reporting taxonomy. Do
  // not leave a valid transaction with category_id NULL just because its
  // merchant is a small local business or a new UPI handle. This is a safe
  // fallback: it does not claim to know the business category, and it keeps
  // totals exact while allowing future rules/history to improve the label.
  const other = await client.query(
    `SELECT id FROM spend_categories WHERE slug = 'other' LIMIT 1`
  );
  return other.rows[0]?.id || null;
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

module.exports = {
  resolveUserCardForImport,
  userCardMatchesInstrument,
  syncCreditLimitFromSms,
  syncDueDayFromSms,
  resolveCategoryForImport,
  fileForReview,
};
