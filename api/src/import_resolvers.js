const { normalizeMerchant } = require('./reward_math');
const { inferBuiltinCategory } = require('./merchant_category');
const {
  normalizeMerchantVpa,
  normalizeMerchantName,
  isGenericMerchantName,
} = require('./merchant_bulk_category');
const { extractCreditLimit } = require('./card_limit_parser');
const {
  extractDueDate,
  extractLast4,
  extractStatementDate,
} = require('./due_date_parser');

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
  // Unknown card type requires an exact, unique suffix match across both
  // types. Never fall through to sole-issuer/product heuristics in this case.
  if (instrument === 'other' && !/^[0-9]{4}$/.test(last4 || '')) return null;
  if (last4 && /^[0-9]{4}$/.test(last4)) {
    const byLast4 = await client.query(
      `SELECT uc.id, cp.card_type
         FROM user_cards uc
         JOIN card_products cp ON cp.id = uc.card_product_id
        WHERE uc.profile_id = $1 AND uc.is_archived = false AND uc.last4 = $2
          AND ($3::uuid IS NULL OR cp.issuer_id = $3::uuid)
          AND ($4::text IS NULL OR cp.card_type::text = $4::text)`,
      [userId, last4, patternIssuerId || null, cardType]
    );
    if (byLast4.rows.length === 1) {
      const matchedType = byLast4.rows[0].card_type;
      if (instrument === 'other' && !['credit', 'debit'].includes(matchedType)) return null;
      return {
        userCardId: byLast4.rows[0].id,
        basis: patternIssuerId ? `issuer+last4:${last4}` : `last4:${last4}`,
        ...(instrument === 'other' ? { instrument: matchedType === 'credit' ? 'credit_card' : 'debit_card' } : {}),
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
  if (instrument === 'other') return null;

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

  // Some issuers print the suffix straight after the instrument: "Credit
  // Card 8708 bill", "Debit Card **** 1234". The strict text rule needs a
  // marker ("ending 8708", "XX8708"), so this shape was read as no card at
  // all — the card's own due day could then never be learned from the very
  // message that states it. Only a suffix that belongs to exactly one owned
  // card counts, and the digits must sit directly after the instrument word
  // so a limit ("card limit 5000") can never be read as a card number.
  if (messageText) {
    const directSuffix = /\b(?:credit|debit)\s+card\b[\s:*x]{0,4}(\d{4})\b/i.exec(messageText);
    if (directSuffix) {
      const byDirectSuffix = await client.query(
        `SELECT uc.id
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.profile_id = $1 AND uc.is_archived = false AND uc.last4 = $2
            AND ($3::uuid IS NULL OR cp.issuer_id = $3::uuid)
            AND ($4::text IS NULL OR cp.card_type::text = $4::text)`,
        [userId, directSuffix[1], patternIssuerId || null, cardType]
      );
      if (byDirectSuffix.rows.length === 1) {
        return {
          userCardId: byDirectSuffix.rows[0].id,
          basis: `card-suffix:${directSuffix[1]}`,
        };
      }
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
async function userCardMatchesInstrument(client, userId, userCardId, instrument, smsLast4 = null, patternIssuerId = null) {
  const cardType = cardTypeForInstrument(instrument);
  if (!cardType || !userCardId) return true;
  const result = await client.query(
    `SELECT uc.id
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.id = $1 AND uc.profile_id = $2 AND uc.is_archived = false
         AND cp.card_type::text = $3::text
         AND ($4::text IS NULL OR uc.last4 = $4::text)
         AND ($5::uuid IS NULL OR cp.issuer_id = $5::uuid)`,
    [userCardId, userId, cardType, smsLast4, patternIssuerId]
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
 * An SMS-learned day heals when a newer bill SMS prints a different due
 * day (the issuer may have moved it); user-entered data is not overwritten
 * by a later alert. Card matching must be unambiguous.
 */
async function syncDueDayFromSms(client, userId, {
  body,
  patternIssuerId,
  explicitUserCardId,
  observedAt,
  asOf = new Date(),
}) {
  const detected = extractDueDate(body);
  if (!detected) return null;
  if (observedAt) {
    const observed = new Date(observedAt);
    const today = new Date(asOf);
    if (Number.isNaN(observed.getTime()) || Number.isNaN(today.getTime())) return null;
    const monthIndex = (date) => {
      const parts = new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit',
      }).formatToParts(date);
      return Number(parts.find((part) => part.type === 'year')?.value) * 12
        + Number(parts.find((part) => part.type === 'month')?.value);
    };
    // The printed due day stays true however old the SMS is — most cards'
    // only explicit due-day evidence arrives months before onboarding. Only
    // a future-dated message is nonsense.
    if (monthIndex(today) - monthIndex(observed) < 0) return null;
  }

  const card = explicitUserCardId
    ? (await userCardMatchesInstrument(client, userId, explicitUserCardId, 'credit_card', extractLast4(body))
      ? { userCardId: explicitUserCardId, basis: 'explicit-user-card' }
      : null)
    : await resolveUserCardForImport(client, userId, {
        last4: extractLast4(body),
        patternIssuerId,
        instrument: 'credit_card',
        messageText: body,
      });
  if (!card) return { detected, updated: false, reason: 'card_not_unambiguous' };

  // Due days carry an explicit printed phrase by construction, so a newer
  // bill SMS heals a previously learned (non-user) value the same way
  // statement_day does.
  const updated = await client.query(
    `UPDATE user_cards
        SET due_day = $1,
            due_day_source = 'sms'
      WHERE id = $2
        AND profile_id = $3
        AND is_archived = false
        AND due_day IS DISTINCT FROM $1
        AND (due_day IS NULL
             OR due_day_source <> 'user')
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
 * Learn the recurring statement day from a card-bill SMS.
 *
 * A printed (generation/period-end) date overwrites an SMS-learned day the
 * same way due_day heals; a receive-date fallback may only fill an empty
 * value; a user-entered day is never touched.
 */
async function syncStatementDayFromSms(client, userId, {
  body,
  patternIssuerId,
  observedAt,
  explicitUserCardId,
  asOf = new Date(),
}) {
  // Only the two completed billing cycles are evidence for an arrival-date
  // fallback: a current-month live alert must not win before a newly granted
  // inbox permission has supplied the previous month's history. A printed
  // generation or period-end date, however, is self-dated by its own text —
  // any age teaches it.
  const observed = observedAt && new Date(observedAt);
  const today = new Date(asOf);
  if (!observed || Number.isNaN(observed.getTime()) || Number.isNaN(today.getTime())) return null;
  const monthInIndia = (date) => {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit',
    }).formatToParts(date);
    return Number(parts.find((part) => part.type === 'year')?.value) * 12
      + Number(parts.find((part) => part.type === 'month')?.value);
  };
  const detected = extractStatementDate(body, observedAt);
  if (!detected) return null;
  const evidenceMonth = detected.explicit
    ? detected.date.getFullYear() * 12 + detected.date.getMonth() + 1
    : monthInIndia(observed);
  const monthsAgo = monthInIndia(today) - evidenceMonth;
  if (!detected.explicit && monthsAgo !== 1 && monthsAgo !== 2) return null;

  const card = explicitUserCardId
    ? (await userCardMatchesInstrument(client, userId, explicitUserCardId, 'credit_card', extractLast4(body))
      ? { userCardId: explicitUserCardId, basis: 'explicit-user-card' }
      : null)
    : await resolveUserCardForImport(client, userId, {
        last4: extractLast4(body),
        patternIssuerId,
        instrument: 'credit_card',
        messageText: body,
      });
  if (!card) return { detected, updated: false, reason: 'card_not_unambiguous' };

  // Healing rule: an SMS-learned day follows newer explicit evidence (the
  // issuer may have moved the billing day), a receive-date fallback may only
  // fill an empty value, and a user-entered day is never touched. Equal
  // values no-op rather than churning the change log.
  const updated = await client.query(
    `UPDATE user_cards
        SET statement_day = $1,
            statement_day_source = 'sms'
      WHERE id = $2
        AND profile_id = $3
        AND is_archived = false
        AND statement_day IS DISTINCT FROM $1
        AND (statement_day IS NULL
             OR ($4 AND statement_day_source <> 'user'))
      RETURNING id`,
    [detected.day, card.userCardId, userId, Boolean(detected.explicit)],
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
function normalizedImportText(...values) {
  return values
    .filter((value) => typeof value === 'string' && value.trim())
    .map((value) => String(value).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim())
    .filter(Boolean)
    .join(' ');
}

// User rules are intentionally narrower than the existing bulk-review
// matcher.  A rule is a durable promise about a merchant, so a provider or
// payment rail name must never become the identity of every merchant it
// processes.  Keep this list conservative: adding a name here only prevents
// future automatic matches; it never changes an existing transaction.
const UNSAFE_USER_RULE_NAMES = new Set([
  'razorpay', 'payu', 'cashfree', 'billdesk', 'ccavenue', 'juspay',
  'stripe', 'payment gateway', 'gateway', 'upi', 'upi collect',
  'phonepe', 'paytm', 'bharatpe', 'mobikwik', 'amazon pay',
]);

function normalizeUserMerchantVpa(value) {
  const normalized = normalizeMerchantVpa(value);
  if (!normalized || !normalized.includes('@') || /\s/.test(normalized)) return null;
  return normalized;
}

function normalizeUserMerchantName(value) {
  return normalizeMerchantName(value);
}

function isUnsafeUserMerchantName(value) {
  const normalized = normalizeUserMerchantName(value);
  if (!normalized || isGenericMerchantName(normalized)) return true;
  if (UNSAFE_USER_RULE_NAMES.has(normalized)) return true;
  if (/\b(?:payment\s+)?gateway\b/i.test(normalized)) return true;
  return false;
}

/**
 * Pure V1 matcher for a user's future merchant rules.
 *
 * A VPA is the strongest identity.  When one is present, name rules are not
 * considered at all: two VPAs displayed as the same merchant must remain
 * independent.  Without a VPA, only a complete, non-generic normalized name
 * can match.  The eligibility guard is kept here (rather than in SQL) so SMS,
 * statement and manual callers share exactly the same exclusions.
 */
function isEligibleUserMerchantRuleTransaction(transaction = {}) {
  if (transaction.status && transaction.status !== 'active') return false;
  if ((transaction.entryKind || transaction.entry_kind || 'spend') !== 'spend') return false;
  if (transaction.isIgnored || transaction.is_ignored || transaction.status === 'ignored') return false;
  if (transaction.isSplit || transaction.is_split || transaction.isSplitParent
      || transaction.is_split_parent || transaction.parentTxnId || transaction.parent_txn_id
      || transaction.hasSplits || transaction.has_splits) return false;
  if (transaction.isRefund || transaction.is_refund || transaction.isReversal
      || transaction.is_reversal) return false;
  const transferKind = String(transaction.transferKind || transaction.transfer_kind || '').toLowerCase();
  if (['refund', 'reversal', 'transfer', 'income'].includes(transferKind)) return false;
  return true;
}

function activeUserRule(rule) {
  return rule && (rule.is_active === true || rule.isActive === true || rule.active === true);
}

function ruleVersion(rule) {
  const value = Number(rule?.version);
  return Number.isFinite(value) ? value : 0;
}

function resolveUserMerchantRule(rules, transaction = {}) {
  if (!isEligibleUserMerchantRuleTransaction(transaction) || !Array.isArray(rules)) return null;
  const vpa = normalizeUserMerchantVpa(transaction.vpa ?? transaction.merchantVpa ?? transaction.merchant_vpa);
  const name = normalizeUserMerchantName(transaction.merchantName ?? transaction.merchant_name);
  const basis = vpa ? 'vpa' : (!isUnsafeUserMerchantName(name) ? 'strict_name' : null);
  if (!basis) return null;
  const value = basis === 'vpa' ? vpa : name;
  const matches = rules
    .filter(activeUserRule)
    .filter((rule) => String(rule.match_basis || rule.matchBasis || '') === basis)
    .filter((rule) => (basis === 'vpa'
      ? normalizeUserMerchantVpa(rule.match_value ?? rule.matchValue) === value
      : normalizeUserMerchantName(rule.match_value ?? rule.matchValue) === value))
    .filter((rule) => rule.category_id || rule.categoryId || rule.resolved_category_id)
    .sort((a, b) => ruleVersion(b) - ruleVersion(a)
      || String(b.updated_at || b.updatedAt || '').localeCompare(String(a.updated_at || a.updatedAt || ''))
      || String(a.id || '').localeCompare(String(b.id || '')));
  const rule = matches[0];
  if (!rule) return null;
  return {
    ...rule,
    matchBasis: basis,
    matchValue: value,
    categoryId: rule.resolved_category_id || rule.category_id || rule.categoryId,
    userCategoryId: rule.user_category_id || rule.userCategoryId || null,
  };
}

async function loadActiveUserMerchantRules(client, userId) {
  const [rulesResult, categoriesResult] = await Promise.all([
    client.query(
      `SELECT umr.id, umr.match_basis, umr.match_value, umr.category_id,
              umr.user_category_id, umr.is_active, umr.version, umr.updated_at
         FROM user_merchant_category_rules umr
        WHERE umr.profile_id = $1 AND umr.is_active = true
        ORDER BY umr.version DESC, umr.updated_at DESC, umr.id`,
      [userId],
    ),
    client.query(
      `SELECT id, parent_category_id, parent_user_category_id
         FROM user_categories
        WHERE profile_id = $1`,
      [userId],
    ),
  ]);

  // A custom child can itself belong to another private category. Resolve
  // the complete chain here so import classification agrees with the API's
  // recursive category validation. Cycles are treated as an invalid target
  // and therefore fall back to ordinary classification.
  const categories = new Map(
    categoriesResult.rows.map((row) => [String(row.id), row]),
  );
  const resolvedParent = (categoryId) => {
    const seen = new Set();
    let current = categories.get(String(categoryId));
    while (current) {
      const key = String(current.id);
      if (seen.has(key)) return null;
      seen.add(key);
      if (current.parent_category_id) return String(current.parent_category_id);
      current = current.parent_user_category_id
        ? categories.get(String(current.parent_user_category_id))
        : null;
    }
    return null;
  };

  return rulesResult.rows
    .map((row) => ({
      ...row,
      resolved_category_id: row.user_category_id
        ? resolvedParent(row.user_category_id)
        : row.category_id,
    }))
    .filter((row) => row.resolved_category_id);
}

async function resolveUserMerchantRuleForImport(client, userId, options = {}) {
  if (options.applyUserMerchantRule === false) return null;
  // A reviewed statement/import hint is an explicit source choice and ranks
  // above a remembered merchant rule.
  if (options.categoryHint || options.subcategoryHint
      || options.explicitCategoryId || options.explicitUserCategoryId) return null;
  if (!isEligibleUserMerchantRuleTransaction(options)) return null;
  const vpa = normalizeUserMerchantVpa(options.vpa);
  const name = normalizeUserMerchantName(options.merchantName);
  if (!vpa && isUnsafeUserMerchantName(name)) return null;
  const rules = Array.isArray(options.userMerchantRules)
    ? options.userMerchantRules
    : await loadActiveUserMerchantRules(client, userId);
  return resolveUserMerchantRule(rules, options);
}

function importTermMatches(text, term) {
  const normalizedTerm = String(term || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  if (!normalizedTerm || normalizedTerm.length < 2) return false;
  if (normalizedTerm.includes(' ')) return text.includes(normalizedTerm);
  return text.split(' ').includes(normalizedTerm);
}

/** Resolve a private category/subcategory before public merchant rules. */
async function resolveUserCategoryForImport(client, userId, {
  merchantName,
  messageText,
  categoryHint,
  subcategoryHint,
}) {
  const text = normalizedImportText(
    merchantName,
    messageText,
    categoryHint,
    subcategoryHint,
  );
  if (!text) return null;

  const rows = await client.query(
    `SELECT uc.id, uc.name, uc.slug, uc.parent_category_id,
            uc.parent_user_category_id, uc.match_terms,
            sc.name AS parent_category_name,
            puc.name AS parent_user_category_name
       FROM user_categories uc
       LEFT JOIN spend_categories sc ON sc.id = uc.parent_category_id
       LEFT JOIN user_categories puc ON puc.id = uc.parent_user_category_id
      WHERE uc.profile_id = $1
      ORDER BY uc.created_at, uc.name`,
    [userId],
  );
  if (!rows.rows.length) return null;

  const hintedSubcategory = normalizeMerchant(subcategoryHint || '');
  const hintedCategory = normalizeMerchant(categoryHint || '');
  const candidates = rows.rows
    .map((row) => {
      const name = normalizeMerchant(row.name);
      const slug = normalizeMerchant(String(row.slug || '').replace(/^custom[:_-]?/i, ''));
      const terms = Array.isArray(row.match_terms) ? row.match_terms : [];
      let score = 0;
      if (hintedSubcategory && (hintedSubcategory === name || hintedSubcategory === slug)) score += 1000;
      if (hintedCategory && (hintedCategory === name || hintedCategory === slug)) score += 900;
      if (terms.some((term) => importTermMatches(text, term))) score += 600;
      if (importTermMatches(text, row.name) || importTermMatches(text, slug)) score += 400;
      if (score === 0) return null;
      return { row, score };
    })
    .filter(Boolean)
    .sort((a, b) => b.score - a.score || a.row.id.localeCompare(b.row.id));

  const match = candidates[0]?.row;
  if (!match) return null;
  return {
    categoryId: match.parent_category_id || null,
    userCategoryId: match.id,
    categoryName: match.parent_category_name || match.parent_user_category_name || null,
    userCategoryName: match.name,
  };
}

/** Returns both the reward/reporting parent and the private child. */
async function resolveCategoryAssignmentForImport(client, userId, options) {
  const hasExplicitHint = Boolean(options.categoryHint || options.subcategoryHint);
  // A reviewed category/subcategory hint is an explicit source choice. It is
  // allowed to resolve before a remembered rule; ordinary match_terms from
  // narration are inference and must wait until after the user rule.
  if (hasExplicitHint) {
    const userCategory = await resolveUserCategoryForImport(client, userId, options);
    if (userCategory) return userCategory;
  }

  // Keep the private child attached when the rule points at one.  The base
  // category resolver intentionally returns only a reporting parent for its
  // legacy callers, so resolve the rule at this richer boundary first.
  const userRule = await resolveUserMerchantRuleForImport(client, userId, options);
  if (userRule) {
    return {
      categoryId: userRule.categoryId,
      userCategoryId: userRule.userCategoryId || null,
    };
  }
  if (!hasExplicitHint) {
    const userCategory = await resolveUserCategoryForImport(client, userId, options);
    if (userCategory) return userCategory;
  }
  return {
    categoryId: await resolveCategoryForImport(client, userId, {
      ...options,
      // The rule was already checked above. Supplying an empty list keeps
      // this fallback query-free while preserving the same precedence.
      userMerchantRules: [],
    }),
    userCategoryId: null,
  };
}

async function resolveCategoryForImport(client, userId, {
  merchantName, vpa, mcc, messageText, categoryHint,
  entryKind, status, isSplit, isSplitParent, parentTxnId, hasSplits,
  isRefund, isReversal, transferKind, userMerchantRules,
}) {
  // Explicit category names from a reviewed import/export are stronger than
  // merchant inference. Match only this product's exact built-in label/slug;
  // arbitrary source text still falls through to the existing resolver.
  const normalizedHint = normalizeMerchant(categoryHint || '');
  if (normalizedHint) {
    const hinted = await client.query(
      `SELECT id FROM spend_categories
        WHERE regexp_replace(lower(name), '[^a-z0-9]', '', 'g') = $1
           OR regexp_replace(lower(slug), '[^a-z0-9]', '', 'g') = $1
        LIMIT 1`,
      [normalizedHint]
    );
    if (hinted.rows[0]) return hinted.rows[0].id;
  }

  // Explicit source categories are handled above by categoryHint and by the
  // callers' categoryId/userCategoryId branches.  A future user rule is the
  // next tier and therefore must run before VPA/MCC/history/global inference.
  const userRule = await resolveUserMerchantRuleForImport(client, userId, {
    merchantName,
    vpa,
    entryKind,
    status,
    isSplit,
    isSplitParent,
    parentTxnId,
    hasSplits,
    isRefund,
    isReversal,
    transferKind,
    userMerchantRules,
  });
  if (userRule) return userRule.categoryId;

  const merchantKey = normalizeMerchant(merchantName);
  const normalized = ['unknown', 'unknownmerchant', 'other', 'na', 'notavailable'].includes(merchantKey) ? '' : merchantKey;

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

  if (entryKind === 'investment') {
    const inv = await client.query(
      `SELECT id FROM spend_categories WHERE slug IN ('investments', 'investment') LIMIT 1`
    );
    if (inv.rows[0]) return inv.rows[0].id;
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

/**
 * The IST day-of-month printed for a device-extracted date. Device facts
 * carry an ISO instant; the day the user recognizes is the Asia/Kolkata
 * calendar day, matching how extractStatementDate/extractDueDate derive
 * their `day` from raw SMS text.
 */
function istDayOfMonth(isoDate) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Kolkata',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date(isoDate));
  return Number(parts.find((part) => part.type === 'day')?.value);
}

/**
 * Statement-day learning from a typed device fact. The device already ran
 * extractStatementDate on the raw body and passed only the resulting
 * statementDate — the raw text never rides the facts route. Device facts are
 * always explicit printed dates, so the healing rule is the explicit branch
 * of syncStatementDayFromSms (no arrival-date fallback).
 */
async function syncStatementDayFromFact(client, userId, {
  statementDate,
  last4,
  patternIssuerId,
  explicitUserCardId,
}) {
  if (!statementDate || Number.isNaN(new Date(statementDate).getTime())) return null;
  const day = istDayOfMonth(statementDate);
  if (!day) return null;

  const card = explicitUserCardId
    ? (await userCardMatchesInstrument(client, userId, explicitUserCardId, 'credit_card', last4)
      ? { userCardId: explicitUserCardId, basis: 'explicit-user-card' }
      : null)
    : await resolveUserCardForImport(client, userId, {
        last4,
        patternIssuerId,
        instrument: 'credit_card',
      });
  if (!card) return { detected: { day }, updated: false, reason: 'card_not_unambiguous' };

  const updated = await client.query(
    `UPDATE user_cards
        SET statement_day = $1,
            statement_day_source = 'sms'
      WHERE id = $2
        AND profile_id = $3
        AND is_archived = false
        AND statement_day IS DISTINCT FROM $1
        AND (statement_day IS NULL OR statement_day_source <> 'user')
      RETURNING id`,
    [day, card.userCardId, userId],
  );

  return {
    detected: { day },
    updated: updated.rowCount > 0,
    userCardId: card.userCardId,
    basis: card.basis,
  };
}

/**
 * Due-day learning from a typed device fact. Same healing rule as
 * syncDueDayFromSms: a different printed day from a newer bill heals the
 * SMS-learned value; a user-entered day is never overwritten.
 */
async function syncDueDayFromFact(client, userId, {
  dueDate,
  last4,
  patternIssuerId,
  explicitUserCardId,
}) {
  if (!dueDate || Number.isNaN(new Date(dueDate).getTime())) return null;
  const day = istDayOfMonth(dueDate);
  if (!day) return null;

  const card = explicitUserCardId
    ? (await userCardMatchesInstrument(client, userId, explicitUserCardId, 'credit_card', last4)
      ? { userCardId: explicitUserCardId, basis: 'explicit-user-card' }
      : null)
    : await resolveUserCardForImport(client, userId, {
        last4,
        patternIssuerId,
        instrument: 'credit_card',
      });
  if (!card) return { detected: { day }, updated: false, reason: 'card_not_unambiguous' };

  const updated = await client.query(
    `UPDATE user_cards
        SET due_day = $1,
            due_day_source = 'sms'
      WHERE id = $2
        AND profile_id = $3
        AND is_archived = false
        AND due_day IS DISTINCT FROM $1
        AND (due_day IS NULL OR due_day_source <> 'user')
      RETURNING id`,
    [day, card.userCardId, userId],
  );

  return {
    detected: { day },
    updated: updated.rowCount > 0,
    userCardId: card.userCardId,
    basis: card.basis,
  };
}

module.exports = {
  resolveUserCardForImport,
  userCardMatchesInstrument,
  syncCreditLimitFromSms,
  syncDueDayFromSms,
  syncStatementDayFromSms,
  syncDueDayFromFact,
  syncStatementDayFromFact,
  extractStatementDate,
  resolveUserCategoryForImport,
  resolveCategoryAssignmentForImport,
  resolveCategoryForImport,
  normalizeUserMerchantVpa,
  normalizeUserMerchantName,
  isUnsafeUserMerchantName,
  isEligibleUserMerchantRuleTransaction,
  resolveUserMerchantRule,
  resolveUserMerchantRuleForImport,
  loadActiveUserMerchantRules,
  fileForReview,
};
