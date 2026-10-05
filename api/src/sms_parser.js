/**
 * UA-5.3 — SMS-to-transaction-fields parsing engine.
 *
 * Pure function: given a `parser_patterns` row (regex + field_map) and a raw
 * SMS body, extract structured transaction fields — or return a "no match"
 * result. Never fabricates a guess: any regex miss or unparseable numeric
 * field is a failure, not a best-effort partial transaction.
 *
 * field_map is jsonb like {"amount": 1, "merchant": 2, "last4": 3, "date": 4}
 * mapping a known field name -> capture group index (1-based, matching JS
 * regex exec() group indexing) in `regex`. Only "amount", "merchant",
 * "last4", "date", "instrument", "reference" and "direction" are recognized fields; anything else in field_map is
 * ignored rather than erroring, so a pattern can carry forward-compatible
 * extra keys without breaking older parser code.
 */

const KNOWN_FIELDS = ['amount', 'merchant', 'last4', 'date', 'instrument', 'reference', 'direction', 'mcc'];
const MAX_MESSAGE_LENGTH = 20000;

// OTP/security alerts can contain the same words as a transaction alert
// ("txn", "INR", "card ending") but must never become spending records.
// Keep this check before admin-configured patterns so a broad pattern cannot
// accidentally turn an OTP into a transaction.
function isSecurityOrOtpMessage(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:otp|one[-\s]?time password|verification code|security code|cvv|pin)\b/.test(text)
    || /\b(?:do not|don't|never)\s+share\b/.test(text)
    || /\bvalid\s+(?:for|till|until)\b/.test(text);
}

function isRejectedTransaction(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:declined|failed|failure|reversed|reversal|refund(?:ed)?|cancelled|canceled|credited)\b/.test(text);
}

// These alerts contain an amount and a card number but do not describe a
// purchase. They must be rejected before configured patterns and before the
// built-in fallbacks, otherwise a credit-card due reminder becomes spending.
function isNonTransactionAlert(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:payment|amount|minimum)\s+due\b/.test(text)
    || /\b(?:statement|bill)\b[\s\S]{0,40}\b(?:generated|ready|available)\b/.test(text)
    || /\b(?:new\s+)?pin\b[\s\S]{0,40}\b(?:generated|created|set)\b/.test(text)
    || /\b(?:card|credit\s+card)\b[\s\S]{0,50}\b(?:dispatched|delivered|activated)\b/.test(text)
    // Card offers often say "Spend ₹15,000, get ₹250" and include the
    // masked card number. That is an offer condition, not a purchase alert.
    || /\bspend\s*(?:₹|rs\.?|inr)\s*[\d,]+[\s\S]{0,50}\b(?:get|earn|cashback|reward|voucher)\b/.test(text)
    || /\b(?:cashback|reward|voucher|offer|eligible|campaign)\b[\s\S]{0,80}\b(?:spend|card)\b/.test(text);
}

// Bank-account UPI alerts often contain a four-digit account suffix. That
// suffix is not a card last-4, and a configured pattern must not be allowed to
// turn the alert into a credit-card transaction just because it mapped one of
// its capture groups to `last4` or `instrument`.
function isBankAccountUpiMessage(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:upi|a\/?c\.?|account)\b/.test(text)
    && /\b(?:debit(?:ed)?|paid|spent|sent|transferred)\b/.test(text)
    && !/\b(?:credit|debit)\s+card\b/.test(text);
}

// An account debit without an explicit UPI rail is not enough evidence of a
// purchase. It may be a bank transfer, bill payment, cash withdrawal, or a
// beneficiary transfer. Counting it as consumer spend silently inflates the
// report, so it is sent to the on-device confirmation queue instead.
function isAmbiguousAccountDebit(body) {
  const text = String(body || '').toLowerCase();
  return isBankAccountUpiMessage(text) && !/\bupi\b/.test(text);
}

function inferInstrument(body, hasLast4) {
  const text = String(body || '').toLowerCase();
  if (/\bdebit\s+card\b/.test(text)) return 'debit_card';
  // ATM/cash-withdrawal alerts commonly say only "Card x1234" and identify
  // the card as DC in the fraud footer. They are not credit-card purchases.
  if (/\b(?:atm|withdrawn|cash\s+withdrawal)\b/.test(text) && !/\bcredit\s+card\b/.test(text)) return 'debit_card';
  if (/\bcredit\s+card\b/.test(text) || (hasLast4 && /\bcard\b/.test(text))) return 'credit_card';
  if (/\b(?:upi|a\/?c\.?|account)\b/.test(text) && /\b(?:debit(?:ed)?|paid|spent|sent|transferred)\b/.test(text)) return 'upi_bank';
  return null;
}

function extractMcc(body) {
  const match = String(body || '').match(
    /\b(?:mcc|merchant\s+category(?:\s+code)?)\s*[:#-]?\s*(\d{4})\b/i
  );
  return match ? match[1] : null;
}

function isSuccessfulSpend(body) {
  const text = String(body || '').toLowerCase();
  if (isSecurityOrOtpMessage(text)) return false;
  if (isRejectedTransaction(text)) return false;
  if (isNonTransactionAlert(text)) return false;
  return /\b(?:spent|debited|debit|paid|purchase|purchased|charged|withdrawn|sent|transferred)\b/.test(text);
}

// Paying a credit-card bill is a movement of money between the user's bank
// account and the card, not a new merchant purchase. Some issuers phrase the
// alert as "payment received towards your credit card" and some as an account
// debit towards the card bill. Only the explicit card-payment direction is
// accepted here; a normal purchase made *on* a credit card must remain spend.
function parseBuiltInCardBillPayment(sms) {
  const body = String(sms?.body || '');
  if (isSecurityOrOtpMessage(body)) return { ok: false, reason: 'security_message' };
  const lower = body.toLowerCase();
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_card_bill_payment_match' };

  const towardCard = /\b(?:payment|amount)\b[\s\S]{0,90}\b(?:received|credited)\b[\s\S]{0,90}\btowards?\b[\s\S]{0,50}\bcredit\s+card\b/i.test(body)
    || /\b(?:payment|paid|debited|debit)\b[\s\S]{0,90}\btowards?\b[\s\S]{0,50}\b(?:your\s+)?credit\s+card(?:\s+bill|\s+account)?\b/i.test(body)
    || /\bcredit\s+card\s+(?:bill|payment)\b[\s\S]{0,90}\b(?:received|credited|debited|paid)\b/i.test(body);
  if (!towardCard) return { ok: false, reason: 'no_card_bill_payment_match' };

  const last4Match = body.match(/\b(?:credit\s+card|card)\b[\s\S]{0,50}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|last\s*4|no\.?)\D{0,5}(\d{4})\b/i);
  const instrument = /\b(?:a\/?c\.?|account|savings)\b[\s\S]{0,60}\b(?:debited|debit|paid)\b/i.test(lower)
    ? 'upi_bank'
    : 'other';
  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_card_bill_payment',
    fields: {
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      ...(last4Match ? { last4: last4Match[1] } : {}),
      merchant: 'Credit card bill payment',
      instrument,
      entryKind: 'transfer',
    },
  };
}

function parseBuiltInUpiDebit(sms) {
  const body = String(sms?.body || '');
  if (!isSuccessfulSpend(body)) return { ok: false, reason: 'no_builtin_upi_match' };
  const instrument = inferInstrument(body, false);
  if (instrument !== 'upi_bank') return { ok: false, reason: 'no_builtin_upi_match' };
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_builtin_upi_match' };
  // UPI alerts commonly put the reference in parentheses immediately after
  // the payee ("to ekart (UPI Ref ...)"). Stop before that metadata so it
  // cannot become part of the merchant name.
  const merchantMatch = body.match(/\b(?:to|at|for)\s+([A-Za-z0-9][A-Za-z0-9 ._&@-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl)\b|\s*\(|[.,]|$)/i);
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:upi\s*)?(?:ref(?:erence)?|txn(?:\s*id)?)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);
  return {
    ok: true,
    patternId: null,
    fields: {
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      ...(merchantMatch ? { merchant: merchantMatch[1].trim() } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      ...(extractMcc(body) ? { mcc: extractMcc(body) } : {}),
      instrument,
      entryKind: 'spend',
    },
  };
}

function parseBuiltInCardSpend(sms) {
  const body = String(sms?.body || '');
  if (!isSuccessfulSpend(body)) return { ok: false, reason: 'no_builtin_card_match' };
  const last4Match = body.match(/\b(?:credit|debit)\s+card\s+(?:no\.?\s*)?(\d{4})\b/i)
    || body.match(/\b(?:credit|debit)\s+card\b[\s\S]{0,60}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|\.{3,}|last\s*4|no\.?)\D{0,5}(\d{4})/i)
    || body.match(/\bcard\s+(?:no\.?\s*)?(\d{4})\b/i)
    || body.match(/\bcard\b[\s\S]{0,40}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|\.{3,}|last\s*4|no\.?)\D{0,5}(\d{4})/i);
  if (!last4Match) return { ok: false, reason: 'no_builtin_card_match' };
  const instrument = inferInstrument(body, true);
  if (instrument !== 'credit_card' && instrument !== 'debit_card') return { ok: false, reason: 'no_builtin_card_match' };
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_builtin_card_match' };
  const merchantMatch = body.match(/\b(?:at|to|for)\s+([A-Za-z0-9_][A-Za-z0-9 ._&@-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl)\b|[.,]|$)/i);
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  return {
    ok: true,
    patternId: null,
    fields: {
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      last4: last4Match[1],
      ...(merchantMatch ? { merchant: merchantMatch[1].trim().replace(/^_+/, '') } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(extractMcc(body) ? { mcc: extractMcc(body) } : {}),
      instrument,
      entryKind: 'spend',
    },
  };
}

/**
 * Does `sender` match a pattern's `sender_pattern`? sender_pattern is a
 * plain substring/prefix match (e.g. 'HDFCBK' matching 'VM-HDFCBK-S' or
 * 'AD-HDFCBK'), NOT a regex — these values come from admin-entered short
 * alphanumeric SMS sender IDs, not attacker-controlled input, but treating
 * them as literal text (not compiled as regex) avoids any surprise from a
 * stray regex metacharacter in an admin's typo.
 */
function senderMatches(senderPattern, sender) {
  if (!senderPattern) return true; // no restriction configured
  if (!sender) return false;
  return sender.toUpperCase().includes(senderPattern.toUpperCase());
}

/**
 * Parse one SMS body against one parser_patterns row.
 *
 * @param {{regex: string, field_map: object, sender_pattern?: string}} pattern
 * @param {{body: string, sender?: string}} sms
 * @returns {{ok: true, fields: {amountInr?: number, merchant?: string, last4?: string, date?: string}}
 *          | {ok: false, reason: string}}
 */
function parseSms(pattern, sms) {
  if (!pattern || typeof pattern.regex !== 'string' || !pattern.regex) {
    return { ok: false, reason: 'invalid_pattern' };
  }
  if (!sms || typeof sms.body !== 'string' || !sms.body.trim()) {
    return { ok: false, reason: 'empty_body' };
  }
  if (sms.body.length > MAX_MESSAGE_LENGTH) {
    return { ok: false, reason: 'body_too_long' };
  }
  if (isSecurityOrOtpMessage(sms.body)) {
    return { ok: false, reason: 'security_message' };
  }
  if (!senderMatches(pattern.sender_pattern, sms.sender)) {
    return { ok: false, reason: 'sender_mismatch' };
  }

  let re;
  try {
    re = new RegExp(pattern.regex);
  } catch (err) {
    return { ok: false, reason: 'invalid_regex' };
  }

  const match = re.exec(sms.body);
  if (!match) {
    return { ok: false, reason: 'no_regex_match' };
  }

  const fieldMap = pattern.field_map || {};
  const fields = {};

  for (const fieldName of KNOWN_FIELDS) {
    const groupIndex = fieldMap[fieldName];
    if (groupIndex === undefined || groupIndex === null) continue;
    const raw = match[groupIndex];
    if (raw === undefined) {
      // field_map points at a group the regex doesn't have / didn't
      // capture in this instance — a malformed pattern, not a partial win.
      return { ok: false, reason: `missing_capture_for_${fieldName}` };
    }

    if (fieldName === 'amount') {
      const cleaned = raw.replace(/,/g, '').trim();
      const amount = Number(cleaned);
      if (!Number.isFinite(amount) || amount <= 0) {
        return { ok: false, reason: 'unparseable_amount' };
      }
      fields.amountInr = amount;
    } else if (fieldName === 'last4') {
      const digits = raw.trim();
      if (!/^\d{4}$/.test(digits)) {
        return { ok: false, reason: 'unparseable_last4' };
      }
      fields.last4 = digits;
    } else if (fieldName === 'date') {
      fields.date = raw.trim();
    } else if (fieldName === 'merchant') {
      const merchant = raw.trim();
      if (!merchant) {
        return { ok: false, reason: 'unparseable_merchant' };
      }
      fields.merchant = merchant;
    } else if (fieldName === 'mcc') {
      const mcc = raw.trim();
      if (!/^\d{4}$/.test(mcc)) return { ok: false, reason: 'unparseable_mcc' };
      fields.mcc = mcc;
    } else if (fieldName === 'instrument' || fieldName === 'reference' || fieldName === 'direction') {
      const value = raw.trim();
      if (!value) return { ok: false, reason: `unparseable_${fieldName}` };
      fields[fieldName] = value;
    }
  }

  if (fields.amountInr === undefined) {
    // Amount is the one field every downstream consumer (cap/milestone/
    // points math in POST /transactions) requires — a pattern that doesn't
    // even map "amount" is not usable, regardless of what else it captured.
    return { ok: false, reason: 'no_amount_field_mapped' };
  }

  const direction = String(fields.direction || '').toLowerCase();
  if (direction && /credit|refund|reversal|failed|declin/.test(direction)) {
    return { ok: false, reason: 'not_a_successful_spend' };
  }
  if (!direction && !isSuccessfulSpend(sms.body)) {
    return { ok: false, reason: 'not_a_successful_spend' };
  }
  if (isBankAccountUpiMessage(sms.body)) {
    // Never carry an account suffix into transaction.last4. It could match a
    // user's unrelated card and silently corrupt card attribution.
    delete fields.last4;
    fields.instrument = 'upi_bank';
  } else {
    fields.instrument = fields.instrument || inferInstrument(sms.body, Boolean(fields.last4)) || 'credit_card';
  }
  fields.entryKind = 'spend';
  return { ok: true, fields };
}

/**
 * Try a raw SMS against a list of candidate parser_patterns (already
 * filtered to `channel = 'sms', is_active = true` by the caller's SQL — this
 * function doesn't touch the DB), highest-priority first. `patterns` should
 * be pre-sorted by whatever the caller considers priority (e.g. version
 * DESC); this just returns the first one that matches, or a failure
 * carrying the last-tried reason if none did.
 *
 * @param {Array<object>} patterns
 * @param {{body: string, sender?: string}} sms
 */
function parseConservativeBankSpend(sms) {
  if (!sms || typeof sms.body !== 'string' || !sms.body.trim()) {
    return { ok: false, reason: 'empty_body' };
  }
  if (sms.body.length > MAX_MESSAGE_LENGTH) {
    return { ok: false, reason: 'body_too_long' };
  }

  const body = sms.body.replace(/\s+/g, ' ').trim();
  const lower = body.toLowerCase();

  // These are opposite/non-spend events or secrets. A generic fallback must
  // prefer a missed import over turning any of them into spend.
  if (/\b(otp|one[ -]?time password|verification code|payment due|amount due|minimum due|credited|refund(?:ed)?|reversal|reversed|declined|failed|cancelled)\b/i.test(body)) {
    return { ok: false, reason: 'non_spend_or_sensitive_message' };
  }
  if (!/\b(spent|spend|debited|purchase|purchased|used|transaction)\b/i.test(body)) {
    return { ok: false, reason: 'no_spend_marker' };
  }
  // Current auto-resolution is a credit-card pipeline. Requiring card
  // evidence prevents an account debit/UPI notification from being assigned
  // to an unrelated card just because amount and merchant look plausible.
  if (!/\b(card|credit card)\b/i.test(body)) {
    return { ok: false, reason: 'no_card_marker' };
  }

  const currencyAmount = body.match(/(?:₹|\bINR\b|\bRS\.?)(?:\s*:?\s*)([0-9][0-9,]*(?:\.\d{1,2})?)/i);
  if (!currencyAmount) return { ok: false, reason: 'no_amount_found' };
  const amountInr = Number(currencyAmount[1].replace(/,/g, ''));
  if (!Number.isFinite(amountInr) || amountInr <= 0) {
    return { ok: false, reason: 'unparseable_amount' };
  }

  const fields = { amountInr, instrument: 'credit_card', entryKind: 'spend' };
  const last4 = body.match(/(?:ending|end(?:ing)?\s+in|xx+|x{2,}|card\s*(?:no\.?|number)?\s*[*x-]*)\s*([0-9]{4})\b/i);
  if (last4) fields.last4 = last4[1];

  const merchant = body.match(/\b(?:at|to)\s+([A-Za-z0-9_][A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:on|using|via|ref|txn|avl|available|for\s+card)\b|[.;]|$)/i);
  if (merchant) {
    const value = merchant[1].trim().replace(/^_+/, '').replace(/[.,;:-]+$/, '').trim();
    if (value && !/^(your|card|account|a\/c)$/i.test(value)) fields.merchant = value;
  }

  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  if (dateMatch) fields.date = dateMatch[1];

  return { ok: true, fields, parserKind: 'conservative_fallback' };
}

function patternPriority(pattern, result) {
  const mappedFields = Object.keys(result.fields || {}).length;
  const senderSpecific = pattern.sender_pattern ? 1000 : 0;
  const version = Number(pattern.version) || 0;
  return senderSpecific + mappedFields * 100 + version;
}

function parseSmsAgainstPatterns(patterns, sms) {
  if (isSecurityOrOtpMessage(sms?.body)) {
    return { ok: false, reason: 'security_message' };
  }
  // Run before the generic "credited" rejection: a positive card-payment
  // receipt is intentionally retained as a non-spend transfer.
  const billPayment = parseBuiltInCardBillPayment(sms);
  if (billPayment.ok) return billPayment;
  if (isRejectedTransaction(sms?.body)) {
    return { ok: false, reason: 'not_a_successful_spend' };
  }
  if (isNonTransactionAlert(sms?.body)) {
    return { ok: false, reason: 'not_a_transaction_alert' };
  }
  if (isAmbiguousAccountDebit(sms?.body)) {
    return { ok: false, reason: 'ambiguous_account_debit' };
  }
  const configuredPatterns = Array.isArray(patterns) ? patterns : [];
  let lastReason = configuredPatterns.length > 0 ? 'no_regex_match' : 'no_transaction_match';
  const matches = [];
  for (const pattern of configuredPatterns) {
    const result = parseSms(pattern, sms);
    if (result.ok) {
      matches.push({
        ...result,
        patternId: pattern.id,
        parserKind: 'configured_pattern',
        priority: patternPriority(pattern, result),
      });
      continue;
    }
    lastReason = result.reason;
  }
  if (matches.length > 0) {
    matches.sort((left, right) => right.priority - left.priority);
    const { priority: _, ...best } = matches[0];
    return best;
  }

  const builtin = parseBuiltInUpiDebit(sms);
  if (builtin.ok) return builtin;
  const fallback = parseConservativeBankSpend(sms);
  if (fallback.ok) return { ...fallback, patternId: null };

  // Keep the issuer-independent card parser as a final fallback for card
  // alerts whose wording is outside the conservative generic grammar.
  const cardBuiltin = parseBuiltInCardSpend(sms);
  if (cardBuiltin.ok) return cardBuiltin;
  return { ok: false, reason: lastReason };
}

/**
 * Build the `parser_failures.redacted_shape` value from a raw SMS body:
 * digits -> '#', then collapse letters run of length>=2 to 'X' to avoid
 * leaking merchant/name text, per the table's
 * `redacted_shape_has_no_digits` CHECK and its "no raw content" intent.
 */
function redactSmsShape(body) {
  return String(body || '')
    .replace(/\d/g, '#')
    .replace(/[A-Za-z]{2,}/g, 'X');
}

const MONTHS = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

/**
 * Turns the raw date string a pattern captured into a real Date.
 *
 * `parseSms` deliberately leaves `fields.date` as the bank's own text —
 * there is no single format across Indian issuers, and the parser's job is
 * extraction, not interpretation. This is the interpretation half, kept
 * separate so it stays unit-testable against real strings.
 *
 * DAY-FIRST throughout. Every pattern this feeds is an Indian bank message,
 * where 03/04/26 is 3 April, never 4 March. Guessing month-first would put
 * spend in the wrong month for two-thirds of the year while looking
 * perfectly plausible.
 *
 * Returns null — never a fallback to "today" — on anything it cannot read
 * with confidence, including impossible dates (31 February) and dates in
 * the future, which are always a misparse rather than a real transaction.
 * A wrong date is worse than no date: it files spend in the wrong week and
 * month, and it moves the transaction outside the ±1-day window that
 * cross-channel duplicate detection relies on, so the same swipe gets
 * counted twice.
 *
 * [reference] is the message's own timestamp, used only to resolve a
 * two-digit year and to reject the future. Defaults to now.
 */
function parseTransactionDate(raw, reference = new Date()) {
  if (!raw || typeof raw !== 'string') return null;
  const text = raw.trim();
  if (!text) return null;

  let year = null;
  let month = null;
  let day = null;

  // ISO first: 2026-04-03. Unambiguous, so it never reaches the day-first
  // branches below.
  let m = text.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/);
  if (m) {
    [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])];
  }

  // 03-04-26, 3/4/2026, 03.04.26
  if (year === null) {
    m = text.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2}|\d{4})$/);
    if (m) {
      day = Number(m[1]);
      month = Number(m[2]);
      year = Number(m[3]);
    }
  }

  // 03-Apr-26, 3 Apr 2026, 03Apr26
  if (year === null) {
    m = text.match(/^(\d{1,2})[-\s]?([A-Za-z]{3,})[-\s]?(\d{2}|\d{4})$/);
    if (m) {
      day = Number(m[1]);
      month = MONTHS[m[2].slice(0, 3).toLowerCase()] ?? null;
      year = Number(m[3]);
    }
  }

  // Apr 03, 2026 / Apr 3 2026
  if (year === null) {
    m = text.match(/^([A-Za-z]{3,})[-\s]+(\d{1,2}),?[-\s]+(\d{2}|\d{4})$/);
    if (m) {
      month = MONTHS[m[1].slice(0, 3).toLowerCase()] ?? null;
      day = Number(m[2]);
      year = Number(m[3]);
    }
  }

  if (year === null || month === null || day === null) return null;
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) return null;

  // A two-digit year is this century. Banks do not text about 1926.
  if (year < 100) year += 2000;

  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  const parsed = new Date(year, month - 1, day);
  // Round-trip check: JS rolls 31 February forward into March rather than
  // rejecting it, so an impossible date would otherwise parse "successfully"
  // into the wrong day.
  if (
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  ) {
    return null;
  }

  // A future date is a misparse, not a transaction. One day of slack covers
  // timezone skew between the device, the bank and this server.
  const limit = new Date(reference.getTime() + 24 * 60 * 60 * 1000);
  if (parsed > limit) return null;

  return parsed;
}

module.exports = {
  parseSms,
  parseSmsAgainstPatterns,
  parseConservativeBankSpend,
  parseBuiltInCardBillPayment,
  senderMatches,
  redactSmsShape,
  parseTransactionDate,
  isAmbiguousAccountDebit,
  KNOWN_FIELDS,
};
